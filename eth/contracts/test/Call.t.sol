// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/Proxy.sol";

contract Caller {
    // The name of the variable doesn’t matter, but where it is located in storage.
    uint256 public xx;
    address public callee;

    constructor(address _callee) {
        callee = _callee;
        xx = 0;
    }

    function inc() public returns (uint256) {
        xx += 1;
        console.log("caller called");
        return xx;
    }

    function callIncrement() public {
        callee.call(abi.encodeWithSignature("inc()"));
    }

    function delegateCallIncrement() public {
        callee.delegatecall(abi.encodeWithSignature("inc()"));
    }
}

contract Callee {
    uint256 public x;

    constructor() {
        x = 0;
    }

    function inc() public returns (uint256) {
        console.log("call impl");
        console.logAddress(tx.origin);
        console.logAddress(msg.sender);
        x += 1;
        console.log("callee called");
        return x;
    }
}

contract CallTest is Test {
    Caller caller;
    Callee callee;

    function setUp() public {
        callee = new Callee();
        caller = new Caller(address(callee));
    }

    // function testCall() public {
    //     caller.callIncrement();
    //     assertEq(caller.x(), 0);
    //     assertEq(callee.x(), 1);
    // }

    function testDelegateCall() public {
        caller.delegateCallIncrement();
        assertEq(caller.xx(), 1);
        assertEq(callee.x(), 0);
    }
}

contract ProxyA is Proxy {
    uint256 public x;
    address private _impl;

    constructor(address implAddress) {
        _impl = implAddress;
    }

    function _implementation() internal view override returns (address) {
        return _impl;
    }

    function _beforeFallback() internal override {
        // do something
        console.log("before f=b");
        super._beforeFallback();
        console.logAddress(tx.origin);
        console.logAddress(msg.sender);
        console.logAddress(_impl);
        console.log("next call");
    }
}

contract ProxyB is Proxy {
    // address private _impl;

    // constructor(address implAddress) {
    //     _impl = implAddress;
    // }

    // only if we know the implementation address, ohterwise using constructor it'll read parent contract's storage
    function _implementation() internal view override returns (address) {
        return address(0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f);
    }

    function _beforeFallback() internal override {
        // do something
        console.log("before fb 2");
        // super._beforeFallback();
        console.logAddress(tx.origin);
        console.logAddress(msg.sender);
        console.logAddress(_implementation());
        console.log("next call 2");
    }
}

//
// delegatecall 的递归调用链，msg.sender 会一直保持最初的调用者, 所以除了最顶层外，msg.sender == tx.origin也是可能的;
// 因此，使用delegete call时一定要确保Delegation destination是可信的
contract TestDelegate2Calls is Test {
    // ALice => proxyA => proxyB => contract
    Callee _ca;
    ProxyA _p1;
    ProxyB _p2;

    function setUp() public {
        _ca = new Callee();
        _p2 = new ProxyB();
        _p1 = new ProxyA(address(_p2));
        console.log("p1:", address(_p1));
        console.log("p2:", address(_p2));
        console.log("ca:", address(_ca));
    }

    function testDelegate2Calls() public {
        address sysaddr = address(0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE);
        vm.prank(sysaddr, sysaddr); // set msg.sender and tx.origin
        (bool success, bytes memory data) = address(_p1).call(abi.encodeWithSignature("inc()"));
        require(success, "Call failed");
        uint256 result = abi.decode(data, (uint256));
        console.log("Result:", result);
    }
}
