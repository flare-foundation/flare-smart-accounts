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
        mintableERC20 = new MintableERC20("Mintable Token", "MNT", 18);
        myERC4626 = new MyERC4626(mintableERC20, "My ERC4626", "MERC4626");
    }

    function testSend() public {
        vm.startPrank(user);
        mintableERC20.mint(user, 2000);
        assertEq(mintableERC20.balanceOf(user), 2000);
        mintableERC20.approve(address(myERC4626), 1000);
        // user deposits 1000 assets
        myERC4626.deposit(1000, user);
        assertEq(myERC4626.balanceOf(user), 1000); // user's shares
        assertEq(myERC4626.totalAssets(), 1000); // total assets in the vault
        assertEq(mintableERC20.balanceOf(user), 1000);
        assertEq(myERC4626.totalSupply(), 1000);

        // check that assets:shares ratio is 1:1 initially
        assertEq(myERC4626.convertToShares(1000), 1000);

        // user sends assets directly to the vault address
        mintableERC20.transfer(address(myERC4626), 500);

        // check that assets:shares ratio has changed
        assertEq(myERC4626.totalAssets(), 1500);
        assertEq(myERC4626.totalSupply(), 1000);
        assertLt(myERC4626.convertToShares(1000), 1000);
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
        assertEq(myERC4626.pendingWithdrawAssets(user, 1), 0);
        assertEq(mintableERC20.balanceOf(user), 0); // user's assets transferred to the vault

        // user starts withdraw of 500 assets
        myERC4626.withdraw(500, user, user);
        assertEq(myERC4626.balanceOf(user), 500); // 500 assets are burned
        assertEq(myERC4626.totalAssets(), 500); // 500 pending withdraw are excluded from total assets
        assertEq(myERC4626.assetsPendingWithdraw(), 500); // 500 pending withdraw
        // total assets in the vault remain the same; assets are not yet transferred
        assertEq(myERC4626.pendingWithdrawAssets(user, 1), 500); // pending withdraw assets
        assertEq(mintableERC20.balanceOf(user), 0); // assets not yet transferred to user

        skip(2 days);
        // user claim the withdraw
        myERC4626.claimWithdraw(1);
        assertEq(myERC4626.balanceOf(user), 500); // shares remain the same
        assertEq(myERC4626.totalAssets(), 500); /// 500 pending withdraw are excluded from total assets
        assertEq(myERC4626.assetsPendingWithdraw(), 0); // pending withdraw cleared
        assertEq(myERC4626.pendingWithdrawAssets(user, 1), 0); // pending withdraw assets cleared
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
        assertEq(myERC4626.pendingWithdrawAssets(user, 1), 0);
        assertEq(mintableERC20.balanceOf(user), 0); // user's assets transferred to the vault

        myERC4626.withdraw(400, user, user);
        assertEq(myERC4626.balanceOf(user), 600); // 400 assets are burned
        assertEq(myERC4626.totalAssets(), 600); // 400 pending withdraw are excluded from total assets
        assertEq(myERC4626.assetsPendingWithdraw(), 400); // 400 pending withdraw
        assertEq(myERC4626.pendingWithdrawAssets(user, 1), 400); // pending withdraw assets
        assertEq(mintableERC20.balanceOf(user), 0); // assets not yet transferred to user

        // second withdraw
        myERC4626.withdraw(300, user, user);
        assertEq(myERC4626.balanceOf(user), 300); //  after first withdraw vault’s share/assets ratio did not change
        assertEq(myERC4626.totalAssets(), 300); // 700 pending withdraw are excluded from total assets
        assertEq(myERC4626.assetsPendingWithdraw(), 700); // 700 pending withdraw
        assertEq(myERC4626.pendingWithdrawAssets(user, 1), 700); // pending withdraw assets
        assertEq(mintableERC20.balanceOf(user), 0); // assets not yet transferred to user

        skip(2 days);
        myERC4626.claimWithdraw(1);
        assertEq(myERC4626.balanceOf(user), 300); // shares remain the same
        assertEq(myERC4626.totalAssets(), 300); /// 700 pending withdraw are excluded from total assets
        assertEq(myERC4626.assetsPendingWithdraw(), 0); // pending withdraw cleared
        assertEq(myERC4626.pendingWithdrawAssets(user, 1), 0); // pending withdraw assets cleared
        assertEq(mintableERC20.balanceOf(user), 700); // assets transferred to user
        vm.stopPrank();
    }
}
