// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolFixture} from "./helpers/PoolFixture.sol";
import {ParcelHook} from "../src/ParcelHook.sol";
import {ParcelRouter} from "../src/ParcelRouter.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract ParcelHookTest is PoolFixture {
    using StateLibrary for IPoolManager;

    function test_constructorAndPermissions() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(HookFlags.flagsOf(address(hook)), 0x44);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterSwap && p.afterSwapReturnDelta);
        assertFalse(p.beforeSwap || p.beforeSwapReturnDelta || p.beforeInitialize || p.afterInitialize);
    }

    function test_constructorRejectsZeroManager() public {
        vm.expectRevert(ParcelHook.ZeroPoolManager.selector);
        new ParcelHook(IPoolManager(address(0)));
    }

    function test_constructorRejectsWrongFlags() public {
        bytes32 salt;
        bytes32 hash = keccak256(abi.encodePacked(type(ParcelHook).creationCode, abi.encode(manager)));
        address predicted = vm.computeCreate2Address(salt, hash, address(this));
        assertFalse(HookFlags.matches(predicted, HookFlags.PARCEL));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new ParcelHook{salt: salt}(manager);
    }

    function test_onlyManagerCanCallAfterSwap() public {
        vm.expectRevert(ParcelHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params(false, -1 ether), BalanceDelta.wrap(0), "");
    }

    function test_noDirectFundingOrOutOfSwapPayment() public {
        compare(key, referenceKey, params(false, -1 ether));
        uint256 saved = hook.pot(key.toId());
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(address(manager));
        (ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "manager cannot transfer outside fee collection");
        (ok,) = address(hook).call(abi.encodeWithSignature("withdraw()"));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("sweep(address)", address(this)));
        assertFalse(ok);
        assertEq(saved, hook.pot(key.toId()));
        assertConservation();
    }

    function test_exactInputSellAndExactOutputSell() public {
        compare(key, referenceKey, params(false, -1 ether));
        compare(key, referenceKey, params(false, 2 ether));
    }

    function test_exactInputBuyPassesWholePot() public {
        compare(key, referenceKey, params(false, -1 ether));
        (,, uint256 paid) = compare(key, referenceKey, params(true, -1 ether));
        assertGt(paid, 0);
        assertEq(hook.pot(key.toId()), 0);
    }

    function test_exactOutputBuyPassesWholePot() public {
        compare(key, referenceKey, params(false, 1 ether));
        (,, uint256 paid) = compare(key, referenceKey, params(true, 1 ether));
        assertGt(paid, 0);
        assertEq(hook.pot(key.toId()), 0);
    }

    function test_emptyPotBuys() public {
        compare(key, referenceKey, params(true, -1 ether));
        compare(key, referenceKey, params(true, 1 ether));
    }

    function test_thresholdAndCapExactInput() public {
        compare(key, referenceKey, params(false, -10 ether));
        uint256 saved = hook.pot(key.toId());
        compare(key, referenceKey, params(true, -int256(0.001 ether - 1)));
        assertEq(saved, hook.pot(key.toId()));
        (BalanceDelta net,, uint256 paid) = compare(key, referenceKey, params(true, -0.001 ether));
        assertEq(net.amount0(), 0);
        assertEq(paid, 0.001 ether);
        assertEq(hook.pot(key.toId()), saved - paid);
    }

    function test_thresholdAndCapExactOutput() public {
        compare(key, referenceKey, params(false, -10 ether));
        uint256 saved = hook.pot(key.toId());
        compare(key, referenceKey, params(true, int256(0.0001 ether)));
        assertEq(saved, hook.pot(key.toId()));
        (BalanceDelta net, BalanceDelta gross, uint256 paid) =
            compare(key, referenceKey, params(true, 0.002 ether));
        assertEq(net.amount0(), 0);
        assertEq(paid, uint256(-int256(gross.amount0())));
        assertGt(hook.pot(key.toId()), 0);
    }

    function test_poolIsolationInBothDirections() public {
        compare(key, referenceKey, params(false, -5 ether));
        uint256 firstPot = hook.pot(key.toId());
        compare(second, secondReference, params(true, -1 ether));
        compare(second, secondReference, params(true, 1 ether));
        assertEq(hook.pot(key.toId()), firstPot);
        compare(second, secondReference, params(false, 2 ether));
        uint256 secondPot = hook.pot(second.toId());
        compare(key, referenceKey, params(true, -1 ether));
        assertEq(hook.pot(second.toId()), secondPot);
    }

    function test_nonNativePoolUntouchedAllFourModes() public {
        compare(key, referenceKey, params(false, -1 ether));
        uint256 saved = hook.pot(key.toId());
        for (uint256 mode; mode < 4; ++mode) {
            SwapParams memory p = params(mode < 2, mode % 2 == 0 ? int256(-1 ether) : int256(1 ether));
            BalanceDelta net = swap(nonNative, p);
            BalanceDelta gross = swap(nonNativeReference, p);
            assertEq(BalanceDelta.unwrap(net), BalanceDelta.unwrap(gross));
            assertEq(hook.pot(nonNative.toId()), 0);
            assertEq(hook.pot(key.toId()), saved);
        }
        assertConservation();
    }

    function test_partialFillSellChargesActualOutputBothModes() public {
        SwapParams memory p = SwapParams(false, -1000 ether, TickMath.getSqrtPriceAtTick(1));
        (,, uint256 added) = compare(key, referenceKey, p);
        assertGt(added, 0);
        assertLt(added, 10 ether);
        p = SwapParams(false, 1000 ether, TickMath.getSqrtPriceAtTick(2));
        compare(key, referenceKey, p);
    }

    function test_partialBuyBelowThresholdDoesNotUseRequestedInput() public {
        compare(key, referenceKey, params(false, -1 ether));
        uint256 saved = hook.pot(key.toId());
        (uint160 price,,,) = manager.getSlot0(key.toId());
        SwapParams memory p = SwapParams(true, -1 ether, price - 100000);
        (, BalanceDelta gross, uint256 paid) = compare(key, referenceKey, p);
        assertLt(uint256(-int256(gross.amount0())), 0.001 ether);
        assertEq(paid, 0);
        assertEq(saved, hook.pot(key.toId()));
    }

    function test_eventsAndRounding() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit ParcelHook.ParcelFilled(key.toId(), 1 ether / 100, 1 ether / 100);
        swap(key, params(false, 1 ether));
        vm.expectEmit(true, false, false, true, address(hook));
        emit ParcelHook.ParcelPassed(key.toId(), 1 ether / 100, 0);
        swap(key, params(true, -1 ether));
        vm.expectEmit(true, false, false, true, address(hook));
        emit ParcelHook.ParcelFilled(key.toId(), 0, 0);
        swap(key, params(false, 99));
        assertConservation();
    }

    function test_slippageRevertRollsBackPotAndPool() public {
        compare(key, referenceKey, params(false, -1 ether));
        uint256 saved = hook.pot(key.toId());
        (uint160 price,,,) = manager.getSlot0(key.toId());
        vm.expectRevert(ParcelRouter.Slippage.selector);
        router.swap{value: 1 ether}(key, params(true, -1 ether), 1 ether, type(uint256).max, block.timestamp);
        assertEq(hook.pot(key.toId()), saved);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(price, afterPrice);
        assertConservation();
    }

    function test_insufficientFundingRollsBackPot() public {
        compare(key, referenceKey, params(false, -1 ether));
        uint256 saved = hook.pot(key.toId());
        vm.expectRevert(ParcelRouter.InsufficientEther.selector);
        router.swap(key, params(true, -1 ether), 1 ether, 0, block.timestamp);
        assertEq(saved, hook.pot(key.toId()));
        assertConservation();
    }

    function test_fullySubsidizedBuyNeedsNoMsgValue() public {
        compare(key, referenceKey, params(false, -1 ether));
        uint256 saved = hook.pot(key.toId());
        uint256 beforeTokens = token.balanceOf(address(this));
        BalanceDelta net = router.swap(key, params(true, -0.001 ether), 0, 1, block.timestamp);
        assertEq(net.amount0(), 0);
        assertGt(token.balanceOf(address(this)), beforeTokens);
        assertEq(hook.pot(key.toId()), saved - 0.001 ether);
        assertConservation();
    }

    function test_removingLiquidityCannotWithdrawPot() public {
        compare(key, referenceKey, params(false, -1 ether));
        uint256 saved = hook.pot(key.toId());
        manager.unlock(abi.encode(key, -int256(100_000 ether)));
        assertEq(hook.pot(key.toId()), saved);
        assertConservation();
        manager.unlock(abi.encode(key, int256(100_000 ether)));
        compare(key, referenceKey, params(true, -1 ether));
        assertEq(hook.pot(key.toId()), 0);
    }

    function test_routerRejectsForgedCallbacksAndExpiredSwap() public {
        vm.expectRevert(ParcelRouter.InvalidCaller.selector);
        router.payParcelSellFee(key.toId(), 1);
        vm.expectRevert(ParcelRouter.InvalidCaller.selector);
        router.unlockCallback("");
        vm.warp(10);
        vm.expectRevert(ParcelRouter.InvalidSwap.selector);
        router.swap(key, params(true, -1 ether), 1 ether, 0, 9);
    }

    function testFuzz_sellBothModes(uint96 size, bool exactInput) public {
        uint256 amount = bound(size, 100, 100 ether);
        compare(key, referenceKey, params(false, exactInput ? -int256(amount) : int256(amount)));
    }

    function testFuzz_buyBothModesWithPot(uint96 size, bool exactInput) public {
        compare(key, referenceKey, params(false, -10 ether));
        uint256 amount = bound(size, 1e10, 10 ether);
        compare(key, referenceKey, params(true, exactInput ? -int256(amount) : int256(amount)));
    }
}
