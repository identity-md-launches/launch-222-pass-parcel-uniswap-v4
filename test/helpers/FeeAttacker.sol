// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IParcelFeePayer} from "../../src/interfaces/IParcelFeePayer.sol";
import {ParcelHook} from "../../src/ParcelHook.sol";

contract AlternatePayer {
    function pay(IPoolManager manager, address hook, uint256 amount) external {
        manager.take(Currency.wrap(address(0)), hook, amount);
    }
}

contract FeeAttacker is IUnlockCallback, IParcelFeePayer {
    using TransientStateLibrary for IPoolManager;
    enum Mode {
        Ignore,
        Underpay,
        Overpay,
        AlternateDebit,
        Reenter
    }
    IPoolManager public immutable manager;
    AlternatePayer public immutable alternate = new AlternatePayer();
    PoolKey private currentKey;
    SwapParams private currentParams;
    Mode private mode;
    address private payer;
    bool public reentryRejected;

    constructor(IPoolManager pm) {
        manager = pm;
    }

    function attack(PoolKey calldata key, SwapParams calldata p, Mode selected) external {
        currentKey = key;
        currentParams = p;
        mode = selected;
        payer = msg.sender;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        manager.swap(currentKey, currentParams, "");
        int256 eth = manager.currencyDelta(address(this), currentKey.currency0);
        int256 tokens = manager.currencyDelta(address(this), currentKey.currency1);
        require(eth >= 0 && tokens <= 0);
        manager.take(currentKey.currency0, payer, uint256(eth));
        manager.sync(currentKey.currency1);
        IERC20(Currency.unwrap(currentKey.currency1)).transferFrom(payer, address(manager), uint256(-tokens));
        manager.settle();
        return "";
    }

    function payParcelSellFee(PoolId id, uint256 amount) external {
        require(msg.sender == address(currentKey.hooks));
        // This fixture uses one funded pool. Custody must agree even inside this untrusted callback.
        require(msg.sender.balance == ParcelHook(payable(msg.sender)).pot(id), "custody before payment");
        if (mode == Mode.Ignore) return;
        if (mode == Mode.AlternateDebit) {
            alternate.pay(manager, msg.sender, amount);
            return;
        }
        if (mode == Mode.Reenter) {
            try manager.swap(currentKey, currentParams, "") {
                revert("reentered");
            } catch {
                reentryRejected = true;
            }
        }
        manager.take(
            currentKey.currency0,
            msg.sender,
            mode == Mode.Underpay ? amount - 1 : mode == Mode.Overpay ? amount + 1 : amount
        );
        require(msg.sender.balance == ParcelHook(payable(msg.sender)).pot(id), "custody after payment");
    }
}
