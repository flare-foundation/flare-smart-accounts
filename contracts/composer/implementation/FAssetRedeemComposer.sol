// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IIFAssetRedeemerAccount} from "../interface/IIFAssetRedeemerAccount.sol";
import {FAssetRedeemerAccountProxy} from "../proxy/FAssetRedeemerAccountProxy.sol";
import {IFAssetRedeemComposer} from "../../userInterfaces/IFAssetRedeemComposer.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {OwnableWithTimelock} from "../../utils/implementation/OwnableWithTimelock.sol";

/**
 * @title FAssetRedeemComposer
 * @notice LayerZero compose handler that orchestrates deterministic redeemer accounts and f-asset redemption.
 */
contract FAssetRedeemComposer is IFAssetRedeemComposer, OwnableWithTimelock, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Mapping of redeemer to deterministic redeemer account address.
    mapping(address redeemer => address redeemerAccount) private redeemerToRedeemerAccount;

    /// @notice Trusted endpoint allowed to invoke `lzCompose`.
    address public endpointV2;
    /// @notice Asset manager used for f-asset redemption.
    IAssetManager public assetManager;
    /// @notice FAsset token.
    IERC20 public fAsset;
    /// @notice Stable coin token - returned in case of a redemption failure.
    IERC20 public stableCoin;
    /// @notice Wrapped native token - returned in case of a redemption failure if stable coin balance is insufficient.
    IERC20 public wNat;
    /// @notice Trusted source OApp address (FAssetOFTAdapter).
    address public trustedSourceOApp;
    /// @notice Current beacon implementation for redeemer account proxies.
    address public redeemerAccountImplementation;
    /// @notice The redeem executor.
    address payable private executor;
    /// @notice The native fee expected by the executor for redeem execution.
    uint256 private executorFee;

    /**
     * @notice Disables initializers on implementation contract.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes composer proxy state.
     * @param _initialOwner Owner address for administrative operations.
     * @param _endpointV2 Trusted endpoint allowed to invoke `lzCompose`.
     * @param _trustedSourceOApp Trusted source OApp address.
     * @param _assetManager Asset manager used for redemption.
     * @param _stableCoin Stable coin token - returned in case of a redemption failure.
     * @param _wNat Wrapped native token - returned in case of a redemption failure
     *              if stable coin balance is insufficient.
     * @param _redeemerAccountImplementation Beacon implementation for redeemer accounts.
     */
    function initialize(
        address _initialOwner,
        address _endpointV2,
        address _trustedSourceOApp,
        IAssetManager _assetManager,
        IERC20 _stableCoin,
        IERC20 _wNat,
        address _redeemerAccountImplementation
    )
        external
        initializer
    {
        require(
            _initialOwner != address(0) &&
            _endpointV2.code.length > 0 &&
            _trustedSourceOApp.code.length > 0 &&
            address(_assetManager) != address(0) &&
            address(_stableCoin) != address(0) &&
            address(_wNat) != address(0),
            InvalidAddress()
        );
        require(
            _redeemerAccountImplementation.code.length > 0,
            InvalidRedeemerAccountImplementation()
        );

        __Ownable_init(_initialOwner);

        endpointV2 = _endpointV2;
        trustedSourceOApp = _trustedSourceOApp;
        assetManager = _assetManager;
        fAsset = _assetManager.fAsset();
        require(address(fAsset) != address(0), InvalidAddress());
        stableCoin = _stableCoin;
        wNat = _wNat;
        redeemerAccountImplementation = _redeemerAccountImplementation;

        emit RedeemerAccountImplementationSet(redeemerAccountImplementation);
    }

    /**
     * @notice Updates beacon implementation used by redeemer accounts.
     * @param _implementation New implementation address.
     */
    function setRedeemerAccountImplementation(
        address _implementation
    )
        external
        onlyOwnerWithTimelock
    {
        require(
            _implementation.code.length > 0,
            InvalidRedeemerAccountImplementation()
        );
        redeemerAccountImplementation = _implementation;
        emit RedeemerAccountImplementationSet(_implementation);
    }

    /**
     * @notice Updates executor data used for redemption execution.
     * @param _executor New executor address.
     * @param _executorFee New expected fee for executor.
     */
    function setExecutorData(
        address payable _executor,
        uint256 _executorFee
    )
        external
        onlyOwnerWithTimelock
    {
        require(_executor != address(0) || _executorFee == 0, InvalidExecutorData());
        executor = _executor;
        executorFee = _executorFee;
        emit ExecutorDataSet(_executor, _executorFee);
    }

    /**
     * @notice Transfers f-assets held by composer to a target address.
     * @dev Recovery function for funds stuck on composer when compose flow fails or is not invoked.
     * @param _to Recipient address.
     * @param _amount Amount of f-asset to transfer.
     */
    function transferFAsset(
        address _to,
        uint256 _amount
    )
        external
        onlyOwnerWithTimelock
    {
        require(_to != address(0), InvalidAddress());
        fAsset.safeTransfer(_to, _amount);
        emit FAssetTransferred(_to, _amount);
    }

    /**
     * @notice Transfers native tokens held by composer to a target address.
     * @dev Recovery function for funds stuck on composer when compose flow fails.
     * @param _to Recipient address.
     * @param _amount Amount of native tokens to transfer.
     */
    function transferNative(
        address _to,
        uint256 _amount
    )
        external
        onlyOwnerWithTimelock
    {
        require(_to != address(0), InvalidAddress());
        (bool success, ) = _to.call{value: _amount}("");
        require(success, NativeTransferFailed());
        emit NativeTransferred(_to, _amount);
    }

    /// @inheritdoc ILayerZeroComposer
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata
    )
        external payable
        nonReentrant
    {
        require(msg.sender == endpointV2, OnlyEndpointV2());
        require(_from == trustedSourceOApp, InvalidSourceOApp(_from));

        uint256 amountToRedeemUBA = OFTComposeMsgCodec.amountLD(_message);
        RedeemComposeData memory data = abi.decode(OFTComposeMsgCodec.composeMsg(_message), (RedeemComposeData));
        require(data.redeemer != address(0), InvalidAddress());

        address redeemerAccount = _getOrCreateRedeemerAccount(data.redeemer);
        fAsset.safeTransfer(redeemerAccount, amountToRedeemUBA);
        emit FAssetTransferred(redeemerAccount, amountToRedeemUBA);

        try IIFAssetRedeemerAccount(redeemerAccount).redeemFAsset{value: msg.value}(
            assetManager,
            amountToRedeemUBA,
            data.redeemerUnderlyingAddress,
            executor,
            executorFee
        )
            returns (uint256 _redeemedAmountUBA)
        {
            emit FAssetRedeemed(
                _guid,
                OFTComposeMsgCodec.srcEid(_message),
                data.redeemer,
                redeemerAccount,
                amountToRedeemUBA,
                data.redeemerUnderlyingAddress,
                executor,
                executorFee,
                _redeemedAmountUBA
            );
        } catch {
            emit FAssetRedeemFailed(
                _guid,
                OFTComposeMsgCodec.srcEid(_message),
                data.redeemer,
                redeemerAccount,
                amountToRedeemUBA
            );
        }
    }

    /// @inheritdoc IBeacon
    function implementation()
        external view
        returns (address)
    {
        return redeemerAccountImplementation;
    }

    /// @inheritdoc IFAssetRedeemComposer
    function getExecutorData()
        external view
        returns (address payable _executor, uint256 _executorFee)
    {
        _executor = executor;
        _executorFee = executorFee;
    }

    /// @inheritdoc IFAssetRedeemComposer
    function getRedeemerAccountAddress(
        address _redeemer
    )
        external view
        returns (address _redeemerAccount)
    {
        _redeemerAccount = redeemerToRedeemerAccount[_redeemer];
        if (_redeemerAccount == address(0)) {
            bytes memory bytecode = _generateRedeemerAccountBytecode(_redeemer);
            _redeemerAccount = Create2.computeAddress(bytes32(0), keccak256(bytecode));
        }
    }

    /**
     * @inheritdoc UUPSUpgradeable
     * @dev Only owner can call this method.
     */
    function upgradeToAndCall(address _newImplementation, bytes memory _data)
        public payable override
        onlyOwnerWithTimelock
    {
        super.upgradeToAndCall(_newImplementation, _data);
    }

    /**
     * Unused. Present just to satisfy UUPSUpgradeable requirement as call is timelocked.
     * The real check is in onlyOwnerWithTimelock modifier on upgradeToAndCall.
     */
    function _authorizeUpgrade(address _newImplementation) internal override {}

    /**
     * @notice Gets existing redeemer account or creates a deterministic one.
     * @param _redeemer Redeemer account owner address.
     * @return _redeemerAccount Redeemer account address.
     */
    function _getOrCreateRedeemerAccount(
        address _redeemer
    )
        internal
        returns (address _redeemerAccount)
    {
        _redeemerAccount = redeemerToRedeemerAccount[_redeemer];
        if (_redeemerAccount != address(0)) {
            return _redeemerAccount;
        }

        // redeemer account does not exist, create it
        bytes memory bytecode = _generateRedeemerAccountBytecode(_redeemer);
        _redeemerAccount = Create2.deploy(0, bytes32(0), bytecode); // reverts on failure
        redeemerToRedeemerAccount[_redeemer] = _redeemerAccount;
        emit RedeemerAccountCreated(_redeemer, _redeemerAccount);

        // set unlimited allowances for fAsset, stable coin and wNat
        // to enable redeemer to transfer funds to redeemer address in case of redemption failure
        IIFAssetRedeemerAccount(_redeemerAccount).setMaxAllowances(
            fAsset,
            stableCoin,
            wNat
        );
    }

    /**
     * @notice Builds CREATE2 deployment bytecode for redeemer account proxy.
     * @param _redeemer Redeemer account owner address.
     * @return Bytecode used for deterministic deployment.
     */
    function _generateRedeemerAccountBytecode(
        address _redeemer
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(FAssetRedeemerAccountProxy).creationCode,
            abi.encode(address(this), _redeemer)
        );
    }
}
