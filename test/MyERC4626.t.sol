// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {MyERC4626} from "../contracts/mock/MyERC4626.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";

contract MyERC4626Test is Test {
    MyERC4626 private myERC4626;
    MintableERC20 private mintableERC20;
    address private user = makeAddr("user");

    function setUp() public {
        mintableERC20 = new MintableERC20("Mintable Token", "MNT");
        myERC4626 = new MyERC4626(mintableERC20, "My ERC4626", "MERC4626");
    }

    function testWithdraw() public {
        vm.startPrank(user);
        mintableERC20.mint(user, 1000);
        assertEq(mintableERC20.balanceOf(user), 1000);

        mintableERC20.approve(address(myERC4626), 1000);

        // user deposits 1000 assets
        myERC4626.deposit(1000, user);
        assertEq(myERC4626.balanceOf(user), 1000); // user's shares
        assertEq(myERC4626.totalAssets(), 1000); // total assets in the vault
        assertEq(myERC4626.pendingWithdrawAssets(user), 0);
        assertEq(mintableERC20.balanceOf(user), 0); // user's assets transferred to the vault

        // user starts withdraw of 500 assets
        myERC4626.withdraw(500, user, user);
        assertEq(myERC4626.balanceOf(user), 500); // 500 assets are burned
        assertEq(myERC4626.totalAssets(), 1000);
        // total assets in the vault remain the same; assets are not yet transferred
        assertEq(myERC4626.pendingWithdrawAssets(user), 500); // pending withdraw assets
        assertEq(mintableERC20.balanceOf(user), 0); // assets not yet transferred to user

        // user claim the withdraw
        myERC4626.claimWithdraw(1);
        assertEq(myERC4626.balanceOf(user), 500); // shares remain the same
        assertEq(myERC4626.totalAssets(), 500); // total assets in the vault decreased
        assertEq(myERC4626.pendingWithdrawAssets(user), 0); // pending withdraw assets cleared
        assertEq(mintableERC20.balanceOf(user), 500); // assets transferred to user
        vm.stopPrank();
    }

    function testWithdrawTwice() public {
        // withdraw twice without claiming in between; claim at the end
        vm.startPrank(user);
        mintableERC20.mint(user, 1000);
        assertEq(mintableERC20.balanceOf(user), 1000);
        mintableERC20.approve(address(myERC4626), 1000);
        myERC4626.deposit(1000, user);
        assertEq(myERC4626.balanceOf(user), 1000); // user's shares
        assertEq(myERC4626.totalAssets(), 1000); // total assets in the vault
        assertEq(myERC4626.pendingWithdrawAssets(user), 0);
        assertEq(mintableERC20.balanceOf(user), 0); // user's assets transferred to the vault

        myERC4626.withdraw(400, user, user);
        assertEq(myERC4626.balanceOf(user), 600); // 400 assets are burned
        assertEq(myERC4626.totalAssets(), 1000);
        assertEq(myERC4626.pendingWithdrawAssets(user), 400); // pending withdraw assets
        assertEq(mintableERC20.balanceOf(user), 0); // assets not yet transferred to user

        // second withdraw
        myERC4626.withdraw(300, user, user);
        // assertEq(myERC4626.balanceOf(user), 300); //  after first withdraw vault’s share/assets ratio changed
        assertEq(myERC4626.totalAssets(), 1000);
        assertEq(myERC4626.pendingWithdrawAssets(user), 700); // pending withdraw assets
        assertEq(mintableERC20.balanceOf(user), 0); // assets not yet transferred to user

        myERC4626.claimWithdraw(1);
        // assertEq(myERC4626.balanceOf(user), 300); // shares remain the same
        assertEq(myERC4626.totalAssets(), 300); // total assets in the vault decreased
        assertEq(myERC4626.pendingWithdrawAssets(user), 0); // pending withdraw assets cleared
        assertEq(mintableERC20.balanceOf(user), 700); // assets transferred to user
        vm.stopPrank();
    }
}
