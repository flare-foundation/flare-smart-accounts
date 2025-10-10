// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AvailableAgentInfo.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IFirelightVault} from "../interface/IFirelightVault.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";

/// @title Personal Account contract
/// @notice Account controlled by MasterAccountController contract. It corresponds to an XRPL address.
contract PersonalAccount is
    IIPersonalAccount,
    UUPSUpgradeable,
    ReentrancyGuard
{
    /// @notice MasterAccountController contract address
    address public controllerAddress;
    /// @notice XRPL address
    string public xrplOwner;

    modifier onlyController() {
        require(msg.sender == controllerAddress, OnlyController());
        _;
    }

    constructor() {}

    /**
     * Proxyable initialization method. Can be called only once, from the proxy constructor
     */
    function initialize(
        string memory _xrplOwner,
        address _controllerAddress
    )
        external
    {
        require(controllerAddress == address(0), AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        require(bytes(_xrplOwner).length > 0, InvalidXrplOwner());

        xrplOwner = _xrplOwner;
        controllerAddress = _controllerAddress;
    }

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
        uint256 totalFee = collateralReservationFee + _executorFee;
        require(msg.value >= totalFee, InsufficientFundsForCollateralReservation(collateralReservationFee));

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
    {
        require(msg.value >= _executorFee, InsufficientFundsForRedeemExecutor());
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        assetManager.redeem{value: msg.value}(_lots, xrplOwner, _executor);
        emit Redeemed(_lots, _executor, _executorFee);
    }

    /// @inheritdoc IIPersonalAccount
    function deposit(
        uint256 _amount,
        address _vault
    )
        external onlyController nonReentrant
    {
        address fxrp = IFirelightVault(_vault).asset();
        require(IERC20(fxrp).approve(_vault, _amount), ApprovalFailed());
        emit Approved(fxrp, _vault, _amount);

        uint256 shares = IFirelightVault(_vault).deposit(_amount, address(this));
        emit Deposited(_vault, _amount, shares);
    }

    /// @inheritdoc IIPersonalAccount
    function withdraw(
        uint256 _amount,
        address _vault
    )
        external onlyController nonReentrant
    {
        uint256 shares = IFirelightVault(_vault).withdraw(_amount, address(this), address(this));
        emit Withdrawn(_vault, _amount, shares);
    }

    /// @inheritdoc IIPersonalAccount
    function claimWithdraw(
        uint256 _period,
        address _vault
    )
        external onlyController nonReentrant
    {
        uint256 amount = IFirelightVault(_vault).claimWithdraw(_period);
        emit WithdrawalClaimed(_vault, _period, amount);
    }

    /// @inheritdoc IPersonalAccount
    function implementation()
        external view
        returns (address)
    {
        return ERC1967Utils.getImplementation();
    }

    /*
     * @inheritdoc UUPSUpgradeable
     * @dev Only the controller can call upgrade functions.
     */
    function _authorizeUpgrade(address _newImplementation) internal override onlyController {}
}
