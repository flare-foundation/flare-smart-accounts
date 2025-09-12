// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC4626} from "@openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

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

    /// @notice constructor
    /// @param baseAsset base asset address - FXRP
    /// @param name_ base asset name
    /// @param symbol_ base asset symbol
    constructor(
        IERC20 baseAsset,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(baseAsset) {}

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    function claimWithdraw(uint256 _period) public returns (uint256 assets) {
        assets = pendingWithdrawAssets[msg.sender];
        require(assets > 0, "No pending withdraw");
        pendingWithdrawAssets[msg.sender] = 0;
        SafeERC20.safeTransfer(IERC20(asset()), msg.sender, assets);
        emit CompleteWithdraw(msg.sender, assets, _period);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);
        pendingWithdrawAssets[owner] += assets;

        emit WithdrawRequest(caller, receiver, owner, 1, assets, shares);
    }
}
