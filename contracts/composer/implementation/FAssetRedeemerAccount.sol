// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIFAssetRedeemerAccount} from "../interface/IIFAssetRedeemerAccount.sol";

/**
 * @title FAssetRedeemerAccount
 * @notice Per-redeemer account used by composer to execute f-asset redemption and set token allowances.
 */
contract FAssetRedeemerAccount is IIFAssetRedeemerAccount {
    using SafeERC20 for IERC20;

    /// @notice Sentinel value used to lock direct initialization of implementation contract.
    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;

    /// @notice Composer contract authorized to execute account actions.
    address public composer;
    /// @notice Owner of the account receiving token allowances.
    address public owner;

    /**
     * @notice Restricts function access to composer contract.
     */
    modifier onlyComposer() {
        require(msg.sender == composer, ComposerOnly());
        _;
    }

    /**
     * @notice Sets sentinel value to prevent using the implementation instance directly.
     */
    constructor() {
        composer = EMPTY_ADDRESS;
    }

    /**
     * @notice Initializes account proxy state.
     * @param _composer Composer contract allowed to execute account actions.
     * @param _owner Owner address.
     */
    function initialize(address _composer, address _owner) external {
        require(
            composer == address(0),
            AlreadyInitialized()
        );
        require(
            _composer != address(0) &&
            _owner != address(0),
            InvalidAddress()
        );

        composer = _composer;
        owner = _owner;
    }

    /// @inheritdoc IIFAssetRedeemerAccount
    function redeemFAsset(
        IAssetManager _assetManager,
        uint256 _amountLD,
        string calldata _redeemerUnderlyingAddress,
        bool _redeemWithTag,
        uint64 _destinationTag,
        address payable _executor
    )
        external payable
        onlyComposer
        returns (uint256 _redeemedAmountUBA)
    {
        require(!_redeemWithTag || _assetManager.redeemWithTagSupported(), RedeemWithTagNotSupported(_destinationTag));
        if (_redeemWithTag) {
            _redeemedAmountUBA = _assetManager.redeemWithTag{value: msg.value}
                (_amountLD, _redeemerUnderlyingAddress, _executor, _destinationTag);
        } else {
            _redeemedAmountUBA = _assetManager.redeemAmount{value: msg.value}
                (_amountLD, _redeemerUnderlyingAddress, _executor);
        }
    }

    /// @inheritdoc IIFAssetRedeemerAccount
    function setMaxAllowances(
        IERC20 _fAsset,
        IERC20 _stableCoin,
        IERC20 _wNat
    )
        external
        onlyComposer
    {
        _fAsset.forceApprove(owner, type(uint256).max);
        _stableCoin.forceApprove(owner, type(uint256).max);
        _wNat.forceApprove(owner, type(uint256).max);

        emit MaxAllowancesSet(owner, _fAsset, _stableCoin, _wNat);
    }
}
