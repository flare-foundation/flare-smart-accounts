// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Subaccounts} from "../contracts/smartAccounts/library/Subaccounts.sol";
import {SubaccountProxy} from "../contracts/smartAccounts/proxy/SubaccountProxy.sol";

/**
 * @title SubaccountsLibraryTest
 * @notice Pins the frozen {Subaccounts.PROXY_CREATION_CODE} constant so any accidental edit
 * fails CI.
 *
 * The constant is `type(SubaccountProxy).creationCode` as compiled when the subaccount
 * module was frozen ahead of its first production deployment (2026-08-12). Keeping it stable
 * across rebuilds is the property that lets subaccount CREATE2 addresses — every type's —
 * match across all networks; for the loan type it is load-bearing for funds in flight, since
 * the forward moves bridge FXRP to this same address on the loan chain.
 *
 * If any test here fails, you are looking at a cross-chain coordination event: all "predicted
 * but not yet deployed" subaccount addresses will shift to a new derivation moment. Do not
 * update fixtures in this file without explicit cross-chain alignment.
 */
contract SubaccountsLibraryTest is Test {
    /// @dev keccak256 of `PROXY_CREATION_CODE` as frozen (2026-08-26, pre-deployment;
    /// re-frozen for the `implementationForType` rename and again for the
    /// `SubaccountProxy` contract rename, while no subaccount was deployed).
    bytes32 private constant EXPECTED_PROXY_CREATION_CODE_HASH =
        0xad4d7fa799f7a81d5abbd9af1c88e479cd564096e8c1f663ce1c3e486088f3df;

    /// @dev Not runnable under `forge coverage` — coverage disables via-IR and `type(...).creationCode`
    /// comes out structurally different from the via-IR build the constant was frozen against.
    /// Excluded by name in `.gitlab-ci.yml` and `package.json`'s `coverage` script.
    function testProxyCreationCodeLengthMatchesFreshCompilation() public pure {
        // Cheapest smoke test: if `SubaccountProxy.sol` recompiles to a different *length*,
        // the proxy's runtime size changed and the frozen constant no longer represents the live
        // source. The deeper check below covers same-length semantic drift.
        assertEq(
            Subaccounts.PROXY_CREATION_CODE.length,
            type(SubaccountProxy).creationCode.length,
            "PROXY_CREATION_CODE length must match the current SubaccountProxy creationCode"
        );
    }

    /// @dev Not runnable under `forge coverage` — same reason as the length test above.
    /// Excluded by name in `.gitlab-ci.yml` and `package.json`'s `coverage` script.
    function testProxyCreationCodeMatchesFreshCompilationModuloMetadata() public pure {
        // Strips the trailing CBOR metadata from both sides and compares the remaining (functional)
        // creation bytecode. Catches same-length semantic edits to `SubaccountProxy.sol` that
        // the length check misses (e.g. swapping opcodes / changing constants in the constructor
        // logic while preserving total bytecode size).
        bytes memory frozen = _stripMetadata(Subaccounts.PROXY_CREATION_CODE);
        bytes memory fresh = _stripMetadata(type(SubaccountProxy).creationCode);
        assertEq(
            keccak256(frozen),
            keccak256(fresh),
            "PROXY_CREATION_CODE functional bytes drifted from the current SubaccountProxy source"
        );
    }

    function testProxyCreationCodeHashFrozen() public pure {
        // Catches any edit to the constant itself. This is the load-bearing cross-chain fixture.
        assertEq(
            keccak256(Subaccounts.PROXY_CREATION_CODE),
            EXPECTED_PROXY_CREATION_CODE_HASH,
            "PROXY_CREATION_CODE hash drifted from the frozen fixture"
        );
    }

    /// @dev Solc metadata layout: trailing 2 bytes = big-endian length of the preceding CBOR blob.
    /// Major type 5 (`>> 5 == 5`) at the blob start validates it's a solc-emitted CBOR map, not
    /// arbitrary trailing data. Falls back to "no strip" on malformed input so the comparison
    /// still detects drift instead of silently passing.
    function _stripMetadata(bytes memory _code) private pure returns (bytes memory _stripped) {
        uint256 codeLen = _code.length;
        if (codeLen < 2) return _code;

        uint256 metaLen = (uint256(uint8(_code[codeLen - 2])) << 8)
            | uint256(uint8(_code[codeLen - 1]));
        if (metaLen == 0 || metaLen + 2 > codeLen) return _code;

        uint256 metaStart = codeLen - metaLen - 2;
        if (uint8(_code[metaStart]) >> 5 != 5) return _code;

        _stripped = new bytes(metaStart);
        for (uint256 i = 0; i < metaStart; i++) {
            _stripped[i] = _code[i];
        }
    }
}
