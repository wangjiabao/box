// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IERC20.sol";

library SafeTransfer {
    error SafeTransferFailed();
    error SafeTransferFromFailed();
    error SafeApproveFailed();

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert SafeTransferFailed();
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert SafeTransferFromFailed();
    }

    /// 可选：安全 approve（注意前置将额度清零或只做“调大/调小”以避免竞态）
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.approve.selector, spender, value));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert SafeApproveFailed();
    }
}
