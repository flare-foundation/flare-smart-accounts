// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {PinnedControllerInitCode} from "../../../deployment/scripts/PinnedControllerInitCode.sol";
import {PersonalAccounts} from "../../../contracts/smartAccounts/library/PersonalAccounts.sol";
import {Subaccounts} from "../../../contracts/smartAccounts/library/Subaccounts.sol";
import {SUBACCOUNT_TYPE_LOAN} from "../../../contracts/userInterfaces/facets/ISubaccountsFacet.sol";

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
    /// @dev The live Coston2 controller, for the SA-02 divergence vector below.
    address private constant COSTON2_CONTROLLER = 0x434936d47503353f06750Db1A444DBDC5F0AD37c;
    address private constant GOLDEN_PERSONAL_ACCOUNT = 0x3A5AE0e715593e617b74B0f4705C3934b0116B3c;
    /// @dev Re-derived 2026-09-09 for the release-build refreeze (pre-deployment; previously
    /// re-derived for the `implementationForType` and `SubaccountProxy` renames). The Personal
    /// Account vector above is untouched by all three: only the subaccount constant moved.
    address private constant GOLDEN_LOAN_SUBACCOUNT = 0x65F5d5954A5CA67406A38D184cd176051cCF3D93;

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
            Subaccounts.PROXY_CREATION_CODE,
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

    function testCoston2LegacyAccountsDivergeFromTheFrozenDerivation() public pure {
        // The real SA-02 vector. These seven Coston2 Personal Accounts were created inside the
        // ~21-hour window between the drift cut (block 30,673,186) and the frozen-code cut
        // (block 30,706,139) on 2026-05-18/19, while rebuilt proxy creation code still drifted.
        // Their registered addresses are therefore NOT what the frozen derivation produces, so
        // their own chain resolves them from the registry while every other chain resolves the
        // canonical address, so the same owner's loan subaccount is a different address depending
        // on which side you ask - which is the harm, and what the last assertion below pins.
        //
        // The owner strings are read from each account's own `xrplOwner()` on chain, not copied
        // from the audit report: the report has a typo in two of them (a dropped `b` and an `H`
        // for an `X`), and a fixture built from those would compute the wrong canonical address
        // and pass for the wrong reason. Both columns were re-read from the live controller on
        // 2026-09-09: every owner resolves to the registered address below, and every account's
        // own `xrplOwner()` returns the string beside it.
        //
        // This records the state BEFORE the migration. Coston2's deployment cut migrates these
        // seven (`deployment/RUNBOOK.md`, step A2), after which the registry returns the
        // canonical column and the divergence is gone - so when that runs, this fixture becomes
        // the historical record and the assertion worth having is the opposite one.
        // cspell:disable
        string[7] memory owners = [
            "r9kDHXyZtWdrSS9kqrKDyVZpBL1cNPUMDp",
            "rffefbMdSErjUx7yypqFBLqG9KAiWF7oAS",
            "rMWwsp6niSFQgcz3qFXHouBYKRC68uFkiE",
            "rnjaMZk1WnhrAybKiSDG76g4nAJMJZqQTE",
            "rPqPX9YqvZbaRQFDT727w5VK4WQYBdCawy",
            "riWhZWop39qCFCbGN8jVczP8RESZdbxPA",
            "rKtZkxRAdjyr7GGDqZ9SdcgXNwjMAdKuvx"
        ];
        // cspell:enable
        address[7] memory registered = [
            0xD2802Df078aa70cAd5e2Af91b636D9E858d1f82c,
            0xfe42AfE6DB37fDe64169c1265496221E72e31310,
            0x761e930e5A236C2C77AE61851Be5e3bBB57b6859,
            0x73cF1052Cb71b6EA23C19b3b31910D44E42064Ac,
            0x256962b5Dbbb4c338D4AC9A83608701438CC714D,
            0x60B626f0cBfc2884cFfb2D6c4856a5Dc6137C84E,
            0xbE6Bd4ee2967156699aD675F484529a90f6f9244
        ];
        address[7] memory canonical = [
            0x17B8436c8C3750fCa14e19D4ce7231a1277E48F8,
            0x3897a3bc14Dc2e64493A7a2A60Ae0D7797F0b768,
            0xA97967A5D61e636c4cE1c437dbB63a826d7c6AA6,
            0x2E5dA7Ff9d99a9E1c5A18a915E32b56DBd5DCb2d,
            0x57ea8cd1A443d587c7111692D77C1e26b5f20dEb,
            0x71e4DD5a7a9bcCC04790ddc3c6D154dd50BA6eb7,
            0x089AEa01C5b4139aFbe01d019E1ac638663EF8dA
        ];

        for (uint256 i = 0; i < owners.length; i++) {
            address computed = Create2.computeAddress(
                PinnedControllerInitCode.SALT,
                keccak256(
                    abi.encodePacked(
                        PersonalAccounts.PROXY_CREATION_CODE,
                        abi.encode(COSTON2_CONTROLLER, owners[i])
                    )
                ),
                PinnedControllerInitCode.SINGLETON_FACTORY
            );
            assertEq(computed, canonical[i], "canonical Personal Account drifted");
            assertNotEq(computed, registered[i], "this owner is no longer a divergence case");
            assertNotEq(
                _coston2Subaccount(computed),
                _coston2Subaccount(registered[i]),
                "the two parents must derive different subaccounts"
            );
        }
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
        if (_needle.length > _haystack.length) {
            return false;
        }
        for (uint256 i = 0; i <= _haystack.length - _needle.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < _needle.length; j++) {
                if (_haystack[i + j] != _needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                return true;
            }
        }
        return false;
    }

    /// @dev The loan subaccount `_parent` derives on the Coston2 controller.
    function _coston2Subaccount(address _parent) private pure returns (address) {
        return Create2.computeAddress(
            PinnedControllerInitCode.SALT,
            keccak256(
                abi.encodePacked(
                    Subaccounts.PROXY_CREATION_CODE,
                    abi.encode(COSTON2_CONTROLLER, _parent, SUBACCOUNT_TYPE_LOAN)
                )
            ),
            PinnedControllerInitCode.SINGLETON_FACTORY
        );
    }
}
