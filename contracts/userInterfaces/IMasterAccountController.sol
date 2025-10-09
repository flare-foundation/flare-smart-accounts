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
    event OperatorExecutionWindowSecondsSet(uint256 newWindowSeconds);
    event PersonalAccountCreated(string xrplOwner, address personalAccount);
    event ExecutorFeeSet(uint256 executorFee);
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

    error InvalidDepositVault();
    error InvalidExecutor();
    error InvalidXrplProviderWallet();
    error InvalidOperatorAddress();
    error InvalidOperatorExecutionWindowSeconds();
    error InvalidPersonalAccountImplementation();
    error OnlyOperator();
    error InvalidTransactionId();
    error InvalidTransactionProof();
    error InvalidReceivingAddressHash();
    error InvalidTransactionStatus();
    error MismatchingSourceAndXrplAddr();
    error TransactionAlreadyExecuted();
    error InvalidInstructionId(uint256 instructionId);
    error InvalidExecutorFee();
    error AmountOrLotsZero();
    error RewardEpochIdZero();
    error UnknownCollateralReservationId();
    error InvalidCollateralReservationId();
    error InvalidAgentVaultAddress();
    error InvalidDepositVaultAddress();
    error FxrpAssetManagerNotSet();
    error InvalidAmount();
    error InvalidMinter();

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
    function executeTransaction(
        IPayment.Proof calldata _proof,
        string calldata _xrplAddress
    )
        external payable;

    /**
     * @notice Create a PersonalAccount for a given XRPL owner, if already exists returns the existing one.
     * @param _xrplOwner The XRPL address of the owner.
     * @return The newly created PersonalAccount contract.
     */
    function createPersonalAccount(
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
     * @notice  Computes the address of a PersonalAccount for a given XRPL owner.
     * @param   _xrplOwner  The XRPL address.
     * @return  The predicted address of the PersonalAccount.
     */
    function computePersonalAccountAddress(
        string calldata _xrplOwner
    )
        external view
        returns (address);
}
