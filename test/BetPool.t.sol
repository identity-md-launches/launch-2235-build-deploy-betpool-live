// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPool} from "../src/BetPool.sol";
import {BetPoolBase} from "./utils/BetPoolBase.sol";
import {MockERC20, ReentrantERC20} from "./utils/Mocks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract BetPoolTest is BetPoolBase {
    bytes32 internal constant M1 = keccak256("match-1");
    bytes32 internal constant M2 = keccak256("match-2");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");
    address internal frank = makeAddr("frank");

    // ================================================================== deployment

    function test_constructorDefaults() public view {
        assertEq(pool.owner(), OWNER);
        assertEq(pool.signer(), signerAddr);
        (uint256 mn, uint256 mx) = pool.limits(IMD);
        assertEq(mn, 0.1 ether);
        assertEq(mx, 500 ether);
        (mn, mx) = pool.limits(SHIFT);
        assertEq(mn, 1_000 ether);
        assertEq(mx, 25_000_000 ether);
        assertEq(pool.hardCap(IMD), 10_000 ether);
        assertEq(pool.hardCap(SHIFT), 500_000_000 ether);
        assertEq(pool.FEE_BPS(), 500);
        assertEq(pool.FEE_RECIPIENT(), FEE_RECIPIENT);
        assertEq(pool.domainSeparator(), _domain(address(pool), block.chainid));
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BetPool(address(0));
    }

    function test_signerUnsetBlocksSignedActions() public {
        BetPool fresh = new BetPool(OWNER);
        assertEq(fresh.signer(), address(0));
        uint64 closesAt = uint64(block.timestamp + 1 hours);
        vm.expectRevert(BetPool.SignerNotSet.selector);
        fresh.createMarket(M1, IMD, closesAt, bytes32(0), "");

        vm.prank(OWNER);
        fresh.setSigner(signerAddr);
        bytes memory sig = _sign(signerKey, _domain(address(fresh), block.chainid), _marketHash(M1, IMD, closesAt, 0));
        fresh.createMarket(M1, IMD, closesAt, bytes32(0), sig);
        (address token,,,,,,,,,) = fresh.markets(M1);
        assertEq(token, IMD);
    }

    // ================================================================== full flows

    function test_fullFlowIMD_weightedPayouts() public {
        _createMarket(M1, IMD);
        // Side A: three bettors, limits and in between, different weights
        _bet(M1, alice, 0, 100 ether, 10_000);
        _bet(M1, bob, 0, 0.1 ether, 5_000); // at min
        _bet(M1, carol, 0, 500 ether, 2_500); // at max
        // Side B
        _bet(M1, dave, 1, 250 ether, 8_000);
        _bet(M1, erin, 1, 33.333333333333333333 ether, 500); // odd amount
        _bet(M1, alice, 1, 7 ether, 9_999); // alice hedges on B too

        (,,, uint256 totalA, uint256 totalB, uint256 sharesA, uint256 sharesB,,,) = pool.markets(M1);
        assertEq(totalA, 600.1 ether);
        assertEq(totalB, 290.333333333333333333 ether);
        assertEq(sharesA, 100 ether + 0.05 ether + 125 ether);
        assertEq(sharesB, 200 ether + 1.666666666666666666 ether + 6.9993 ether);

        _settleAndCheck(M1, IMD, 0, _addrs(alice, bob, carol), _addrs(dave, erin));
    }

    function test_fullFlowSHIFT_weightedPayouts() public {
        _createMarket(M2, SHIFT);
        _bet(M2, alice, 1, 25_000_000 ether, 10_000); // max
        _bet(M2, bob, 1, 1_000 ether, 500); // min, minimum weight
        _bet(M2, carol, 1, 1_234_567.891011121314151617 ether, 7_321);
        _bet(M2, dave, 0, 3_000_000 ether, 6_000);
        _bet(M2, erin, 0, 1_001 ether, 10_000);
        _bet(M2, frank, 0, 24_999_999 ether, 1_234);
        _bet(M2, frank, 0, 7_777 ether + 1, 9_000);

        _settleAndCheck(M2, SHIFT, 1, _addrs(dave, erin, frank), _addrs(alice, bob, carol));
    }

    function test_payoutsFollowWeightedShares() public {
        _createMarket(M1, IMD);
        // Same amount, early bettor weight 10000, late bettor weight 2500 => 4x the winnings share
        _bet(M1, alice, 0, 100 ether, 10_000);
        _bet(M1, bob, 0, 100 ether, 2_500);
        _bet(M1, carol, 1, 200 ether, 10_000);
        _settle(M1, 0);
        // losing side 200, fee 10, distributable 190; shares 100 vs 25
        assertEq(pool.claimable(M1, alice), 100 ether + 152 ether);
        assertEq(pool.claimable(M1, bob), 100 ether + 38 ether);
        assertEq(pool.claimable(M1, carol), 0);
        assertEq(MockERC20(IMD).balanceOf(FEE_RECIPIENT), 10 ether);
    }

    function test_multipleBetsSameWalletAccumulate() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, alice, 0, 10 ether, 5_000);
        _bet(M1, alice, 1, 4 ether, 2_000);
        (uint256 aA, uint256 aB, uint256 sA, uint256 sB, bool claimed) = pool.betsOf(M1, alice);
        assertEq(aA, 20 ether);
        assertEq(aB, 4 ether);
        assertEq(sA, 15 ether);
        assertEq(sB, 0.8 ether);
        assertFalse(claimed);
    }

    function test_feeExactlyFivePercentOddAmountsManyBettors() public {
        _createMarket(M1, IMD);
        uint256 losing;
        for (uint256 i; i < 30; ++i) {
            address w = address(uint160(0x1000 + i));
            uint256 amt = 0.1 ether + i * 13.370000000000000007 ether + i;
            _bet(M1, w, 1, amt, uint16(500 + i * 317));
            losing += amt;
        }
        for (uint256 i; i < 17; ++i) {
            address w = address(uint160(0x2000 + i));
            _bet(M1, w, 0, 0.1 ether + i * 29.999999999999999999 ether, uint16(10_000 - i * 401));
        }
        uint256 before = MockERC20(IMD).balanceOf(FEE_RECIPIENT);
        vm.expectEmit(address(pool));
        emit BetPool.Settled(M1, 0, losing * 500 / 10_000);
        _settle(M1, 0);
        assertEq(MockERC20(IMD).balanceOf(FEE_RECIPIENT) - before, losing * 5 / 100);
        assertEq(losing * 5 / 100, losing * 500 / 10_000);
    }

    // ================================================================== refunds

    function test_voidRefundsEverythingNoFee() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 100 ether, 10_000);
        _bet(M1, bob, 1, 50 ether, 700);
        _bet(M1, bob, 0, 3 ether, 700);
        vm.expectEmit(address(pool));
        emit BetPool.Settled(M1, 2, 0);
        _settle(M1, 2);
        (,,,,,,, bool settled, uint8 outcome, bool refundable) = pool.markets(M1);
        assertTrue(settled);
        assertEq(outcome, 2);
        assertTrue(refundable);
        assertEq(MockERC20(IMD).balanceOf(FEE_RECIPIENT), 0);
        _claimExpect(M1, alice, 100 ether);
        _claimExpect(M1, bob, 53 ether);
        assertEq(MockERC20(IMD).balanceOf(address(pool)), 0);
    }

    function test_oneSidedMarketWinningSideOnlyRefunds() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 100 ether, 10_000);
        _bet(M1, bob, 0, 10 ether, 500);
        _settle(M1, 0); // losing side has no bets
        (,,,,,,,, uint8 outcome, bool refundable) = pool.markets(M1);
        assertEq(outcome, 0);
        assertTrue(refundable);
        _claimExpect(M1, alice, 100 ether);
        _claimExpect(M1, bob, 10 ether);
        assertEq(MockERC20(IMD).balanceOf(FEE_RECIPIENT), 0);
    }

    function test_oneSidedMarketLosingSideOnlyRefunds() public {
        _createMarket(M1, SHIFT);
        _bet(M1, alice, 1, 5_000 ether, 10_000);
        _settle(M1, 0); // winning side has no bets: nobody to pay, so refund
        (,,,,,,,,, bool refundable) = pool.markets(M1);
        assertTrue(refundable);
        _claimExpect(M1, alice, 5_000 ether);
        assertEq(MockERC20(SHIFT).balanceOf(FEE_RECIPIENT), 0);
    }

    function test_emptyMarketSettlesRefundable() public {
        _createMarket(M1, IMD);
        _settle(M1, 1);
        (,,,,,,,,, bool refundable) = pool.markets(M1);
        assertTrue(refundable);
        vm.prank(alice);
        vm.expectRevert(BetPool.NothingToClaim.selector);
        pool.claim(M1);
    }

    function test_expireAfter24Hours() public {
        uint64 closesAt = _createMarket(M1, IMD);
        _bet(M1, alice, 0, 100 ether, 10_000);
        _bet(M1, bob, 1, 40 ether, 1_000);

        vm.warp(uint256(closesAt) + 24 hours);
        vm.expectRevert(BetPool.NotExpirable.selector);
        pool.expire(M1);
        vm.prank(alice);
        vm.expectRevert(BetPool.NotSettled.selector);
        pool.claim(M1);

        vm.warp(uint256(closesAt) + 24 hours + 1);
        vm.expectEmit(address(pool));
        emit BetPool.Expired(M1);
        vm.prank(frank);
        pool.expire(M1);

        (,,,,,,, bool settled, uint8 outcome, bool refundable) = pool.markets(M1);
        assertTrue(settled);
        assertEq(outcome, 2);
        assertTrue(refundable);

        vm.expectRevert(BetPool.MarketSettled.selector);
        pool.expire(M1);
        uint256 deadline = block.timestamp + 100;
        bytes memory sig = _signHash(_outcomeHash(M1, 0, deadline));
        vm.expectRevert(BetPool.MarketSettled.selector);
        pool.settle(M1, 0, deadline, sig);

        _claimExpect(M1, alice, 100 ether);
        _claimExpect(M1, bob, 40 ether);
        assertEq(MockERC20(IMD).balanceOf(FEE_RECIPIENT), 0);
    }

    function test_expireRefusedOnSettledOrUnknown() public {
        uint64 closesAt = _createMarket(M1, IMD);
        _settle(M1, 2);
        vm.warp(uint256(closesAt) + 2 days);
        vm.expectRevert(BetPool.MarketSettled.selector);
        pool.expire(M1);
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.expire(M2);
    }

    function test_settleStillPossibleLateIfNotExpired() public {
        uint64 closesAt = _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 10_000);
        vm.warp(uint256(closesAt) + 30 hours);
        _settle(M1, 0);
        assertEq(pool.claimable(M1, alice), 19.5 ether);
    }

    // ================================================================== claims

    function test_doubleClaimRefused() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 10_000);
        _settle(M1, 0);
        _claimExpect(M1, alice, 19.5 ether);
        assertEq(pool.claimable(M1, alice), 0);
        vm.prank(alice);
        vm.expectRevert(BetPool.AlreadyClaimed.selector);
        pool.claim(M1);
    }

    function test_loserClaimGetsNothing() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 10_000);
        _settle(M1, 0);
        assertEq(pool.claimable(M1, bob), 0);
        vm.prank(bob);
        vm.expectRevert(BetPool.NothingToClaim.selector);
        pool.claim(M1);
        assertEq(MockERC20(IMD).balanceOf(bob), 0);
    }

    function test_hedgerGetsOnlyWinningSide() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, alice, 1, 10 ether, 10_000);
        _bet(M1, bob, 1, 30 ether, 10_000);
        _settle(M1, 0);
        // losing 40, fee 2, distributable 38 all to alice's 10 on A
        _claimExpect(M1, alice, 48 ether);
    }

    function test_claimBeforeSettleRefused() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        vm.prank(alice);
        vm.expectRevert(BetPool.NotSettled.selector);
        pool.claim(M1);
        vm.prank(alice);
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.claim(M2);
        assertEq(pool.claimable(M1, alice), 0);
    }

    function test_claimMany() public {
        _createMarket(M1, IMD);
        _createMarket(M2, SHIFT);
        bytes32 m3 = keccak256("m3");
        _createMarket(m3, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 10_000);
        _bet(M2, alice, 1, 2_000 ether, 10_000);
        _bet(M2, bob, 0, 2_000 ether, 10_000);
        _bet(m3, alice, 1, 1 ether, 10_000); // alice loses m3
        _bet(m3, bob, 0, 1 ether, 10_000);
        _settle(M1, 0);
        _settle(M2, 2);
        _settle(m3, 0);

        bytes32[] memory ids = new bytes32[](4);
        ids[0] = M1;
        ids[1] = M2;
        ids[2] = m3;
        ids[3] = keccak256("unknown");
        vm.prank(alice);
        pool.claimMany(ids);
        assertEq(MockERC20(IMD).balanceOf(alice), 19.5 ether);
        assertEq(MockERC20(SHIFT).balanceOf(alice), 2_000 ether);
        (,,,, bool claimed) = pool.betsOf(M1, alice);
        assertTrue(claimed);

        vm.prank(alice);
        vm.expectRevert(BetPool.NothingToClaim.selector);
        pool.claimMany(ids);
    }

    // ================================================================== ticket checks

    function _ticketSetup() internal returns (uint64 expiry, bytes32 nonce) {
        _createMarket(M1, IMD);
        _fund(IMD, alice, 1_000 ether);
        expiry = uint64(block.timestamp + 60);
        nonce = _nextNonce();
    }

    function test_ticketWrongBettor() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        bytes memory sig = _signHash(_ticketHash(M1, bob, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_ticketWrongSide() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 1, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_ticketInvalidSideValue() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 2, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSide.selector);
        pool.bet(M1, 2, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_ticketWrongAmount() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 11 ether, 10_000, expiry, nonce, sig);
    }

    function test_ticketWrongWeight() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 600, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_ticketWeightOutOfRange() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        uint16[2] memory bad = [uint16(499), uint16(10_001)];
        for (uint256 i; i < 2; ++i) {
            bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, bad[i], expiry, nonce));
            vm.prank(alice);
            vm.expectRevert(BetPool.InvalidWeight.selector);
            pool.bet(M1, 0, 10 ether, bad[i], expiry, nonce, sig);
        }
        // boundaries accepted
        _bet(M1, alice, 0, 10 ether, 500);
        _bet(M1, alice, 0, 10 ether, 10_000);
        (,, uint256 sA,,) = pool.betsOf(M1, alice);
        assertEq(sA, 0.5 ether + 10 ether);
    }

    function test_ticketExpired() public {
        (, bytes32 nonce) = _ticketSetup();
        uint64 expiry = uint64(block.timestamp + 10);
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.warp(block.timestamp + 11);
        vm.prank(alice);
        vm.expectRevert(BetPool.TicketExpired.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_ticketAtExactExpiryAccepted() public {
        (, bytes32 nonce) = _ticketSetup();
        uint64 expiry = uint64(block.timestamp + 10);
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.warp(expiry);
        vm.prank(alice);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
        assertTrue(pool.usedNonce(nonce));
    }

    function test_ticketTooFarExpiry() public {
        (, bytes32 nonce) = _ticketSetup();
        uint64 expiry = uint64(block.timestamp + 121);
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.TicketTooLong.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);

        expiry = uint64(block.timestamp + 120);
        sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_ticketReusedNonce() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
        vm.prank(alice);
        vm.expectRevert(BetPool.NonceUsed.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
        // a nonce is global: a different ticket with the same nonce is refused too
        bytes memory sig2 = _signHash(_ticketHash(M1, alice, 1, 5 ether, 9_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.NonceUsed.selector);
        pool.bet(M1, 1, 5 ether, 9_000, expiry, nonce, sig2);
    }

    function test_ticketWrongSigner() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        bytes memory sig = _sign(
            0xB0B, _domain(address(pool), block.chainid), _ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce)
        );
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_ticketWrongContract() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        bytes memory sig = _sign(
            signerKey,
            _domain(address(0xC0FFEE), block.chainid),
            _ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce)
        );
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_ticketWrongChain() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        bytes memory sig = _sign(
            signerKey,
            _domain(address(pool), block.chainid + 1),
            _ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce)
        );
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);

        // and a correctly signed ticket stops working after a fork to another chain id
        bytes memory good = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.chainId(block.chainid + 7);
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, good);
    }

    function test_ticketMalformedSignature() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, hex"1234");
    }

    function test_ticketForOtherMarketRefused() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        _createMarket(M2, IMD);
        bytes memory sig = _signHash(_ticketHash(M2, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_signerRotationInvalidatesOldSigner() public {
        (uint64 expiry, bytes32 nonce) = _ticketSetup();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(OWNER);
        pool.setSigner(vm.addr(0xB0B));
        vm.prank(alice);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    // ================================================================== market state checks for bets

    function test_betAfterClosesAtRefused() public {
        uint64 closesAt = _createMarket(M1, IMD);
        _fund(IMD, alice, 10 ether);
        vm.warp(closesAt);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.BettingClosed.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_betOneSecondBeforeCloseAccepted() public {
        uint64 closesAt = _createMarket(M1, IMD);
        vm.warp(closesAt - 1);
        _bet(M1, alice, 0, 10 ether, 10_000);
    }

    function test_betOnSettledMarketRefused() public {
        _createMarket(M1, IMD);
        _settle(M1, 2);
        _fund(IMD, alice, 10 ether);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.MarketSettled.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_betOnUnknownMarketRefused() public {
        _fund(IMD, alice, 10 ether);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    function test_betLimits() public {
        _createMarket(M1, IMD);
        _createMarket(M2, SHIFT);
        _expectLimitRevert(M1, 0.1 ether - 1);
        _expectLimitRevert(M1, 500 ether + 1);
        _expectLimitRevert(M2, 1_000 ether - 1);
        _expectLimitRevert(M2, 25_000_000 ether + 1);
        _bet(M1, alice, 0, 0.1 ether, 10_000);
        _bet(M1, alice, 0, 500 ether, 10_000);
        _bet(M2, alice, 0, 1_000 ether, 10_000);
        _bet(M2, alice, 0, 25_000_000 ether, 10_000);
    }

    function _expectLimitRevert(bytes32 id, uint256 amount) internal {
        (address token,,,,,,,,,) = pool.markets(id);
        _fund(token, carol, amount);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(id, carol, 0, amount, 10_000, expiry, nonce));
        vm.prank(carol);
        vm.expectRevert(BetPool.AmountOutOfLimits.selector);
        pool.bet(id, 0, amount, 10_000, expiry, nonce, sig);
    }

    function test_betWithoutAllowanceReverts() public {
        _createMarket(M1, IMD);
        MockERC20(IMD).mint(alice, 10 ether);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert();
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
        assertFalse(pool.usedNonce(nonce));
    }

    function test_betEmitsAndPullsExactAmount() public {
        _createMarket(M1, IMD);
        _fund(IMD, alice, 50 ether);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 1, 12.5 ether, 3_333, expiry, nonce));
        vm.expectEmit(address(pool));
        emit BetPool.BetPlaced(M1, alice, 1, 12.5 ether, 3_333, 12.5 ether * 3_333 / 10_000);
        vm.prank(alice);
        pool.bet(M1, 1, 12.5 ether, 3_333, expiry, nonce, sig);
        assertEq(MockERC20(IMD).balanceOf(alice), 37.5 ether);
        assertEq(MockERC20(IMD).balanceOf(address(pool)), 12.5 ether);
    }

    function test_feeOnTransferTokenRefused() public {
        _createMarket(M1, IMD);
        deployCodeTo("Mocks.sol:FeeOnTransferERC20", IMD);
        _fund(IMD, alice, 10 ether);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.TransferMismatch.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, sig);
    }

    // ================================================================== market creation

    function test_createMarketEmitsAndStores() public {
        uint64 closesAt = uint64(block.timestamp + 1 hours);
        bytes32 game = bytes32("SPACE PINBALL");
        bytes memory sig = _signHash(_marketHash(M1, SHIFT, closesAt, game));
        vm.expectEmit(address(pool));
        emit BetPool.MarketCreated(M1, SHIFT, closesAt, game);
        vm.prank(frank);
        pool.createMarket(M1, SHIFT, closesAt, game, sig);
        (address token, uint64 c, bytes32 g,,,,, bool settled,, bool refundable) = pool.markets(M1);
        assertEq(token, SHIFT);
        assertEq(c, closesAt);
        assertEq(g, game);
        assertFalse(settled);
        assertFalse(refundable);
    }

    function test_createMarketSignatureChecks() public {
        uint64 closesAt = uint64(block.timestamp + 1 hours);
        bytes32 game = bytes32("g");
        bytes32 h = _marketHash(M1, IMD, closesAt, game);
        // wrong signer
        bytes memory bad = _sign(0xB0B, _domain(address(pool), block.chainid), h);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(M1, IMD, closesAt, game, bad);
        // wrong contract / chain
        bad = _sign(signerKey, _domain(address(1), block.chainid), h);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(M1, IMD, closesAt, game, bad);
        bad = _sign(signerKey, _domain(address(pool), 5), h);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(M1, IMD, closesAt, game, bad);
        // tampered fields
        bytes memory good = _signHash(h);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(M1, SHIFT, closesAt, game, good);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(M1, IMD, closesAt + 1, game, good);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(M1, IMD, closesAt, bytes32("h"), good);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.createMarket(M2, IMD, closesAt, game, good);
        // genuine
        pool.createMarket(M1, IMD, closesAt, game, good);
        vm.expectRevert(BetPool.MarketExists.selector);
        pool.createMarket(M1, IMD, closesAt, game, good);
    }

    function test_createMarketParameterChecks() public {
        bytes32 game = bytes32("g");
        uint64 t = uint64(block.timestamp);
        vm.expectRevert(BetPool.InvalidClosesAt.selector);
        pool.createMarket(M1, IMD, t, game, _signHash(_marketHash(M1, IMD, t, game)));
        uint64 far = uint64(block.timestamp + 7 days + 1);
        vm.expectRevert(BetPool.InvalidClosesAt.selector);
        pool.createMarket(M1, IMD, far, game, _signHash(_marketHash(M1, IMD, far, game)));
        address other = address(new MockERC20());
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.createMarket(M1, other, t + 60, game, _signHash(_marketHash(M1, other, t + 60, game)));
        uint64 max = uint64(block.timestamp + 7 days);
        pool.createMarket(M1, IMD, max, game, _signHash(_marketHash(M1, IMD, max, game)));
    }

    // ================================================================== settlement

    function test_settleSignatureChecks() public {
        _createMarket(M1, IMD);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 h = _outcomeHash(M1, 0, deadline);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline, _sign(0xB0B, _domain(address(pool), block.chainid), h));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline, _sign(signerKey, _domain(address(2), block.chainid), h));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline, _sign(signerKey, _domain(address(pool), 1337), h));
        bytes memory good = _signHash(h);
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 1, deadline, good); // flipped outcome
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline + 1, good);
        vm.expectRevert(BetPool.InvalidOutcome.selector);
        pool.settle(M1, 3, deadline, _signHash(_outcomeHash(M1, 3, deadline)));
        vm.expectRevert(BetPool.UnknownMarket.selector);
        pool.settle(M2, 0, deadline, _signHash(_outcomeHash(M2, 0, deadline)));

        vm.warp(deadline + 1);
        vm.expectRevert(BetPool.SignatureExpired.selector);
        pool.settle(M1, 0, deadline, good);
        vm.warp(deadline);
        pool.settle(M1, 0, deadline, good);
    }

    function test_doubleSettleRefused() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 10_000);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signHash(_outcomeHash(M1, 0, deadline));
        pool.settle(M1, 0, deadline, sig);
        vm.expectRevert(BetPool.MarketSettled.selector);
        pool.settle(M1, 0, deadline, sig);
        bytes memory sig2 = _signHash(_outcomeHash(M1, 1, deadline));
        vm.expectRevert(BetPool.MarketSettled.selector);
        pool.settle(M1, 1, deadline, sig2);
        assertEq(MockERC20(IMD).balanceOf(FEE_RECIPIENT), 0.5 ether);
    }

    function test_settleBeforeClosesAtClosesBetting() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _settle(M1, 0);
        _fund(IMD, bob, 10 ether);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, bob, 1, 10 ether, 10_000, expiry, nonce));
        vm.prank(bob);
        vm.expectRevert(BetPool.MarketSettled.selector);
        pool.bet(M1, 1, 10 ether, 10_000, expiry, nonce, sig);
    }

    // ================================================================== pause

    function test_pauseBlocksNewMarketsAndBetsOnly() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 10_000);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.pause();

        vm.prank(OWNER);
        pool.pause();

        uint64 closesAt = uint64(block.timestamp + 1 hours);
        bytes memory msig = _signHash(_marketHash(M2, IMD, closesAt, 0));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.createMarket(M2, IMD, closesAt, 0, msig);

        _fund(IMD, carol, 10 ether);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory tsig = _signHash(_ticketHash(M1, carol, 0, 10 ether, 10_000, expiry, nonce));
        vm.prank(carol);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.bet(M1, 0, 10 ether, 10_000, expiry, nonce, tsig);

        // settle and claim keep working
        _settle(M1, 0);
        _claimExpect(M1, alice, 19.5 ether);

        // expire keeps working
        vm.prank(OWNER);
        pool.unpause();
        bytes32 m3 = keccak256("m3");
        uint64 c3 = _createMarket(m3, IMD);
        _bet(m3, dave, 0, 1 ether, 10_000);
        vm.prank(OWNER);
        pool.pause();
        vm.warp(uint256(c3) + 24 hours + 1);
        pool.expire(m3);
        _claimExpect(m3, dave, 1 ether);

        vm.prank(OWNER);
        pool.unpause();
        pool.createMarket(
            M2,
            IMD,
            uint64(block.timestamp + 1 hours),
            0,
            _signHash(_marketHash(M2, IMD, uint64(block.timestamp + 1 hours), 0))
        );
    }

    // ================================================================== owner powers

    function test_setLimits() public {
        vm.expectEmit(address(pool));
        emit BetPool.LimitsSet(IMD, 1 ether, 10_000 ether);
        vm.prank(OWNER);
        pool.setLimits(IMD, 1 ether, 10_000 ether);
        (uint256 mn, uint256 mx) = pool.limits(IMD);
        assertEq(mn, 1 ether);
        assertEq(mx, 10_000 ether);

        vm.startPrank(OWNER);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 1 ether, 10_000 ether + 1);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(SHIFT, 1 ether, 500_000_000 ether + 1);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 0, 10 ether);
        vm.expectRevert(BetPool.InvalidLimits.selector);
        pool.setLimits(IMD, 11 ether, 10 ether);
        vm.expectRevert(BetPool.UnsupportedToken.selector);
        pool.setLimits(address(0x1234), 1, 2);
        pool.setLimits(SHIFT, 1, 500_000_000 ether);
        pool.setLimits(IMD, 5 ether, 5 ether);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setLimits(IMD, 1 ether, 2 ether);
    }

    function test_newLimitsApplyToBets() public {
        _createMarket(M1, IMD);
        vm.prank(OWNER);
        pool.setLimits(IMD, 1 ether, 10_000 ether);
        _expectLimitRevert(M1, 0.5 ether);
        _bet(M1, alice, 0, 10_000 ether, 10_000);
    }

    function test_tinyMinRejectsZeroShareBet() public {
        _createMarket(M1, IMD);
        vm.prank(OWNER);
        pool.setLimits(IMD, 1, 10 ether);
        _fund(IMD, alice, 1);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(M1, alice, 0, 1, 500, expiry, nonce));
        vm.prank(alice);
        vm.expectRevert(BetPool.ZeroShares.selector);
        pool.bet(M1, 0, 1, 500, expiry, nonce, sig);
    }

    function test_setSigner() public {
        address s2 = makeAddr("s2");
        vm.expectEmit(address(pool));
        emit BetPool.SignerSet(signerAddr, s2);
        vm.prank(OWNER);
        pool.setSigner(s2);
        assertEq(pool.signer(), s2);
        vm.prank(OWNER);
        vm.expectRevert(BetPool.InvalidSigner.selector);
        pool.setSigner(address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setSigner(alice);
    }

    function test_renounceDisabledAndTwoStepTransfer() public {
        vm.prank(OWNER);
        vm.expectRevert(BetPool.RenounceDisabled.selector);
        pool.renounceOwnership();
        vm.prank(OWNER);
        pool.transferOwnership(alice);
        assertEq(pool.owner(), OWNER);
        vm.prank(alice);
        pool.acceptOwnership();
        assertEq(pool.owner(), alice);
    }

    function test_ownerCannotMoveFunds() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 100 ether, 10_000);
        _bet(M1, bob, 1, 100 ether, 10_000);
        uint256 held = MockERC20(IMD).balanceOf(address(pool));

        // The owner has no claim, cannot settle without the signer, and cannot expire early.
        vm.startPrank(OWNER);
        vm.expectRevert(BetPool.NotSettled.selector);
        pool.claim(M1);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory forged = _sign(0x0BAD, _domain(address(pool), block.chainid), _outcomeHash(M1, 0, deadline));
        vm.expectRevert(BetPool.InvalidSignature.selector);
        pool.settle(M1, 0, deadline, forged);
        vm.expectRevert(BetPool.NotExpirable.selector);
        pool.expire(M1);
        pool.pause();
        pool.setLimits(IMD, 1 ether, 10_000 ether);
        vm.stopPrank();

        // There is no sweep/withdraw/rescue entry point at all.
        (bool ok,) = address(pool).call(abi.encodeWithSignature("sweep(address,uint256)", IMD, held));
        assertFalse(ok);
        (ok,) = address(pool).call(abi.encodeWithSignature("withdraw(address,uint256)", IMD, held));
        assertFalse(ok);
        (ok,) = address(pool).call{value: 1}("");
        assertFalse(ok);

        assertEq(MockERC20(IMD).balanceOf(address(pool)), held);
        assertEq(MockERC20(IMD).balanceOf(OWNER), 0);

        // Bettors are still paid in full by the signed outcome.
        _settle(M1, 0);
        _claimExpect(M1, alice, 195 ether);
        assertEq(MockERC20(IMD).balanceOf(FEE_RECIPIENT), 5 ether);
        vm.prank(OWNER);
        vm.expectRevert(BetPool.NothingToClaim.selector);
        pool.claim(M1);
    }

    // ================================================================== reentrancy

    function test_reentrancyGuardOnClaim() public {
        _createMarket(M1, IMD);
        _bet(M1, alice, 0, 10 ether, 10_000);
        _bet(M1, bob, 1, 10 ether, 10_000);
        _settle(M1, 0);
        // Swap the token code for one that calls back into the pool during transfers out of it.
        uint256 poolBal = MockERC20(IMD).balanceOf(address(pool));
        deployCodeTo("Mocks.sol:ReentrantERC20", IMD);
        ReentrantERC20 re = ReentrantERC20(IMD);
        re.mint(address(pool), poolBal);
        re.arm(address(pool), abi.encodeCall(BetPool.claim, (M1)));
        vm.prank(alice);
        pool.claim(M1);
        assertFalse(re.reentered());
        assertEq(bytes4(re.lastRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(re.balanceOf(alice), 19.5 ether);
    }

    // ================================================================== fuzz

    function testFuzz_twoSidedPayoutConservation(
        uint256[6] memory amounts,
        uint16[6] memory weights,
        uint8 sidesMask,
        uint8 outcome
    ) public {
        _createMarket(M1, IMD);
        outcome = uint8(bound(outcome, 0, 2));
        address[6] memory who = [alice, bob, carol, dave, erin, frank];
        uint256 pot;
        for (uint256 i; i < 6; ++i) {
            uint256 amt = bound(amounts[i], 0.1 ether, 500 ether);
            uint16 w = uint16(bound(weights[i], 500, 10_000));
            _bet(M1, who[i], uint8((sidesMask >> i) & 1), amt, w);
            pot += amt;
        }
        _settle(M1, outcome);
        uint256 fee = MockERC20(IMD).balanceOf(FEE_RECIPIENT);
        uint256 paid;
        uint256 winners;
        for (uint256 i; i < 6; ++i) {
            uint256 c = pool.claimable(M1, who[i]);
            if (c == 0) continue;
            winners++;
            vm.prank(who[i]);
            pool.claim(M1);
            paid += c;
        }
        uint256 dust = MockERC20(IMD).balanceOf(address(pool));
        assertEq(paid + fee + dust, pot);
        assertLe(paid + fee, pot);
        assertLe(dust, winners);
    }

    function testFuzz_feeIsFivePercentOfLosers(uint256 a, uint256 b, uint256 c) public {
        _createMarket(M1, SHIFT);
        a = bound(a, 1_000 ether, 25_000_000 ether);
        b = bound(b, 1_000 ether, 25_000_000 ether);
        c = bound(c, 1_000 ether, 25_000_000 ether);
        _bet(M1, alice, 0, a, 10_000);
        _bet(M1, bob, 1, b, 777);
        _bet(M1, carol, 1, c, 9_001);
        _settle(M1, 0);
        assertEq(MockERC20(SHIFT).balanceOf(FEE_RECIPIENT), (b + c) * 500 / 10_000);
        _claimExpect(M1, alice, a + (b + c) - (b + c) * 500 / 10_000);
    }

    // ================================================================== helpers

    function _addrs(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _addrs(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _claimExpect(bytes32 id, address who, uint256 expected) internal {
        (address token,,,,,,,,,) = pool.markets(id);
        uint256 before = MockERC20(token).balanceOf(who);
        assertEq(pool.claimable(id, who), expected);
        vm.expectEmit(address(pool));
        emit BetPool.Claimed(id, who, expected);
        vm.prank(who);
        pool.claim(id);
        assertEq(MockERC20(token).balanceOf(who) - before, expected);
    }

    /// @dev Settles, checks the fee, each winner's exact weighted payout, that losers get nothing,
    /// and that payouts + fee + dust equal the pot with at most one wei of dust per winner.
    function _settleAndCheck(bytes32 id, address token, uint8 outcome, address[] memory sideA, address[] memory sideB)
        internal
    {
        (,,, uint256 totalA, uint256 totalB,,,,,) = pool.markets(id);
        uint256 pot = MockERC20(token).balanceOf(address(pool));
        assertEq(pot, totalA + totalB);
        uint256 fee = (outcome == 0 ? totalB : totalA) * 5 / 100;
        uint256 feeBefore = MockERC20(token).balanceOf(FEE_RECIPIENT);
        _settle(id, outcome);
        assertEq(MockERC20(token).balanceOf(FEE_RECIPIENT) - feeBefore, fee);

        address[] memory winners = outcome == 0 ? sideA : sideB;
        uint256 paid;
        for (uint256 i; i < winners.length; ++i) {
            uint256 expected = _expectedPayout(id, outcome, winners[i]);
            _claimExpect(id, winners[i], expected);
            paid += expected;
        }
        _assertLosersGetNothing(id, outcome == 0 ? sideB : sideA);
        uint256 dust = MockERC20(token).balanceOf(address(pool));
        assertEq(paid + fee + dust, pot);
        assertLe(dust, winners.length);
    }

    function _assertLosersGetNothing(bytes32 id, address[] memory losers) internal {
        for (uint256 i; i < losers.length; ++i) {
            assertEq(pool.claimable(id, losers[i]), 0);
            vm.prank(losers[i]);
            vm.expectRevert(BetPool.NothingToClaim.selector);
            pool.claim(id);
        }
    }

    /// @dev Independent recomputation of a winner's payout from the public views.
    function _expectedPayout(bytes32 id, uint8 outcome, address who) internal view returns (uint256) {
        (,,, uint256 totalA, uint256 totalB, uint256 sharesA, uint256 sharesB,,,) = pool.markets(id);
        (uint256 aA, uint256 aB, uint256 sA, uint256 sB,) = pool.betsOf(id, who);
        uint256 losingTotal = outcome == 0 ? totalB : totalA;
        uint256 distributable = losingTotal - losingTotal * 5 / 100;
        return outcome == 0 ? aA + distributable * sA / sharesA : aB + distributable * sB / sharesB;
    }
}
