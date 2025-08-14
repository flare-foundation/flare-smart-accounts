// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {PersonalAccount} from "../xrpcw/implementation/PersonalAccount.sol";

/**
 * @title IMasterAccountController
 * @notice Interface for the MasterAccountController contract,
 which manages personal accounts and executes XRPL instructions.
 */
interface IMasterAccountController {

    event PersonalAccountImplementationSet(address newImplementation);
    event OperatorExecutionWindowSecondsSet(uint256 newWindowSeconds);
    event PersonalAccountCreated(string xrplOwner, address personalAccount);
    event ExecutorFeeSet(uint256 executorFee);
    event InstructionExecuted(
        address indexed personalAccount,
        string indexed xrplOwner,
        uint256 indexed instructionId,
        uint256 paymentReference
    );

    error InvalidDepositVault();
    error InvalidFxrp();
    error InvalidExecutor();
    error InvalidXrplProviderWallet();
    error InvalidOperatorAddress();
    error InvalidOperatorExecutionWindowSeconds();
    error InvalidPersonalAccountImplementation();
    error OnlyOperatorCanExecute();
    error InvalidTransactionProof();
    error InvalidReceivingAddressHash();
    error MismatchingSourceAndXrplAddr();
    error TransactionAlreadyExecuted();
    error InvalidInstructionId(uint256 instructionId);
    error InvalidExecutorFee();
    error AmountZero();
    error LotsZero();
    error InvalidAgentVaultAddress();

    /**
     * @notice Execute an XRPL instruction for a given Ripple account.
     * @param _proof Proof of XRPL transaction.
     * @param _rippleAccount The XRPL account requesting execution.
     */
    function executeTransaction(
        IPayment.Proof calldata _proof,
        string calldata _rippleAccount
    )
        external payable;

    /**
     * @notice Get the PersonalAccount contract for a given XRPL owner.
     * @param xrplOwner The XRPL address of the owner.
     * @return The PersonalAccount contract associated with the XRPL owner.
     */
    function getPersonalAccount(
        string calldata xrplOwner
    )
        external returns (PersonalAccount);
}