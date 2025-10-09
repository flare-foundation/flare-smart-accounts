// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {UUPSUpgradeable} from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {IGovernanceSettings} from "flare-periphery/src/flare/IGovernanceSettings.sol";
import {GovernedBase} from "../../governance/implementation/GovernedBase.sol";
import {ERC1967Utils} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {GovernedProxyImplementation} from "../../governance/implementation/GovernedProxyImplementation.sol";
import {PersonalAccountProxy} from "../proxy/PersonalAccountProxy.sol";
import {IFdcVerification} from "flare-periphery/src/flare/IFdcVerification.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";
import {CollateralReservationInfo} from "flare-periphery/src/flare/data/CollateralReservationInfo.sol";
import {Create2} from "@openzeppelin-contracts/utils/Create2.sol";

// payment reference format (32 bytes):
// FXRP
// bytes 00: uint8 -> instruction id
    // 00: collateral reservation
    // 01: redeem
// bytes 01: uint8 -> wallet identifier
// bytes 02-17: uint128 -> lots
// bytes 18-19: uint16 -> agent vault address id
// bytes 20-31: future use

// Vaults (Firelight, ...)
// bytes 00: uint8 -> instruction id
    // 10: collateral reservation and deposit
    // 11: deposit
    // 12: withdraw
    // 13: claim withdraw
    // 14: claim withdraw and redeem
// bytes 01: uint8 -> wallet identifier
// bytes 02-17: uint128 -> amount/lots
// bytes 18-19: uint16 -> agent vault address id
// bytes 20-21: uint16 -> deposit/withdraw vault address id
// bytes 22-24: uint24 -> period
// bytes 25-31: future use

/**
 * @title   MasterAccountController contract
 * @notice  The contract controlling personal accounts (XRPL master controller)
 */
contract MasterAccountController is
    IMasterAccountController,
    UUPSUpgradeable,
    GovernedProxyImplementation
{
    /// @notice The minting executor.
    address payable public executor;
    /// @notice Executor fee for reserveCollateral (in wei)
    uint256 public executorFee;
    /// @notice XRPL provider wallet address
    string public xrplProviderWallet;
    /// @notice XRPL provider wallet hash
    bytes32 public xrplProviderWalletHash;
    /// @notice Operator address
    address public operatorAddress;
    /// @notice Time window (in seconds) for operator-only execution after XRPL transaction (default: 10 minutes)
    uint256 public operatorExecutionWindowSeconds;
    /// @notice PersonalAccount implementation address
    address public personalAccountImplementation;
    /// @notice Seed PersonalAccount implementation address (for create2 deployment)
    address public seedPersonalAccountImplementation;

    /// Mapping from XRPL address to Personal Account
    mapping(string xrplAddress => IIPersonalAccount) private personalAccounts;
    /// @notice Indicates if payment instruction has already been executed.
    mapping(bytes32 transactionId => bool) public usedPaymentHashes;
    /// @notice Mapping from collateral reservation ID to XRPL transaction ID
    mapping(uint256 collateralReservationId => bytes32 transactionId) public collateralReservationIdToTransactionId;
    /// @notice Mapping from agent vault ID to agent vault address
    mapping(uint256 agentVaultId => address agentVaultAddress) public agentVaults;
    /// @notice Mapping from vault ID to vault address
    mapping(uint256 vaultId => address vaultAddress) private vaults;

    constructor() {}

    /**
     * Proxyable initialization method. Can be called only once, from the proxy constructor
     * (single call is assured by GovernedBase.initialise).
     */
    function initialize(
        IGovernanceSettings _governanceSettings,
        address _initialGovernance,
        address _vault,
        address payable _executor,
        uint256 _executorFee,
        string memory _xrplProviderWallet,
        address _operatorAddress,
        uint256 _operatorExecutionWindowSeconds,
        address _personalAccountImplementation
    )
        external
    {
        require(_vault != address(0), InvalidVault());
        require(_executor != address(0), InvalidExecutor());
        require(bytes(_xrplProviderWallet).length > 0, InvalidXrplProviderWallet());
        require(_operatorAddress != address(0), InvalidOperatorAddress());
        require(_personalAccountImplementation != address(0), InvalidPersonalAccountImplementation());
        require(_executorFee > 0, InvalidExecutorFee());

        GovernedBase.initialise(_governanceSettings, _initialGovernance);
        vaults[0] = _vault; // TODO
        executor = _executor;
        xrplProviderWalletHash = keccak256(
            abi.encodePacked(_xrplProviderWallet)
        );
        xrplProviderWallet = _xrplProviderWallet;
        operatorAddress = _operatorAddress;
        operatorExecutionWindowSeconds = _operatorExecutionWindowSeconds;
        personalAccountImplementation = _personalAccountImplementation;
        executorFee = _executorFee;
        seedPersonalAccountImplementation = _personalAccountImplementation;
        emit PersonalAccountImplementationSet(_personalAccountImplementation);
        emit OperatorExecutionWindowSecondsSet(_operatorExecutionWindowSeconds);
        emit ExecutorFeeSet(_executorFee);
        // TODO should we have set of operators?

        // TODO
        // set up agent vaults - there are <= 10 for now, can be extended in the future
        (address[] memory availableAgentVaults, uint256 totalLength) =
            _getFxrpAssetManager().getAvailableAgentsList(0, 100);
        require(totalLength <= 100, "Too many agent vaults");
        for (uint256 i = 0; i < availableAgentVaults.length; i++) {
            agentVaults[i] = availableAgentVaults[i];
        }
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
        uint256 instructionId = _getInstructionId(_paymentReference);
        require(instructionId == 0 || instructionId == 10, InvalidInstructionId(instructionId));
        // check transaction id
        require(_transactionId != bytes32(0), InvalidTransactionId());
        // create or get existing Personal Account for the XRPL address
        IIPersonalAccount personalAccount = _getOrCreatePersonalAccount(_xrplAddress);
        // reserve collateral
        uint256 lots = _getAmountOrLots(_paymentReference);
        address agentVault = _getAgentVaultAddress(_paymentReference);
        _collateralReservationId = personalAccount.reserveCollateral{value: msg.value}(
            lots,
            agentVault,
            executor,
            executorFee
        );
        // set mapping from collateral reservation id to transaction id
        collateralReservationIdToTransactionId[_collateralReservationId] = _transactionId;
        // emit event
        emit CollateralReserved(
            address(personalAccount),
            _xrplAddress,
            _collateralReservationId,
            lots,
            agentVault,
            _transactionId
        );
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
        // check operator-only window
        _checkOperatorOnlyWindow(_proof.data.responseBody.blockTimestamp);

        // check instruction id
        uint256 instructionId = _getInstructionId(_proof.data.responseBody.standardPaymentReference);
        require(instructionId == 10, InvalidInstructionId(instructionId));

        // check that crtId and txId match
        bytes32 transactionId = _proof.data.requestBody.transactionId;
        require(
            transactionId != bytes32(0) &&
            collateralReservationIdToTransactionId[_collateralReservationId] == transactionId,
            UnknownCollateralReservationId()
        );

        // check if minting was successfully completed
        CollateralReservationInfo.Data memory reservationInfo =
            _getFxrpAssetManager().collateralReservationInfo(_collateralReservationId);
        require(reservationInfo.status == CollateralReservationInfo.Status.SUCCESSFUL, MintingNotCompleted());

        // verify payment proof
        _verifyPayment(_proof, _xrplAddress);
        // check that minter and amount match
        IIPersonalAccount personalAccount = _getOrCreatePersonalAccount(_xrplAddress);
        require(address(personalAccount) == reservationInfo.minter, InvalidMinter());
        uint256 lots = _getAmountOrLots(_proof.data.responseBody.standardPaymentReference);
        uint256 amount = _lotsToAmount(lots);
        // could revert if lot size changes between minting and deposit, but very unlikely
        // user should call deposit in that case
        require(amount == reservationInfo.valueUBA, InvalidAmount());
        // mark transaction as used
        usedPaymentHashes[transactionId] = true;

        // execute deposit
        address vault = _getVaultAddress(_proof.data.responseBody.standardPaymentReference);
        personalAccount.deposit(amount, vault);
    }

    // TODO should we use hashes of addresses instead of string addresses?
    /**
     * @inheritdoc IMasterAccountController
     */
    function executeInstruction(
        IPayment.Proof calldata _proof,
        string calldata _xrplAddress
    )
        external payable
    {
        // check operator-only window
        _checkOperatorOnlyWindow(_proof.data.responseBody.blockTimestamp);

        // verify payment proof
        _verifyPayment(_proof, _xrplAddress);

        // create or get existing Personal Account for the XRPL address
        IIPersonalAccount personalAccount = _getOrCreatePersonalAccount(_xrplAddress);
        // mark transaction as used
        usedPaymentHashes[_proof.data.requestBody.transactionId] = true;

        // execute instruction
        _executeInstruction(
            _proof.data.responseBody.standardPaymentReference,
            personalAccount,
            _xrplAddress,
            _proof.data.requestBody.transactionId
        );
    }

    /**
     * @notice Sets new PersonalAccount implementation address.
     * @param _newImplementation New implementation address.
     * Can only be called by the governance.
     */
    function setPersonalAccountImplementation(
        address _newImplementation
    )
        external onlyGovernance
    {
        require(
            _newImplementation != address(0),
            InvalidPersonalAccountImplementation()
        );
        personalAccountImplementation = _newImplementation;
        emit PersonalAccountImplementationSet(_newImplementation);
    }

    /**
     * @notice Updates the operator-only window (in seconds).
     * @param _newWindowSeconds New execution window duration in seconds.
     * Can only be called by the governance.
     */
    function setOperatorExecutionWindowSeconds(
        uint256 _newWindowSeconds
    )
        external onlyGovernance
    {
        require(_newWindowSeconds > 0, InvalidOperatorExecutionWindowSeconds());
        operatorExecutionWindowSeconds = _newWindowSeconds;
        emit OperatorExecutionWindowSecondsSet(_newWindowSeconds);
    }

    /**
     * @notice Sets new executor fee.
     * @param _newExecutorFee New executor fee in wei.
     * Can only be called by the governance.
     */
    function setExecutorFee(
        uint256 _newExecutorFee
    )
        external onlyGovernance
    {
        require(_newExecutorFee > 0, InvalidExecutorFee());
        executorFee = _newExecutorFee;
        emit ExecutorFeeSet(_newExecutorFee);
    }

    /**
     * @inheritdoc IMasterAccountController
     */
    function createOrUpdatePersonalAccount(
        string calldata xrplOwner
    )
        external
        returns (IPersonalAccount)
    {
        return _getOrCreatePersonalAccount(xrplOwner);
    }

    /**
     * @inheritdoc IMasterAccountController
     */
    function computePersonalAccountAddress(
        string calldata _xrplOwner
    )
        external view
        returns (address)
    {
        bytes32 salt = _generateSalt(_xrplOwner);
        bytes memory bytecode = _generateBytecode(_xrplOwner);
        return Create2.computeAddress(salt, keccak256(bytecode));
    }

    /**
     * @inheritdoc IMasterAccountController
     */
    function getPersonalAccount(
        string calldata xrplOwner
    )
        external view
        returns (IPersonalAccount)
    {
        return personalAccounts[xrplOwner];
    }

    /////////////////////////////// UUPS UPGRADABLE ///////////////////////////////
    /**
     * Returns current implementation address.
     * @return Current implementation address.
     */
    function implementation()
        external view
        returns (address)
    {
        return ERC1967Utils.getImplementation();
    }

    /**
     * @inheritdoc UUPSUpgradeable
     * @dev Only governance can call this method.
     */
    function upgradeToAndCall(
        address _newImplementation,
        bytes memory _data
    )
        public payable override onlyGovernance onlyProxy
    {
        super.upgradeToAndCall(_newImplementation, _data);
    }

    /**
     * Unused. Present just to satisfy UUPSUpgradeable requirement.
     * The real check is in onlyGovernance modifier on upgradeToAndCall.
     */
    function _authorizeUpgrade(address _newImplementation) internal override {}

    /////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////
    function _executeInstruction(
        bytes32 _paymentReference,
        IIPersonalAccount _personalAccount,
        string memory _xrplOwner,
        bytes32 _transactionId
    )
        internal
    {
        // TODO _xrplOwner could maybe be removed from here. Probably not needed in events?
        // byte 0
        uint256 instructionId = _getInstructionId(_paymentReference);
        if (instructionId == 1) { // redeem
            uint256 lots = _getAmountOrLots(_paymentReference);
            _personalAccount.redeem{value: msg.value}(lots, executor, executorFee);
        } else if (instructionId == 11 || instructionId == 12) { // deposit or withdraw
            uint256 amount = _getAmountOrLots(_paymentReference);
            address vault = _getVaultAddress(_paymentReference);
            if (instructionId == 11) { // deposit
                _personalAccount.deposit(amount, vault);
            } else if (instructionId == 12) { // withdraw
                _personalAccount.withdraw(amount, vault);
            }
        } else if (instructionId == 13) { // claim withdraw
            uint256 period = _getPeriod(_paymentReference);
            address vault = _getVaultAddress(_paymentReference);
            _personalAccount.claimWithdraw(period, vault);
        } else if (instructionId == 14) { // claim withdraw and redeem
            uint256 period = _getPeriod(_paymentReference);
            address vault = _getVaultAddress(_paymentReference);
            uint256 lots = _getAmountOrLots(_paymentReference);
            _personalAccount.claimWithdraw(period, vault);
            // TODO swap
            _personalAccount.redeem{value: msg.value}(lots, executor, executorFee);
        } else {
            revert InvalidInstructionId(instructionId);
        }
        // TODO are more granular events needed?
        emit InstructionExecuted(
            address(_personalAccount),
            _xrplOwner,
            instructionId,
            _paymentReference,
            _transactionId
        );
    }

    function _getOrCreatePersonalAccount(
        string memory _xrplOwner
    )
        internal
        returns (IIPersonalAccount _personalAccount)
    {
        _personalAccount = personalAccounts[_xrplOwner];
        if (address(_personalAccount) == address(0)) {
            // create new Personal Account
            _personalAccount = _createPersonalAccount(_xrplOwner);
        } else {
            // check for implementation upgrade
            address personalAccountImpl = _personalAccount.implementation();
            if (personalAccountImpl != personalAccountImplementation) {
                UUPSUpgradeable(address(_personalAccount)).upgradeToAndCall(personalAccountImplementation, bytes(""));
            }
        }
    }

    function _createPersonalAccount(
        string memory _xrplOwner
    )
        internal
        returns (IIPersonalAccount _personalAccount)
    {
        bytes32 salt = _generateSalt(_xrplOwner);
        bytes memory bytecode = _generateBytecode(_xrplOwner);
        // deploy PersonalAccountProxy using CREATE2
        address personalAccountProxyAddress = Create2.deploy(0, salt, bytecode);
        _personalAccount = IIPersonalAccount(payable(personalAccountProxyAddress));

        // immediately upgrade to current implementation
        if (personalAccountImplementation != seedPersonalAccountImplementation) {
            UUPSUpgradeable(personalAccountProxyAddress).upgradeToAndCall(personalAccountImplementation, bytes(""));
        }

        personalAccounts[_xrplOwner] = _personalAccount;
        emit PersonalAccountCreated(_xrplOwner, personalAccountProxyAddress);
    }

    /**
     * @notice Generates the bytecode for deploying a PersonalAccountProxy contract with the given XRPL owner.
     * @param _xrplOwner The XRPL address.
     * @return The bytecode to be used for CREATE2 deployment.
     */
    function _generateBytecode(string memory _xrplOwner) internal view returns (bytes memory) {
        // deploy proxy with seed implementation for stable address
        return abi.encodePacked(
            type(PersonalAccountProxy).creationCode,
            abi.encode(
                seedPersonalAccountImplementation,
                _xrplOwner,
                address(this)
            )
        );
    }

    function _verifyPayment(IPayment.Proof calldata _proof, string memory _xrplAddress) internal view {
        // FDC verification
        require(
            _proof.data.responseBody.status == 0,
            InvalidTransactionStatus()
        );

        require(
            ContractRegistry.getFdcVerification().verifyPayment(_proof),
            InvalidTransactionProof()
        );
        require(
            _proof.data.responseBody.receivingAddressHash == xrplProviderWalletHash,
            InvalidReceivingAddressHash()
        );
        require(
            _proof.data.responseBody.sourceAddressHash == keccak256(abi.encodePacked(_xrplAddress)),
            MismatchingSourceAndXrplAddr()
        );
        require(
            !usedPaymentHashes[_proof.data.requestBody.transactionId],
            TransactionAlreadyExecuted()
        );
    }

    function _getFxrpAssetManager() internal view returns (IAssetManager) {
        address assetManagerAddress = ContractRegistry.getContractAddressByName("AssetManagerFXRP");
        require(assetManagerAddress != address(0), FxrpAssetManagerNotSet());
        return IAssetManager(assetManagerAddress);
    }

    function _checkOperatorOnlyWindow(uint256 _timestamp) internal view {
        if (block.timestamp < _timestamp + operatorExecutionWindowSeconds) {
            require(msg.sender == operatorAddress, OnlyOperator());
        }
    }

    function _lotsToAmount(uint256 _lots) internal view returns (uint256) {
        uint256 lotSize = _getFxrpAssetManager().lotSize();
        return _lots * lotSize;
    }

    function _getAgentVaultAddress(bytes32 _paymentReference) internal view returns (address _vault) {
        // bytes 18-19: agent vault address id
        uint256 vaultId = (uint256(_paymentReference) >> 96) & ((uint256(1) << 16) - 1);
        _vault = agentVaults[vaultId];
        require(_vault != address(0), InvalidAgentVault());
    }

    function _getVaultAddress(bytes32 _paymentReference) internal view returns (address _vault) {
        // bytes 20-21: Firelight vault address id
        uint256 vaultId = (uint256(_paymentReference) >> 80) & ((uint256(1) << 16) - 1);
        _vault = vaults[vaultId];
        require(address(_vault) != address(0), InvalidVault());
    }

    function _getInstructionId(bytes32 _paymentReference) internal pure returns (uint256) {
        // byte 0: instruction id
        return (uint256(_paymentReference) >> 248) & 0xFF;
    }

    function _getAmountOrLots(bytes32 _paymentReference) internal pure returns (uint256 _amountOrLots) {
        // bytes 2-17: amount/lots
        _amountOrLots = (uint256(_paymentReference) >> 112) & ((uint256(1) << 128) - 1);
        require(_amountOrLots > 0, AmountOrLotsZero());
    }

    function _getPeriod(bytes32 _paymentReference) internal pure returns (uint256) {
        // bytes 22-24: period
        return (uint256(_paymentReference) >> 56) & ((uint256(1) << 24) - 1);
    }

    /**
     * @notice Generates a deterministic salt for CREATE2 deployment based on XRPL address.
     * @param _xrplOwner The XRPL address.
     * @return The salt to be used for CREATE2 deployment.
     */
    function _generateSalt(string memory _xrplOwner) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_xrplOwner));
    }
}
