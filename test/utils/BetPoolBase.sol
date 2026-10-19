// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BetPool} from "../../src/BetPool.sol";
import {MockERC20} from "./Mocks.sol";

abstract contract BetPoolBase is Test {
    address internal constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    address internal constant FEE_RECIPIENT = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    BetPool internal pool;
    uint256 internal signerKey = 0xA11CE;
    address internal signerAddr;
    uint256 internal nonceCounter;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        deployCodeTo("Mocks.sol:MockERC20", IMD);
        deployCodeTo("Mocks.sol:MockERC20", SHIFT);
        signerAddr = vm.addr(signerKey);
        pool = new BetPool(OWNER);
        vm.prank(OWNER);
        pool.setSigner(signerAddr);
    }

    // ------------------------------------------------------------------ signing

    function _domain(address verifying, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("NightshiftBets"), keccak256("1"), chainId, verifying));
    }

    function _sign(uint256 key, bytes32 domain, bytes32 structHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _signHash(bytes32 structHash) internal view returns (bytes memory) {
        return _sign(signerKey, _domain(address(pool), block.chainid), structHash);
    }

    function _marketHash(bytes32 id, address token, uint64 closesAt, bytes32 game) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("Market(bytes32 marketId,address token,uint64 closesAt,bytes32 game)"),
                id,
                token,
                closesAt,
                game
            )
        );
    }

    function _ticketHash(
        bytes32 id,
        address bettor,
        uint8 side,
        uint256 amount,
        uint16 weight,
        uint64 expiry,
        bytes32 nonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "Ticket(bytes32 marketId,address bettor,uint8 side,uint256 amount,uint16 weightBps,uint64 expiry,bytes32 nonce)"
                ),
                id,
                bettor,
                side,
                amount,
                weight,
                expiry,
                nonce
            )
        );
    }

    function _outcomeHash(bytes32 id, uint8 outcome, uint256 deadline) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(keccak256("Outcome(bytes32 marketId,uint8 outcome,uint256 deadline)"), id, outcome, deadline)
        );
    }

    // ------------------------------------------------------------------ actions

    function _createMarket(bytes32 id, address token) internal returns (uint64 closesAt) {
        closesAt = uint64(block.timestamp + 2 hours);
        bytes32 game = keccak256(abi.encode("NIGHT CHESS", id));
        pool.createMarket(id, token, closesAt, game, _signHash(_marketHash(id, token, closesAt, game)));
    }

    function _fund(address token, address who, uint256 amount) internal {
        MockERC20(token).mint(who, amount);
        vm.prank(who);
        MockERC20(token).approve(address(pool), type(uint256).max);
    }

    function _nextNonce() internal returns (bytes32) {
        return keccak256(abi.encode("nonce", ++nonceCounter));
    }

    function _bet(bytes32 id, address bettor, uint8 side, uint256 amount, uint16 weight) internal {
        (address token,,,,,,,,,) = pool.markets(id);
        _fund(token, bettor, amount);
        uint64 expiry = uint64(block.timestamp + 60);
        bytes32 nonce = _nextNonce();
        bytes memory sig = _signHash(_ticketHash(id, bettor, side, amount, weight, expiry, nonce));
        vm.prank(bettor);
        pool.bet(id, side, amount, weight, expiry, nonce, sig);
    }

    function _settle(bytes32 id, uint8 outcome) internal {
        uint256 deadline = block.timestamp + 1 hours;
        pool.settle(id, outcome, deadline, _signHash(_outcomeHash(id, outcome, deadline)));
    }
}
