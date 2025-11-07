// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {CollateralReservationInfo} from "flare-periphery/src/flare/data/CollateralReservationInfo.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IIInstructionsFacet} from "../interface/IIInstructionsFacet.sol";
import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";
import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {PaymentProofs} from "../library/PaymentProofs.sol";
import {FXrp} from "../library/FXrp.sol";
import {Vault} from "../library/Vault.sol";
import {Vaults} from "../library/Vaults.sol";
import {AgentVaults} from "../library/AgentVaults.sol";
import {InstructionFees} from "../library/InstructionFees.sol";
import {Instructions} from "../library/Instructions.sol";

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

/**
 * @title InstructionsFacet
 * @notice Facet for handling instructions.
 */
contract InstructionsFacet is IIInstructionsFacet {

    /**
     * @inheritdoc IInstructionsFacet
     */
    function reserveCollateral(
        string calldata _xrplAddress,
        bytes32 _paymentReference,
        bytes32 _transactionId
    )
        external payable
        returns (uint256 _collateralReservationId)
    {
        // check instruction id
        uint256 instructionType = _getInstructionType(_paymentReference);
        uint256 instructionCommand = _getInstructionCommand(_paymentReference);
        require(
            instructionType <= 2 && instructionCommand == 0,
            InvalidInstruction(instructionType, instructionCommand)
        );
        // check transaction id
        require(_transactionId != bytes32(0), InvalidTransactionId());
        // create or get existing Personal Account for the XRPL address
        IIPersonalAccount personalAccount = PersonalAccounts.getOrCreatePersonalAccount(_xrplAddress);
        // reserve collateral
        address agentVault = AgentVaults.getAgentVaultAddress(_paymentReference);
        uint256 lots = _getValue(_paymentReference);
        _collateralReservationId = FXrp.reserveCollateral(
            personalAccount,
            agentVault,
            lots,
            _transactionId,
            _paymentReference,
            _xrplAddress
        );
        // set mapping from collateral reservation id to transaction id
        Instructions.State storage state = Instructions.getState();
        state.collateralReservationIdToTransactionId[_collateralReservationId] = _transactionId;
    }

    /**
     * @inheritdoc IInstructionsFacet
     */
    function executeDepositAfterMinting(
        uint256 _collateralReservationId,
        IPayment.Proof calldata _proof,
        string calldata _xrplAddress
    )
        external
    {
        bytes32 paymentReference = _proof.data.responseBody.standardPaymentReference;

        // check instruction id
        uint256 instructionType = _getInstructionType(paymentReference);
        uint256 instructionCommand = _getInstructionCommand(paymentReference);
        require(
            0 < instructionType && instructionType <= 2 && instructionCommand == 0,
            InvalidInstruction(instructionType, instructionCommand)
        );
        uint256 instructionId = instructionType << 4 | instructionCommand;

        // check that crtId and txId match
        bytes32 transactionId = _proof.data.requestBody.transactionId;
        Instructions.State storage state = Instructions.getState();
        require(
            transactionId != bytes32(0) &&
            state.collateralReservationIdToTransactionId[_collateralReservationId] == transactionId,
            UnknownCollateralReservationId()
        );

        // check if minting was successfully completed
        CollateralReservationInfo.Data memory reservationInfo =
            ContractRegistry.getAssetManagerFXRP().collateralReservationInfo(_collateralReservationId);
        require(
            reservationInfo.status == CollateralReservationInfo.Status.SUCCESSFUL,
            MintingNotCompleted()
        );
        // no check of instruction fee here, as fee includes collateral reservation fee and has to be checked off-chain
        // verify payment proof
        PaymentProofs.verifyPayment(_proof, _xrplAddress);
        // check that minter and amount match
        IIPersonalAccount personalAccount = PersonalAccounts.getOrCreatePersonalAccount(_xrplAddress);
        require(address(personalAccount) == reservationInfo.minter, InvalidMinter());
        uint256 amount = FXrp.lotsToAmount(_getValue(paymentReference));
        // could revert if lot size changes between minting and deposit, but very unlikely
        // user should call deposit in that case
        require(amount == reservationInfo.valueUBA, InvalidAmount());
        // mark transaction as used
        require(!state.usedPaymentHashes[transactionId], TransactionAlreadyExecuted());
        state.usedPaymentHashes[transactionId] = true;

        // execute deposit
        address vault = Vaults.getVaultAddress(paymentReference);
        Vault.deposit(personalAccount, vault, amount);

        // emit event
        emit InstructionExecuted(
            address(personalAccount),
            paymentReference,
            transactionId,
            _xrplAddress,
            instructionId
        );
    }

    /**
     * @inheritdoc IInstructionsFacet
     */
    function executeInstruction(
        IPayment.Proof calldata _proof,
        string calldata _xrplAddress
    )
        external payable
    {
        bytes32 paymentReference = _proof.data.responseBody.standardPaymentReference;
        uint256 instructionType = _getInstructionType(paymentReference);
        uint256 instructionCommand = _getInstructionCommand(paymentReference);
        uint256 instructionId = instructionType << 4 | instructionCommand;
        // check instruction fee payment
        uint256 instructionFee = InstructionFees.getInstructionFee(instructionId);
        int256 receivedAmount = _proof.data.responseBody.receivedAmount;
        require(
            receivedAmount >= 0 && uint256(receivedAmount) >= instructionFee,
            InvalidPaymentAmount(instructionFee)
        );

        // verify payment proof
        PaymentProofs.verifyPayment(_proof, _xrplAddress);

        // mark transaction as used
        Instructions.State storage state = Instructions.getState();
        bytes32 transactionId = _proof.data.requestBody.transactionId;
        require(!state.usedPaymentHashes[transactionId], TransactionAlreadyExecuted());
        state.usedPaymentHashes[transactionId] = true;

        // create or get existing Personal Account for the XRPL address
        IIPersonalAccount personalAccount = PersonalAccounts.getOrCreatePersonalAccount(_xrplAddress);

        // execute instruction
        Instructions.executeInstruction(
            instructionType,
            instructionCommand,
            paymentReference,
            personalAccount
        );

        // emit event
        emit InstructionExecuted(
            address(personalAccount),
            transactionId,
            paymentReference,
            _xrplAddress,
            instructionId
        );
    }

    /**
     * @inheritdoc IInstructionsFacet
     */
    function executeWithdrawal(
        string calldata _xrplAddress,
        uint256 _vaultId,
        uint256 _epoch
    )
        external
    {
        IIPersonalAccount personalAccount = PersonalAccounts.getOrCreatePersonalAccount(_xrplAddress);
        Vaults.VaultInfo memory vaultInfo = Vaults.getState().vaults[_vaultId];
        require(vaultInfo.vaultAddress != address(0), IVaultsFacet.InvalidVaultId(_vaultId));
        if (vaultInfo.vaultType == 1) {
            // Firelight vault
            Vault.claimWithdrawal(personalAccount, vaultInfo.vaultAddress, _epoch);
        } else if (vaultInfo.vaultType == 2) {
            // Upshift vault
            Vault.claim(personalAccount, vaultInfo.vaultAddress, _epoch);
        } else {
            revert IVaultsFacet.InvalidVaultType(vaultInfo.vaultType);
        }

        emit WithdrawalExecuted(
            address(personalAccount),
            vaultInfo.vaultAddress,
            _xrplAddress,
            _epoch
        );
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
        require(_value > 0, ValueZero());
    }
}
