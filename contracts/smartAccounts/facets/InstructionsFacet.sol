// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {CollateralReservationInfo} from "flare-periphery/src/flare/data/CollateralReservationInfo.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {PaymentProofs} from "../library/PaymentProofs.sol";
import {FXrp} from "../library/FXrp.sol";
import {Vault} from "../library/Vault.sol";
import {Vaults} from "../library/Vaults.sol";
import {AgentVaults} from "../library/AgentVaults.sol";
import {InstructionFees} from "../library/InstructionFees.sol";

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
 * @title MasterAccountController contract
 * @notice The contract controlling personal accounts (XRPL master controller)
 */
contract InstructionsFacet {

    struct State {
        /// @notice Indicates if payment instruction has already been executed.
        mapping(bytes32 transactionId => bool) usedPaymentHashes;
        /// @notice Mapping from collateral reservation ID to XRPL transaction ID - used for deposit after minting
        mapping(uint256 collateralReservationId => bytes32 transactionId) collateralReservationIdToTransactionId;
    }

    /**
     * @notice Initializer function for upgrading from MasterAccountControllerBase.
     * @param _executor The FAssets executor (mint and redeem).
     * @param _executorFee The executor fee (in wei).
     * @param _paymentProofValidityDurationSeconds The duration (in seconds) for which the payment proof is valid.
     * @param _defaultInstructionFee The default instruction fee in underlying asset's smallest unit (drops for XRP).
     * @param _personalAccountImplementation The PersonalAccount implementation address.
     */
    function initialize(
        address payable _executor,
        uint256 _executorFee,
        uint256 _paymentProofValidityDurationSeconds,
        uint256 _defaultInstructionFee,
        address _personalAccountImplementation
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        FXrp.setExecutor(_executor);
        FXrp.setExecutorFee(_executorFee);
        PaymentProofs.setPaymentProofValidityDurationSeconds(_paymentProofValidityDurationSeconds);
        InstructionFees.setDefaultInstructionFee(_defaultInstructionFee);
        // set the PA implementation that this controller (as beacon) will return
        PersonalAccounts.setPersonalAccountImplementation(_personalAccountImplementation);
    }

    /**
     * @inheritdoc IMasterAccountController
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
            IMasterAccountController.InvalidInstruction(instructionType, instructionCommand)
        );
        // check transaction id
        require(_transactionId != bytes32(0), IMasterAccountController.InvalidTransactionId());
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
        State storage state = getState();
        state.collateralReservationIdToTransactionId[_collateralReservationId] = _transactionId;
    }

    /**
     * @inheritdoc IMasterAccountController
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
            IMasterAccountController.InvalidInstruction(instructionType, instructionCommand)
        );
        uint256 instructionId = instructionType << 4 | instructionCommand;

        // check that crtId and txId match
        bytes32 transactionId = _proof.data.requestBody.transactionId;
        State storage state = getState();
        require(
            transactionId != bytes32(0) &&
            state.collateralReservationIdToTransactionId[_collateralReservationId] == transactionId,
            IMasterAccountController.UnknownCollateralReservationId()
        );

        // check if minting was successfully completed
        CollateralReservationInfo.Data memory reservationInfo =
            ContractRegistry.getAssetManagerFXRP().collateralReservationInfo(_collateralReservationId);
        require(
            reservationInfo.status == CollateralReservationInfo.Status.SUCCESSFUL,
            IMasterAccountController.MintingNotCompleted()
        );
        // no check of instruction fee here, as fee includes collateral reservation fee and has to be checked off-chain
        // verify payment proof
        PaymentProofs.verifyPayment(_proof, _xrplAddress);
        // check that minter and amount match
        IIPersonalAccount personalAccount = PersonalAccounts.getOrCreatePersonalAccount(_xrplAddress);
        require(address(personalAccount) == reservationInfo.minter, IMasterAccountController.InvalidMinter());
        uint256 lots = _getValue(paymentReference);
        uint256 amount = _lotsToAmount(lots);
        // could revert if lot size changes between minting and deposit, but very unlikely
        // user should call deposit in that case
        require(amount == reservationInfo.valueUBA, IMasterAccountController.InvalidAmount());
        // mark transaction as used
        require(!state.usedPaymentHashes[transactionId], IMasterAccountController.TransactionAlreadyExecuted());
        state.usedPaymentHashes[transactionId] = true;

        // execute deposit
        address vault = Vaults.getVaultAddress(paymentReference);
        Vault.deposit(personalAccount, vault, amount);

        // emit event
        emit IMasterAccountController.InstructionExecuted(
            address(personalAccount),
            paymentReference,
            transactionId,
            _xrplAddress,
            instructionId
        );
    }

    /**
     * @inheritdoc IMasterAccountController
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
            IMasterAccountController.InvalidPaymentAmount(instructionFee)
        );

        // verify payment proof
        PaymentProofs.verifyPayment(_proof, _xrplAddress);

        // mark transaction as used
        State storage state = getState();
        bytes32 transactionId = _proof.data.requestBody.transactionId;
        require(!state.usedPaymentHashes[transactionId], IMasterAccountController.TransactionAlreadyExecuted());
        state.usedPaymentHashes[transactionId] = true;

        // create or get existing Personal Account for the XRPL address
        IIPersonalAccount personalAccount = PersonalAccounts.getOrCreatePersonalAccount(_xrplAddress);

        // execute instruction
        _executeInstruction(
            instructionType,
            instructionCommand,
            paymentReference,
            personalAccount
        );

        // emit event
        emit IMasterAccountController.InstructionExecuted(
            address(personalAccount),
            transactionId,
            paymentReference,
            _xrplAddress,
            instructionId
        );
    }

    /**
     * @inheritdoc IMasterAccountController
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
        require(vaultInfo.vaultAddress != address(0), IMasterAccountController.InvalidVaultId(_vaultId));
        if (vaultInfo.vaultType == 1) {
            // Firelight vault
            Vault.claimWithdrawal(personalAccount, vaultInfo.vaultAddress, _epoch);
        } else if (vaultInfo.vaultType == 2) {
            // Upshift vault
            Vault.claim(personalAccount, vaultInfo.vaultAddress, _epoch);
        } else {
            revert IMasterAccountController.InvalidVaultType(vaultInfo.vaultType);
        }

        emit IMasterAccountController.WithdrawalExecuted(
            address(personalAccount),
            vaultInfo.vaultAddress,
            _xrplAddress,
            _epoch
        );
    }

    /////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////
    function _executeInstruction(
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
            revert IMasterAccountController.InvalidInstruction(_instructionType, _instructionCommand);
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

    function _getWalletId(bytes32 _paymentReference) internal pure returns (uint256) {
        // byte 01: wallet identifier
        return (uint256(_paymentReference) >> 240) & 0xFF;
    }

    function _getValue(bytes32 _paymentReference) internal pure returns (uint256 _value) {
        // bytes 02-11: uint80
        _value = (uint256(_paymentReference) >> 160) & ((uint256(1) << 80) - 1);
        require(_value > 0, IMasterAccountController.ValueZero());
    }

    function _getAddress(bytes32 _paymentReference) internal pure returns (address _address) {
        // bytes 12-31: address (20 bytes)
        _address = address(uint160(uint256(_paymentReference) & ((uint256(1) << 160) - 1)));
        require(_address != address(0), IMasterAccountController.AddressZero());
    }

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.Instructions.State");

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
