// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {PersonalAccount} from "../xrpcw/implementation/PersonalAccount.sol";

/**
 * @title IMasterAccountController
 * @notice Interface for the MasterAccountController contract,
 which manages personal accounts and executes XRPL instructions.
 */
interface IMasterAccountController {
    struct CustomInstruction {
        address targetContract;
        uint256 value;
        bytes data;
    }

    event PersonalAccountImplementationSet(address newImplementation);
    event OperatorExecutionWindowSecondsSet(uint256 newWindowSeconds);
    event PersonalAccountCreated(string xrplOwner, address personalAccount);
    event ExecutorFeeSet(uint256 executorFee);
    event InstructionExecuted(
        address indexed personalAccount,
        string indexed xrplOwner,
        uint256 indexed instructionId,
        uint256 paymentReference,
        bytes32 transactionId
    );
    event CustomInstructionRegistered(uint256 callHash);

    error InvalidDepositVault();
    error InvalidExecutor();
    error InvalidXrplProviderWallet();
    error InvalidOperatorAddress();
    error InvalidOperatorExecutionWindowSeconds();
    error InvalidPersonalAccountImplementation();
    error OnlyOperatorCanExecute();
    error InvalidTransactionProof();
    error InvalidReceivingAddressHash();
    error InvalidTransactionStatus();
    error MismatchingSourceAndXrplAddr();
    error TransactionAlreadyExecuted();
    error InvalidInstructionId(uint256 instructionId);
    error InvalidExecutorFee();
    error AmountZero();
    error LotsZero();
    error InvalidAgentVaultAddress();
    error RewardEpochIdZero();

    /**
     * @notice Execute an XRPL instruction for a given XRPL address.
     * @param _proof Proof of XRPL transaction.
     * @param _xrplAddress The XRPL address requesting execution.
     */
    function executeTransaction(
        IPayment.Proof calldata _proof,
        string calldata _xrplAddress
    ) external payable;

    /**
     * @notice Get the PersonalAccount contract for a given XRPL owner.
     * @param _xrplOwner The XRPL address of the owner.
     * @return The PersonalAccount contract associated with the XRPL owner.
     */
    function getPersonalAccount(
        string calldata _xrplOwner
    ) external returns (PersonalAccount);

    /**
     * @notice  Returns the first 31 bytes of the keccak256 hash of the custom instruction.
     * @param   _customInstruction  Custom instruction.
     * @return  31 bytes of the keccak256 hash of the custom instruction.
     */
    function encodeCustomInstruction(
        CustomInstruction[] memory _customInstruction
    ) external returns (uint256);

    /**
     * @notice  Registers a custom instruction.
     * @param   _customInstruction  Custom instruction.
     * @return  31 bytes of the keccak256 hash of the custom instruction.
     * The custom instruction is stored in a mapping from the first 31 bytes of the keccak256 hash of the custom
     * instruction to the custom instruction.
     */
    function registerCustomInstruction(
        CustomInstruction[] memory _customInstruction
    ) external returns (uint256);
}
