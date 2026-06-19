// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

contract Calculator {
    uint256 public x = 20;
    uint256 public y = 20;

    function getSum() public view returns (uint256) {
        return x + y;
    }
}

contract Caller {
    Calculator calculator;

    constructor(address _calc) {
        calculator = Calculator(_calc);
    }

    // call the getSum function in the calculator contract
    function callCalculator() public view returns (uint256 sum) {
        sum = calculator.getSum();
        sum = calculator.getSum();
    }
}

/*
# start anvil
anvil -p 6500
# create contracts(CA)
forge create src/Accesslist.sol:Calculator --rpc-url $L1 --private-key $PK
forge create src/Accesslist.sol:Caller --constructor-args "0x5FbDB2315678afecb367f032d93F642f64180aa3" --rpc-url $L1 --private-key $PK

# get access list
cast access-list CallerCA "callCalculator()" --rpc-url $L1
# gas: 30711
cast send '[{"address": "CA", "storageKeys":["0x0000000000000000000
000000000000000000000000000000000000000000000","0x0000000000000000000000000000000000000000000000000000000000000001"]}]'  CallerCA "callCalculator()" --rpc-url $L1 --private-key $PK
# gas: 30411
cast send --access-list '[{"address": "CA", "storageKeys":["0x0000000000000000000
000000000000000000000000000000000000000000000","0x0000000000000000000000000000000000000000000000000000000000000001"]}]'  CA "callCalculator()" --rpc-url $L1 --private-key $PK
*/
