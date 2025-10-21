// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AvailableAgentInfo.sol";
import {CollateralReservationInfo} from "flare-periphery/src/flare/data/CollateralReservationInfo.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IGovernanceSettings} from "flare-periphery/src/flare/IGovernanceSettings.sol";
import {IFdcVerification} from "flare-periphery/src/flare/IFdcVerification.sol";
import {UUPSUpgradeable} from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IBeacon} from "@openzeppelin-contracts/proxy/beacon/IBeacon.sol";
import {MasterAccountControllerBase} from "./MasterAccountControllerBase.sol";
import {Create2} from "@openzeppelin-contracts/utils/Create2.sol";
import {PersonalAccountProxy} from "../proxy/PersonalAccountProxy.sol";
import {PersonalAccount} from "../implementation/PersonalAccount.sol";
import {GovernedBase} from "../../governance/implementation/GovernedBase.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IISingletonFactory} from "../interface/IISingletonFactory.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";

// payment reference format (32 bytes):
// FXRP
// bytes 00: uint8 -> instruction id
    // 00: collateral reservation
    // 01: redeem
// bytes 01: uint8 -> wallet identifier
// bytes 02-17: uint128 -> value (lots)
// bytes 18-19: uint16 -> agent vault address id
// bytes 20-31: future use

// Firelight vaults
// bytes 00: uint8 -> instruction id
    // 10: collateral reservation and deposit
    // 11: deposit
    // 12: withdraw
    // 13: claim withdraw
    // 14: claim withdraw and redeem
// bytes 01: uint8 -> wallet identifier
// bytes 02-17: uint128 -> value (amount, lots, period,...)
// bytes 18-19: uint16 -> agent vault address id
// bytes 20-21: uint16 -> deposit/withdraw vault address id
// bytes 22-31: future use

// Upshift vaults
// bytes 00: uint8 -> instruction id
    // 20: collateral reservation and deposit
    // 21: deposit
    // 22: requestRedeem
    // 23: claim
    // 24: claim and redeem
// bytes 01: uint8 -> wallet identifier
// bytes 02-17: uint128 -> value (amount, shares, lots, date(yyyymmdd),...)
// bytes 18-19: uint16 -> agent vault address id
// bytes 20-21: uint16 -> deposit/withdraw vault address id
// bytes 22-31: future use

/**
 * @title MasterAccountController contract
 * @notice The contract controlling personal accounts (XRPL master controller)
 */
contract MasterAccountController is
    IMasterAccountController,
    IBeacon,
    MasterAccountControllerBase
{
    /// @notice EIP-2470 Singleton Factory address used as the CREATE2 deployer
    address public constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    /// @notice The minting executor.
    address payable public executor;
    /// @notice Executor fee for reserveCollateral (in wei)
    uint256 public executorFee;
    /// @notice XRPL provider wallet addresses
    string[] private xrplProviderWallets;
    /// @notice Indicates whether the contract has been initialized
    bool private initialized;
    /// @notice XRPL provider wallet hashes
    mapping(bytes32 => uint256 index) private xrplProviderWalletHashes; // 1-based index
    /// @notice Default fee for instruction execution in underlying asset's smallest unit (e.g., drops for XRP)
    uint256 public defaultInstructionFee;
    /// @notice Override for default instruction fee (1-based to distinguish from default (0))
    mapping(uint256 instructionId => uint256 fee) private instructionFees;
    /// @notice Duration (in seconds) for which the payment proof is valid
    uint256 public paymentProofValidityDurationSeconds;
    /// @notice PersonalAccount implementation used by BeaconProxy PA instances via IBeacon
    address public personalAccountImplementation;
    /// Mapping from XRPL address to Personal Account
    mapping(string xrplAddress => IIPersonalAccount) private personalAccounts;
    /// @notice Indicates if payment instruction has already been executed.
    mapping(bytes32 transactionId => bool) public usedPaymentHashes;
    /// @notice Mapping from collateral reservation ID to XRPL transaction ID - used for deposit after minting
    mapping(uint256 collateralReservationId => bytes32 transactionId) public collateralReservationIdToTransactionId;
    /// @notice Mapping from agent vault ID to agent vault address
    mapping(uint256 agentVaultId => address agentVaultAddress) public agentVaults;
    uint256[] private agentVaultIds;
    /// @notice Mapping from vault ID to vault address
    mapping(uint256 vaultId => address vaultAddress) public vaults;
    uint256[] private vaultIds;

    /**
     * Proxyable initialization method. Can be called only once, from the proxy constructor
     * (single call is assured by GovernedBase.initialise).
     */
    function initialize(
        address payable _executor,
        uint256 _executorFee,
        uint256 _paymentProofValidityDurationSeconds,
        uint256 _defaultInstructionFee,
        string memory _xrplProviderWallet,
        address _personalAccountImplementation
    )
        external onlyOwner
    {
        require(!initialized, AlreadyInitialized());
        initialized = true;
        _setExecutor(_executor);
        _setExecutorFee(_executorFee);
        _setPaymentProofValidityDurationSeconds(_paymentProofValidityDurationSeconds);
        _setDefaultInstructionFee(_defaultInstructionFee);
        string[] memory xrplProviderWalletList = new string[](1);
        xrplProviderWalletList[0] = _xrplProviderWallet;
        _addXrplProviderWallets(xrplProviderWalletList);
        // set the PA implementation that this controller (as beacon) will return
        _setPersonalAccountImplementation(_personalAccountImplementation);
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
        require(
            instructionId == 0 || instructionId == 10 || instructionId == 20,
            InvalidInstructionId(instructionId)
        );
        // check transaction id
        require(_transactionId != bytes32(0), InvalidTransactionId());
        // create or get existing Personal Account for the XRPL address
        IIPersonalAccount personalAccount = _getOrCreatePersonalAccount(_xrplAddress);
        // reserve collateral
        address agentVault = _getAgentVaultAddress(_paymentReference);
        uint256 lots = _getValue(_paymentReference);
        _collateralReservationId = personalAccount.reserveCollateral{value: msg.value}(
            agentVault,
            lots,
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
            _getWalletId(_paymentReference),
            agentVault,
            lots,
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
        bytes32 paymentReference = _proof.data.responseBody.standardPaymentReference;

        // check instruction id
        uint256 instructionId = _getInstructionId(paymentReference);
        require(
            instructionId == 10 || instructionId == 20,
            InvalidInstructionId(instructionId)
        );

        // check that crtId and txId match
        bytes32 transactionId = _proof.data.requestBody.transactionId;
        require(
            transactionId != bytes32(0) &&
            collateralReservationIdToTransactionId[_collateralReservationId] == transactionId,
            UnknownCollateralReservationId()
        );

        // check if minting was successfully completed
        CollateralReservationInfo.Data memory reservationInfo =
            ContractRegistry.getAssetManagerFXRP().collateralReservationInfo(_collateralReservationId);
        require(reservationInfo.status == CollateralReservationInfo.Status.SUCCESSFUL, MintingNotCompleted());

        // verify payment proof
        _verifyPayment(instructionId, _proof, _xrplAddress);
        // check that minter and amount match
        IIPersonalAccount personalAccount = _getOrCreatePersonalAccount(_xrplAddress);
        require(address(personalAccount) == reservationInfo.minter, InvalidMinter());
        uint256 lots = _getValue(paymentReference);
        uint256 amount = _lotsToAmount(lots);
        // could revert if lot size changes between minting and deposit, but very unlikely
        // user should call deposit in that case
        require(amount == reservationInfo.valueUBA, InvalidAmount());
        // mark transaction as used
        usedPaymentHashes[transactionId] = true;

        // execute deposit
        address vault = _getVaultAddress(paymentReference);
        personalAccount.deposit(vault, amount);

        // emit event
        emit InstructionExecuted(
            address(personalAccount),
            _xrplAddress,
            instructionId,
            paymentReference,
            transactionId
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
        uint256 instructionId = _getInstructionId(paymentReference);
        // verify payment proof
        _verifyPayment(instructionId, _proof, _xrplAddress);

        // create or get existing Personal Account for the XRPL address
        IIPersonalAccount personalAccount = _getOrCreatePersonalAccount(_xrplAddress);

        bytes32 transactionId = _proof.data.requestBody.transactionId;
        // mark transaction as used
        usedPaymentHashes[transactionId] = true;

        // execute instruction
        _executeInstruction(
            instructionId,
            paymentReference,
            personalAccount,
            _xrplAddress,
            transactionId
        );
    }

    /**
     * @notice Sets new executor address.
     * @param _newExecutor New executor address.
     * Can only be called by the governance.
     */
    function setExecutor(
        address payable _newExecutor
    )
        external onlyOwner
    {
        _setExecutor(_newExecutor);
    }

    /**
     * @notice Sets new executor fee.
     * @param _newExecutorFee New executor fee in wei.
     * Can only be called by the governance.
     */
    function setExecutorFee(
        uint256 _newExecutorFee
    )
        external onlyOwner
    {
        _setExecutorFee(_newExecutorFee);
    }

    /**
     * @notice Updates the payment proof validity duration.
     * @param _newDurationSeconds New duration in seconds.
     * Can only be called by the governance.
     */
    function setPaymentProofValidityDuration(
        uint256 _newDurationSeconds
    )
        external onlyOwner
    {
        _setPaymentProofValidityDurationSeconds(_newDurationSeconds);
    }

    /**
     * @notice Sets new default instruction fee.
     * @param _fee New default instruction fee in underlying asset's smallest unit (e.g., drops for XRP).
     * Can only be called by the governance.
     */
    function setDefaultInstructionFee(
        uint256 _fee
    )
        external onlyOwner
    {
        _setDefaultInstructionFee(_fee);
    }

    /**
     * @notice Sets instruction-specific fees, overriding the default fee.
     * @param _instructionIds The IDs of the instructions.
     * @param _fees The fees for the instructions in underlying asset's smallest unit (e.g., drops for XRP).
     * Can only be called by the governance.
     */
    function setInstructionFees(
        uint256[] calldata _instructionIds,
        uint256[] calldata _fees
    )
        external onlyOwner
    {
        require(_instructionIds.length == _fees.length, LengthsMismatch());
        for (uint256 i = 0; i < _instructionIds.length; i++) {
            uint256 instructionId = _instructionIds[i];
            uint256 fee = _fees[i];
            instructionFees[instructionId] = fee + 1; // store 1-based to distinguish from default (0)
            emit InstructionFeeSet(instructionId, fee);
        }
    }

    /**
     * @notice Removes instruction-specific fees, reverting to the default fee.
     * @param _instructionIds The IDs of the instructions to remove fees for.
     * Can only be called by the governance.
     */
    function removeInstructionFees(
        uint256[] calldata _instructionIds
    )
        external onlyOwner
    {
        for (uint256 i = 0; i < _instructionIds.length; i++) {
            uint256 instructionId = _instructionIds[i];
            delete instructionFees[instructionId];
            emit InstructionFeeRemoved(instructionId);
        }
    }

    /**
     * @notice Adds new XRPL provider wallet addresses.
     * @param _xrplProviderWallets The XRPL provider wallet addresses to add.
     * Can only be called by the governance.
     */
    function addXrplProviderWallets(
        string[] memory _xrplProviderWallets
    )
        external onlyOwner
    {
        _addXrplProviderWallets(_xrplProviderWallets);
    }

    /**
     * @notice Removes existing XRPL provider wallet addresses.
     * @param _xrplProviderWallets The XRPL provider wallet addresses to remove.
     * Can only be called by the governance.
     */
    function removeXrplProviderWallets(
        string[] calldata _xrplProviderWallets
    )
        external onlyOwner
    {
        for (uint256 i = 0; i < _xrplProviderWallets.length; i++) {
            string calldata xrplProviderWallet = _xrplProviderWallets[i];
            bytes32 walletHash = keccak256(bytes(xrplProviderWallet));
            uint256 index = xrplProviderWalletHashes[walletHash]; // 1-based index
            require(index != 0, InvalidXrplProviderWallet(xrplProviderWallet));
            // remove from mapping
            delete xrplProviderWalletHashes[walletHash];
            uint256 length = xrplProviderWallets.length;
            if (index == length) {
                // removing the last element
                xrplProviderWallets.pop();
            } else {
                string memory lastWallet = xrplProviderWallets[length - 1];
                // move the last element to the removed position
                xrplProviderWallets[index - 1] = lastWallet;
                xrplProviderWallets.pop();
                // update moved wallet's index in mapping
                bytes32 movedWalletHash = keccak256(bytes(lastWallet));
                xrplProviderWalletHashes[movedWalletHash] = index; // update to new 1-based index
            }
            emit XrplProviderWalletRemoved(xrplProviderWallet);
        }
    }

    /**
     * @notice Sets new PersonalAccount implementation address.
     * @param _newImplementation New PersonalAccount implementation address.
     * Can only be called by the governance.
     */
    function setPersonalAccountImplementation(
        address _newImplementation
    )
        external onlyOwner
    {
        _setPersonalAccountImplementation(_newImplementation);
    }

    /**
     * @notice Adds new agent vault addresses with the given IDs.
     * @param _agentVaultIds The IDs of the agent vaults.
     * @param _agentVaultAddresses The addresses of the agent vaults.
     * Can only be called by the governance.
     */
    function addAgentVaults(
        uint256[] calldata _agentVaultIds,
        address[] calldata _agentVaultAddresses
    )
        external onlyOwner
    {
        require(_agentVaultIds.length == _agentVaultAddresses.length, LengthsMismatch());
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        for (uint256 i = 0; i < _agentVaultIds.length; i++) {
            uint256 agentVaultId = _agentVaultIds[i];
            address agentVaultAddress = _agentVaultAddresses[i];
            require(agentVaults[agentVaultId] == address(0), AgentVaultIdAlreadyUsed(agentVaultId));
            require(agentVaultAddress != address(0), InvalidAgentVault(agentVaultId));
            AgentInfo.Info memory agentInfo = assetManager.getAgentInfo(agentVaultAddress);
            require(agentInfo.status == AgentInfo.Status.NORMAL, AgentNotAvailable(agentVaultAddress));
            agentVaults[agentVaultId] = agentVaultAddress;
            agentVaultIds.push(agentVaultId);
            emit AgentVaultAdded(agentVaultId, agentVaultAddress);
        }
    }

    /**
     * @notice Removes existing agent vault addresses by their IDs.
     * @param _agentVaultIds The IDs of the agent vaults to remove.
     * Can only be called by the governance.
     */
    function removeAgentVaults(
        uint256[] calldata _agentVaultIds
    )
        external onlyOwner
    {
        for (uint256 i = 0; i < _agentVaultIds.length; i++) {
            uint256 agentVaultId = _agentVaultIds[i];
            address agentVault = agentVaults[agentVaultId];
            require(agentVault != address(0), InvalidAgentVault(agentVaultId));
            // remove from mapping
            delete agentVaults[agentVaultId];
            // remove from array
            for (uint256 j = 0; j < agentVaultIds.length; j++) {
                if (agentVaultIds[j] == agentVaultId) {
                    agentVaultIds[j] = agentVaultIds[agentVaultIds.length - 1];
                    agentVaultIds.pop();
                    break;
                }
            }
            emit AgentVaultRemoved(agentVaultId, agentVault);
        }
    }

    /**
     * @notice Adds new vault addresses with the given IDs.
     * @param _vaultIds The IDs of the vaults.
     * @param _vaultAddresses The addresses of the vaults.
     * Can only be called by the governance.
     */
    function addVaults(
        uint256[] calldata _vaultIds,
        address[] calldata _vaultAddresses
    )
        external onlyOwner
    {
        require(_vaultIds.length == _vaultAddresses.length, LengthsMismatch());
        for (uint256 i = 0; i < _vaultIds.length; i++) {
            uint256 vaultId = _vaultIds[i];
            address vaultAddress = _vaultAddresses[i];
            require(vaults[vaultId] == address(0), VaultIdAlreadyUsed(vaultId));
            require(vaultAddress != address(0), InvalidVault(vaultId));
            vaults[vaultId] = vaultAddress;
            vaultIds.push(vaultId);
            emit VaultAdded(vaultId, vaultAddress);
        }
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
        bytes memory bytecode = _generateBytecode(_xrplOwner);
        return Create2.computeAddress(bytes32(0), keccak256(bytecode), SINGLETON_FACTORY);
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

    /**
     * @inheritdoc IMasterAccountController
     */
    function getInstructionFee(
        uint256 _instructionId
    )
        external view
        returns (uint256)
    {
        return _getInstructionFee(_instructionId);
    }

    /**
     * @inheritdoc IMasterAccountController
     */
    function getXrplProviderWallets()
        external view
        returns (string[] memory)
    {
        return xrplProviderWallets;
    }

    /**
     * @inheritdoc IMasterAccountController
     */
    function getAgentVaults()
        external view
        returns (uint256[] memory _agentVaultIds, address[] memory _agentVaultAddresses)
    {
        _agentVaultIds = agentVaultIds;
        _agentVaultAddresses = new address[](_agentVaultIds.length);
        for (uint256 i = 0; i < _agentVaultIds.length; i++) {
            _agentVaultAddresses[i] = agentVaults[_agentVaultIds[i]];
        }
    }

    /**
     * @inheritdoc IMasterAccountController
     */
    function getVaults()
        external view
        returns (uint256[] memory _vaultIds, address[] memory _vaultAddresses)
    {
        _vaultIds = vaultIds;
        _vaultAddresses = new address[](_vaultIds.length);
        for (uint256 i = 0; i < _vaultIds.length; i++) {
            _vaultAddresses[i] = vaults[_vaultIds[i]];
        }
    }

    /////////////////////////////// UUPS UPGRADABLE ///////////////////////////////
    /**
     * Returns current implementation address.
     * @return Current implementation address.
     */
    // expose current controller implementation address under a distinct name to avoid
    // collision with IBeacon.implementation()
    function controllerImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /**
     * @inheritdoc IBeacon
     */
    function implementation() external view override returns (address) {
        return personalAccountImplementation;
    }

    /**
     * @inheritdoc UUPSUpgradeable
     * @dev Only governance can call this method.
     */
    function upgradeToAndCall(
        address _newImplementation,
        bytes memory _data
    )
        public payable override onlyOwner onlyProxy
    {
        super.upgradeToAndCall(_newImplementation, _data);
    }

    /**
     * Unused. Present just to satisfy UUPSUpgradeable requirement.
     * The real check is in onlyOwner modifier on upgradeToAndCall.
     */
    function _authorizeUpgrade(address _newImplementation) internal override {}

    /////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////
    function _executeInstruction(
        uint256 _instructionId,
        bytes32 _paymentReference,
        IIPersonalAccount _personalAccount,
        string memory _xrplOwner,
        bytes32 _transactionId
    )
        internal
    {
        if (_instructionId == 1) { // redeem
            uint256 lots = _getValue(_paymentReference);
            _personalAccount.redeem{value: msg.value}(lots, executor, executorFee);
        } else if (_instructionId == 11 || _instructionId == 21) { // deposit
            uint256 amount = _getValue(_paymentReference);
            address vault = _getVaultAddress(_paymentReference);
            _personalAccount.deposit(vault, amount);
        } else if (_instructionId == 12) { // withdraw
            address vault = _getVaultAddress(_paymentReference);
            uint256 amount = _getValue(_paymentReference);
            _personalAccount.withdraw(vault, amount);
        } else if (_instructionId == 13) { // claim withdraw
            uint256 period = _getValue(_paymentReference);
            address vault = _getVaultAddress(_paymentReference);
            _personalAccount.claimWithdraw(vault, period);
        } else if (_instructionId == 14) { // claim withdraw and redeem
            uint256 period = _getValue(_paymentReference);
            address vault = _getVaultAddress(_paymentReference);
            uint256 amount = _personalAccount.claimWithdraw(vault, period);
            uint256 lots = _amountToLots(amount);
            _personalAccount.redeem{value: msg.value}(lots, executor, executorFee);
        } else if (_instructionId == 22) { // requestRedeem
            uint256 shares = _getValue(_paymentReference);
            address vault = _getVaultAddress(_paymentReference);
            _personalAccount.requestRedeem(vault, shares);
        } else if (_instructionId == 23) { // claim
            (uint256 year, uint256 month, uint256 day) = _getDate(_paymentReference);
            address vault = _getVaultAddress(_paymentReference);
            _personalAccount.claim(vault, year, month, day);
        } else if (_instructionId == 24) { // claim and redeem
            (uint256 year, uint256 month, uint256 day) = _getDate(_paymentReference);
            address vault = _getVaultAddress(_paymentReference);
            (,uint256 amount) = _personalAccount.claim(vault, year, month, day);
            uint256 lots = _amountToLots(amount);
            _personalAccount.redeem{value: msg.value}(lots, executor, executorFee);
        } else {
            revert InvalidInstructionId(_instructionId);
        }
        // TODO are more granular events needed?
        emit InstructionExecuted(
            address(_personalAccount),
            _xrplOwner,
            _instructionId,
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
        }
    }

    function _createPersonalAccount(
        string memory _xrplOwner
    )
        internal
        returns (IIPersonalAccount _personalAccount)
    {
        bytes memory bytecode = _generateBytecode(_xrplOwner);
        // check if already deployed
        address personalAccountProxyAddress =
            Create2.computeAddress(bytes32(0), keccak256(bytecode), SINGLETON_FACTORY);
        uint256 codeSize;
        // solhint-disable-next-line no-inline-assembly
        assembly { codeSize := extcodesize(personalAccountProxyAddress) }
        if (codeSize == 0) {
            // deploy via EIP-2470 singleton factory using CREATE2
            IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, bytes32(0));
        }

        _personalAccount = IIPersonalAccount(payable(personalAccountProxyAddress));

        // ensure the proxy address is a contract before calling initialize
        // solhint-disable-next-line no-inline-assembly
        assembly { codeSize := extcodesize(personalAccountProxyAddress) }
        require(codeSize > 0, PersonalAccountNotSuccessfullyDeployed(personalAccountProxyAddress));

        personalAccounts[_xrplOwner] = _personalAccount;
        emit PersonalAccountCreated(_xrplOwner, personalAccountProxyAddress);
    }

    function _setExecutor(address payable _newExecutor) internal {
        require(_newExecutor != address(0), InvalidExecutor());
        executor = _newExecutor;
        emit ExecutorSet(_newExecutor);
    }

    function _setExecutorFee(uint256 _newExecutorFee) internal {
        require(_newExecutorFee > 0, InvalidExecutorFee());
        executorFee = _newExecutorFee;
        emit ExecutorFeeSet(_newExecutorFee);
    }

    function _setPaymentProofValidityDurationSeconds(uint256 _newDuration) internal {
        require(_newDuration > 0, InvalidPaymentProofValidityDuration());
        paymentProofValidityDurationSeconds = _newDuration;
        emit PaymentProofValidityDurationSecondsSet(_newDuration);
    }

    function _setDefaultInstructionFee(uint256 _newDefaultInstructionFee) internal {
        defaultInstructionFee = _newDefaultInstructionFee;
        emit DefaultInstructionFeeSet(_newDefaultInstructionFee);
    }

    function _addXrplProviderWallets(
        string[] memory _xrplProviderWallets
    )
        internal
    {
        for (uint256 i = 0; i < _xrplProviderWallets.length; i++) {
            string memory xrplProviderWallet = _xrplProviderWallets[i];
            require(bytes(xrplProviderWallet).length > 0, InvalidXrplProviderWallet(xrplProviderWallet));
            bytes32 walletHash = keccak256(bytes(xrplProviderWallet));
            require(xrplProviderWalletHashes[walletHash] == 0, XrplProviderWalletAlreadyExists(xrplProviderWallet));
            xrplProviderWallets.push(xrplProviderWallet);
            xrplProviderWalletHashes[walletHash] = xrplProviderWallets.length; // store 1-based index
            emit XrplProviderWalletAdded(xrplProviderWallet);
        }
    }

    function _setPersonalAccountImplementation(address _newImplementation) internal {
        require(_newImplementation != address(0), InvalidPersonalAccountImplementation());
        personalAccountImplementation = _newImplementation;
        emit PersonalAccountImplementationSet(_newImplementation);
    }

    /**
     * @notice Generates the bytecode for deploying a PersonalAccountProxy contract.
     * @return The bytecode to be used for CREATE2 deployment.
     */
    function _generateBytecode(string memory _xrplOwner) internal view returns (bytes memory) {
        // Use the controller proxy address as the beacon so the controller acts as IBeacon for PAs.
        // address(this) resolves to the proxy address when called via delegatecall.
        return abi.encodePacked(
            type(PersonalAccountProxy).creationCode,
            abi.encode(address(this), _xrplOwner, address(this))
        );
    }

    function _verifyPayment(
        uint256 _instructionId,
        IPayment.Proof calldata _proof,
        string memory _xrplAddress
    )
        internal view
    {
        uint256 instructionFee = _getInstructionFee(_instructionId);
        int256 receivedAmount = _proof.data.responseBody.receivedAmount;
        require(
            receivedAmount >= 0 && uint256(receivedAmount) >= instructionFee,
            InvalidPaymentAmount(instructionFee)
        );
        require(
            _proof.data.responseBody.status == 0,
            InvalidTransactionStatus()
        );
        require(
            block.timestamp <= paymentProofValidityDurationSeconds + _proof.data.responseBody.blockTimestamp,
            PaymentProofExpired()
        );
        require(
            _proof.data.responseBody.sourceAddressHash == keccak256(bytes(_xrplAddress)),
            MismatchingSourceAndXrplAddr()
        );
        require(
            xrplProviderWalletHashes[_proof.data.responseBody.receivingAddressHash] != 0,
            InvalidReceivingAddressHash()
        );
        require(
            !usedPaymentHashes[_proof.data.requestBody.transactionId],
            TransactionAlreadyExecuted()
        );
        require(
            ContractRegistry.getFdcVerification().verifyPayment(_proof),
            InvalidTransactionProof()
        );
    }

    function _lotsToAmount(uint256 _lots) internal view returns (uint256) {
        uint256 lotSize = ContractRegistry.getAssetManagerFXRP().lotSize();
        return _lots * lotSize;
    }

    function _amountToLots(uint256 _amount) internal view returns (uint256) {
        uint256 lotSize = ContractRegistry.getAssetManagerFXRP().lotSize();
        return _amount / lotSize; // there might be remainder
    }

    function _getInstructionFee(uint256 _instructionId) internal view returns (uint256) {
        uint256 fee = instructionFees[_instructionId]; // 1-based to distinguish unset (0) from zero fee
        if (fee > 0) {
            return fee - 1;
        }
        return defaultInstructionFee;
    }

    function _getAgentVaultAddress(bytes32 _paymentReference) internal view returns (address _agentVault) {
        // bytes 18-19: agent vault address id
        uint256 agentVaultId = (uint256(_paymentReference) >> 96) & ((uint256(1) << 16) - 1);
        _agentVault = agentVaults[agentVaultId];
        require(_agentVault != address(0), InvalidAgentVault(agentVaultId));
    }

    function _getVaultAddress(bytes32 _paymentReference) internal view returns (address _vault) {
        // bytes 20-21: vault address id
        uint256 vaultId = (uint256(_paymentReference) >> 80) & ((uint256(1) << 16) - 1);
        _vault = vaults[vaultId];
        require(address(_vault) != address(0), InvalidVault(vaultId));
    }

    function _getInstructionId(bytes32 _paymentReference) internal pure returns (uint256) {
        // byte 0: instruction id
        return (uint256(_paymentReference) >> 248) & 0xFF;
    }

    function _getWalletId(bytes32 _paymentReference) internal pure returns (uint256) {
        // byte 1: wallet identifier
        return (uint256(_paymentReference) >> 240) & 0xFF;
    }

    function _getValue(bytes32 _paymentReference) internal pure returns (uint256 _value) {
        // bytes 2-17: value
        _value = (uint256(_paymentReference) >> 112) & ((uint256(1) << 128) - 1);
        require(_value > 0, ValueZero());
    }

    function _getDate(bytes32 _paymentReference) internal pure returns (uint256 _year, uint256 _month, uint256 _day) {
        // bytes 2-17: value (date in yyyymmdd format)
        uint256 date = _getValue(_paymentReference);
        _year = (date / 10000) % 10000;
        _month = (date / 100) % 100;
        _day = date % 100;
    }

    /**
     * @notice Generates a deterministic salt for CREATE2 deployment based on XRPL address.
     * @param _xrplOwner The XRPL address.
     * @return The salt to be used for CREATE2 deployment.
     */
    function _generateSalt(string memory _xrplOwner) internal pure returns (bytes32) {
        return keccak256(bytes(_xrplOwner));
    }
}
