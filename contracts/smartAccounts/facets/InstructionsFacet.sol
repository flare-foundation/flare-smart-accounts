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
import {MemoInstructions} from "../library/MemoInstructions.sol";
import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";
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
        Vault.deposit(personalAccount, IVaultsFacet.VaultType(instructionType), vault, amount);

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
        address personalAccount = address(PersonalAccounts.getOrCreatePersonalAccount(_sourceAddress));

        // check ignoreMemo first — before any memo validation
        // allows recovery from malformed memos (length < 6, bad instruction ID, malformed UserOp, ...)
        bool memoIgnored;
        if (_memoData.length > 0) {
            MemoInstructions.State storage userOpState = MemoInstructions.getState();
            if (userOpState.ignoreMemo[personalAccount][_transactionId]) {
                userOpState.ignoreMemo[personalAccount][_transactionId] = false;
                memoIgnored = true;
            }
        }

        // check PA executor (0xD0/0xD1 bypass to prevent lock-out)
        bool bypassesExecutorCheck = !memoIgnored && _memoData.length > 0 &&
            (uint8(_memoData[0]) == 0xD0 || uint8(_memoData[0]) == 0xD1);
        if (!bypassesExecutorCheck) {
            address paExecutor = MemoInstructions.getExecutor(personalAccount);
            if (paExecutor != address(0)) {
                require(_executor == paExecutor, WrongExecutor(paExecutor, _executor));
            }
        }

        // determine executor fee
        uint256 executorFee;
        if (!memoIgnored && _memoData.length > 0) {
            require(_memoData.length >= 10, InvalidMemoData());
            executorFee = uint64(bytes8(_memoData[2:10]));
        } else {
            // no memo or memo ignored — use default fee
            executorFee = assetManager.getDirectMintingExecutorFeeUBA();
        }
        // check fee override (applies to all instruction IDs)
        uint64 feeOverride = MemoInstructions.getReplacementFee(personalAccount, _transactionId);
        if (feeOverride > 0) {
            executorFee = feeOverride - 1;
        }

        _mintFAssets(
            personalAccount, _transactionId,
            _sourceAddress, _amount, _executor, executorFee
        );

        // if memo present and not ignored, execute memo instruction
        if (!memoIgnored && _memoData.length > 0) {
            uint8 instructionId = uint8(_memoData[0]);
            if (instructionId == 0xFF) {
                MemoInstructions.execute(_memoData, personalAccount);
            } else if (instructionId == 0xE0) {
                MemoInstructions.setIgnoreMemo(_memoData, personalAccount);
            } else if (instructionId == 0xE1) {
                MemoInstructions.setNonce(_memoData, personalAccount);
            } else if (instructionId == 0xE2) {
                MemoInstructions.setReplacementFee(_memoData, personalAccount);
            } else if (instructionId == 0xD0) {
                MemoInstructions.setExecutor(_memoData, personalAccount);
            } else if (instructionId == 0xD1) {
                MemoInstructions.removeExecutor(_memoData, personalAccount);
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
        return MemoInstructions.getExecutor(_personalAccount);
    }

    /// @inheritdoc IInstructionsFacet
    function getNonce(
        address _personalAccount
    )
        external view
        returns (uint256)
    {
        return MemoInstructions.getNonce(_personalAccount);
    }

    function _mintFAssets(
        address _personalAccount,
        bytes32 _transactionId,
        string calldata _sourceAddress,
        uint256 _amount,
        address payable _executor,
        uint256 _executorFee
    )
        private
    {
        require(_amount >= _executorFee, InsufficientAmountForFee(_amount, _executorFee));

        // replay protection
        Instructions.State storage state = Instructions.getState();
        require(!state.usedTransactionIds[_transactionId], TransactionAlreadyExecuted());
        state.usedTransactionIds[_transactionId] = true;

        // transfer fAssets
        IERC20 fAsset = ContractRegistry.getAssetManagerFXRP().fAsset();
        if (_executorFee > 0) {
            fAsset.safeTransfer(_executor, _executorFee);
        }
        uint256 remaining = _amount - _executorFee;
        if (remaining > 0) {
            fAsset.safeTransfer(_personalAccount, remaining);
        }

        emit DirectMintingExecuted(
            _personalAccount,
            _transactionId,
            _sourceAddress,
            _amount,
            _executorFee,
            _executor
        );
    }

}
