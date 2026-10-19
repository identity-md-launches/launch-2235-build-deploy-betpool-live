// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {BetPool} from "../src/BetPool.sol";

/// @notice Reviewable deployment recipe. The IMD launch factory deploys BetPool from its bytecode with
/// the single constructor argument below; this script exists to document and test that configuration.
contract DeployBetPool is Script {
    /// @notice The owner named in the brief.
    address public constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;

    /// @notice Deploys BetPool owned by `owner`.
    function deploy(address owner) public returns (BetPool) {
        return new BetPool(owner);
    }

    /// @notice Broadcasts a deployment with the brief's owner.
    function run() external returns (BetPool pool) {
        vm.startBroadcast();
        pool = deploy(OWNER);
        vm.stopBroadcast();
    }
}
