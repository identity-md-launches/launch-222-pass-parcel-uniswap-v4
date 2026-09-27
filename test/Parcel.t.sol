// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Parcel} from "../src/Parcel.sol";

contract ParcelTest is Test {
    Parcel internal token;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new Parcel();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "Parcel");
        assertEq(token.symbol(), "PRCL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_factoryReceivesSupply() public {
        vm.prank(alice);
        Parcel deployed = new Parcel();
        assertEq(deployed.balanceOf(alice), 1e27);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    function testFuzz_transferAndTransferFrom(uint96 seed) public {
        uint256 amount = bound(seed, 0, 1e27);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.approve(address(this), amount);
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.allowance(alice, address(this)), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_infiniteApprovalAndSelfTransfer() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 10);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
        vm.prank(bob);
        token.transfer(bob, 10);
        assertEq(token.balanceOf(bob), 10);
    }

    function test_invalidTransfersAndAllowanceRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(this), bob, 1);
    }

    function test_noMintAdminOrUpgradeSelectors() public {
        string[8] memory calls = [
            "mint(address,uint256)",
            "mint(uint256)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)",
            "burn(uint256)"
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(calls[i], alice, 1));
            assertFalse(ok, calls[i]);
            vm.prank(alice);
            (ok,) = address(token).call(abi.encodeWithSignature(calls[i], alice, 1));
            assertFalse(ok, calls[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}
