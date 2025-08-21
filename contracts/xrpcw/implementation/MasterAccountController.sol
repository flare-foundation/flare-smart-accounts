// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {PersonalAccount} from "./PersonalAccount.sol";
import {UUPSUpgradeable} from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {IGovernanceSettings} from "flare-periphery/src/flare/IGovernanceSettings.sol";
import {GovernedBase} from "../../governance/implementation/GovernedBase.sol";
import {ERC1967Utils} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {GovernedProxyImplementation} from "../../governance/implementation/GovernedProxyImplementation.sol";
import {PersonalAccountProxy} from "../proxy/PersonalAccountProxy.sol";
import {IFdcVerification} from "flare-periphery/src/flare/IFdcVerification.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";

/**
 * @title   MasterAccountController contract
 * @notice  The contract controlling personal accounts (XRPL master controller)
 */
contract MasterAccountController is IMasterAccountController, UUPSUpgradeable, GovernedProxyImplementation {
    /// @notice Mapping from PersonalAccount address to XRPL address
    mapping(address personalAccount => string xrplAddress) public personalAccountToXrpl;
    /// @notice The minting executor.
    address payable public  executor;
    /// @notice Executor fee for reserveCollateral (in wei)
    uint256 public executorFee;
    /// @notice Deposit vault
    address public depositVault;
    /// @notice FXRP address
    address public fxrp;
    /// @notice XRPL provider wallet address
    string public xrplProviderWallet;
    /// @notice XRPL provider wallet hash
    bytes32 public xrplProviderWalletHash;
    /// @notice Operator address
    address public operatorAddress;
    /// @notice PersonalAccount implementation address
    address public personalAccountImplementation;
    /// @notice Time window (in seconds) for operator-only execution after XRPL transaction (default: 10 minutes)
    uint256 public operatorExecutionWindowSeconds;

    /// Mapping from Ripple address to Personal Account
    mapping(string xrplAddress => PersonalAccount) private personalAccounts;
    /// @notice Mapping from hashed Ripple Address to Ripple address
    mapping(bytes32 xrplAddressHash => string) public hashToAccount;
    /// @notice Indicates if payment instruction has already been executed.
    mapping(bytes32 transactionId => uint256) public usedPaymentHashes;


    constructor() {}

    /**
     * Proxyable initialization method. Can be called only once, from the proxy constructor
     * (single call is assured by GovernedBase.initialise).
     */
    function initialize(
        IGovernanceSettings _governanceSettings,
        address _initialGovernance,
        address _depositVault,
        address _fxrp,
        address payable _executor,
        uint256 _executorFee,
        string memory _xrplProviderWallet,
        address _operatorAddress,
        uint256 _operatorExecutionWindowSeconds,
        address _personalAccountImplementation
    )
        external virtual
    {
        require(_depositVault != address(0), InvalidDepositVault());
        require(_fxrp != address(0), InvalidFxrp());
        require(_executor != address(0), InvalidExecutor());
        require(bytes(_xrplProviderWallet).length > 0, InvalidXrplProviderWallet());
        require(_operatorAddress != address(0), InvalidOperatorAddress());
        require(_personalAccountImplementation != address(0), InvalidPersonalAccountImplementation());
        require(_executorFee > 0, InvalidExecutorFee());

        GovernedBase.initialise(_governanceSettings, _initialGovernance);
        depositVault = _depositVault;
        fxrp = _fxrp;
        executor = _executor;
        xrplProviderWalletHash = keccak256(abi.encodePacked(_xrplProviderWallet));
        xrplProviderWallet = _xrplProviderWallet;
        operatorAddress = _operatorAddress;
        personalAccountImplementation = _personalAccountImplementation;
        operatorExecutionWindowSeconds = _operatorExecutionWindowSeconds;
        executorFee = _executorFee;
        emit PersonalAccountImplementationSet(_personalAccountImplementation);
        emit OperatorExecutionWindowSecondsSet(_operatorExecutionWindowSeconds);
        emit ExecutorFeeSet(_executorFee);
        // TODO should we have set of operators?
    }

    // TODO should we use hashes of addresses instead of string addresses?
    /**
     * @inheritdoc IMasterAccountController
     */
    function executeTransaction(
        IPayment.Proof calldata _proof,
        string calldata _rippleAccount
    ) external payable {
        if (block.timestamp < _proof.data.responseBody.blockTimestamp + operatorExecutionWindowSeconds) {
            require(msg.sender == operatorAddress, OnlyOperatorCanExecute());
        }

        // FDC verification
        require(
            IFdcVerification(ContractRegistry.getContractAddressByName("FdcVerification")).verifyPayment(_proof),
            InvalidTransactionProof()
        );
        require(
           _proof.data.responseBody.receivingAddressHash == xrplProviderWalletHash,
            InvalidReceivingAddressHash()
        );
        require(
            _proof.data.responseBody.sourceAddressHash ==
                keccak256(abi.encodePacked(_rippleAccount)),
            MismatchingSourceAndXrplAddr()
        );
        require(
            usedPaymentHashes[_proof.data.requestBody.transactionId] == 0,
            TransactionAlreadyExecuted()
        );

        // hashToAccount[
        //     _proof.data.responseBody.sourceAddressHash
        // ] = _rippleAccount;

        // create or get existing Personal Account for the XRPL account
        PersonalAccount personalAccount = _getOrCreatePersonalAccount(_rippleAccount);
        // implementation upgrade
        address personalAccountImpl = personalAccount.implementation();
        if (personalAccountImpl != personalAccountImplementation) {
            personalAccount.upgradeToAndCall(personalAccountImplementation, bytes(""));
        }

        usedPaymentHashes[_proof.data.requestBody.transactionId] = 1;

        _executeInstruction(
            uint256(_proof.data.responseBody.standardPaymentReference),
            personalAccount,
            _rippleAccount
        );
    }

    /**
     * @notice  Sets new PersonalAccount implementation address.
     * @param   _newImplementation  New implementation address.
     * Can only be called by the governance.
     */
    function setPersonalAccountImplementation(address _newImplementation) external onlyGovernance {
        require(_newImplementation != address(0), InvalidPersonalAccountImplementation());
        personalAccountImplementation = _newImplementation;
        emit PersonalAccountImplementationSet(_newImplementation);
    }

    /**
     * @notice  Updates the operator-only window (in seconds).
     * @param   _newWindowSeconds  New execution window duration in seconds.
     * Can only be called by the governance.
     */
    function setOperatorExecutionWindowSeconds(uint256 _newWindowSeconds) external onlyGovernance {
        require(_newWindowSeconds > 0, InvalidOperatorExecutionWindowSeconds());
        operatorExecutionWindowSeconds = _newWindowSeconds;
        emit OperatorExecutionWindowSecondsSet(_newWindowSeconds);
    }

    /**
     * @notice  Sets new executor fee.
     * @param   _newExecutorFee  New executor fee in wei.
     * Can only be called by the governance.
     */
    function setExecutorFee(uint256 _newExecutorFee) external onlyGovernance {
        require(_newExecutorFee > 0, InvalidExecutorFee());
        executorFee = _newExecutorFee;
        emit ExecutorFeeSet(_newExecutorFee);
    }

    /**
     * @inheritdoc IMasterAccountController
     */
    function getPersonalAccount(
        string calldata xrplOwner
    ) external view returns (PersonalAccount) {
        return personalAccounts[xrplOwner];
    }

    /////////////////////////////// UUPS UPGRADABLE ///////////////////////////////
    /**
     * Returns current implementation address.
     * @return Current implementation address.
     */
    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /**
     * @inheritdoc UUPSUpgradeable
     * @dev Only governance can call this method.
     */
    function upgradeToAndCall(address newImplementation, bytes memory data)
        public payable override
        onlyGovernance
        onlyProxy
    {
        super.upgradeToAndCall(newImplementation, data);
    }

    /**
     * Unused. Present just to satisfy UUPSUpgradeable requirement.
     * The real check is in onlyGovernance modifier on upgradeToAndCall.
     */
    function _authorizeUpgrade(address newImplementation) internal override {}

    /////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////
    function _executeInstruction(
        uint256 _paymentReference,
        PersonalAccount _personalAccount,
        string memory _xrplOwner
    ) internal {
        // TODO _xrplOwner could maybe be removed from here. Probably not needed in events?
        // byte 0
        uint256 instructionId = (_paymentReference >> 248) & 0xFF;
        if (instructionId >= 1 && instructionId <= 4) {
            if (instructionId == 4) {
                // bytes 1–11: lots
                // bytes 12–31: empty (ignored)
                uint88 lots = uint88((_paymentReference >> 160) & ((uint256(1) << 88) - 1));
                require(lots > 0, LotsZero());
                _personalAccount.redeem{value: msg.value}(lots, executor, executorFee);
            } else {
                // bytes 1-31: amount
                uint256 amount = _paymentReference & ((uint256(1) << 248) - 1);
                require(amount > 0, AmountZero());
                if (instructionId == 1) {
                    // Deposit
                    _personalAccount.deposit(amount, depositVault);
                } else if (instructionId == 2) {
                    // Withdraw
                    _personalAccount.withdraw(amount, depositVault);
                } else if (instructionId == 3) {
                    // Approve ERC20
                    _personalAccount.approve(amount, fxrp, depositVault);
                }
            }
        } else if (instructionId == 5) {
            // bytes 1–11: lots
            // bytes 12–31: agent vault address
            uint88 lots = uint88((_paymentReference >> 160) & ((uint256(1) << 88) - 1));
            require(lots > 0, LotsZero());
            address agentVault = address(uint160(_paymentReference & ((uint256(1) << 160) - 1)));
            require(agentVault != address(0), InvalidAgentVaultAddress());
            _personalAccount.reserveCollateral{value: msg.value}(lots, agentVault, executor, executorFee);
        } else {
            revert InvalidInstructionId(instructionId);
        }
        // TODO are more granular events needed?
        emit InstructionExecuted(
            address(_personalAccount),
            _xrplOwner,
            instructionId,
            _paymentReference
        );
    }

    function _getOrCreatePersonalAccount(
        string memory _xrplOwner
    ) internal returns (PersonalAccount) {
        if (personalAccounts[_xrplOwner] == PersonalAccount(address(0))) {
            _createPersonalAccount(_xrplOwner);
        }
        return personalAccounts[_xrplOwner];
    }

    function _createPersonalAccount(string memory _xrplOwner) internal {
        // hashToAccount[keccak256(abi.encodePacked(_xrplOwner))] = _xrplOwner;
        PersonalAccountProxy personalAccountProxy = new PersonalAccountProxy(
            personalAccountImplementation,
            _xrplOwner,
            address(this)
        );
        personalAccounts[_xrplOwner] = PersonalAccount(address(personalAccountProxy));
        personalAccountToXrpl[address(personalAccountProxy)] = _xrplOwner;
        emit PersonalAccountCreated(
            _xrplOwner,
            address(personalAccountProxy)
        );
    }
}
