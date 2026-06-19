// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// https://medium.com/@organmo/demystifying-eip-1153-transient-storage-faeabbadd0d

contract ReentrancyGuard {
    bool private locked;

    modifier lock() {
        require(!locked);
        locked = true;
        _;
        locked = false;
    }

    // 14376 gas
    function test() public lock {
        // Ignore call error
        bytes memory b = "";
        msg.sender.call(b);
    }
}

contract ReentrancyGuardTransient {
    bytes32 constant SLOT = 0;

    modifier lock() {
        assembly {
            if tload(SLOT) { revert(0, 0) }
            tstore(SLOT, 1)
        }
        _;
        assembly {
            tstore(SLOT, 0)
        }
    }

    // 982 gas
    function test() external lock {
        // Ignore call error
        bytes memory b = "";
        msg.sender.call(b);
    }
}
