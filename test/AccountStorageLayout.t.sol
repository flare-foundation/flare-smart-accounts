// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PersonalAccount} from "../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {PersonalAccountRemote} from "../contracts/smartAccounts/implementation/PersonalAccountRemote.sol";
import {LoanSubaccount} from "../contracts/smartAccounts/implementation/LoanSubaccount.sol";
import {LoanSubaccountRemote} from "../contracts/smartAccounts/implementation/LoanSubaccountRemote.sol";

/// The storage rule of the account bases, pinned: `controllerAddress` is slot 0, linear, in
/// every lineage, and `xrplOwner` slot 1 in every Personal Account lineage - the production
/// Flare Personal Account's layout, which every implementation behind the same proxies must
/// reproduce forever. Everything else a base holds lives in its ERC-7201 namespace, so a base
/// can grow without shifting a derived lineage's own linear state.
contract AccountStorageLayoutTest is Test {
    /// The sentinel every implementation's constructor writes into slot 0.
    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;
    bytes32 private constant SUBACCOUNT_NAMESPACE = bytes32(erc7201("smartAccounts.SubaccountBase.State"));

    address private controller = makeAddr("controller");
    address private parent = makeAddr("parent");

    function testControllerAddressIsSlotZeroInEveryLineage() public {
        address[4] memory implementations = [
            address(new PersonalAccount()),
            address(new PersonalAccountRemote()),
            address(new LoanSubaccount()),
            address(new LoanSubaccountRemote())
        ];
        for (uint256 i = 0; i < implementations.length; i++) {
            assertEq(_addressAt(implementations[i], 0), EMPTY_ADDRESS, "slot 0 is not the controller");
        }
    }

    function testPersonalAccountLayoutIsTheProductionLayout() public {
        // the deployed Flare Personal Account: slot 0 controllerAddress, slot 1 xrplOwner - and
        // the remote implementation, behind the same frozen proxy, reproduces it exactly
        PersonalAccount flare = new PersonalAccount();
        PersonalAccountRemote remote = new PersonalAccountRemote();
        _initializePersonalAccount(address(flare));
        _initializePersonalAccount(address(remote));
        assertEq(_addressAt(address(flare), 0), controller);
        assertEq(_addressAt(address(remote), 0), controller);
        // a short string occupies its slot inline: the bytes left-aligned, 2 * length in the low byte
        bytes32 expectedOwner = bytes32(bytes("rOwner")) | bytes32(uint256(bytes("rOwner").length * 2));
        assertEq(vm.load(address(flare), bytes32(uint256(1))), expectedOwner);
        assertEq(vm.load(address(remote), bytes32(uint256(1))), expectedOwner);
        assertEq(flare.xrplOwner(), "rOwner");
        assertEq(remote.xrplOwner(), "rOwner");
    }

    function testSubaccountIdentityLivesInItsNamespaceOnBothChains() public {
        LoanSubaccount flare = new LoanSubaccount();
        LoanSubaccountRemote remote = new LoanSubaccountRemote();
        _initializeSubaccount(address(flare));
        _initializeSubaccount(address(remote));
        address[2] memory accounts = [address(flare), address(remote)];
        for (uint256 i = 0; i < accounts.length; i++) {
            assertEq(_addressAt(accounts[i], 0), controller);
            // the parent and the type sit in the SubaccountBase namespace, not in linear slots
            assertEq(_addressAt(accounts[i], uint256(SUBACCOUNT_NAMESPACE)), parent);
            assertEq(uint256(vm.load(accounts[i], bytes32(uint256(SUBACCOUNT_NAMESPACE) + 1))), 7);
        }
        // the Flare lineage has no linear state of its own after slot 0
        assertEq(vm.load(address(flare), bytes32(uint256(1))), bytes32(0));
        assertEq(flare.parentPersonalAccount(), parent);
        assertEq(remote.subaccountType(), 7);
    }

    function _initializePersonalAccount(address _impl) private {
        // clear the constructor's lock so the implementation itself can be initialized here
        vm.store(_impl, bytes32(0), bytes32(0));
        PersonalAccount(payable(_impl)).initialize(controller, "rOwner");
    }

    function _initializeSubaccount(address _impl) private {
        vm.store(_impl, bytes32(0), bytes32(0));
        LoanSubaccount(payable(_impl)).initialize(controller, parent, 7);
    }

    function _addressAt(address _account, uint256 _slot) private view returns (address) {
        return address(uint160(uint256(vm.load(_account, bytes32(_slot)))));
    }
}
