// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BetPool} from "../src/BetPool.sol";
import {DeployBetPool} from "../script/DeployBetPool.s.sol";

contract DeployBetPoolTest is Test {
    function test_deployConfiguration() public {
        DeployBetPool script = new DeployBetPool();
        BetPool pool = script.deploy(script.OWNER());
        assertEq(pool.owner(), 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5);
        assertTrue(pool.owner() != address(script));
        assertEq(pool.signer(), address(0));
        assertEq(pool.IMD(), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(pool.SHIFT(), 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC);
        assertEq(pool.FEE_RECIPIENT(), 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44);
        assertFalse(pool.paused());
    }

    function test_runtimeHasNoForbiddenOpcodes() public {
        BetPool pool = new BetPool(address(0xBEEF));
        bytes memory code = address(pool).code;
        assertLe(code.length, 24_576);
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
