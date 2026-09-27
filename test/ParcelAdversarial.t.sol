// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolFixture} from "./helpers/PoolFixture.sol";
import {FeeAttacker} from "./helpers/FeeAttacker.sol";
import {ParcelHook} from "../src/ParcelHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ParcelRouter} from "../src/ParcelRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract RejectingBuyer {
    function buy(ParcelRouter router, PoolKey calldata key, SwapParams calldata p) external payable {
        router.swap{value: msg.value}(key, p, 1 ether, 0, block.timestamp);
    }
}

contract ParcelAdversarialTest is PoolFixture {
    using StateLibrary for IPoolManager;

    function test_exactOutputSellerCannotIgnoreFeeOrDebitAnotherAccount() public {
        FeeAttacker attacker = new FeeAttacker(manager);
        token.approve(address(attacker), type(uint256).max);
        bytes memory expected = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(ParcelHook.InvalidFeePayment.selector),
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
        (uint160 price,,,) = manager.getSlot0(key.toId());
        vm.expectRevert(expected);
        attacker.attack(key, params(false, 1 ether), FeeAttacker.Mode.Ignore);
        vm.expectRevert(expected);
        attacker.attack(key, params(false, 1 ether), FeeAttacker.Mode.AlternateDebit);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, price, "failed fee collection rolls back AMM");
        assertEq(hook.pot(key.toId()), 0);
        assertConservation();
    }

    function test_wrongFeeAmountRevertsAtomically() public {
        FeeAttacker attacker = new FeeAttacker(manager);
        vm.expectRevert();
        attacker.attack(key, params(false, 1 ether), FeeAttacker.Mode.Underpay);
        vm.expectRevert();
        attacker.attack(key, params(false, 1 ether), FeeAttacker.Mode.Overpay);
        assertEq(hook.pot(key.toId()), 0);
        assertConservation();
    }

    function test_feeCallbackCannotReenterButCanFinishPaying() public {
        FeeAttacker attacker = new FeeAttacker(manager);
        token.approve(address(attacker), type(uint256).max);
        uint256 before = address(this).balance;
        attacker.attack(key, params(false, 1 ether), FeeAttacker.Mode.Reenter);
        assertTrue(attacker.reentryRejected());
        assertEq(address(this).balance - before, 0.99 ether);
        assertEq(hook.pot(key.toId()), 0.01 ether);
        assertConservation();
    }

    function test_failedRefundRollsBackThePayout() public {
        compare(key, referenceKey, params(false, -1 ether));
        uint256 saved = hook.pot(key.toId());
        RejectingBuyer buyer = new RejectingBuyer();
        vm.expectRevert(ParcelRouter.EtherTransferFailed.selector);
        buyer.buy{value: 1 ether}(router, key, params(true, -1 ether));
        assertEq(hook.pot(key.toId()), saved);
        assertEq(token.balanceOf(address(buyer)), 0);
        assertConservation();
    }
}
