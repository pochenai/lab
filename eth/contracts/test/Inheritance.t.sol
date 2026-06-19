// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Higher, Base} from "../src/Inheritance.sol";

contract InheritanceTest is Test {
    Higher higher;
    Base baseca;

    function setUp() public {
        higher = new Higher();
        baseca = new Higher();
        // Error (4614): Cannot instantiate an abstract contract.
        // baseca = new Base();
    }

    function test_MyCall() public view {
        uint256 result = higher.mycall();
        console.log("Higher.mycall() =", result);
        assertEq(result, 7);
    }
}
