// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Minimal ReentrancyGuard
/// @notice 与 OpenZeppelin 语义一致：nonReentrant 不能嵌套；建议只标注在 external/public 函数上
abstract contract ReentrancyGuard {
    uint256 private _entered;

    modifier nonReentrant() {
        require(_entered == 0, "REENTRANCY");
        _entered = 1;
        _;
        _entered = 0;
    }
}
