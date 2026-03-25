// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {CollateralReservationInfo} from "flare-periphery/src/flare/data/CollateralReservationInfo.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IIInstructionsFacet} from "../interface/IIInstructionsFacet.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {PaymentProofs} from "../library/PaymentProofs.sol";
import {FXrp} from "../library/FXrp.sol";
import {Vault} from "../library/Vault.sol";
import {Vaults} from "../library/Vaults.sol";
import {AgentVaults} from "../library/AgentVaults.sol";
import {InstructionFees} from "../library/InstructionFees.sol";
import {Instructions} from "../library/Instructions.sol";
import {UserOp} from "../library/UserOp.sol";
import {Pause} from "../library/Pause.sol";
import {PaymentReferenceParser} from "../library/PaymentReferenceParser.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title InstructionsFacet
 * @notice Facet for handling instructions.
 */
contract InstructionsFacet is IIInstructionsFacet, FacetBase {
    using SafeERC20 for IERC20;

    modifier notPaused {
        Pause.checkNotPaused();
        _;
    }

    /// @inheritdoc IInstructionsFacet
    function reserveCollateral(
        string calldata _xrplAddress,
        bytes32 _paymentReference,
        bytes32 _transactionId
    )
        external payable
        notPaused
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

    /// @inheritdoc IInstructionsFacet
    function executeDepositAfterMinting(
        uint256 _collateralReservationId,
        IPayment.Proof calldata _proof,
        string calldata _xrplAddress
    )
        external
        notPaused
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
        require(!state.usedTransactionIds[transactionId], TransactionAlreadyExecuted());
        state.usedTransactionIds[transactionId] = true;

        // execute deposit
        address vault = Vaults.getVaultAddress(paymentReference);
        Vault.deposit(personalAccount, instructionType, vault, amount); // instructionType == vaultType

        // emit event
        emit InstructionExecuted(
            address(personalAccount),
            transactionId,
            paymentReference,
            _xrplAddress,
            PaymentReferenceParser.getInstructionId(paymentReference)
        );
    }

    /// @inheritdoc IInstructionsFacet
    function executeInstruction(
        IPayment.Proof calldata _proof,
        string calldata _xrplAddress
    )
        external payable
        notPaused
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
        bytes32 transactionId = _proof.data.requestBody.transactionId;
        Instructions.State storage state = Instructions.getState();
        require(!state.usedTransactionIds[transactionId], TransactionAlreadyExecuted());
        state.usedTransactionIds[transactionId] = true;

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

    /// @inheritdoc IInstructionsFacet
    function mintedFAssets(
        bytes32 _transactionId,
        string calldata _sourceAddress,
        uint256 _amount,
        uint256 /* _underlyingTimestamp */,
        bytes calldata _memoData,
        address payable _executor
    )
        external payable
        notPaused
    {
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        require(msg.sender == address(assetManager), OnlyAssetManager());
        // get or create PA
        IIPersonalAccount personalAccount = PersonalAccounts.getOrCreatePersonalAccount(_sourceAddress);

        // determine executor fee, validate memo, check PA executor
        uint256 executorFee;
        if (_memoData.length > 0) {
            require(_memoData.length >= 6, InvalidMemoData());
            uint8 instructionId = uint8(_memoData[0]);
            // check PA executor (0xD0/0xD1 bypass to prevent lock-out)
            if (instructionId != 0xD0 && instructionId != 0xD1) {
                address paExecutor = UserOp.getExecutor(address(personalAccount));
                if (paExecutor != address(0)) {
                    require(_executor == paExecutor, WrongExecutor(paExecutor, _executor));
                }
            }
            executorFee = uint32(bytes4(_memoData[2:6]));
            if (instructionId == 0xFF) {
                uint32 storedFee = UserOp.getReplacementFee(_transactionId);
                if (storedFee > 0) {
                    executorFee = storedFee - 1;
                }
            }
        } else {
            // check PA executor for plain direct mint (no memo)
            {
                address paExecutor = UserOp.getExecutor(address(personalAccount));
                if (paExecutor != address(0)) {
                    require(_executor == paExecutor, WrongExecutor(paExecutor, _executor));
                }
            }
            // no memo — only direct mint, use default executor fee
            // TODO: uncomment when getDirectMintingExecutorFeeUBA is added to IAssetManager
            // executorFee = assetManager.getDirectMintingExecutorFeeUBA();
        }

        {
            require(_amount >= executorFee, InsufficientAmountForFee(_amount, executorFee));

            // replay protection
            Instructions.State storage state = Instructions.getState();
            require(!state.usedTransactionIds[_transactionId], TransactionAlreadyExecuted());
            state.usedTransactionIds[_transactionId] = true;

            // transfer fAssets
            IERC20 fAsset = assetManager.fAsset();
            if (executorFee > 0) {
                fAsset.safeTransfer(_executor, executorFee);
            }
            uint256 remaining = _amount - executorFee;
            if (remaining > 0) {
                fAsset.safeTransfer(address(personalAccount), remaining);
            }

            emit DirectMintingExecuted(
                address(personalAccount),
                _transactionId,
                _sourceAddress,
                _amount,
                executorFee,
                _executor
            );
        }

        // if memo present, execute AA instruction
        if (_memoData.length > 0) {
            uint8 instructionId = uint8(_memoData[0]);
            if (instructionId == 0xFF) {
                UserOp.State storage userOpState = UserOp.getState();
                if (userOpState.ignoreMemo[_transactionId]) {
                    // only mint fAssets, do not execute AA instruction from memo
                    userOpState.ignoreMemo[_transactionId] = false;
                } else {
                    UserOp.execute(_memoData, address(personalAccount));
                }
            } else if (instructionId == 0xE0) {
                UserOp.setIgnoreMemo(_memoData, address(personalAccount));
            } else if (instructionId == 0xE1) {
                UserOp.setNonce(_memoData, address(personalAccount));
            } else if (instructionId == 0xE2) {
                UserOp.setReplacementFee(_memoData, address(personalAccount));
            } else if (instructionId == 0xD0) {
                UserOp.setExecutor(_memoData, address(personalAccount));
            } else if (instructionId == 0xD1) {
                UserOp.removeExecutor(_memoData, address(personalAccount));
            } else {
                revert InvalidInstructionId(instructionId);
            }
        }
    }

    /// @inheritdoc IInstructionsFacet
    function isTransactionIdUsed(
        bytes32 _transactionId
    )
        external view
        returns (bool)
    {
        Instructions.State storage state = Instructions.getState();
        return state.usedTransactionIds[_transactionId];
    }

    /// @inheritdoc IInstructionsFacet
    function getTransactionIdForCollateralReservation(
        uint256 _collateralReservationId
    )
        external view
        returns (bytes32)
    {
        Instructions.State storage state = Instructions.getState();
        return state.collateralReservationIdToTransactionId[_collateralReservationId];
    }

    /// @inheritdoc IInstructionsFacet
    function getExecutor(
        address _personalAccount
    )
        external view
        returns (address)
    {
        return UserOp.getExecutor(_personalAccount);
    }

    /// @inheritdoc IInstructionsFacet
    function getNonce(
        address _personalAccount
    )
        external view
        returns (uint256)
    {
        return UserOp.getNonce(_personalAccount);
    }
}
