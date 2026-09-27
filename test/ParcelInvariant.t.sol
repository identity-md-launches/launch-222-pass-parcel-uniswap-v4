// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolFixture} from "./helpers/PoolFixture.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract ParcelInvariantTest is PoolFixture {
    uint256 public totalFilled;
    uint256 public totalPassed;
    uint256 public firstExpected;
    uint256 public secondExpected;

    function setUp() public override {
        super.setUp();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = this.step.selector;
        targetContract(address(this));
        targetSelector(FuzzSelector(address(this), selectors));
    }

    function step(uint96 seed, uint8 mode, bool useSecond) external {
        uint256 amount = bound(seed, 1e9, 1 ether);
        bool buy = mode % 4 < 2;
        bool exactInput = mode % 2 == 0;
        PoolKey memory target = useSecond ? second : key;
        PoolKey memory ref = useSecond ? secondReference : referenceKey;
        (,, uint256 change) = compare(target, ref, params(buy, exactInput ? -int256(amount) : int256(amount)));
        if (buy) {
            totalPassed += change;
            if (useSecond) secondExpected -= change;
            else firstExpected -= change;
        } else {
            totalFilled += change;
            if (useSecond) secondExpected += change;
            else firstExpected += change;
        }
    }

    function invariant_potsEqualCustodyAndCumulativeFeesLessPayouts() public view {
        assertConservation();
        assertEq(address(hook).balance, totalFilled - totalPassed);
        assertEq(hook.pot(key.toId()), firstExpected);
        assertEq(hook.pot(second.toId()), secondExpected);
        assertEq(token.totalSupply(), 1e27);
    }
}
