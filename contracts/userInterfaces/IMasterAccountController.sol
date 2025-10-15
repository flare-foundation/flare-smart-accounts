// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IPersonalAccount} from "./IPersonalAccount.sol";

/**
 * @title IMasterAccountController
 * @notice Interface for the MasterAccountController contract,
 which manages personal accounts and executes XRPL instructions.
 */
interface IMasterAccountController {

    event PersonalAccountImplementationSet(address newImplementation);
    event PersonalAccountCreated(string xrplOwner, address personalAccount);
    event ExecutorSet(address executor);
    event ExecutorFeeSet(uint256 executorFee);
    event PaymentProofValidityDurationSecondsSet(uint256 durationSeconds);
    event DefaultInstructionFeeSet(uint256 defaultInstructionFee);
    event InstructionFeeSet(uint256 indexed instructionId, uint256 instructionFee);
    event InstructionFeeRemoved(uint256 indexed instructionId);
    event XrplProviderWalletAdded(string xrplProviderWallet);
    event XrplProviderWalletRemoved(string xrplProviderWallet);
    event VaultAdded(uint256 indexed vaultId, address indexed vaultAddress);
    event AgentVaultAdded(uint256 indexed agentVaultId, address indexed agentVaultAddress);
    event AgentVaultRemoved(uint256 indexed agentVaultId, address indexed agentVaultAddress);
    event CollateralReserved(
        address indexed personalAccount,
        string indexed xrplOwner,
        uint256 indexed collateralReservationId,
        uint256 lots,
        address agentVault,
        bytes32 transactionId
    );
    event InstructionExecuted(
        address indexed personalAccount,
        string indexed xrplOwner,
        uint256 indexed instructionId,
        bytes32 paymentReference,
        bytes32 transactionId
    );

    error InvalidExecutor();
    error InvalidExecutorFee();
    error InvalidPersonalAccountImplementation();
    error InvalidTransactionId();
    error InvalidTransactionProof();
    error InvalidReceivingAddressHash();
    error InvalidTransactionStatus();
    error MismatchingSourceAndXrplAddr();
    error InvalidPaymentAmount(uint256 requiredAmount);
    error TransactionAlreadyExecuted();
    error InvalidInstructionId(uint256 instructionId);
    error LengthsMismatch();
    error AgentVaultIdAlreadyUsed(uint256 agentVaultId);
    error InvalidAgentVault(uint256 agentVaultId);
    error AgentNotAvailable(address agentVault);
    error VaultIdAlreadyUsed(uint256 vaultId);
    error InvalidVault(uint256 vaultId);
    error ValueZero();
    error UnknownCollateralReservationId();
    error MintingNotCompleted();
    error InvalidAmount();
    error InvalidMinter();
    error InvalidInstructionFee(uint256 instructionId);
    error PersonalAccountNotSuccessfullyDeployed(address personalAccountAddress);
    error InvalidPaymentProofValidityDuration();
    error PaymentProofExpired();
    error InvalidXrplProviderWallet(string xrplProviderWallet);
    error XrplProviderWalletAlreadyExists(string xrplProviderWallet);

    /**
     * @notice Reserve collateral for minting operation.
     * @param _xrplAddress The XRPL address requesting the collateral reservation.
     * @param _paymentReference The payment reference associated with the request.
     * @param _transactionId The unique transaction ID for tracking.
     * @return _collateralReservationId The ID of the collateral reservation.
     */
    function reserveCollateral(
        string calldata _xrplAddress,
        bytes32 _paymentReference,
        bytes32 _transactionId
    )
        external payable
        returns (uint256 _collateralReservationId);

    /**
     * @notice Execute deposit after successful minting for _collateralReservationId.
     * @param _collateralReservationId The ID of the collateral reservation request returned
       by `reserveCollateral` call.
     * @param _proof Proof of XRPL transaction.
     * @param _xrplAddress The XRPL address requesting execution.
     */
    function executeDepositAfterMinting(
        uint256 _collateralReservationId,
        IPayment.Proof calldata _proof,
        string calldata _xrplAddress
    )
        external;

    /**
     * @notice Execute an XRPL instruction for a given XRPL address.
     * @param _proof Proof of XRPL transaction.
     * @param _xrplAddress The XRPL address requesting execution.
     */
    function executeInstruction(
        IPayment.Proof calldata _proof,
        string calldata _xrplAddress
    )
        external payable;

    /**
     * @notice Create or update PersonalAccount for a given XRPL owner.
     * @param _xrplOwner The XRPL address of the owner.
     * @return The PersonalAccount contract associated with the XRPL owner.
     */
    function createOrUpdatePersonalAccount(
        string calldata _xrplOwner
    )
        external
        returns (IPersonalAccount);

    /**
     * @notice Get the PersonalAccount contract for a given XRPL owner.
     * @param _xrplOwner The XRPL address of the owner.
     * @return The PersonalAccount contract associated with the XRPL owner or address(0) if none exists.
     */
    function getPersonalAccount(
        string calldata _xrplOwner
    )
        external view
        returns (IPersonalAccount);


    /**
     * @notice Computes the address of a PersonalAccount for a given XRPL owner.
     * @param _xrplOwner The XRPL address.
     * @return The predicted address of the PersonalAccount.
     */
    function computePersonalAccountAddress(
        string calldata _xrplOwner
    )
        external view
        returns (address);

    /**
     * @notice Returns the instruction fee for a given instruction ID.
     * @param _instructionId The ID of the instruction.
     * @return The instruction fee in in underlying asset's smallest unit (e.g., drops for XRP).
     */
    function getInstructionFee(
        uint256 _instructionId
    )
        external view
        returns (uint256);

    /**
     * Returns the list of registered XRPL provider wallets.
     * @return The list of registered XRPL provider wallets.
     */
    function getXrplProviderWallets()
        external view
        returns (string[] memory);

    /**
     * Returns the list of registered agent vault IDs and their corresponding addresses.
     * @return _agentVaultIds The list of registered agent vault IDs.
     * @return _agentVaultAddresses The list of registered agent vault addresses.
     */
    function getAgentVaults()
        external view
        returns (uint256[] memory _agentVaultIds, address[] memory _agentVaultAddresses);

    /**
     * Returns the list of registered vault IDs and their corresponding addresses.
     * @return _vaultIds The list of registered vault IDs.
     * @return _vaultAddresses The list of registered vault addresses.
     */
    function getVaults()
        external view
        returns (uint256[] memory _vaultIds, address[] memory _vaultAddresses);
}
