# BetPool: live pari-mutuel betting for NIGHTSHIFT

`src/BetPool.sol` is a live (in-play) pari-mutuel betting pool for NIGHTSHIFT's skill games (NIGHT CHESS,
Space Pinball, later games) and the Agent Arena. Spectators bet on side A or side B while a match is
played. Every bet carries a weight that the NIGHTSHIFT server sets from the live game state and signs into
a short-lived ticket. When the match ends, winners get their stake back plus a share of the losing side
proportional to their **weighted** stake, minus a 5% fee taken only from the losing side.

Markets, tickets and results are all EIP-712 messages from the NIGHTSHIFT result signer. Settlement works
like NIGHTSHIFT's live GameEscrow (`0xf460fd9ad76f18414f54a2431870e8a116193489`).

## Layout

| Path | What it is |
| --- | --- |
| `src/BetPool.sol` | The contract (Solidity 0.8.26, OpenZeppelin 5.4.0) |
| `test/BetPool.t.sol` | Unit, flow and fuzz tests |
| `test/BetPool.invariant.t.sol` | Handler-based invariant tests (solvency, conservation, dust bound) |
| `test/DeployBetPool.t.sol` | Deployment configuration and opcode/size checks |
| `test/utils/` | Shared test base (signing helpers) and mock tokens |
| `script/DeployBetPool.s.sol` | Reviewable deploy recipe (`deploy(owner)` is what the tests call) |
| `lib/forge-std`, `lib/openzeppelin` | Vendored as plain files: forge-std v1.11.0, OpenZeppelin Contracts v5.4.0 (`contracts/` only) |

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, the optimizer (200 runs) and `bytecode_hash = "none"`. It enables no
ffi and no filesystem access. Runtime size is about 9.3 KB. The bytecode has no DELEGATECALL, CALLCODE or
SELFDESTRUCT, and every library call is internal, so nothing needs linking.

## Deployment parameters

| Constructor argument | Value |
| --- | --- |
| `owner_` | `0x6c4c78f2c3bdf4c4318fe305fb1c8bc1694d19b5` (the owner named in the brief) |

That is the only constructor argument. The constructor calls no other contract, so it runs on an empty
chain. Everything else is fixed in the bytecode:

| Constant | Value |
| --- | --- |
| `IMD` | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (checked on mainnet: symbol IMD, 18 decimals) |
| `SHIFT` | `0xe5e58e53d0bb204aa62c995a6c8cc8a48e60c3ac` (checked on mainnet: symbol SHIFT, 18 decimals) |
| `FEE_RECIPIENT` | `0x1119d5df2f046bc2d3c0f6279ef2e9ce49422d44`, the NIGHTSHIFT fee splitter (has code on mainnet) |
| `FEE_BPS` | 500 (5% of the losing side, rounded down) |
| Default limits | IMD 0.1 to 500; SHIFT 1,000 to 25,000,000 (whole tokens, 18 decimals) |
| Hard caps on `max` | IMD 10,000; SHIFT 500,000,000 |
| Weight range | 500 to 10,000 bps inclusive |
| `MAX_TICKET_TTL` | 120 s (a ticket's expiry may be at most this far after the block time) |
| `MAX_MARKET_DURATION` | 7 days (latest allowed `closesAt` at creation) |
| `EXPIRY_DELAY` | 24 h after `closesAt`, after which an unsettled market may be expired into refunds |
| EIP-712 domain | name `NightshiftBets`, version `1`, the current chainId, this contract |

Target chain: Ethereum mainnet (chain id 1).

## After launch

| Setting | Setter | What to set | Where the owner gets it |
| --- | --- | --- | --- |
| Result signer | `setSigner(address)` (event `SignerSet`) | NIGHTSHIFT's result-signer address | The NIGHTSHIFT server's signing key. On 2026-10-19 the live GameEscrow's `signer()` returned `0x3B5919586FC04F7e99b450a72bcB14Eeb6977497`. Confirm it is still the intended key before setting it. |

The signer starts unset. Until the owner calls `setSigner`, `createMarket`, `bet` and `settle` revert with
`SignerNotSet()`. No funds can enter before then, so an unset signer cannot strand anything.

## Flow

1. **`createMarket(marketId, token, closesAt, game, sig)`**. Anyone may submit this, but it needs a signer
   signature over `Market(bytes32 marketId,address token,uint64 closesAt,bytes32 game)`. The `marketId`
   must be new, `token` must be IMD or SHIFT, and `block.timestamp < closesAt <= block.timestamp + 7 days`.
   Emits `MarketCreated`.
2. **`bet(marketId, side, amount, weightBps, expiry, nonce, sig)`**. Needs a signer ticket
   `Ticket(bytes32 marketId,address bettor,uint8 side,uint256 amount,uint16 weightBps,uint64 expiry,bytes32 nonce)`
   with `bettor == msg.sender`. The checks:
   - `block.timestamp <= expiry <= block.timestamp + 120`
   - the nonce is unused (nonces are global, not per market)
   - `500 <= weightBps <= 10000` and `side` is 0 or 1
   - the market exists, is unsettled, and `block.timestamp < closesAt`
   - `amount` is within the token's limits

   The contract pulls exactly `amount` with `transferFrom` and checks the balance delta. It records
   `shares = amount * weightBps / 10000` for that wallet and side. A wallet may bet many times and on both
   sides. Emits `BetPlaced`.
3. **`settle(marketId, outcome, deadline, sig)`**. Anyone may submit a signer signature over
   `Outcome(bytes32 marketId,uint8 outcome,uint256 deadline)`, with `block.timestamp <= deadline` and
   outcome 0 (A won), 1 (B won) or 2 (void). Settling closes betting.
   - If the outcome is void, or either side has no bets, the market becomes refundable and no fee is taken.
   - Otherwise `fee = losingTotal * 500 / 10000` goes to the fee splitter in the same transaction.

   Emits `Settled(marketId, outcome, fee)`.
4. **`claim(marketId)` / `claimMany(marketIds)`**. Pull payments.
   - A winner receives `stake + (losingTotal - fee) * walletShares / winningShares`, rounded down.
   - In a refundable market, everyone receives `amountA + amountB`.
   - Each wallet claims once. A claim that would pay nothing (a loser, or a wallet with no bets) reverts
     with `NothingToClaim`.
   - `claimMany` skips markets with nothing due and reverts only if it paid nothing at all.

   Emits `Claimed`.
5. **`expire(marketId)`**. If a market is still unsettled when `block.timestamp > closesAt + 24h`, anyone
   may expire it. It becomes `settled = true`, `outcome = 2`, `refundable = true`, with no fee. Emits
   `Expired`. A signed result can still settle the market after 24 h if nobody has expired it yet.
6. **Views**: `markets`, `betsOf`, `claimable`, `limits`, `usedNonce`, plus `signer`, `hardCap`,
   `domainSeparator`, `paused`, `owner`.

### Rounding

Each winner's share is rounded down once. The dust left in the contract is therefore below one wei per
winning wallet. It stays in the contract permanently because there is no sweep. The sum of all claims
never exceeds `pot - fee`, and the invariant tests check this.

## Owner powers (trust assumptions)

The owner can only:

- rotate the result signer (`setSigner`, must be non-zero);
- change a token's per-bet limits (`setLimits`), never with `min == 0`, `min > max` or `max` above the
  hard cap;
- `pause` / `unpause` new markets and new bets. Settle, expire and claim keep working while paused.
- transfer ownership in two steps (`transferOwnership` + `acceptOwnership`). `renounceOwnership` is
  disabled so there is always someone who can rotate a compromised signer.

The owner cannot move, take or redirect bets, change the fee, the fee recipient or the tokens, settle
without the signer, or sweep tokens. There is no upgradeability, delegatecall or selfdestruct.

**The result signer is the real trust anchor.** A compromised or malicious signer key could:

- sign a wrong outcome, which redirects a market's losing side to the other side's bettors (the fee still
  goes only to the splitter);
- issue itself or friends high-weight tickets late in a match;
- create markets.

It can never pay anyone more than a market holds, and never take bets out of the contract to an address
that did not bet. If the key leaks, the owner should immediately `setSigner` to a fresh key and `pause`.

## Operational responsibilities (NIGHTSHIFT server)

- Sign `Market` messages only for real matches, with a `closesAt` no later than the match could still be
  undecided.
- Issue tickets only while the match is live, with weights computed from the live state: high for early
  bets and for the side that is behind, low (down to 500) for late bets on a side that is clearly winning.
  Keep ticket expiry short (at most 120 s is enforced). Use unique random nonces.
- Stop issuing tickets as soon as a result is foreseeable, and sign the `Outcome` promptly after the match.
  Use outcome 2 for draws, abandoned or cancelled matches.
- Submit `settle` (or let anyone submit it) well within 24 hours after `closesAt`. After that anyone can
  `expire` the market into full refunds.
- Keep the signer key in a secured signing service. It is shared with GameEscrow if the same key is used.
- Front-ends should read `claimable` and remind users to claim. Funds wait in the contract indefinitely.

## Assumptions

- IMD and SHIFT are plain ERC-20s: 18 decimals, no transfer fee, no rebasing, no hooks. `bet` measures
  the balance delta and reverts (`TransferMismatch`) if a token ever charges a fee on transfer.
- The fee splitter accepts plain ERC-20 transfers. If a transfer to it ever reverted, `settle` would
  revert. The market could then still be expired into refunds after 24 h, so bettors' funds are never
  stuck.
- A bet whose weighted shares round to zero is refused (`ZeroShares`). This only matters if the owner
  sets a minimum of a few wei.
- `block.timestamp` is used only for coarse windows (ticket TTL, `closesAt`, the 24 h expiry). Nothing
  depends on randomness.

## Tests

`forge test` runs 63 tests. All pass, including with the verifier's fuzz seed.

- **Full flows** for IMD and SHIFT, with several bettors on both sides, different weights, amounts at the
  minimum, at the maximum and in between, odd amounts, and a hedging wallet. Each winner's payout is
  recomputed independently, payouts + fee + dust equal the pot, and dust is at most one wei per winner.
- **Fee**: exactly 5% of the losing side to the splitter, with odd amounts and 47 bettors; also fuzzed.
- **Refunds**: void outcome, a market where only the winning side bet, a market where only the losing side
  bet, an empty market, expiry exactly at and after 24 h, and expire after settle (refused).
- **Tickets refused** for a wrong bettor, side, amount, weight, market, signer, contract or chain; a weight
  of 499 or 10001; an expired ticket; an expiry more than 120 s ahead; a reused nonce; a malformed
  signature. Boundaries 500, 10000, an expiry exactly at the block time and exactly 120 s ahead are
  accepted.
- **Bets refused** after `closesAt`, on settled markets, on unknown markets, below or above the limits,
  without allowance, and from a fee-on-transfer token.
- **Signature checks** on market creation and settlement. Also: double settle, double claim, a loser's
  claim, claiming before settlement, `claimMany`.
- **Pause**: blocks only markets and bets; settle, claim and expire still work.
- **Owner powers**: limits within the caps, signer rotation, renounce disabled, two-step transfer, and the
  owner unable to move funds.
- **Reentrancy**: a token that calls back into `claim` during a payout hits `ReentrancyGuardReentrantCall`.
- **Fuzz**: conservation over random bets, weights, sides and outcomes.
- **Invariants** over random create/bet/settle/expire/claim/warp sequences: the pool always holds at least
  what it owes; paid + fees never exceed bets, and held + paid + fees equals bets exactly; dust is bounded.

## Open items

- Passing tests are not an audit. This contract holds other people's funds and needs an independent
  adversarial review before release.
- After deployment the owner must call `setSigner` (see "After launch") before the pool is usable.
- No static analysers (Slither, Mythril) were run in this task; only the Foundry suite above.
