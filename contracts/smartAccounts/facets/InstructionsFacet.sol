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
import {PaymentReferenceParser} from "../library/PaymentReferenceParser.sol";

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
        uint256 instructionType = PaymentReferenceParser.getInstructionType(_paymentReference);
        uint256 instructionCommand = PaymentReferenceParser.getInstructionCommand(_paymentReference);
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
        uint256 lots = PaymentReferenceParser.getValue(_paymentReference);
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
        uint256 instructionType = PaymentReferenceParser.getInstructionType(paymentReference);
        uint256 instructionCommand = PaymentReferenceParser.getInstructionCommand(paymentReference);
        require(
            0 < instructionType && instructionType <= 2 && instructionCommand == 0,
            InvalidInstruction(instructionType, instructionCommand)
        );

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
        uint256 amount = FXrp.lotsToAmount(PaymentReferenceParser.getValue(paymentReference)); // value = lots
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
            PaymentReferenceParser.getInstructionId(paymentReference)
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
        uint256 instructionType = PaymentReferenceParser.getInstructionType(paymentReference);
        uint256 instructionCommand = PaymentReferenceParser.getInstructionCommand(paymentReference);
        uint256 instructionId = PaymentReferenceParser.getInstructionId(paymentReference);
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
}
