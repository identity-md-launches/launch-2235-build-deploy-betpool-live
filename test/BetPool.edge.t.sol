// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPool} from "../src/BetPool.sol";
import {BetPoolBase} from "./utils/BetPoolBase.sol";
import {MockERC20} from "./utils/Mocks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice Edge cases and adversarial inputs not covered by BetPool.t.sol: boundaries, cross-market
/// isolation, nonce scope, claimMany corner cases, signature malleability, hard caps and owner handover.
contract BetPoolEdgeTest is BetPoolBase {
    bytes32 internal constant M1 = keccak256("edge-1");
    bytes32 internal constant M2 = keccak256("edge-2");
    bytes32 internal constant M3 = keccak256("edge-3");

    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    // ================================================================== boundaries

    function test_createMarketOneSecondAheadAccepted() public {
        uint64 closesAt = uint64(block.timestamp + 1);
        pool.createMarket(M1, IMD, closesAt, 0, _signHash(_marketHash(M1, IMD, closesAt, 0)));
        // betting is open for exactly that one second
        _bet(M1, alice, 0, 1 ether, 10_000);
        vm.warp(closesAt);
        _fund(IMD, bob, 1 ether);
        uint64 expiry = uint64(block.timestamp + 10);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, bob, 1, 1 ether, 10_000, expiry, nonce));
        vm.prank(bob);
        vm.expectRevert(BetPool.BettingClosed.selector);
        pool.bet(M1, 1, 1 ether, 10_000, expiry, nonce, sig);
    }

    function test_createMarketInPastRefused() public {
        uint64 closesAt = uint64(block.timestamp - 1);
        bytes memory sig = _signHash(_marketHash(M1, IMD, closesAt, 0));
        vm.expectRevert(BetPool.InvalidClosesAt.selector);
        pool.createMarket(M1, IMD, closesAt, 0, sig);
    }

    function test_createMarketZeroTokenRefused() public {
        uint64 closesAt = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signHash(_marketHash(M1, address(0), closesAt, 0));
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.createMarket(M1, address(0), closesAt, 0, sig);
    }

    function test_marketIdCannotBeReusedAfterSettlement() public {
        _createMarket(M1, IMD);
        _settle(M1, 2);
        uint64 closesAt = uint64(block.timestamp + 1 hours);
        bytes memory sig = _signHash(_marketHash(M1, SHIFT, closesAt, bytes32("other")));
        vm.expectRevert(BetPool.MarketExists.selector);
        pool.createMarket(M1, SHIFT, closesAt, bytes32("other"), sig);
    }

    function test_weightBoundsExactSharesRecorded() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 3 ether + 7, 500);
        _bet(M1, bob, 1, 3 ether + 7, 10_000);
        (,, uint256 sA, uint256 sB,) = _bets(M1, alice);
        assertEq(sA, uint256(3 ether + 7) * 500 / 10_000);
        assertEq(sB, 0);
        (,, sA, sB,) = _bets(M1, bob);
        assertEq(sB, 3 ether + 7);
    }

    function test_ticketExpiryExactlyMaxTtlAccepted() public {
        _createMarket(M1, IMD);
        _fund(IMD, alice, 1 ether);
        uint64 expiry = uint64(block.timestamp + 120);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 1 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        pool.bet(M1, 0, 1 ether, 10_000, expiry, nonce, sig);
        assertTrue(pool.usedNonce(nonce));
    }

    function test_ticketWithExpiryAfterCloseStillStopsAtClose() public {
        uint64 closesAt = uint64(block.timestamp + 60);
        pool.createMarket(M1, IMD, closesAt, 0, _signHash(_marketHash(M1, IMD, closesAt, 0)));
        _fund(IMD, alice, 1 ether);
        vm.warp(closesAt - 10);
        uint64 expiry = uint64(block.timestamp + 120); // beyond closesAt
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 1 ether, 10_000, expiry, nonce));
        vm.warp(closesAt);
        vm.prank(alice);
        vm.expectRevert(BetPool.BettingClosed.selector);
        pool.bet(M1, 0, 1 ether, 10_000, expiry, nonce, sig);
        assertFalse(pool.usedNonce(nonce));
    }

    function test_settleExactlyAtDeadlineAndExpireBoundary() public {
        uint64 closesAt = _createMarket(M1, IMD);
        _bet(M1, alice, 0, 1 ether, 10_000);
        vm.warp(uint256(closesAt) + 24 hours);
        // at closesAt + 24h exactly, settlement still wins and expire is refused
        vm.expectRevert(BetPool.NotExpirable.selector);
        pool.expire(M1);
        uint256 deadline = block.timestamp;
        pool.settle(M1, 0, deadline, _signHash(_outcomeHash(M1, 0, deadline)));
        (,,,,,,, bool settled,,) = pool.markets(M1);
        assertTrue(settled);
    }

    function test_expireMarketWithoutBets() public {
        uint64 closesAt = _createMarket(M1, SHIFT);
        vm.warp(uint256(closesAt) + 24 hours + 1);
        pool.expire(M1);
        (,,,,,,,, uint8 outcome, bool refundable) = pool.markets(M1);
        assertEq(outcome, 2);
        assertTrue(refundable);
        vm.prank(alice);
        vm.expectRevert(BetPool.NothingToClaim.selector);
        pool.claim(M1);
    }

    function test_expiredMarketRefusesBets() public {
        uint64 closesAt = _createMarket(M1, IMD);
        vm.warp(uint256(closesAt) + 24 hours + 1);
        pool.expire(M1);
        _fund(IMD, alice, 1 ether);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 1 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.MarketSettled.selector);
        pool.bet(M1, 0, 1 ether, 10_000, expiry, nonce, sig);
    }

    // ================================================================== nonces

    function test_nonceIsGlobalAcrossMarkets() public {
        _createMarket(M1, IMD);
        _createMarket(M2, IMD);
        _fund(IMD, alice, 2 ether);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = keccak256("shared");
        bytes memory sig1 = _signHash(_ticketHash(M1, alice, 0, 1 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        pool.bet(M1, 0, 1 ether, 10_000, expiry, nonce, sig1);
        bytes memory sig2 = _signHash(_ticketHash(M2, alice, 0, 1 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.NonceUsed.selector);
        pool.bet(M2, 0, 1 ether, 10_000, expiry, nonce, sig2);
    }

    function test_nonceReuseRefusedForOtherBettor() public {
        _createMarket(M1, IMD);
        _fund(IMD, alice, 1 ether);
        _fund(IMD, bob, 1 ether);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = keccak256("n");
        bytes memory sig1 = _signHash(_ticketHash(M1, alice, 0, 1 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        pool.bet(M1, 0, 1 ether, 10_000, expiry, nonce, sig1);
        bytes memory sig = _signHash(_ticketHash(M1, bob, 1, 1 ether, 10_000, expiry, nonce));
        vm.prank(bob);
        vm.expectRevert(BetPool.NonceUsed.selector);
        pool.bet(M1, 1, 1 ether, 10_000, expiry, nonce, sig);
    }

    function test_failedBetDoesNotConsumeNonce() public {
        _createMarket(M1, IMD);
        MockERC20(IMD).mint(alice, 1 ether); // no approval yet
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 1 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 1 ether)
        );
        pool.bet(M1, 0, 1 ether, 10_000, expiry, nonce, sig);
        assertFalse(pool.usedNonce(nonce));
        (uint256 aA,,,,) = _bets(M1, alice);
        assertEq(aA, 0);

        vm.prank(alice);
        MockERC20(IMD).approve(address(pool), 1 ether);
        vm.prank(alice);
        pool.bet(M1, 0, 1 ether, 10_000, expiry, nonce, sig);
        assertTrue(pool.usedNonce(nonce));
    }

    function test_insufficientBalanceRefused() public {
        _createMarket(M1, IMD);
        MockERC20(IMD).mint(alice, 1 ether - 1);
        vm.prank(alice);
        MockERC20(IMD).approve(address(pool), type(uint256).max);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 1 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1 ether - 1, 1 ether)
        );
        pool.bet(M1, 0, 1 ether, 10_000, expiry, nonce, sig);
    }

    // ================================================================== signatures

    function test_highSMalleatedTicketRefused() public {
        _createMarket(M1, IMD);
        _fund(IMD, alice, 1 ether);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domain(address(pool), block.chainid),
                _ticketHash(M1, alice, 0, 1 ether, 10_000, expiry, nonce)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory malleated = abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 1 ether, 10_000, expiry, nonce, malleated);
        // the canonical one works
        vm.prank(alice);
        pool.bet(M1, 0, 1 ether, 10_000, expiry, nonce, abi.encodePacked(r, s, v));
    }

    function test_emptyAndShortSignaturesRefused() public {
        _createMarket(M1, IMD);
        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline, "");
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline, new bytes(64));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline, new bytes(65));
    }

    function test_outcomeSignedForOtherMarketRefused() public {
        _createMarket(M1, IMD);
        _createMarket(M2, IMD);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sigForM2 = _signHash(_outcomeHash(M2, 0, deadline));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline, sigForM2);
    }

    function test_crossTypeSignatureRefused() public {
        // A Market signature must not double as an Outcome signature or a Ticket signature.
        uint64 closesAt = uint64(block.timestamp + 1 hours);
        bytes memory marketSig = _signHash(_marketHash(M1, IMD, closesAt, 0));
        pool.createMarket(M1, IMD, closesAt, 0, marketSig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, closesAt, marketSig);
        _fund(IMD, alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 1 ether, 10_000, uint64(block.timestamp + 60), bytes32(0), marketSig);
    }

    function test_voidSignatureCannotSettleAsWin() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 10_000);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory voidSig = _signHash(_outcomeHash(M1, 2, deadline));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline, voidSig);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 1, deadline, voidSig);
        pool.settle(M1, 2, deadline, voidSig);
        assertEq(pool.claimable(M1, alice), 10 ether);
        assertEq(pool.claimable(M1, bob), 10 ether);
    }

    function test_settleAfterSignerRotationNeedsNewSigner() public {
        _createMarket(M1, IMD);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory oldSig = _signHash(_outcomeHash(M1, 0, deadline));
        uint256 newKey = 0xB0B0;
        vm.prank(OWNER);
        pool.setSigner(vm.addr(newKey));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline, oldSig);
        pool.settle(
            M1, 0, deadline, _sign(newKey, _domain(address(pool), block.chainid), _outcomeHash(M1, 0, deadline))
        );
    }

    function test_chainForkInvalidatesSignatures() public {
        _createMarket(M1, IMD);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signHash(_outcomeHash(M1, 0, deadline));
        uint256 original = block.chainid;
        vm.chainId(original + 1);
        assertEq(pool.domainSeparator(), _domain(address(pool), original + 1));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline, sig);
        vm.chainId(original);
        pool.settle(M1, 0, deadline, sig);
    }

    // ================================================================== payouts

    function test_marketsAreIsolatedSameToken() public {
        _createMarket(M1, IMD);
        _createMarket(M2, IMD);
        _bet(M1, alice, 0, 100 ether, 10_000);
        _bet(M1, bob, 1, 100 ether, 10_000);
        _bet(M2, carol, 0, 7 ether, 1_000);
        _bet(M2, dave, 1, 3 ether, 9_000);
        _settle(M1, 0);
        _claim(M1, alice, 195 ether);
        // M1 is drained to zero (no dust here); M2 still holds exactly its pot
        assertEq(MockERC20(IMD).balanceOf(address(pool)), 10 ether);
        _settle(M2, 1);
        // losing 7, fee 0.35, distributable 6.65 all to dave
        assertEq(MockERC20(IMD).balanceOf(FEE_RECIPIENT), 5 ether + 0.35 ether);
        _claim(M2, dave, 3 ether + 6.65 ether);
        assertEq(MockERC20(IMD).balanceOf(address(pool)), 0);
    }

    function test_dustAtMostOneWeiPerWinner() public {
        _createMarket(M1, IMD);
        // three equal winners splitting a distributable amount not divisible by three
        _bet(M1, alice, 0, 1 ether, 10_000);
        _bet(M1, bob, 0, 1 ether, 10_000);
        _bet(M1, carol, 0, 1 ether, 10_000);
        _bet(M1, dave, 1, 1 ether + 1, 10_000);
        _settle(M1, 0);
        uint256 losing = 1 ether + 1;
        uint256 dist = losing - losing * 500 / 10_000;
        uint256 each = 1 ether + dist / 3;
        _claim(M1, alice, each);
        _claim(M1, bob, each);
        _claim(M1, carol, each);
        uint256 dust = MockERC20(IMD).balanceOf(address(pool));
        assertEq(dust, dist % 3);
        assertLe(dust, 3);
    }

    function test_hardCapBetsSettleWithoutOverflow() public {
        vm.startPrank(OWNER);
        pool.setLimits(IMD, 1, 10_000 ether);
        pool.setLimits(SHIFT, 1, 500_000_000 ether);
        vm.stopPrank();
        _createMarket(M1, SHIFT);
        for (uint256 i; i < 20; ++i) {
            _bet(M1, address(uint160(0x5000 + i)), uint8(i % 2), 500_000_000 ether, uint16(500 + i * 450));
        }
        _settle(M1, 1);
        uint256 losing = 10 * 500_000_000 ether;
        assertEq(MockERC20(SHIFT).balanceOf(FEE_RECIPIENT), losing / 20);
        uint256 paid;
        for (uint256 i = 1; i < 20; i += 2) {
            address w = address(uint160(0x5000 + i));
            uint256 c = pool.claimable(M1, w);
            assertGt(c, 500_000_000 ether);
            vm.prank(w);
            pool.claim(M1);
            paid += c;
        }
        assertLe(MockERC20(SHIFT).balanceOf(address(pool)), 10);
        assertEq(paid + losing / 20 + MockERC20(SHIFT).balanceOf(address(pool)), 20 * 500_000_000 ether);

        // IMD at its hard cap too
        _createMarket(M2, IMD);
        _bet(M2, alice, 0, 10_000 ether, 10_000);
        _bet(M2, bob, 1, 10_000 ether, 500);
        _settle(M2, 1);
        _claim(M2, bob, 10_000 ether + 9_500 ether);
    }

    function test_minWeightWinnerStillGetsWholeLosingPotWhenAlone() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 0.1 ether, 500);
        _bet(M1, bob, 1, 500 ether, 10_000);
        _settle(M1, 0);
        _claim(M1, alice, 0.1 ether + 475 ether);
        assertEq(MockERC20(IMD).balanceOf(FEE_RECIPIENT), 25 ether);
        assertEq(MockERC20(IMD).balanceOf(address(pool)), 0);
    }

    function test_hedgerRefundedBothSidesOnVoidAndOneSided() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 4 ether, 10_000);
        _bet(M1, alice, 1, 6 ether, 700);
        _settle(M1, 2);
        _claim(M1, alice, 10 ether);

        // only alice bet, on both sides: a decided result has both sides non-empty, so it pays out
        _createMarket(M2, IMD);
        _bet(M2, alice, 0, 4 ether, 10_000);
        _bet(M2, alice, 1, 6 ether, 700);
        _settle(M2, 1);
        (,,,,,,,,, bool refundable) = pool.markets(M2);
        assertFalse(refundable);
        assertEq(MockERC20(IMD).balanceOf(FEE_RECIPIENT), 0.2 ether);
        _claim(M2, alice, 6 ether + 3.8 ether);
    }

    function test_loserInRefundableMarketGetsStakeBack() public {
        _createMarket(M1, IMD);
        _bet(M1, bob, 1, 5 ether, 10_000);
        _settle(M1, 0); // A won but nobody backed A
        _claim(M1, bob, 5 ether);
    }

    function test_settledStateFrozenAfterClaims() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 5_000);
        _settle(M1, 1);
        (,,, uint256 tA, uint256 tB, uint256 sA, uint256 sB,, uint8 o,) = pool.markets(M1);
        _claim(M1, bob, 19.5 ether);
        (,,, uint256 tA2, uint256 tB2, uint256 sA2, uint256 sB2,, uint8 o2,) = pool.markets(M1);
        assertEq(tA, tA2);
        assertEq(tB, tB2);
        assertEq(sA, sA2);
        assertEq(sB, sB2);
        assertEq(o, o2);
        (,,,, bool claimed) = _bets(M1, bob);
        assertTrue(claimed);
        (,,,, claimed) = _bets(M1, alice);
        assertFalse(claimed); // a loser who never claimed is not flagged
    }

    function test_claimableViewsForUnknownAndUnsettled() public view {
        assertEq(pool.claimable(M3, alice), 0);
        (address token,,,,,,,,,) = pool.markets(M3);
        assertEq(token, address(0));
        (uint256 mn, uint256 mx) = pool.limits(address(0xCAFE));
        assertEq(mn, 0);
        assertEq(mx, 0);
        assertEq(pool.hardCap(address(0xCAFE)), 0);
        assertFalse(pool.usedNonce(bytes32(0)));
    }

    // ================================================================== claimMany

    function test_claimManyEmptyArrayReverts() public {
        vm.prank(alice);
        vm.expectRevert(BetPool.NothingToClaim.selector);
        pool.claimMany(new bytes32[](0));
    }

    function test_claimManyDuplicateIdsPayOnce() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 10_000);
        _settle(M1, 0);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = M1;
        ids[1] = M1;
        ids[2] = M1;
        vm.expectEmit(address(pool));
        emit BetPool.Claimed(M1, alice, 19.5 ether);
        vm.prank(alice);
        uint256 total = pool.claimMany(ids);
        assertEq(total, 19.5 ether);
        assertEq(MockERC20(IMD).balanceOf(alice), 19.5 ether);
        assertEq(MockERC20(IMD).balanceOf(address(pool)), 0);
    }

    function test_claimManySkipsUnsettledAndLosing() public {
        _createMarket(M1, IMD);
        _createMarket(M2, IMD);
        _createMarket(M3, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 10_000);
        _bet(M2, alice, 1, 10 ether, 10_000);
        _bet(M2, bob, 0, 10 ether, 10_000);
        _bet(M3, alice, 0, 1 ether, 10_000);
        _settle(M1, 0); // alice wins
        _settle(M2, 0); // alice loses
        // M3 unsettled
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = M2;
        ids[1] = M3;
        ids[2] = M1;
        vm.prank(alice);
        pool.claimMany(ids);
        assertEq(MockERC20(IMD).balanceOf(alice), 19.5 ether);
        (,,,, bool claimed) = _bets(M2, alice);
        assertFalse(claimed);
        (,,,, claimed) = _bets(M3, alice);
        assertFalse(claimed);

        // a single claim after claimMany is refused
        vm.prank(alice);
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        pool.claim(M1);

        // only losing/unsettled left: claimMany reverts
        bytes32[] memory rest = new bytes32[](2);
        rest[0] = M2;
        rest[1] = M3;
        vm.prank(alice);
        vm.expectRevert(BetPool.NothingToClaim.selector);
        pool.claimMany(rest);
    }

    function test_claimManyWorksWhilePaused() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 10_000);
        vm.prank(OWNER);
        pool.pause();
        _settle(M1, 0);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = M1;
        vm.prank(alice);
        pool.claimMany(ids);
        assertEq(MockERC20(IMD).balanceOf(alice), 19.5 ether);
    }

    // ================================================================== owner

    function test_ownerSettingsWorkWhilePausedAndPauseIsNotIdempotent() public {
        vm.startPrank(OWNER);
        pool.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.pause();
        pool.setLimits(IMD, 1 ether, 2 ether);
        pool.setSigner(makeAddr("s2"));
        pool.unpause();
        vm.expectRevert(Pausable.ExpectedPause.selector);
        pool.unpause();
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.unpause();
    }

    function test_ownershipHandoverMovesAllPowers() public {
        vm.prank(OWNER);
        pool.transferOwnership(alice);
        // pending owner has no power yet
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.pause();
        vm.prank(alice);
        pool.acceptOwnership();

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        pool.setSigner(OWNER);
        vm.prank(alice);
        pool.pause();
        assertTrue(pool.paused());

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        pool.acceptOwnership();
    }

    function test_ownerCannotExpireEarlyOrClaimOthersAfterSettle() public {
        _createMarket(M1, SHIFT);
        _bet(M1, alice, 0, 1_000 ether, 10_000);
        _bet(M1, bob, 1, 1_000 ether, 10_000);
        _settle(M1, 2);
        vm.prank(OWNER);
        vm.expectRevert(BetPool.NothingToClaim.selector);
        pool.claim(M1);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = M1;
        vm.prank(OWNER);
        vm.expectRevert(BetPool.NothingToClaim.selector);
        pool.claimMany(ids);
        // lowering limits after the fact does not touch existing positions
        vm.prank(OWNER);
        pool.setLimits(SHIFT, 1 ether, 1 ether);
        _claim(M1, alice, 1_000 ether);
        _claim(M1, bob, 1_000 ether);
        assertEq(MockERC20(SHIFT).balanceOf(OWNER), 0);
    }

    function test_constantsCannotBeChangedByOwner() public {
        // No setter exists for fee, fee recipient or tokens.
        string[5] memory sigs = [
            "setFee(uint256)",
            "setFeeRecipient(address)",
            "setToken(address,bool)",
            "rescue(address,address,uint256)",
            "upgradeTo(address)"
        ];
        vm.startPrank(OWNER);
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(pool).call(abi.encodeWithSignature(sigs[i], address(1), address(1), 1));
            assertFalse(ok, sigs[i]);
        }
        vm.stopPrank();
        assertEq(pool.FEE_BPS(), 500);
        assertEq(pool.FEE_RECIPIENT(), FEE_RECIPIENT);
    }

    // ================================================================== fuzz

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_claimManyEqualsIndividualClaims(uint256[4] memory amounts, uint16[4] memory weights, uint8 mask)
        public
    {
        _createMarket(M1, IMD);
        _createMarket(M2, IMD);
        address[4] memory who = [alice, bob, carol, dave];
        for (uint256 i; i < 4; ++i) {
            uint256 amt = bound(amounts[i], 0.1 ether, 500 ether);
            uint16 w = uint16(bound(weights[i], 500, 10_000));
            _bet(M1, who[i], uint8((mask >> i) & 1), amt, w);
            _bet(M2, who[i], uint8((mask >> i) & 1), amt, w);
        }
        _settle(M1, 0);
        _settle(M2, 0);
        bytes32[] memory one = new bytes32[](1);
        one[0] = M2;
        for (uint256 i; i < 4; ++i) {
            uint256 c1 = pool.claimable(M1, who[i]);
            uint256 c2 = pool.claimable(M2, who[i]);
            assertEq(c1, c2);
            if (c1 == 0) continue;
            vm.prank(who[i]);
            uint256 a = pool.claim(M1);
            vm.prank(who[i]);
            uint256 b = pool.claimMany(one);
            assertEq(a, b);
        }
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_payoutMatchesWeightedFormula(uint256[3] memory amt, uint16[2] memory w, bool useShift) public {
        address token = useShift ? SHIFT : IMD;
        (uint256 mn, uint256 mx) = pool.limits(token);
        for (uint256 i; i < 3; ++i) {
            amt[i] = bound(amt[i], mn, mx);
        }
        w[0] = uint16(bound(w[0], 500, 10_000));
        w[1] = uint16(bound(w[1], 500, 10_000));
        _createMarket(M1, token);
        _bet(M1, alice, 1, amt[0], w[0]);
        _bet(M1, bob, 1, amt[1], w[1]);
        _bet(M1, carol, 0, amt[2], 10_000);
        _settle(M1, 1);
        uint256 sa = amt[0] * w[0] / 10_000;
        uint256 sb = amt[1] * w[1] / 10_000;
        uint256 dist = amt[2] - amt[2] * 500 / 10_000;
        assertEq(MockERC20(token).balanceOf(FEE_RECIPIENT), amt[2] * 500 / 10_000);
        uint256 pa = pool.claimable(M1, alice);
        uint256 pb = pool.claimable(M1, bob);
        assertEq(pa, amt[0] + dist * sa / (sa + sb));
        assertEq(pb, amt[1] + dist * sb / (sa + sb));
        assertEq(pool.claimable(M1, carol), 0);
        // the bettor with more weighted shares gets at least as large a share of the losing pot
        if (sa >= sb) assertGe(pa - amt[0], pb - amt[1]);
        else assertGe(pb - amt[1], pa - amt[0]);
        _claim(M1, alice, pa);
        _claim(M1, bob, pb);
        assertLe(MockERC20(token).balanceOf(address(pool)), 2);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_refundableAlwaysReturnsExactStake(uint256 a1, uint256 a2, uint8 outcome, bool oneSided) public {
        _createMarket(M1, IMD);
        a1 = bound(a1, 0.1 ether, 500 ether);
        a2 = bound(a2, 0.1 ether, 500 ether);
        _bet(M1, alice, 0, a1, 600);
        _bet(M1, bob, oneSided ? 0 : 1, a2, 9_400);
        // void always refunds; a one-sided market refunds for any outcome
        outcome = oneSided ? uint8(bound(outcome, 0, 2)) : 2;
        _settle(M1, outcome);
        assertEq(MockERC20(IMD).balanceOf(FEE_RECIPIENT), 0);
        _claim(M1, alice, a1);
        _claim(M1, bob, a2);
        assertEq(MockERC20(IMD).balanceOf(address(pool)), 0);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_betLimitBoundaries(uint256 amount, bool useShift) public {
        address token = useShift ? SHIFT : IMD;
        (uint256 mn, uint256 mx) = pool.limits(token);
        amount = bound(amount, 0, mx * 2);
        _createMarket(M1, token);
        _fund(token, alice, amount);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, amount, 10_000, expiry, nonce));
        vm.prank(alice);
        if (amount < mn || amount > mx) {
            vm.expectRevert(BetPool.AmountOutOfLimits.selector);
            pool.bet(M1, 0, amount, 10_000, expiry, nonce, sig);
        } else {
            pool.bet(M1, 0, amount, 10_000, expiry, nonce, sig);
            assertEq(MockERC20(token).balanceOf(address(pool)), amount);
        }
    }

    // ================================================================== helpers

    function _bets(bytes32 id, address who) internal view returns (uint256, uint256, uint256, uint256, bool) {
        return pool.betsOf(id, who);
    }

    function _claim(bytes32 id, address who, uint256 expected) internal {
        (address token,,,,,,,,,) = pool.markets(id);
        uint256 before = ERC20(token).balanceOf(who);
        assertEq(pool.claimable(id, who), expected);
        vm.prank(who);
        uint256 paid = pool.claim(id);
        assertEq(paid, expected);
        assertEq(ERC20(token).balanceOf(who) - before, expected);
        assertEq(pool.claimable(id, who), 0);
    }
}
