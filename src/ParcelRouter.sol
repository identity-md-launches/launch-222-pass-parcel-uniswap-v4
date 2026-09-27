// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IParcelFeePayer} from "./interfaces/IParcelFeePayer.sol";

/// @notice Single-swap router that settles Parcel's net ETH deltas and refunds unused msg.value.
/// @dev Output targets in SwapParams are gross; minOutput is the user's net, post-fee protection.
contract ParcelRouter is IUnlockCallback, IParcelFeePayer {
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using SafeCast for int256;

    error InvalidCaller();
    error InvalidSwap();
    error Slippage();
    error InsufficientEther();
    error EtherTransferFailed();

    IPoolManager public immutable manager;
    bool private active;
    address private activeHook;
    PoolId private activePool;
    uint256 private feeBudget;
    uint256 private ethRemaining;

    struct Request {
        PoolKey key;
        SwapParams params;
        uint256 maxInput;
        uint256 minOutput;
        address payer;
    }

    constructor(IPoolManager poolManager) {
        if (address(poolManager) == address(0)) revert InvalidSwap();
        manager = poolManager;
    }

    /// @notice Receive output and refunds at msg.sender. Deadline is inclusive.
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 maxInput,
        uint256 minOutput,
        uint256 deadline
    ) external payable returns (BalanceDelta net) {
        if (active || block.timestamp > deadline || params.amountSpecified == 0) {
            revert InvalidSwap();
        }
        active = true;
        ethRemaining = msg.value;
        net = abi.decode(
            manager.unlock(abi.encode(Request(key, params, maxInput, minOutput, msg.sender))), (BalanceDelta)
        );
        uint256 refund = ethRemaining;
        ethRemaining = 0;
        if (refund != 0) _sendEther(msg.sender, refund);
        active = false;
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager) || !active) revert InvalidCaller();
        Request memory request = abi.decode(raw, (Request));
        activeHook = address(request.key.hooks);
        activePool = request.key.toId();
        feeBudget = request.key.currency0.isAddressZero() && !request.params.zeroForOne
            && request.params.amountSpecified > 0
            ? uint256(request.params.amountSpecified) / 100
            : 0;

        manager.swap(request.key, request.params, "");
        activeHook = address(0);
        feeBudget = 0;

        // A specified-ETH adjustment changes the ledger directly, not swap()'s return value.
        int256 amount0 = manager.currencyDelta(address(this), request.key.currency0);
        int256 amount1 = manager.currencyDelta(address(this), request.key.currency1);
        int256 input = request.params.zeroForOne ? -amount0 : -amount1;
        int256 output = request.params.zeroForOne ? amount1 : amount0;
        if (
            input < 0 || output < 0 || uint256(input) > request.maxInput
                || uint256(output) < request.minOutput
        ) {
            revert Slippage();
        }
        BalanceDelta net = toBalanceDelta(amount0.toInt128(), amount1.toInt128());
        _settle(request.key.currency0, amount0, request.payer);
        _settle(request.key.currency1, amount1, request.payer);
        return abi.encode(net);
    }

    function payParcelSellFee(PoolId id, uint256 amount) external {
        if (
            !active || msg.sender != activeHook || PoolId.unwrap(id) != PoolId.unwrap(activePool)
                || amount == 0 || amount > feeBudget
        ) revert InvalidCaller();
        feeBudget = 0;
        manager.take(Currency.wrap(address(0)), msg.sender, amount);
    }

    function _settle(Currency currency, int256 delta, address payer) private {
        if (delta > 0) {
            manager.take(currency, payer, uint256(delta));
        } else if (delta < 0) {
            uint256 owed = uint256(-delta);
            manager.sync(currency);
            if (currency.isAddressZero()) {
                if (owed > ethRemaining) revert InsufficientEther();
                ethRemaining -= owed;
                manager.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), owed);
                manager.settle();
            }
        }
    }

    function _sendEther(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EtherTransferFailed();
    }
}
