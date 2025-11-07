// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";
import {FXrp} from "../library/FXrp.sol";
import {Vault} from "../library/Vault.sol";
import {Vaults} from "../library/Vaults.sol";

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

library Instructions {

    struct State {
        /// @notice Indicates if payment instruction has already been executed.
        mapping(bytes32 transactionId => bool) usedPaymentHashes;
        /// @notice Mapping from collateral reservation ID to XRPL transaction ID - used for deposit after minting
        mapping(uint256 collateralReservationId => bytes32 transactionId) collateralReservationIdToTransactionId;
    }

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.Instructions.State");

    function executeInstruction(
        uint256 _instructionType,
        uint256 _instructionCommand,
        bytes32 _paymentReference,
        IIPersonalAccount _personalAccount
    )
        internal
    {
        if (_instructionType == 0 && _instructionCommand == 1) { // transfer FXRP
            uint256 amount = _getValue(_paymentReference);
            address recipient = _getAddress(_paymentReference);
            FXrp.transfer(_personalAccount, recipient, amount);
        } else if (_instructionType == 0 && _instructionCommand == 2) { // redeem FXRP
            uint256 lots = _getValue(_paymentReference);
            FXrp.redeem(_personalAccount, lots);
        } else if ((_instructionType == 1 || _instructionType == 2) && _instructionCommand == 1) { // deposit
            uint256 amount = _getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            Vault.deposit(_personalAccount, vault, amount);
        } else if (_instructionType == 1 && _instructionCommand == 2) { // redeem
            address vault = Vaults.getVaultAddress(_paymentReference);
            uint256 shares = _getValue(_paymentReference);
            Vault.redeem(_personalAccount, vault, shares);
        } else if (_instructionType == 1 && _instructionCommand == 3) { // claim withdraw
            uint256 period = _getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            Vault.claimWithdrawal(_personalAccount, vault, period);
        } else if (_instructionType == 1 && _instructionCommand == 4) { // claim withdraw and redeem FXRP
            uint256 period = _getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            uint256 amount = Vault.claimWithdrawal(_personalAccount, vault, period);
            uint256 lots = _amountToLots(amount);
            FXrp.redeem(_personalAccount, lots);
        } else if (_instructionType == 2 && _instructionCommand == 2) { // requestRedeem
            uint256 shares = _getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            Vault.requestRedeem(_personalAccount, vault, shares);
        } else if (_instructionType == 2 && _instructionCommand == 3) { // claim
            uint256 date = _getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            Vault.claim(_personalAccount, vault, date);
        } else if (_instructionType == 2 && _instructionCommand == 4) { // claim and redeem FXRP
            uint256 date = _getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            uint256 amount = Vault.claim(_personalAccount, vault, date);
            uint256 lots = _amountToLots(amount);
            FXrp.redeem(_personalAccount, lots);
        } else {
            revert IInstructionsFacet.InvalidInstruction(_instructionType, _instructionCommand);
        }
    }

    function _lotsToAmount(uint256 _lots) internal view returns (uint256) {
        uint256 lotSize = ContractRegistry.getAssetManagerFXRP().lotSize();
        return _lots * lotSize;
    }

    function _amountToLots(uint256 _amount) internal view returns (uint256) {
        uint256 lotSize = ContractRegistry.getAssetManagerFXRP().lotSize();
        return _amount / lotSize; // there might be remainder
    }

    function _getInstructionType(bytes32 _paymentReference) internal pure returns (uint256) {
        // byte 00 (first 4 bits): instruction type
        return uint256(_paymentReference) >> 252;
    }

    function _getInstructionCommand(bytes32 _paymentReference) internal pure returns (uint256) {
        // byte 00 (last 4 bits): instruction command
        return (uint256(_paymentReference) >> 248) & 0x0F;
    }

    function _getValue(bytes32 _paymentReference) internal pure returns (uint256 _value) {
        // bytes 02-11: uint80
        _value = (uint256(_paymentReference) >> 160) & ((uint256(1) << 80) - 1);
        require(_value > 0, IInstructionsFacet.ValueZero());
    }

    function _getAddress(bytes32 _paymentReference) internal pure returns (address _address) {
        // bytes 12-31: address (20 bytes)
        _address = address(uint160(uint256(_paymentReference) & ((uint256(1) << 160) - 1)));
        require(_address != address(0), IInstructionsFacet.AddressZero());
    }

    function getState()
        internal pure
        returns (State storage _state)
    {
        bytes32 position = STATE_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }
}
