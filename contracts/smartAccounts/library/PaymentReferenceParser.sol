// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// payment reference format (32 bytes):
// instruction id consists of instruction type (4 bits) and instruction command (4 bits)
// FXRP (instruction type 0)
// bytes 00: bytes1 (hex) -> instruction id
    // 00: collateral reservation
    // 01: transfer
    // 02: redeem
// bytes 01: uint8 -> wallet identifier
// bytes 02-11: uint80 -> value (value, lots)
// collateral reservation:
// bytes 12-13: uint16 -> agent vault address id (collateral reservation)
// bytes 14-31: future use
// transfer:
// bytes 12-31: address (20 bytes) -> recipient address

// Firelight vaults (instruction type 1)
// bytes 00: bytes1 (hex) -> instruction id
    // 10: collateral reservation and deposit
    // 11: deposit
    // 12: redeem
    // 13: claim withdraw
    // 14: claim withdraw and redeem FXRP
// bytes 01: uint8 -> wallet identifier
// bytes 02-11: uint80 -> value (amount, shares, lots, period,...)
// bytes 12-13: uint16 -> agent vault address id
// bytes 14-15: uint16 -> deposit/withdraw vault address id
// bytes 16-31: future use

// Upshift vaults (instruction type 2)
// bytes 00: bytes1 (hex) -> instruction id
    // 20: collateral reservation and deposit
    // 21: deposit
    // 22: requestRedeem
    // 23: claim
    // 24: claim and redeem FXRP
// bytes 01: uint8 -> wallet identifier
// bytes 02-11: uint80 -> value (amount, shares, lots, date(yyyymmdd),...)
// bytes 12-13: uint16 -> agent vault address id
// bytes 14-15: uint16 -> deposit/withdraw vault address id
// bytes 16-31: future use

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

    function getAgentVaultId(bytes32 _paymentReference) internal pure returns (uint256) {
        // bytes 12-13: agent vault id
        return (uint256(_paymentReference) >> 144) & ((uint256(1) << 16) - 1);
    }

    function getVaultId(bytes32 _paymentReference) internal pure returns (uint256) {
        // bytes 14-15: vault id
        return (uint256(_paymentReference) >> 128) & ((uint256(1) << 16) - 1);
    }

    function getAddress(bytes32 _paymentReference) internal pure returns (address _address) {
        // bytes 12-31: address (20 bytes)
        _address = address(uint160(uint256(_paymentReference) & ((uint256(1) << 160) - 1)));
        require(_address != address(0), IInstructionsFacet.AddressZero());
    }
}
