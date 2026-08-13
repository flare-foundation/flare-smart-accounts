// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {PinnedControllerInitCode} from "../deployment/scripts/PinnedControllerInitCode.sol";
import {PersonalAccounts} from "../contracts/smartAccounts/library/PersonalAccounts.sol";
import {LoanSubaccounts} from "../contracts/smartAccounts/library/LoanSubaccounts.sol";
import {SUBACCOUNT_TYPE_LOAN} from "../contracts/userInterfaces/facets/ILoanSubaccountsFacet.sol";

/**
 * @title PinnedInitCodeTest
 * @notice Pins the historical CREATE2 inputs of the production MasterAccountController
 * deployment: the raw init code files under `deployment/pinned-init-code/` must hash to the
 * pinned fixtures, and the CREATE2 derivation from those hashes must reproduce the live
 * production addresses. This is what makes the diamond reproducible byte-exactly on new
 * chains (Ethereum) — rebuilding from today's sources does not reproduce it.
 *
 * If any test here fails, either the pinned files were modified (restore them: they are
 * chain-recovered facts, not build outputs) or a fixture was edited without cross-chain
 * alignment.
 */
contract PinnedInitCodeTest is Test {
    /// @dev A synthetic golden vector: with the production controller, this XRPL owner maps to
    /// these exact Personal Account and loan subaccount addresses on every chain. Computed
    /// from the frozen proxy creation codes; any drift in the derivation inputs breaks this.
    string private constant GOLDEN_XRPL_OWNER = "rGoldenVectorXrplOwner";
    address private constant GOLDEN_PERSONAL_ACCOUNT = 0x3A5AE0e715593e617b74B0f4705C3934b0116B3c;
    address private constant GOLDEN_LOAN_SUBACCOUNT = 0x56b897CA71D515e3324037f64AC2d849DE5CB013;

    function testPinnedInitCodeDeploysToPinnedRuntimeCode() public {
        // the pinned init code must actually deploy, and what it deploys must be
        // byte-identical to the Flare production runtime (EXTCODEHASH fixtures). The base
        // facets are etched to their production addresses first, because the controller's
        // constructor cuts them and requires their code there.
        address cutFacet = _create(_readInitCode("DiamondCutFacet"));
        assertEq(
            cutFacet.codehash,
            PinnedControllerInitCode.DIAMOND_CUT_FACET_RUNTIME_CODE_HASH,
            "DiamondCutFacet runtime drifted"
        );
        address loupeFacet = _create(_readInitCode("DiamondLoupeFacet"));
        assertEq(
            loupeFacet.codehash,
            PinnedControllerInitCode.DIAMOND_LOUPE_FACET_RUNTIME_CODE_HASH,
            "DiamondLoupeFacet runtime drifted"
        );
        address ownershipFacet = _create(_readInitCode("OwnershipFacet"));
        assertEq(
            ownershipFacet.codehash,
            PinnedControllerInitCode.OWNERSHIP_FACET_RUNTIME_CODE_HASH,
            "OwnershipFacet runtime drifted"
        );

        vm.etch(PinnedControllerInitCode.DIAMOND_CUT_FACET, cutFacet.code);
        vm.etch(PinnedControllerInitCode.DIAMOND_LOUPE_FACET, loupeFacet.code);
        vm.etch(PinnedControllerInitCode.OWNERSHIP_FACET, ownershipFacet.code);

        address controller = _create(_readInitCode("MasterAccountController"));
        assertEq(
            controller.codehash,
            PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER_RUNTIME_CODE_HASH,
            "MasterAccountController runtime drifted"
        );
    }

    function testPinnedMasterAccountControllerInitCode() public view {
        _checkPinned(
            "MasterAccountController",
            PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER_INIT_CODE_HASH,
            PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER
        );
    }

    function testPinnedBaseFacetInitCode() public view {
        _checkPinned(
            "DiamondCutFacet",
            PinnedControllerInitCode.DIAMOND_CUT_FACET_INIT_CODE_HASH,
            PinnedControllerInitCode.DIAMOND_CUT_FACET
        );
        _checkPinned(
            "DiamondLoupeFacet",
            PinnedControllerInitCode.DIAMOND_LOUPE_FACET_INIT_CODE_HASH,
            PinnedControllerInitCode.DIAMOND_LOUPE_FACET
        );
        _checkPinned(
            "OwnershipFacet",
            PinnedControllerInitCode.OWNERSHIP_FACET_INIT_CODE_HASH,
            PinnedControllerInitCode.OWNERSHIP_FACET
        );
    }

    function testControllerInitCodeEmbedsBaseFacetsAndOwner() public view {
        // the controller's constructor args commit to the base facet addresses and the
        // initial owner; if the pinned bytes ever stopped containing them, the fixture would
        // have been swapped for something else entirely
        bytes memory initCode = _readInitCode("MasterAccountController");
        assertTrue(_contains(initCode, abi.encode(PinnedControllerInitCode.DIAMOND_CUT_FACET)));
        assertTrue(_contains(initCode, abi.encode(PinnedControllerInitCode.DIAMOND_LOUPE_FACET)));
        assertTrue(_contains(initCode, abi.encode(PinnedControllerInitCode.OWNERSHIP_FACET)));
        assertTrue(_contains(initCode, abi.encode(PinnedControllerInitCode.INITIAL_OWNER)));
    }

    function testGoldenVectorAddressesOnProductionController() public pure {
        // full derivation chain on the production controller: xrplOwner -> Personal Account
        // -> loan subaccount, all through the frozen creation-code constants
        bytes memory personalAccountInitCode = abi.encodePacked(
            PersonalAccounts.PROXY_CREATION_CODE,
            abi.encode(PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER, GOLDEN_XRPL_OWNER)
        );
        address personalAccount = Create2.computeAddress(
            PinnedControllerInitCode.SALT,
            keccak256(personalAccountInitCode),
            PinnedControllerInitCode.SINGLETON_FACTORY
        );
        assertEq(
            personalAccount,
            GOLDEN_PERSONAL_ACCOUNT,
            "Personal Account golden vector drifted"
        );

        bytes memory subaccountInitCode = abi.encodePacked(
            LoanSubaccounts.PROXY_CREATION_CODE,
            abi.encode(
                PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER,
                personalAccount,
                SUBACCOUNT_TYPE_LOAN
            )
        );
        assertEq(
            Create2.computeAddress(
                PinnedControllerInitCode.SALT,
                keccak256(subaccountInitCode),
                PinnedControllerInitCode.SINGLETON_FACTORY
            ),
            GOLDEN_LOAN_SUBACCOUNT,
            "loan subaccount golden vector drifted"
        );
    }

    function _create(bytes memory _initCode) private returns (address _deployed) {
        // plain CREATE: the runtime hash is address-independent, so the CREATE2 factory is
        // not needed to verify what the pinned bytes deploy
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _deployed := create(0, add(_initCode, 32), mload(_initCode))
        }
        require(_deployed != address(0), "pinned init code failed to deploy");
    }

    function _checkPinned(
        string memory _name,
        bytes32 _expectedInitCodeHash,
        address _expectedAddress
    )
        private view
    {
        bytes memory initCode = _readInitCode(_name);
        assertEq(
            keccak256(initCode),
            _expectedInitCodeHash,
            string.concat(_name, ": pinned init code drifted from its hash fixture")
        );
        assertEq(
            Create2.computeAddress(
                PinnedControllerInitCode.SALT,
                _expectedInitCodeHash,
                PinnedControllerInitCode.SINGLETON_FACTORY
            ),
            _expectedAddress,
            string.concat(_name, ": CREATE2 derivation does not reproduce production")
        );
    }

    function _readInitCode(string memory _name) private view returns (bytes memory) {
        return vm.parseBytes(
            vm.readFile(
                string.concat(PinnedControllerInitCode.INIT_CODE_DIR, _name, ".hex")
            )
        );
    }

    function _contains(bytes memory _haystack, bytes memory _needle) private pure returns (bool) {
        if (_needle.length > _haystack.length) return false;
        for (uint256 i = 0; i <= _haystack.length - _needle.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < _needle.length; j++) {
                if (_haystack[i + j] != _needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
