// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BatchCallDelegation} from "../src/BatchCallDelegation.sol";

contract TestECRecover is Test {
    BatchCallDelegation testCa;
    uint256 PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address ADDR = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function setUp() public {
        testCa = new BatchCallDelegation();
    }

    function testECRecover() public view {
        // Create a message hash
        bytes32 messageHash = keccak256(abi.encodePacked("Test message"));

        // Sign the message hash with the private key of the contract address
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, messageHash);

        address signer = ecrecover(messageHash, v, r, s);
        require(signer == ADDR, "Invalid signer");
    }
}
