// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// constants and immutable are **not** stored in the contract's storage layout
contract Example {
    uint256 public normalVar = 1;

    // must be used, or it will be skipped in the byte code
    uint256 constant CONST_VAR = 0xbbbbbbb;
    uint256 immutable immutVar;
    uint256 public var2 = 2;

    constructor(uint256 _val) {
        immutVar = CONST_VAR + _val;
    }
}

/*
solc --storage-layout StorageSlot.sol
solc --ir StorageSlot.sol
solc --bin --metadata StorageSlot.sol
 */