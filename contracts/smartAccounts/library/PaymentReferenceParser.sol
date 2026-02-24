// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";
import {IAgentVaultsFacet} from "../../userInterfaces/facets/IAgentVaultsFacet.sol";
import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";

// payment reference format (32 bytes):
// instruction id consists of instruction type (4 bits) and instruction command (4 bits)

// FXRP (instruction type 0)
// bytes 00: bytes1 (hex) -> instruction id
    // 00: collateral reservation
    // 01: transfer
    // 02: redeem
// bytes 01: uint8 -> wallet identifier
// collateral reservation:
// bytes 02-11: uint80 -> value (lots)
// bytes 12-13: uint16 -> agent vault address id (collateral reservation)
// transfer:
// bytes 02-11: uint80 -> value (amount in drops)
// bytes 12-31: address (20 bytes) -> recipient address
// redeem:
// bytes 02-11: uint80 -> value (lots)

// Firelight vaults (instruction type 1)
// bytes 00: bytes1 (hex) -> instruction id
    // 10: collateral reservation and deposit
    // 11: deposit
    // 12: redeem
    // 13: claim withdraw
// bytes 01: uint8 -> wallet identifier
// collateral reservation and deposit:
// bytes 02-11: uint80 -> value (lots)
// bytes 12-13: uint16 -> agent vault address id
// bytes 14-15: uint16 -> deposit vault address id
// deposit:
// bytes 02-11: uint80 -> value (assets in drops)
// bytes 14-15: uint16 -> deposit vault address id
// redeem:
// bytes 02-11: uint80 -> value (shares in drops)
// bytes 14-15: uint16 -> withdraw vault address id
// claim withdraw:
// bytes 02-11: uint80 -> value (period)
// bytes 14-15: uint16 -> withdraw vault address id

// Upshift vaults (instruction type 2)
// bytes 00: bytes1 (hex) -> instruction id
    // 20: collateral reservation and deposit
    // 21: deposit
    // 22: requestRedeem
    // 23: claim
// bytes 01: uint8 -> wallet identifier
// collateral reservation and deposit:
// bytes 02-11: uint80 -> value (lots)
// bytes 12-13: uint16 -> agent vault address id
// bytes 14-15: uint16 -> deposit vault address id
// deposit:
// bytes 02-11: uint80 -> value (assets in drops)
// bytes 14-15: uint16 -> deposit vault address id
// requestRedeem:
// bytes 02-11: uint80 -> value (shares in drops)
// bytes 14-15: uint16 -> withdraw vault address id
// claim:
// bytes 02-11: uint80 -> value (date(yyyymmdd))
// bytes 14-15: uint16 -> withdraw vault address id

library PaymentReferenceParser {

    function getInstructionId(bytes32 _paymentReference) internal pure returns (uint256) {
        // byte 00: instruction id
        return uint256(_paymentReference) >> 248;
    }

    function getInstructionType(bytes32 _paymentReference) internal pure returns (uint256) {
        // byte 00 (first 4 bits): instruction type
        return uint256(_paymentReference) >> 252;
    }

    function getInstructionCommand(bytes32 _paymentReference) internal pure returns (uint256) {
        // byte 00 (last 4 bits): instruction command
        return (uint256(_paymentReference) >> 248) & 0x0F;
    }

    function getValue(bytes32 _paymentReference) internal pure returns (uint256 _value) {
        // bytes 02-11: uint80
        _value = (uint256(_paymentReference) >> 160) & ((uint256(1) << 80) - 1);
        require(_value > 0, IInstructionsFacet.ValueZero());
    }

    function getAgentVaultId(bytes32 _paymentReference) internal pure returns (uint256 _agentVaultId) {
        // bytes 12-13: agent vault id
        _agentVaultId = (uint256(_paymentReference) >> 144) & ((uint256(1) << 16) - 1);
        require(_agentVaultId > 0, IAgentVaultsFacet.InvalidAgentVault(0));
    }

    function getVaultId(bytes32 _paymentReference) internal pure returns (uint256 _vaultId) {
        // bytes 14-15: vault id
        _vaultId = (uint256(_paymentReference) >> 128) & ((uint256(1) << 16) - 1);
        require(_vaultId > 0, IVaultsFacet.InvalidVaultId(0));
    }

    function getAddress(bytes32 _paymentReference) internal pure returns (address _address) {
        // bytes 12-31: address (20 bytes)
        _address = address(uint160(uint256(_paymentReference) & ((uint256(1) << 160) - 1)));
        require(_address != address(0), IInstructionsFacet.AddressZero());
    }
}
