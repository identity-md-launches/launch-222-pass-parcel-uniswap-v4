// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IParcelFeePayer} from "./interfaces/IParcelFeePayer.sol";

/// @notice Collects 1% of gross ETH sell output and rebates the next qualifying buy in that pool.
/// @dev ETH-specified swaps require settlement from the manager's live currency deltas; see ParcelRouter.
contract ParcelHook {
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    error ZeroPoolManager();
    error OnlyPoolManager();
    error ReentrantCallback();
    error InvalidFeePayment();
    error UnexpectedEther();

    event ParcelFilled(PoolId indexed poolId, uint256 added, uint256 potAfter);
    event ParcelPassed(PoolId indexed poolId, uint256 paid, uint256 potAfter);

    uint256 public constant MIN_BUY = 0.001 ether;
    IPoolManager public immutable poolManager;
    mapping(PoolId => uint256) public pot;
    bool private entered;
    uint256 private expectedReceipt;
    PoolId private receivingPool;

    constructor(IPoolManager manager) {
        if (address(manager) == address(0)) revert ZeroPoolManager();
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128 adjustment) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (entered) revert ReentrantCallback();
        if (!key.currency0.isAddressZero()) return (IHooks.afterSwap.selector, 0);
        entered = true;

        PoolId id = key.toId();
        if (!params.zeroForOne) {
            uint256 added = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) / 100 : 0;
            if (added != 0) {
                expectedReceipt = added;
                receivingPool = id;
                if (params.amountSpecified < 0) {
                    // ETH is unspecified: the returned delta charges the seller and cancels our take.
                    poolManager.take(key.currency0, address(this), added);
                    adjustment = added.toInt128();
                } else {
                    // ETH is specified: afterSwap cannot change its returned delta. The router must
                    // debit its own ledger balance. No allowance, sender identity or hookData is trusted.
                    int256 beforeDebit = poolManager.currencyDelta(sender, key.currency0);
                    uint256 beforeBalance = address(this).balance;
                    IParcelFeePayer(sender).payParcelSellFee(id, added);
                    if (
                        poolManager.currencyDelta(sender, key.currency0) != beforeDebit - int256(added)
                            || address(this).balance != beforeBalance + added
                    ) revert InvalidFeePayment();
                }
                if (expectedReceipt != 0) revert InvalidFeePayment();
            }
            emit ParcelFilled(id, added, pot[id]);
        } else if (delta.amount0() < 0) {
            uint256 input = uint256(-int256(delta.amount0()));
            if (input >= MIN_BUY) {
                uint256 paid = pot[id] < input ? pot[id] : input;
                if (paid != 0) {
                    pot[id] -= paid;
                    // Reset any ERC20 sync left by the caller before settling native ETH.
                    poolManager.sync(key.currency0);
                    if (params.amountSpecified > 0) {
                        poolManager.settle{value: paid}();
                        adjustment = (-int256(paid)).toInt128();
                    } else {
                        // Credit the swap caller, which must settle from the live ledger.
                        poolManager.settleFor{value: paid}(sender);
                    }
                    emit ParcelPassed(id, paid, pot[id]);
                }
            }
        }
        entered = false;
        return (IHooks.afterSwap.selector, adjustment);
    }

    /// @dev Accept only the single, exact PoolManager transfer currently collecting a sell fee.
    receive() external payable {
        if (msg.sender != address(poolManager) || msg.value == 0 || msg.value != expectedReceipt) {
            revert UnexpectedEther();
        }
        expectedReceipt = 0;
        // Record the deposit on receipt, so an untrusted fee payer observes matched custody
        // and accounting both before and after calling PoolManager.take.
        pot[receivingPool] += msg.value;
    }
}
