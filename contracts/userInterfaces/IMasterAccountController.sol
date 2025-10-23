// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IPersonalAccount} from "./IPersonalAccount.sol";

/**
 * @title IMasterAccountController
 * @notice Interface for the MasterAccountController contract,
 * which manages personal accounts and executes XRPL instructions.
 */
interface IMasterAccountController {
    /**
     * @notice Emitted when the PersonalAccount implementation address is set.
     * @param newImplementation The new implementation address.
     */
    event PersonalAccountImplementationSet(
        address newImplementation
    );

    /**
     * @notice Emitted when a new PersonalAccount is created.
     * @param xrplOwner The XRPL owner address.
     * @param personalAccount The deployed PersonalAccount contract address.
     */
    event PersonalAccountCreated(
        string xrplOwner,
        address personalAccount
    );

    /**
     * @notice Emitted when the executor address is set.
     * @param executor The new executor address.
     */
    event ExecutorSet(
        address executor
    );

    /**
     * @notice Emitted when the executor fee is set.
     * @param executorFee The new executor fee.
     */
    event ExecutorFeeSet(
        uint256 executorFee
    );

    /**
     * @notice Emitted when the payment proof validity duration is set.
     * @param durationSeconds The new duration in seconds.
     */
    event PaymentProofValidityDurationSecondsSet(
        uint256 durationSeconds
    );

    /**
     * @notice Emitted when the default instruction fee is set.
     * @param defaultInstructionFee The new default instruction fee.
     */
    event DefaultInstructionFeeSet(
        uint256 defaultInstructionFee
    );

    /**
     * @notice Emitted when an instruction-specific fee is set.
     * @param instructionId The instruction ID.
     * @param instructionFee The fee for the instruction.
     */
    event InstructionFeeSet(
        uint256 indexed instructionId,
        uint256 instructionFee
    );

    /**
     * @notice Emitted when an instruction-specific fee is removed.
     * @param instructionId The instruction ID.
     */
    event InstructionFeeRemoved(
        uint256 indexed instructionId
    );

    /**
     * @notice Emitted when an XRPL provider wallet is added.
     * @param xrplProviderWallet The XRPL provider wallet address.
     */
    event XrplProviderWalletAdded(
        string xrplProviderWallet
    );

    /**
     * @notice Emitted when an XRPL provider wallet is removed.
     * @param xrplProviderWallet The XRPL provider wallet address.
     */
    event XrplProviderWalletRemoved(
        string xrplProviderWallet
    );

    /**
     * @notice Emitted when a vault is added.
     * @param vaultId The vault ID.
     * @param vaultAddress The vault address.
     */
    event VaultAdded(
        uint256 indexed vaultId,
        address indexed vaultAddress
    );

    /**
     * @notice Emitted when an agent vault is added.
     * @param agentVaultId The agent vault ID.
     * @param agentVaultAddress The agent vault address.
     */
    event AgentVaultAdded(
        uint256 indexed agentVaultId,
        address indexed agentVaultAddress
    );

    /**
     * @notice Emitted when an agent vault is removed.
     * @param agentVaultId The agent vault ID.
     * @param agentVaultAddress The agent vault address.
     */
    event AgentVaultRemoved(
        uint256 indexed agentVaultId,
        address indexed agentVaultAddress
    );

    /**
     * @notice Emitted when collateral is reserved for minting.
     * @param personalAccount The personal account address.
     * @param xrplOwner The XRPL owner address.
     * @param collateralReservationId The collateral reservation ID.
     * @param walletId The wallet ID.
     * @param agentVault The agent vault address.
     * @param lots The number of lots reserved.
     * @param transactionId The transaction ID.
     */
    event CollateralReserved(
        address indexed personalAccount,
        string indexed xrplOwner,
        uint256 indexed collateralReservationId,
        uint256 walletId,
        address agentVault,
        uint256 lots,
        bytes32 transactionId
    );

    /**
     * @notice Emitted when an instruction is executed.
     * @param personalAccount The personal account address.
     * @param xrplOwner The XRPL owner address.
     * @param instructionId The instruction ID.
     * @param paymentReference The payment reference.
     * @param transactionId The transaction ID.
     */
    event InstructionExecuted(
        address indexed personalAccount,
        string indexed xrplOwner,
        uint256 indexed instructionId,
        bytes32 paymentReference,
        bytes32 transactionId
    );

    /**
     * @notice Reverts if the executor address is invalid.
     */
    error InvalidExecutor();

    /**
     * @notice Reverts if the executor fee is invalid.
     */
    error InvalidExecutorFee();

    /**
     * @notice Reverts if the personal account implementation address is invalid.
     */
    error InvalidPersonalAccountImplementation();

    /**
     * @notice Reverts if the transaction ID is invalid.
     */
    error InvalidTransactionId();

    /**
     * @notice Reverts if the transaction proof is invalid.
     */
    error InvalidTransactionProof();

    /**
     * @notice Reverts if the receiving address hash is invalid.
     */
    error InvalidReceivingAddressHash();

    /**
     * @notice Reverts if the transaction status is invalid.
     */
    error InvalidTransactionStatus();

    /**
     * @notice Reverts if the source address and XRPL address do not match.
     */
    error MismatchingSourceAndXrplAddr();

    /**
     * @notice Reverts if the payment amount is invalid.
     * @param requiredAmount The required payment amount.
     */
    error InvalidPaymentAmount(
        uint256 requiredAmount
    );

    /**
     * @notice Reverts if the transaction has already been executed.
     */
    error TransactionAlreadyExecuted();

    /**
     * @notice Reverts if the instruction ID is invalid.
     * @param instructionId The invalid instruction ID.
     */
    error InvalidInstructionId(
        uint256 instructionId
    );

    /**
     * @notice Reverts if array lengths do not match.
     */
    error LengthsMismatch();

    /**
     * @notice Reverts if the agent vault ID is already used.
     * @param agentVaultId The agent vault ID.
     */
    error AgentVaultIdAlreadyUsed(
        uint256 agentVaultId
    );

    /**
     * @notice Reverts if the agent vault is invalid.
     * @param agentVaultId The agent vault ID.
     */
    error InvalidAgentVault(
        uint256 agentVaultId
    );

    /**
     * @notice Reverts if the agent is not available.
     * @param agentVault The agent vault address.
     */
    error AgentNotAvailable(
        address agentVault
    );

    /**
     * @notice Reverts if the vault ID is already used.
     * @param vaultId The vault ID.
     */
    error VaultIdAlreadyUsed(
        uint256 vaultId
    );

    /**
     * @notice Reverts if the vault is invalid.
     * @param vaultId The vault ID.
     */
    error InvalidVault(
        uint256 vaultId
    );

    /**
     * @notice Reverts if the value is zero.
     */
    error ValueZero();

    /**
     * @notice Reverts if the collateral reservation ID is unknown.
     */
    error UnknownCollateralReservationId();

    /**
     * @notice Reverts if minting is not completed.
     */
    error MintingNotCompleted();

    /**
     * @notice Reverts if the amount is invalid.
     */
    error InvalidAmount();

    /**
     * @notice Reverts if the minter is invalid.
     */
    error InvalidMinter();

    /**
     * @notice Reverts if the instruction fee is invalid.
     * @param instructionId The instruction ID.
     */
    error InvalidInstructionFee(
        uint256 instructionId
    );

    /**
     * @notice Reverts if the personal account was not successfully deployed.
     * @param personalAccountAddress The address of the personal account.
     */
    error PersonalAccountNotSuccessfullyDeployed(
        address personalAccountAddress
    );

    /**
     * @notice Reverts if the payment proof validity duration is invalid.
     */
    error InvalidPaymentProofValidityDuration();

    /**
     * @notice Reverts if the payment proof has expired.
     */
    error PaymentProofExpired();

    /**
     * @notice Reverts if the XRPL provider wallet is invalid.
     * @param xrplProviderWallet The XRPL provider wallet address.
     */
    error InvalidXrplProviderWallet(
        string xrplProviderWallet
    );

    /**
     * @notice Reverts if the XRPL provider wallet already exists.
     * @param xrplProviderWallet The XRPL provider wallet address.
     */
    error XrplProviderWalletAlreadyExists(
        string xrplProviderWallet
    );

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
