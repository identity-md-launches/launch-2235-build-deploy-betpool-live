// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain 18-decimal ERC-20 with open minting, etched at the IMD and SHIFT addresses in tests.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Token that keeps 1% of every transfer, to prove the pool refuses fee-on-transfer behaviour.
contract FeeOnTransferERC20 is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 cut = value / 100;
            super._update(from, address(0xdead), cut);
            value -= cut;
        }
        super._update(from, to, value);
    }
}

/// @notice Token that calls back into a target during transfers, to prove the reentrancy guard holds.
contract ReentrantERC20 is ERC20 {
    address public target;
    bytes public payload;
    bool public reentered;
    bytes public lastRevert;

    constructor() ERC20("Re", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        address t = target;
        if (t != address(0) && from == t) {
            target = address(0);
            (bool ok, bytes memory ret) = t.call(payload);
            reentered = ok;
            lastRevert = ret;
        }
    }
}
