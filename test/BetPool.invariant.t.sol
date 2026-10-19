// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BetPool} from "../src/BetPool.sol";
import {BetPoolBase} from "./utils/BetPoolBase.sol";
import {MockERC20} from "./utils/Mocks.sol";

/// @notice Drives random markets, bets, settlements, expiries and claims, tracking what the pool owes.
contract BetPoolHandler is Test {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    address internal constant FEE_RECIPIENT = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;

    BetPool public pool;
    uint256 internal key;
    bytes32[] public ids;
    address[] public actors;
    uint256 internal nonceCounter;

    mapping(address => uint256) public totalBet;
    mapping(address => uint256) public totalPaid;
    mapping(address => uint256) public totalFees;

    constructor(BetPool pool_, uint256 key_) {
        pool = pool_;
        key = key_;
        for (uint256 i; i < 5; ++i) {
            actors.push(address(uint160(0xA000 + i)));
        }
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

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

    function createMarket(uint256 seed) external {
        if (ids.length >= 6) return;
        bytes32 id = keccak256(abi.encode("inv", ids.length));
        address token = seed % 2 == 0 ? IMD : SHIFT;
        uint64 closesAt = uint64(block.timestamp + 1 hours + seed % 1 days);
        bytes32 game = bytes32(seed);
        pool.createMarket(
            id, token, closesAt, game, _sign(keccak256(abi.encode(pool.MARKET_TYPEHASH(), id, token, closesAt, game)))
        );
        ids.push(id);
    }

    function bet(uint256 idSeed, uint256 actorSeed, uint8 side, uint256 amount, uint16 weight) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        (address token, uint64 closesAt,,,,,, bool settled,,) = pool.markets(id);
        if (settled || block.timestamp >= closesAt) return;
        (uint256 mn, uint256 mx) = pool.limits(token);
        amount = bound(amount, mn, mx);
        _placeBet(id, token, actors[actorSeed % actors.length], side % 2, amount, uint16(bound(weight, 500, 10_000)));
    }

    function _placeBet(bytes32 id, address token, address bettor, uint8 side, uint256 amount, uint16 weight) internal {
        uint64 expiry = uint64(block.timestamp + 120);
        bytes32 nonce = keccak256(abi.encode("inv-nonce", ++nonceCounter));
        bytes memory sig = _sign(_ticketHash(id, bettor, side, amount, weight, expiry, nonce));
        MockERC20(token).mint(bettor, amount);
        vm.startPrank(bettor);
        MockERC20(token).approve(address(pool), amount);
        pool.bet(id, side, amount, weight, expiry, nonce, sig);
        vm.stopPrank();
        totalBet[token] += amount;
    }

    function _ticketHash(
        bytes32 id,
        address bettor,
        uint8 side,
        uint256 amount,
        uint16 weight,
        uint64 expiry,
        bytes32 nonce
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(pool.TICKET_TYPEHASH(), id, bettor, side, amount, weight, expiry, nonce));
    }

    function settle(uint256 idSeed, uint8 outcome) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        (address token,,,,,,, bool settled,,) = pool.markets(id);
        if (settled) return;
        outcome = outcome % 3;
        uint256 deadline = block.timestamp + 10;
        uint256 before = MockERC20(token).balanceOf(FEE_RECIPIENT);
        pool.settle(id, outcome, deadline, _sign(keccak256(abi.encode(pool.OUTCOME_TYPEHASH(), id, outcome, deadline))));
        totalFees[token] += MockERC20(token).balanceOf(FEE_RECIPIENT) - before;
    }

    function expire(uint256 idSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        (, uint64 closesAt,,,,,, bool settled,,) = pool.markets(id);
        if (settled) return;
        vm.warp(uint256(closesAt) + 24 hours + 1);
        pool.expire(id);
    }

    function claim(uint256 idSeed, uint256 actorSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        address who = actors[actorSeed % actors.length];
        uint256 c = pool.claimable(id, who);
        if (c == 0) return;
        (address token,,,,,,,,,) = pool.markets(id);
        vm.prank(who);
        pool.claim(id);
        totalPaid[token] += c;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 6 hours));
    }
}

contract BetPoolInvariantTest is BetPoolBase {
    BetPoolHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new BetPoolHandler(pool, signerKey);
        targetContract(address(handler));
    }

    /// @dev What the pool still owes across all markets of a token.
    function _owed(address token) internal view returns (uint256 owed) {
        uint256 n = handler.idsLength();
        uint256 m = handler.actorsLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.ids(i);
            (address t,,,,,,, bool settled,,) = pool.markets(id);
            if (t != token) continue;
            for (uint256 j; j < m; ++j) {
                address who = handler.actors(j);
                if (settled) {
                    owed += pool.claimable(id, who);
                } else {
                    (uint256 aA, uint256 aB,,,) = pool.betsOf(id, who);
                    owed += aA + aB;
                }
            }
        }
    }

    function invariant_poolHoldsWhatItOwes() public view {
        assertGe(MockERC20(IMD).balanceOf(address(pool)), _owed(IMD));
        assertGe(MockERC20(SHIFT).balanceOf(address(pool)), _owed(SHIFT));
    }

    function invariant_payoutsNeverExceedBets() public view {
        address[2] memory tokens = [IMD, SHIFT];
        for (uint256 i; i < 2; ++i) {
            address t = tokens[i];
            assertLe(handler.totalPaid(t) + handler.totalFees(t), handler.totalBet(t));
            // Exact accounting: everything bet is either still held, paid out or sent as fee.
            assertEq(
                MockERC20(t).balanceOf(address(pool)) + handler.totalPaid(t) + handler.totalFees(t), handler.totalBet(t)
            );
        }
    }

    function invariant_dustBounded() public view {
        // Rounding dust is at most one wei per winning position on settled decided markets.
        address[2] memory tokens = [IMD, SHIFT];
        for (uint256 i; i < 2; ++i) {
            uint256 bal = MockERC20(tokens[i]).balanceOf(address(pool));
            assertLe(bal - _owed(tokens[i]), handler.idsLength() * handler.actorsLength());
        }
    }
}
