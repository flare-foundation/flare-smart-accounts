// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Vault
/// @author Filip Koprivec
/// @notice This is the vault that is used by MasterAccountController contract only for demo purposes.
contract MyERC4626 is ERC4626 {
    mapping(address => uint256 assets) public pendingWithdrawAssets;

    event WithdrawRequest(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 period,
        uint256 assets,
        uint256 shares
    );

    event CompleteWithdraw(
        address indexed owner,
        uint256 assets,
        uint256 period
    );

    event CompleteWithdraw(
        address indexed owner,
        uint256 assets,
        uint256 year,
        uint256 month,
        uint256 day
    );

    /// @notice constructor
    /// @param baseAsset_ base asset address - FXRP
    /// @param name_ base asset name
    /// @param symbol_ base asset symbol
    constructor(
        IERC20 baseAsset_,
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
        ERC4626(baseAsset_)
    {}

    function requestRedeem(
        uint256 _shares,
        address _receiver,
        address _owner
    )
        public
        returns (uint256 _assets, uint256 _claimableEpoch)
    {
        uint256 maxShares = maxRedeem(_owner);
        if (_shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(_owner, _shares, maxShares);
        }

        _assets = previewRedeem(_shares);
        _withdraw(_msgSender(), _receiver, _owner, _assets, _shares);
        _claimableEpoch = 1; // for testing purposes
    }

    function claimWithdraw(uint256 _period) public returns (uint256 _assets) {
        (, _assets) = _completeWithdraw(msg.sender);
        emit CompleteWithdraw(msg.sender, _assets, _period);
    }

    function claim(
        uint256 _year,
        uint256 _month,
        uint256 _day,
        address _receiverAddr
    )
        external
        returns (uint256 _shares, uint256 _assets)
    {
        (_shares, _assets) = _completeWithdraw(_receiverAddr);
        emit CompleteWithdraw(_receiverAddr, _assets, _year, _month, _day);
    }

    function _withdraw(
        address _caller,
        address _receiver,
        address _owner,
        uint256 _assets,
        uint256 _shares
    )
        internal override
    {
        if (_caller != _owner) {
            _spendAllowance(_owner, _caller, _shares);
        }
        _burn(_owner, _shares);
        pendingWithdrawAssets[_receiver] += _assets;

        emit WithdrawRequest(_caller, _receiver, _owner, 1, _assets, _shares);
    }

    function _completeWithdraw(
        address _receiverAddr
    )
        internal
        returns (uint256 _shares, uint256 _assets)
    {
        _assets = pendingWithdrawAssets[_receiverAddr];
        require(_assets > 0, "No pending withdraw");
        _shares = convertToShares(_assets);
        pendingWithdrawAssets[_receiverAddr] = 0;
        SafeERC20.safeTransfer(IERC20(asset()), _receiverAddr, _assets);
    }
}
