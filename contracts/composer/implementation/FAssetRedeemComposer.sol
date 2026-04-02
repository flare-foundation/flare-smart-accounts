// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IWNat} from "flare-periphery/src/flare/IWNat.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IIFAssetRedeemerAccount} from "../interface/IIFAssetRedeemerAccount.sol";
import {FAssetRedeemerAccountProxy} from "../proxy/FAssetRedeemerAccountProxy.sol";
import {IFAssetRedeemComposer} from "../../userInterfaces/IFAssetRedeemComposer.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {OwnableWithTimelock} from "../../utils/implementation/OwnableWithTimelock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title FAssetRedeemComposer
 * @notice LayerZero compose handler that orchestrates deterministic redeemer accounts and f-asset redemption.
 */
contract FAssetRedeemComposer is
    IFAssetRedeemComposer,
    OwnableWithTimelock,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    uint256 private constant PPM_DENOMINATOR = 1_000_000;

    /// @notice Mapping of redeemer to deterministic redeemer account address.
    mapping(address redeemer => address redeemerAccount) private redeemerToRedeemerAccount;

    /// @notice Trusted endpoint allowed to invoke `lzCompose`.
    address public endpoint;
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
    /// @notice Recipient of composer fee collected in fAsset.
    address public composerFeeRecipient;
    /// @notice Default composer fee in PPM.
    uint256 public defaultComposerFeePPM;
    /// @notice Optional srcEid-specific composer fee in PPM, stored as fee + 1 to distinguish unset values.
    mapping(uint32 srcEid => uint256 feePPM) private composerFeesPPM;
    /// @notice The default executor address used for redemption execution if not specified in the compose message.
    address payable public defaultExecutor;

    /**
     * @notice Disables initializers on implementation contract.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes composer proxy state.
     * @param _initialOwner Owner address for administrative operations.
     * @param _endpoint Trusted endpoint allowed to invoke `lzCompose`.
     * @param _trustedSourceOApp Trusted source OApp address.
     * @param _assetManager Asset manager used for redemption.
     * @param _stableCoin Stable coin token - returned in case of a redemption failure.
     * @param _wNat Wrapped native token - returned in case of a redemption failure
     *              if stable coin balance is insufficient.
     * @param _composerFeeRecipient Recipient of composer fee collected in fAsset.
     * @param _defaultComposerFeePPM Default composer fee in PPM.
     * @param _defaultExecutor Default executor address used for redemption execution.
     * @param _redeemerAccountImplementation Beacon implementation for redeemer accounts.
     */
    function initialize(
        address _initialOwner,
        address _endpoint,
        address _trustedSourceOApp,
        IAssetManager _assetManager,
        IERC20 _stableCoin,
        IERC20 _wNat,
        address _composerFeeRecipient,
        uint256 _defaultComposerFeePPM,
        address payable _defaultExecutor,
        address _redeemerAccountImplementation
    )
        external
        initializer
    {
        require(_initialOwner != address(0), InvalidAddress());
        require(_endpoint != address(0), InvalidAddress());
        require(_trustedSourceOApp != address(0), InvalidAddress());
        require(address(_assetManager).code.length > 0, InvalidAddress());
        require(address(_stableCoin).code.length > 0, InvalidAddress());
        require(address(_wNat).code.length > 0, InvalidAddress());
        require(_composerFeeRecipient != address(0), InvalidAddress());
        require(_defaultComposerFeePPM < PPM_DENOMINATOR, InvalidComposerFeePPM());
        require(_defaultExecutor != address(0), InvalidAddress());
        require(_redeemerAccountImplementation.code.length > 0, InvalidRedeemerAccountImplementation());

        __Ownable_init(_initialOwner);

        endpoint = _endpoint;
        trustedSourceOApp = _trustedSourceOApp;
        assetManager = _assetManager;
        fAsset = _assetManager.fAsset();
        require(address(fAsset).code.length > 0, InvalidAddress());
        stableCoin = _stableCoin;
        wNat = _wNat;
        composerFeeRecipient = _composerFeeRecipient;
        defaultComposerFeePPM = _defaultComposerFeePPM;
        defaultExecutor = _defaultExecutor;
        redeemerAccountImplementation = _redeemerAccountImplementation;

        emit ComposerFeeRecipientSet(_composerFeeRecipient);
        emit DefaultComposerFeeSet(_defaultComposerFeePPM);
        emit DefaultExecutorSet(_defaultExecutor);
        emit RedeemerAccountImplementationSet(redeemerAccountImplementation);
    }

    /**
     * @notice Updates default composer fee in PPM.
     * @param _defaultComposerFeePPM New default composer fee in PPM.
     */
    function setDefaultComposerFee(
        uint256 _defaultComposerFeePPM
    )
        external
        onlyOwnerWithTimelock
    {
        require(_defaultComposerFeePPM < PPM_DENOMINATOR, InvalidComposerFeePPM());
        defaultComposerFeePPM = _defaultComposerFeePPM;
        emit DefaultComposerFeeSet(_defaultComposerFeePPM);
    }

    /**
     * @notice Sets srcEid-specific composer fees in PPM.
     * @dev Uses fee+1 storage to distinguish unset (0) from an explicit zero fee.
     * @param _srcEids List of OFT source endpoint IDs.
     * @param _composerFeesPPM Composer fee values in PPM for corresponding srcEids.
     */
    function setComposerFees(
        uint32[] calldata _srcEids,
        uint256[] calldata _composerFeesPPM
    )
        external
        onlyOwnerWithTimelock
    {
        require(_srcEids.length == _composerFeesPPM.length, LengthMismatch());

        for (uint256 i = 0; i < _srcEids.length; i++) {
            uint32 srcEid = _srcEids[i];
            uint256 feePPM = _composerFeesPPM[i];
            require(feePPM < PPM_DENOMINATOR, InvalidComposerFeePPM());
            composerFeesPPM[srcEid] = feePPM + 1;
            emit ComposerFeeSet(srcEid, feePPM);
        }
    }

    /**
     * @notice Removes srcEid-specific composer fee overrides.
     * @param _srcEids List of OFT source endpoint IDs.
     */
    function removeComposerFees(
        uint32[] calldata _srcEids
    )
        external
        onlyOwnerWithTimelock
    {
        for (uint256 i = 0; i < _srcEids.length; i++) {
            uint32 srcEid = _srcEids[i];
            require(
                composerFeesPPM[srcEid] != 0,
                ComposerFeeNotSet(srcEid)
            );
            delete composerFeesPPM[srcEid];
            emit ComposerFeeRemoved(srcEid);
        }
    }

    /**
     * @notice Updates recipient for collected composer fee.
     * @param _composerFeeRecipient New recipient address.
     */
    function setComposerFeeRecipient(
        address _composerFeeRecipient
    )
        external
        onlyOwnerWithTimelock
    {
        require(_composerFeeRecipient != address(0), InvalidComposerFeeRecipient());
        composerFeeRecipient = _composerFeeRecipient;
        emit ComposerFeeRecipientSet(_composerFeeRecipient);
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
     * @notice Updates default executor used for redemption execution.
     * @param _executor New default executor address.
     */
    function setDefaultExecutor(
        address payable _executor
    )
        external
        onlyOwnerWithTimelock
    {
        require(_executor != address(0), InvalidAddress());
        defaultExecutor = _executor;
        emit DefaultExecutorSet(_executor);
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

    /// @inheritdoc ILayerZeroComposer
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    )
        external payable
        nonReentrant
    {
        require(msg.sender == endpoint, OnlyEndpoint());
        require(_from == trustedSourceOApp, InvalidSourceOApp(_from));

        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
        uint256 composerFee = Math.mulDiv(
            amountLD,
            _getComposerFeePPM(srcEid),
            PPM_DENOMINATOR
        );
        uint256 amountToRedeemAfterFee = amountLD - composerFee;
        RedeemComposeMessage memory redeemComposeMessage = abi.decode(
            OFTComposeMsgCodec.composeMsg(_message), (RedeemComposeMessage)
        );
        require(redeemComposeMessage.redeemer != address(0), InvalidAddress());

        if (composerFee > 0) {
            fAsset.safeTransfer(composerFeeRecipient, composerFee);
            emit ComposerFeeCollected(_guid, srcEid, composerFeeRecipient, composerFee);
        }

        address redeemerAccount = _getOrCreateRedeemerAccount(redeemComposeMessage.redeemer);
        fAsset.safeTransfer(redeemerAccount, amountToRedeemAfterFee);
        emit FAssetTransferred(redeemerAccount, amountToRedeemAfterFee);

        address payable executor = redeemComposeMessage.executor != address(0) ?
            redeemComposeMessage.executor : defaultExecutor;

        try IIFAssetRedeemerAccount(redeemerAccount).redeemFAsset{value: msg.value}(
            assetManager,
            amountToRedeemAfterFee,
            redeemComposeMessage.redeemerUnderlyingAddress,
            redeemComposeMessage.redeemWithTag,
            redeemComposeMessage.destinationTag,
            executor
        )
            returns (uint256 _redeemedAmountUBA)
        {
            emit FAssetRedeemed(
                _guid,
                srcEid,
                redeemComposeMessage.redeemer,
                redeemerAccount,
                amountToRedeemAfterFee,
                redeemComposeMessage.redeemerUnderlyingAddress,
                redeemComposeMessage.redeemWithTag,
                redeemComposeMessage.destinationTag,
                executor,
                msg.value,
                _redeemedAmountUBA
            );
        } catch {
            if (msg.value > 0) {
                // wrap native tokens and deposit to redeemer account in case of failure
                //slither-disable-next-line arbitrary-send-eth
                IWNat(address(wNat)).depositTo{value: msg.value}(redeemerAccount);
            }

            emit FAssetRedeemFailed(
                _guid,
                srcEid,
                redeemComposeMessage.redeemer,
                redeemerAccount,
                amountToRedeemAfterFee,
                msg.value
            );
        }
    }

    /// @inheritdoc IFAssetRedeemComposer
    function getComposerFeePPM(
        uint32 _srcEid
    )
        external view
        returns (uint256 _composerFeePPM)
    {
        _composerFeePPM = _getComposerFeePPM(_srcEid);
    }

    /// @inheritdoc IBeacon
    function implementation()
        external view
        returns (address)
    {
        return redeemerAccountImplementation;
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

    /// @inheritdoc IFAssetRedeemComposer
    function isRedeemerAccount(
        address _address
    )
        external view
        returns (bool _isRedeemerAccount, address _owner)
    {
        if (_address.code.length == 0) {
            return (false, address(0));
        }

        try IIFAssetRedeemerAccount(_address).owner() returns (address _redeemer) {
            // verify _address is matching redeemer account
            if (_address == redeemerToRedeemerAccount[_redeemer]) {
                return (true, _redeemer);
            }
        } catch {
            // not a redeemer account if call fails
        }
        return (false, address(0));
    }

    /// @inheritdoc IFAssetRedeemComposer
    function getBalances(
        address _account
    )
        external view
        returns (AccountBalances memory _balances)
    {
        _balances.fAsset = TokenBalance(address(fAsset), fAsset.balanceOf(_account));
        _balances.stableCoin = TokenBalance(address(stableCoin), stableCoin.balanceOf(_account));
        _balances.wNat = TokenBalance(address(wNat), wNat.balanceOf(_account));
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
        internal view
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(FAssetRedeemerAccountProxy).creationCode,
            abi.encode(address(this), _redeemer)
        );
    }

    /**
     * @notice Retrieves composer fee in PPM for a given srcEid, falling back to default if not set.
     * @param _srcEid OFT source endpoint ID.
     * @return _composerFeePPM Composer fee in PPM.
     */
    function _getComposerFeePPM(
        uint32 _srcEid
    )
        internal view
        returns (uint256 _composerFeePPM)
    {
        uint256 srcEidFeePlusOne = composerFeesPPM[_srcEid];
        if (srcEidFeePlusOne > 0) {
            return srcEidFeePlusOne - 1;
        }

        return defaultComposerFeePPM;
    }
}
