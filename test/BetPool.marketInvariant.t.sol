// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BetPool} from "../src/BetPool.sol";
import {BetPoolBase} from "./utils/BetPoolBase.sol";
import {MockERC20} from "./utils/Mocks.sol";

/// @notice Handler with per-market ghost accounting. Besides valid calls it mixes in owner actions
/// (pause, limits), claimMany with duplicates, and calls that must fail (bets while paused or closed,
/// double settle, double claim, loser claims). Any of those succeeding is counted and fails an invariant.
contract MarketHandler is Test {
    address internal constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    address internal constant FEE_RECIPIENT = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;

    BetPool public pool;
    uint256 internal key;
    uint256 internal nonceCounter;

    bytes32[] public ids;
    address[] public actors;

    // ghost accounting per market
    mapping(bytes32 => uint256) public deposited;
    mapping(bytes32 => uint256) public fees;
    mapping(bytes32 => uint256) public paid;
    mapping(bytes32 => mapping(address => uint256)) public paidTo;
    // snapshot of totals at settlement, to prove a finished market never changes
    mapping(bytes32 => uint256[4]) internal frozen;
    mapping(bytes32 => bool) public wasSettled;

    uint256 public unexpectedSuccess;
    uint256 public overpaidClaims;
    uint256 public claimsDone;
    uint256 public settlesDone;

    constructor(BetPool pool_, uint256 key_) {
        pool = pool_;
        key = key_;
        for (uint256 i; i < 4; ++i) {
            actors.push(address(uint160(0xB000 + i)));
        }
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function frozenTotals(bytes32 id) external view returns (uint256[4] memory) {
        return frozen[id];
    }

    // ------------------------------------------------------------------ signing

    function _sign(bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NightshiftBets"),
                keccak256("1"),
                block.chainid,
                address(pool)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _pick(uint256 seed) internal view returns (bytes32) {
        return ids[seed % ids.length];
    }

    // ------------------------------------------------------------------ actions

    function createMarket(uint256 seed) external {
        if (ids.length >= 5) return;
        bytes32 id = keccak256(abi.encode("mi", ids.length));
        address token = seed % 2 == 0 ? IMD : SHIFT;
        uint64 closesAt = uint64(block.timestamp + 10 minutes + seed % 2 days);
        bytes memory sig = _sign(keccak256(abi.encode(pool.MARKET_TYPEHASH(), id, token, closesAt, bytes32(seed))));
        if (pool.paused()) {
            try pool.createMarket(id, token, closesAt, bytes32(seed), sig) {
                unexpectedSuccess++;
            } catch {}
            return;
        }
        pool.createMarket(id, token, closesAt, bytes32(seed), sig);
        ids.push(id);
    }

    struct BetArgs {
        bytes32 id;
        address token;
        address bettor;
        uint8 side;
        uint256 amount;
        uint16 weight;
        uint64 expiry;
        bytes32 nonce;
        bytes sig;
    }

    function bet(uint256 idSeed, uint256 actorSeed, uint8 side, uint256 amount, uint16 weight) external {
        if (ids.length == 0) return;
        BetArgs memory b;
        b.id = _pick(idSeed);
        uint64 closesAt;
        bool settled;
        (b.token, closesAt,,,,,, settled,,) = pool.markets(b.id);
        (uint256 mn, uint256 mx) = pool.limits(b.token);
        b.amount = bound(amount, mn, mx);
        b.weight = uint16(bound(weight, 500, 10_000));
        b.side = side % 2;
        b.bettor = actors[actorSeed % actors.length];
        b.expiry = uint64(block.timestamp + 120);
        b.nonce = keccak256(abi.encode("mi-nonce", ++nonceCounter));
        b.sig = _sign(
            keccak256(abi.encode(pool.TICKET_TYPEHASH(), b.id, b.bettor, b.side, b.amount, b.weight, b.expiry, b.nonce))
        );
        bool shouldFail = settled || block.timestamp >= closesAt || pool.paused();
        if (shouldFail) {
            if (_tryBet(b)) unexpectedSuccess++;
            return;
        }
        if (!_tryBet(b)) revert("valid bet refused");
        deposited[b.id] += b.amount;
        // replaying the same ticket must fail
        if (_tryBet(b)) unexpectedSuccess++;
    }

    function _tryBet(BetArgs memory b) internal returns (bool ok) {
        MockERC20(b.token).mint(b.bettor, b.amount);
        vm.prank(b.bettor);
        MockERC20(b.token).approve(address(pool), b.amount);
        vm.prank(b.bettor);
        try pool.bet(b.id, b.side, b.amount, b.weight, b.expiry, b.nonce, b.sig) {
            ok = true;
        } catch {}
        if (!ok) {
            // drop the unused allowance; the minted tokens stay with the bettor and are never counted
            vm.prank(b.bettor);
            MockERC20(b.token).approve(address(pool), 0);
        }
    }

    function settle(uint256 idSeed, uint8 outcome) external {
        if (ids.length == 0) return;
        bytes32 id = _pick(idSeed);
        (address token,,,,,,, bool settled,,) = pool.markets(id);
        outcome = outcome % 3;
        uint256 deadline = block.timestamp + 30;
        bytes memory sig = _sign(keccak256(abi.encode(pool.OUTCOME_TYPEHASH(), id, outcome, deadline)));
        if (settled) {
            try pool.settle(id, outcome, deadline, sig) {
                unexpectedSuccess++;
            } catch {}
            return;
        }
        uint256 before = MockERC20(token).balanceOf(FEE_RECIPIENT);
        pool.settle(id, outcome, deadline, sig);
        fees[id] += MockERC20(token).balanceOf(FEE_RECIPIENT) - before;
        _freeze(id);
        settlesDone++;
    }

    function expire(uint256 idSeed, bool early) external {
        if (ids.length == 0) return;
        bytes32 id = _pick(idSeed);
        (, uint64 closesAt,,,,,, bool settled,,) = pool.markets(id);
        if (settled) {
            try pool.expire(id) {
                unexpectedSuccess++;
            } catch {}
            return;
        }
        if (early && block.timestamp <= uint256(closesAt) + 24 hours) {
            try pool.expire(id) {
                unexpectedSuccess++;
            } catch {}
            return;
        }
        if (block.timestamp <= uint256(closesAt) + 24 hours) vm.warp(uint256(closesAt) + 24 hours + 1);
        pool.expire(id);
        _freeze(id);
    }

    function claim(uint256 idSeed, uint256 actorSeed) external {
        if (ids.length == 0) return;
        bytes32 id = _pick(idSeed);
        address who = actors[actorSeed % actors.length];
        uint256 c = pool.claimable(id, who);
        if (c == 0) {
            vm.prank(who);
            try pool.claim(id) {
                unexpectedSuccess++;
            } catch {}
            return;
        }
        (address token,,,,,,,,,) = pool.markets(id);
        uint256 before = MockERC20(token).balanceOf(who);
        vm.prank(who);
        uint256 out = pool.claim(id);
        if (out != c || MockERC20(token).balanceOf(who) - before != c) overpaidClaims++;
        _record(id, who, c);

        vm.prank(who);
        try pool.claim(id) {
            unexpectedSuccess++;
        } catch {}
    }

    function claimMany(uint256 seed, uint256 actorSeed) external {
        if (ids.length == 0) return;
        address who = actors[actorSeed % actors.length];
        uint256 n = 1 + seed % 6;
        bytes32[] memory list = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            // duplicates are likely and an unknown id is mixed in
            list[i] = (seed >> (8 * i)) % 7 == 6 ? keccak256("unknown") : ids[(seed >> (8 * i)) % ids.length];
        }
        uint256 expected;
        bytes32[] memory seen = new bytes32[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 seenLen;
        for (uint256 i; i < n; ++i) {
            bool dup;
            for (uint256 j; j < seenLen; ++j) {
                if (seen[j] == list[i]) dup = true;
            }
            if (dup) continue;
            seen[seenLen] = list[i];
            amounts[seenLen] = pool.claimable(list[i], who);
            expected += amounts[seenLen];
            seenLen++;
        }
        vm.prank(who);
        if (expected == 0) {
            try pool.claimMany(list) {
                unexpectedSuccess++;
            } catch {}
            return;
        }
        uint256 total = pool.claimMany(list);
        if (total != expected) overpaidClaims++;
        for (uint256 i; i < seenLen; ++i) {
            if (amounts[i] > 0) _record(seen[i], who, amounts[i]);
        }
    }

    function togglePause() external {
        bool paused = pool.paused();
        vm.prank(OWNER);
        if (paused) pool.unpause();
        else pool.pause();
    }

    function setLimits(bool shift, uint256 mn, uint256 mx) external {
        address token = shift ? SHIFT : IMD;
        uint256 cap = pool.hardCap(token);
        // keep min large enough that every bet carries shares
        mx = bound(mx, 1 ether, cap);
        mn = bound(mn, 1 ether, mx);
        vm.prank(OWNER);
        pool.setLimits(token, mn, mx);
        // above the hard cap is always refused
        vm.prank(OWNER);
        try pool.setLimits(token, mn, cap + 1) {
            unexpectedSuccess++;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 8 hours));
    }

    // ------------------------------------------------------------------ internal

    function _record(bytes32 id, address who, uint256 amount) internal {
        paid[id] += amount;
        paidTo[id][who] += amount;
        claimsDone++;
    }

    function _freeze(bytes32 id) internal {
        (,,, uint256 tA, uint256 tB, uint256 sA, uint256 sB,,,) = pool.markets(id);
        frozen[id] = [tA, tB, sA, sB];
        wasSettled[id] = true;
    }
}

contract BetPoolMarketInvariantTest is BetPoolBase {
    MarketHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new MarketHandler(pool, signerKey);
        targetContract(address(handler));
    }

    /// @dev Guards against a vacuous run: the handler really reaches bets, settlement, fees and claims.
    function test_handlerReachesAllPaths() public {
        handler.createMarket(0); // IMD
        handler.createMarket(1); // SHIFT
        for (uint256 i; i < 8; ++i) {
            handler.bet(i, i, uint8(i / 2), uint256(keccak256(abi.encode(i))), uint16(500 + i * 1000));
        }
        handler.settle(0, 0);
        handler.settle(0, 1); // double settle attempt, must fail
        for (uint256 j; j < 4; ++j) {
            handler.claim(0, j);
            handler.claim(0, j); // second attempt, nothing left
        }
        handler.togglePause();
        handler.bet(1, 0, 0, 1, 1); // paused: must fail
        handler.togglePause();
        handler.expire(1, true); // too early: must fail
        handler.expire(1, false);
        handler.claimMany(type(uint256).max / 3, 1);
        assertGt(handler.deposited(handler.ids(0)), 0);
        assertGt(handler.fees(handler.ids(0)), 0);
        assertGe(handler.claimsDone(), 2);
        assertEq(handler.settlesDone(), 1);
        assertTrue(handler.wasSettled(handler.ids(1)));
        invariant_eachMarketSolventAndDustBounded();
        invariant_tokenBalancesMatchGhostLedger();
        invariant_feeRule();
        invariant_finishedMarketsNeverReopenOrChange();
        invariant_perBettorPayoutRules();
        invariant_noForbiddenCallSucceeded();
    }

    function _owedInMarket(bytes32 id, bool settled) internal view returns (uint256 owed) {
        uint256 n = handler.actorsLength();
        for (uint256 j; j < n; ++j) {
            address who = handler.actors(j);
            if (settled) {
                owed += pool.claimable(id, who);
            } else {
                (uint256 aA, uint256 aB,,,) = pool.betsOf(id, who);
                owed += aA + aB;
            }
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    function invariant_eachMarketSolventAndDustBounded() public view {
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.ids(i);
            (,,, uint256 tA, uint256 tB,,, bool settled,,) = pool.markets(id);
            uint256 dep = handler.deposited(id);
            assertEq(tA + tB, dep, "market totals != deposits");
            uint256 out = handler.paid(id) + handler.fees(id);
            assertLe(out, dep, "market paid out more than it took in");
            uint256 owed = _owedInMarket(id, settled);
            assertLe(out + owed, dep, "market owes more than it holds");
            // rounding dust left in a market never exceeds one wei per bettor
            assertLe(dep - out - owed, handler.actorsLength(), "dust above bound");
            if (!settled) assertEq(owed, dep);
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    function invariant_tokenBalancesMatchGhostLedger() public view {
        address[2] memory tokens = [IMD, SHIFT];
        uint256 n = handler.idsLength();
        for (uint256 t; t < 2; ++t) {
            uint256 expectHeld;
            uint256 owed;
            uint256 totalFees;
            for (uint256 i; i < n; ++i) {
                bytes32 id = handler.ids(i);
                (address token,,,,,,, bool settled,,) = pool.markets(id);
                if (token != tokens[t]) continue;
                expectHeld += handler.deposited(id) - handler.paid(id) - handler.fees(id);
                owed += _owedInMarket(id, settled);
                totalFees += handler.fees(id);
            }
            uint256 bal = MockERC20(tokens[t]).balanceOf(address(pool));
            assertEq(bal, expectHeld, "untracked token flow");
            assertGe(bal, owed, "pool holds less than it owes");
            assertEq(MockERC20(tokens[t]).balanceOf(FEE_RECIPIENT), totalFees, "fee recipient got untracked funds");
            assertEq(MockERC20(tokens[t]).balanceOf(OWNER), 0, "owner received funds");
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    function invariant_feeRule() public view {
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.ids(i);
            (,,, uint256 tA, uint256 tB,,, bool settled, uint8 outcome, bool refundable) = pool.markets(id);
            uint256 fee = handler.fees(id);
            if (!settled || refundable) {
                assertEq(fee, 0, "fee on unsettled or refundable market");
            } else {
                assertLt(outcome, 2);
                uint256 losing = outcome == 0 ? tB : tA;
                assertEq(fee, losing * 500 / 10_000, "fee not 5% of losing side");
                assertGt(tA, 0);
                assertGt(tB, 0);
            }
            if (settled && outcome == 2) assertTrue(refundable, "void not refundable");
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    function invariant_finishedMarketsNeverReopenOrChange() public view {
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.ids(i);
            if (!handler.wasSettled(id)) continue;
            (,,, uint256 tA, uint256 tB, uint256 sA, uint256 sB, bool settled,,) = pool.markets(id);
            uint256[4] memory f = handler.frozenTotals(id);
            assertTrue(settled, "market reopened");
            assertEq(tA, f[0]);
            assertEq(tB, f[1]);
            assertEq(sA, f[2]);
            assertEq(sB, f[3]);
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    function invariant_perBettorPayoutRules() public view {
        uint256 n = handler.idsLength();
        uint256 m = handler.actorsLength();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < m; ++j) {
                _checkBettor(handler.ids(i), handler.actors(j));
            }
        }
    }

    function _checkBettor(bytes32 id, address who) internal view {
        (uint256 aA, uint256 aB, uint256 sA, uint256 sB, bool claimed) = pool.betsOf(id, who);
        uint256 got = handler.paidTo(id, who);
        if (!claimed) {
            assertEq(got, 0, "paid without claimed flag");
            return;
        }
        assertEq(pool.claimable(id, who), 0, "claimed wallet still claimable");
        (,,,,,,,, uint8 outcome, bool refundable) = pool.markets(id);
        if (refundable) {
            assertEq(got, aA + aB, "refund not exact");
            return;
        }
        if (outcome == 0) _checkWinner(id, got, aA, sA, 0);
        else _checkWinner(id, got, aB, sB, 1);
    }

    /// @dev A winner gets the winning stake back plus at most the pro rata share of 95% of the losing side.
    function _checkWinner(bytes32 id, uint256 got, uint256 stake, uint256 shares, uint8 outcome) internal view {
        (,,, uint256 tA, uint256 tB, uint256 mSA, uint256 mSB,,,) = pool.markets(id);
        uint256 losing = outcome == 0 ? tB : tA;
        uint256 dist = losing - losing * 500 / 10_000;
        assertGt(shares, 0, "loser was paid");
        assertGe(got, stake, "winner lost stake");
        assertLe(got - stake, dist * shares / (outcome == 0 ? mSA : mSB), "winner share above pro rata");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    function invariant_noForbiddenCallSucceeded() public view {
        assertEq(handler.unexpectedSuccess(), 0, "a call that must fail succeeded");
        assertEq(handler.overpaidClaims(), 0, "claim paid other than claimable");
    }
}
