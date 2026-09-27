// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Parcel} from "../../src/Parcel.sol";
import {ParcelHook} from "../../src/ParcelHook.sol";
import {ParcelRouter} from "../../src/ParcelRouter.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

abstract contract PoolFixture is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal manager;
    ParcelHook internal hook;
    ParcelRouter internal router;
    Parcel internal token;
    MockERC20 internal other;
    PoolKey internal key;
    PoolKey internal referenceKey;
    PoolKey internal second;
    PoolKey internal secondReference;
    PoolKey internal nonNative;
    PoolKey internal nonNativeReference;
    uint160 internal constant PRICE = 1 << 96;

    function setUp() public virtual {
        vm.deal(address(this), 1e30);
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = deployHook(manager);
        router = new ParcelRouter(manager);
        token = new Parcel();
        other = new MockERC20("Other", "OTH", 1e27);
        token.approve(address(router), type(uint256).max);
        other.approve(address(router), type(uint256).max);
        key = pool(address(0), address(token), address(hook));
        referenceKey = pool(address(0), address(token), address(0));
        second = pool(address(0), address(other), address(hook));
        secondReference = pool(address(0), address(other), address(0));
        nonNative = pool(address(token), address(other), address(hook));
        nonNativeReference = pool(address(token), address(other), address(0));
        initialize(key);
        initialize(referenceKey);
        initialize(second);
        initialize(secondReference);
        initialize(nonNative);
        initialize(nonNativeReference);
    }

    function deployHook(IPoolManager pm) internal returns (ParcelHook deployed) {
        bytes memory init = abi.encodePacked(type(ParcelHook).creationCode, abi.encode(pm));
        bytes32 hash = keccak256(init);
        for (uint256 salt; salt < 200_000; ++salt) {
            address predicted = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), hash)))
                )
            );
            if (!HookFlags.matches(predicted, HookFlags.PARCEL)) continue;
            deployed = new ParcelHook{salt: bytes32(salt)}(pm);
            assertEq(address(deployed), predicted);
            return deployed;
        }
        revert("no CREATE2 salt");
    }

    function pool(address a, address b, address hooks) internal pure returns (PoolKey memory) {
        (a, b) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(hooks));
    }

    function initialize(PoolKey memory target) internal {
        manager.initialize(target, PRICE);
        manager.unlock(abi.encode(target, int256(100_000 ether)));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory target, int256 liquidity) = abi.decode(raw, (PoolKey, int256));
        (BalanceDelta delta,) =
            manager.modifyLiquidity(target, ModifyLiquidityParams(-60000, 60000, liquidity, bytes32(0)), "");
        settle(target.currency0, delta.amount0());
        settle(target.currency1, delta.amount1());
        return "";
    }

    function settle(Currency currency, int128 delta) internal {
        if (delta > 0) manager.take(currency, address(this), uint256(uint128(delta)));
        if (delta >= 0) return;
        uint256 debt = uint256(-int256(delta));
        manager.sync(currency);
        if (currency.isAddressZero()) {
            manager.settle{value: debt}();
        } else {
            IERC20(Currency.unwrap(currency)).transfer(address(manager), debt);
            manager.settle();
        }
    }

    function params(bool buy, int256 specified) internal pure returns (SwapParams memory) {
        return SwapParams(buy, specified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function swap(PoolKey memory target, SwapParams memory p) internal returns (BalanceDelta) {
        return router.swap{value: target.currency0.isAddressZero() && p.zeroForOne ? 1000 ether : 0}(
            target, p, type(uint256).max, 0, block.timestamp
        );
    }

    function compare(PoolKey memory target, PoolKey memory ref, SwapParams memory p)
        internal
        returns (BalanceDelta net, BalanceDelta gross, uint256 change)
    {
        uint256 beforePot = hook.pot(target.toId());
        uint256 beforeEth = address(this).balance;
        uint256 beforeTokens = IERC20(Currency.unwrap(target.currency1)).balanceOf(address(this));
        net = swap(target, p);
        assertEq(int256(address(this).balance) - int256(beforeEth), int256(net.amount0()));
        assertEq(
            int256(IERC20(Currency.unwrap(target.currency1)).balanceOf(address(this))) - int256(beforeTokens),
            int256(net.amount1())
        );
        gross = swap(ref, p);
        assertEq(net.amount1(), gross.amount1(), "same token leg");
        if (!p.zeroForOne) {
            change = uint256(uint128(gross.amount0())) / 100;
            assertEq(int256(net.amount0()), int256(gross.amount0()) - int256(change), "sell fee");
            assertEq(hook.pot(target.toId()), beforePot + change);
        } else {
            uint256 input = uint256(-int256(gross.amount0()));
            change = input >= 0.001 ether ? (input < beforePot ? input : beforePot) : 0;
            assertEq(int256(net.amount0()), int256(gross.amount0()) + int256(change), "buy credit");
            assertEq(hook.pot(target.toId()), beforePot - change);
        }
        assertSamePoolState(target, ref);
        assertConservation();
    }

    function assertSamePoolState(PoolKey memory target, PoolKey memory ref) internal view {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(target.toId());
        (uint160 refPrice, int24 refTick, uint24 refProtocolFee, uint24 refLpFee) =
            manager.getSlot0(ref.toId());
        assertEq(price, refPrice, "same AMM execution");
        assertEq(tick, refTick);
        assertEq(protocolFee, refProtocolFee);
        assertEq(lpFee, refLpFee);
    }

    function assertConservation() internal view {
        assertEq(
            address(hook).balance, hook.pot(key.toId()) + hook.pot(second.toId()) + hook.pot(nonNative.toId())
        );
        assertEq(manager.getNonzeroDeltaCount(), 0, "all ledger deltas settled");
        assertEq(address(router).balance, 0, "no router leftovers");
        assertEq(token.balanceOf(address(hook)), 0, "no token custody");
        assertEq(other.balanceOf(address(hook)), 0);
    }

    receive() external payable {}
}
