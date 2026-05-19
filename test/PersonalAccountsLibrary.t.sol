// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PersonalAccounts} from "../contracts/smartAccounts/library/PersonalAccounts.sol";
import {PersonalAccountProxy} from "../contracts/smartAccounts/proxy/PersonalAccountProxy.sol";

/**
 * @title PersonalAccountsLibraryTest
 * @notice Pins the frozen {PROXY_CREATION_CODE} constant so any accidental edit fails CI.
 *
 * The constant is `type(PersonalAccountProxy).creationCode` as compiled at commit `2abb115` (the
 * source commit used for the live Flare deployment on 2026-02-13). Keeping it stable across
 * rebuilds is the property that lets Personal Account CREATE2 addresses match across all
 * networks the protocol is deployed to.
 *
 * If any test here fails, you are looking at a cross-chain coordination event: all "predicted but
 * not yet deployed" Personal Account addresses will shift to a new derivation moment. Do not
 * update fixtures in this file without explicit cross-chain alignment.
 */
contract PersonalAccountsLibraryTest is Test {

    /// @dev keccak256 of `PROXY_CREATION_CODE` from the live Flare deployment (commit `2abb115`).
    bytes32 private constant EXPECTED_PROXY_CREATION_CODE_HASH =
        0x309250c8635e70dc667c1239a7bb73386e767b7084e9328b70de2c1f505b9b4a;

    function testProxyCreationCodeLengthMatchesFreshCompilation() public pure {
        // Cheapest smoke test: if `PersonalAccountProxy.sol` recompiles to a different *length*,
        // the proxy's runtime size changed and the frozen constant no longer represents the live
        // source. The deeper check below covers same-length semantic drift.
        assertEq(
            PersonalAccounts.PROXY_CREATION_CODE.length,
            type(PersonalAccountProxy).creationCode.length,
            "PROXY_CREATION_CODE length must match the current PersonalAccountProxy creationCode"
        );
    }

    function testProxyCreationCodeMatchesFreshCompilationModuloMetadata() public pure {
        // Strips the trailing CBOR metadata from both sides and compares the remaining (functional)
        // creation bytecode. Catches same-length semantic edits to `PersonalAccountProxy.sol` that
        // the length check misses (e.g. swapping opcodes / changing constants in the constructor
        // logic while preserving total bytecode size).
        bytes memory frozen = _stripMetadata(PersonalAccounts.PROXY_CREATION_CODE);
        bytes memory fresh  = _stripMetadata(type(PersonalAccountProxy).creationCode);
        assertEq(
            keccak256(frozen),
            keccak256(fresh),
            "PROXY_CREATION_CODE functional bytes drifted from the current PersonalAccountProxy source"
        );
    }

    function testProxyCreationCodeHashFrozen() public pure {
        // Catches any edit to the constant itself. This is the load-bearing cross-chain fixture.
        assertEq(
            keccak256(PersonalAccounts.PROXY_CREATION_CODE),
            EXPECTED_PROXY_CREATION_CODE_HASH,
            "PROXY_CREATION_CODE hash drifted from the Flare fixture"
        );
    }

    /// @dev Solc metadata layout: trailing 2 bytes = big-endian length of the preceding CBOR blob.
    /// Major type 5 (`>> 5 == 5`) at the blob start validates it's a solc-emitted CBOR map, not
    /// arbitrary trailing data. Falls back to "no strip" on malformed input so the comparison
    /// still detects drift instead of silently passing.
    function _stripMetadata(bytes memory _code) internal pure returns (bytes memory _stripped) {
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
