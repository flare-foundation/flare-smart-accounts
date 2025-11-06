// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IPayment} from "flare-periphery/src/flare/IPayment.sol";

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
     * @param personalAccount The deployed PersonalAccount contract address.
     * @param xrplOwner The XRPL owner address.
     */
    event PersonalAccountCreated(
        address indexed personalAccount,
        string xrplOwner
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
     * @notice Emitted when a vault is added.
     * @param vaultId The vault ID.
     * @param vaultAddress The vault address.
     * @param vaultType The vault type (e.g., 1 = Firelight, 2 = Upshift).
     */
    event VaultAdded(
        uint256 indexed vaultId,
        address indexed vaultAddress,
        uint8 indexed vaultType
    );

    /**
     * @notice Emitted when swap parameters are set.
     * @param uniswapV3Router The Uniswap V3 router address.
     * @param usdt0 USDT0 token address.
     * @param wNatUsdt0PoolFeeTierPPM The WNAT/USDT0 pool fee tier (in PPM - supported values: 100, 500, 3000, 10000).
     * @param usdt0FXrpPoolFeeTierPPM The USDT0/FXRP pool fee tier (in PPM - supported values: 100, 500, 3000, 10000).
     * @param maxSlippagePPM The maximum slippage allowed for swaps (in PPM).
     */
    event SwapParamsSet(
        address uniswapV3Router,
        address usdt0,
        uint24 wNatUsdt0PoolFeeTierPPM,
        uint24 usdt0FXrpPoolFeeTierPPM,
        uint24 maxSlippagePPM
    );

    /**
     * @notice Emitted when collateral is reserved for minting.
     * @param personalAccount The personal account address.
     * @param transactionId The transaction ID.
     * @param paymentReference The payment reference.
     * @param xrplOwner The XRPL owner address.
     * @param collateralReservationId The collateral reservation ID.
     * @param agentVault The agent vault address.
     * @param lots The number of lots reserved.
     * @param executor The executor address.
     * @param executorFee The fee paid to the executor.
     */
    event CollateralReserved(
        address indexed personalAccount,
        bytes32 indexed transactionId,
        bytes32 indexed paymentReference,
        string xrplOwner,
        uint256 collateralReservationId,
        address agentVault,
        uint256 lots,
        address executor,
        uint256 executorFee
    );

    /**
     * @notice Emitted when an instruction is executed.
     * @param personalAccount The personal account address.
     * @param transactionId The transaction ID.
     * @param paymentReference The payment reference.
     * @param xrplOwner The XRPL owner address.
     * @param instructionId The instruction ID.
     */
    event InstructionExecuted(
        address indexed personalAccount,
        bytes32 indexed transactionId,
        bytes32 indexed paymentReference,
        string xrplOwner,
        uint256 instructionId
    );

    /**
     * @notice Emitted when a FXRP redeem operation is performed.
     * @param personalAccount The personal account address.
     * @param lots The number of lots redeemed.
     * @param amount The amount redeemed.
     * @param executor The executor address.
     * @param executorFee The fee paid to the executor.
     */
    event FXrpRedeemed(
        address indexed personalAccount,
        uint256 lots,
        uint256 amount,
        address executor,
        uint256 executorFee
    );

    /**
     * @notice Emitted when a transfer of FXRP is made.
     * @param personalAccount The personal account address.
     * @param to The recipient address.
     * @param amount The amount of FXRP transferred.
     */
    event FXrpTransferred(
        address indexed personalAccount,
        address to,
        uint256 amount
    );

    /**
     * @notice Emitted when a token approval is made for a vault.
     * @param personalAccount The personal account address.
     * @param fxrp The FXRP token address.
     * @param vault The vault address.
     * @param amount The approved amount.
     */
    event Approved(
        address indexed personalAccount,
        address fxrp,
        address vault,
        uint256 amount
    );

    /**
     * @notice Emitted when a deposit is made to a vault.
     * @param personalAccount The personal account address.
     * @param vault The vault address.
     * @param amount The amount deposited.
     * @param shares The number of shares received.
     */
    event Deposited(
        address indexed personalAccount,
        address indexed vault,
        uint256 amount,
        uint256 shares
    );

    /**
     * @notice Emitted when a redeem is made from a vault.
     * @param personalAccount The personal account address.
     * @param vault The vault address.
     * @param amount The amount redeemed.
     * @param shares The number of shares burned.
     */
    event Redeemed(
        address indexed personalAccount,
        address indexed vault,
        uint256 amount,
        uint256 shares
    );

    /**
     * @notice Emitted when a withdrawal claim is made.
     * @param personalAccount The personal account address.
     * @param vault The vault address.
     * @param period The period for which the claim is made.
     * @param amount The amount claimed.
     */
    event WithdrawalClaimed(
        address indexed personalAccount,
        address indexed vault,
        uint256 period,
        uint256 amount
    );

    /**
     * @notice Emitted when a redeem request is made.
     * @param personalAccount The personal account address.
     * @param vault The vault address.
     * @param shares The number of shares to redeem.
     * @param amount The amount to redeem.
     * @param claimableEpoch The epoch when the claim becomes available.
     */
    event RedeemRequested(
        address indexed personalAccount,
        address indexed vault,
        uint256 shares,
        uint256 amount,
        uint256 claimableEpoch
    );

    /**
     * @notice Emitted when a claim is made for a specific date.
     * @param personalAccount The personal account address.
     * @param vault The vault address.
     * @param year The year of the claim.
     * @param month The month of the claim.
     * @param day The day of the claim.
     * @param shares The number of shares claimed.
     * @param amount The amount claimed.
     */
    event Claimed(
        address indexed personalAccount,
        address indexed vault,
        uint256 year,
        uint256 month,
        uint256 day,
        uint256 shares,
        uint256 amount
    );

    /**
     * @notice Emitted when a token swap is executed.
     * @param personalAccount The personal account address.
     * @param xrplOwner The XRPL owner address.
     * @param tokenIn The input token address.
     * @param tokenOut The output token address.
     * @param amountIn The amount of input tokens.
     * @param amountOut The amount of output tokens received.
     */
    event SwapExecuted(
        address indexed personalAccount,
        string xrplOwner,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /**
     * @notice Emitted when a withdrawal is executed.
     * @param personalAccount The personal account address.
     * @param xrplOwner The XRPL owner address.
     * @param vault The vault address.
     * @param epoch The epoch representing the withdrawal period or date.
     */
    event WithdrawalExecuted(
        address indexed personalAccount,
        string xrplOwner,
        address indexed vault,
        uint256 epoch
    );

    /**
     * @notice Reverts if the Uniswap V3 router address is invalid.
     */
    error InvalidUniswapV3Router();

    /**
     * @notice Reverts if the pool fee tier in PPM is invalid (allowed values: 100, 500, 3000, 10000).
     */
    error InvalidPoolFeeTierPPM();

    /**
     * @notice Reverts if the USDT0 token address is invalid.
     */
    error InvalidUsdt0();

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
     * @notice Reverts if the instruction is invalid.
     * @param instructionType The invalid instruction type.
     * @param instructionCommand The invalid instruction command.
     */
    error InvalidInstruction(
        uint256 instructionType,
        uint256 instructionCommand
    );

    /**
     * @notice Reverts if the instruction type is invalid.
     * @param instructionType The invalid instruction type.
     */
    error InvalidInstructionType(
        uint256 instructionType
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
     * @notice Reverts if the vault ID is invalid.
     * @param vaultId The vault ID.
     */
    error InvalidVaultId(
        uint256 vaultId
    );

    /**
     * @notice Reverts if the vault type is invalid.
     * @param vaultType The vault type.
     */
    error InvalidVaultType(
        uint8 vaultType
    );

    /**
     * @notice Reverts if the value is zero.
     */
    error ValueZero();

    /**
     * @notice Reverts if the address is zero.
     */
    error AddressZero();

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
     * @notice Reverts if there are no XRPL provider wallets.
     */
    error NoXrplProviderWallets();

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
     * @notice Execute withdrawal from a vault for a given XRPL address.
     * @param _xrplAddress The XRPL address requesting the withdrawal.
     * @param _vaultId The ID of the vault from which to withdraw.
     * @param _epoch The epoch representing the withdrawal period or date.
     */
    function executeWithdrawal(
        string calldata _xrplAddress,
        uint256 _vaultId,
        uint256 _epoch
    )
        external;

    /**
     * @notice Get the PersonalAccount contract for a given XRPL owner.
     * @param _xrplOwner The XRPL address of the owner.
     * @return The PersonalAccount contract address associated with the XRPL owner
     * or the computed address if not yet deployed.
     */
    function getPersonalAccount(
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
     * Returns the list of registered vault IDs, their corresponding addresses and types.
     * @return _vaultIds The list of registered vault IDs.
     * @return _vaultAddresses The list of vault addresses corresponding to the vault IDs.
     * @return _vaultTypes The list of vault types corresponding to the vault IDs.
     */
    function getVaults()
        external view
        returns (uint256[] memory _vaultIds, address[] memory _vaultAddresses, uint8[] memory _vaultTypes);

    /**
     * Returns the executor address and fee.
     * @return _executor The executor address.
     * @return _executorFee The executor fee (in wei).
     */
    function getExecutorInfo()
        external view
        returns (address payable _executor, uint256 _executorFee);

    /**
     * Returns the swap parameters.
     * @return _uniswapV3Router The Uniswap V3 router address.
     * @return _usdt0 USDT0 token address.
     * @return _wNatUsdt0PoolFeeTierPPM The WNAT/USDT0 pool fee tier (in PPM).
     * @return _usdt0FXrpPoolFeeTierPPM The USDT0/FXRP pool fee tier (in PPM).
     * @return _maxSlippagePPM The maximum slippage allowed for swaps (in PPM).
     */
    function getSwapParams()
        external view
        returns (
            address _uniswapV3Router,
            address _usdt0,
            uint24 _wNatUsdt0PoolFeeTierPPM,
            uint24 _usdt0FXrpPoolFeeTierPPM,
            uint24 _maxSlippagePPM
        );
}
