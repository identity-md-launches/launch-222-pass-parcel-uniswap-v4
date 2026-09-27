// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice Settlement extension for sells specifying gross ETH output.
interface IParcelFeePayer {
    /// @dev Debit your own PoolManager ETH delta using take(native, msg.sender, amount).
    /// Authenticate the hook and active swap before paying. The hook verifies the debit and receipt.
    function payParcelSellFee(PoolId poolId, uint256 amount) external;
}
