// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AvailableAgentInfo.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {ERC1967Utils} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IFirelightVault} from "../interface/IFirelightVault.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";
import {PersonalAccountBase} from "./PersonalAccountBase.sol";

/// @title PersonalAccount contract
/// @notice Account controlled by MasterAccountController contract. It corresponds to an XRPL address.
contract PersonalAccount is
    IIPersonalAccount,
    PersonalAccountBase,
    ReentrancyGuard
{

    /// @inheritdoc IIPersonalAccount
    function reserveCollateral(
        uint256 _lots,
        address _agentVault,
        address payable _executor,
        uint256 _executorFee
    )
        external payable onlyController nonReentrant
        returns (uint256 _collateralReservationId)
    {
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();

        // Check agent vault status
        AgentInfo.Info memory agentInfo = assetManager.getAgentInfo(_agentVault);
        require(agentInfo.status == AgentInfo.Status.NORMAL, AgentNotAvailable());

        // Check fees
        uint256 collateralReservationFee = assetManager.collateralReservationFee(_lots);
        require(
            msg.value >= collateralReservationFee + _executorFee,
            InsufficientFundsForCollateralReservation(collateralReservationFee, _executorFee)
        );

        // Reserve collateral
        _collateralReservationId = assetManager.reserveCollateral{value: msg.value}(
            _agentVault,
            _lots,
            agentInfo.feeBIPS,
            _executor
        );
        assert(_collateralReservationId > 0);
        emit CollateralReserved(
            _lots,
            _agentVault,
            _executor,
            _executorFee,
            _collateralReservationId
        );
    }

    /// @inheritdoc IIPersonalAccount
    function redeem(
        uint256 _lots,
        address payable _executor,
        uint256 _executorFee
    )
        external payable onlyController nonReentrant
        returns (uint256 _amount)
    {
        require(msg.value >= _executorFee, InsufficientFundsForRedeem(_executorFee));
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        _amount = assetManager.redeem{value: msg.value}(_lots, xrplOwner, _executor);
        emit Redeemed(_lots, _amount, _executor, _executorFee);
    }

    /// @inheritdoc IIPersonalAccount
    function deposit(
        uint256 _amount,
        address _vault
    )
        external onlyController nonReentrant
        returns (uint256 _shares)
    {
        address fxrp = IFirelightVault(_vault).asset();
        require(IERC20(fxrp).approve(_vault, _amount), ApprovalFailed());
        emit Approved(fxrp, _vault, _amount);

        _shares = IFirelightVault(_vault).deposit(_amount, address(this));
        emit Deposited(_vault, _amount, _shares);
    }

    /// @inheritdoc IIPersonalAccount
    function withdraw(
        uint256 _amount,
        address _vault
    )
        external onlyController nonReentrant
        returns (uint256 _shares)
    {
        _shares = IFirelightVault(_vault).withdraw(_amount, address(this), address(this));
        emit Withdrawn(_vault, _amount, _shares);
    }

    /// @inheritdoc IIPersonalAccount
    function claimWithdraw(
        uint256 _period,
        address _vault
    )
        external onlyController nonReentrant
        returns (uint256 _amount)
    {
        _amount = IFirelightVault(_vault).claimWithdraw(_period);
        emit WithdrawalClaimed(_vault, _period, _amount);
    }
}
