// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/coston2/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/coston2/data/AvailableAgentInfo.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// TODO - update flare-periphery to coston2

/// @title Personal Account contract
/// @notice Account controlled by MasterAccountController contract. It corresponds to an XRPL address.
contract PersonalAccount is IIPersonalAccount, UUPSUpgradeable, ReentrancyGuard {
    /// @dev Initialization flag
    bool private initialised;
    /// @notice MasterAccountController contract address
    address public controllerAddress;
    /// @notice Ripple address
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
        external virtual
    {
        require(!initialised, AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        require(bytes(_xrplOwner).length > 0, InvalidXrplOwner());

        xrplOwner = _xrplOwner;
        controllerAddress = _controllerAddress;
        initialised = true;
    }

    /// @inheritdoc IIPersonalAccount
    function deposit(uint256 _amount, address _vault) external onlyController nonReentrant {
        uint256 actualAmount = ERC4626(_vault).mint(_amount, address(this));
        emit Deposited(_vault, _amount, actualAmount);
        // require(amount == actualAmount, "Deposited != amount requested");
        // TODO that will not always be true, as ERC4626.mint can return less than requested due to rounding?
    }

    /// @inheritdoc IIPersonalAccount
    function withdraw(uint256 _amount, address _vault) external onlyController nonReentrant {
        uint256 actualAmount = ERC4626(_vault).withdraw(
            _amount,
            address(this),
            address(this)
        );
        emit Withdrawn(_vault, _amount, actualAmount);
    }

    /// @inheritdoc IIPersonalAccount
    function approve(uint256 _amount, address _fxrp, address _vault) external onlyController nonReentrant {
        require(IERC20(_fxrp).approve(_vault, _amount), ApprovalFailed());
        emit Approved(_fxrp, _vault, _amount);
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
        IAssetManager assetManager = _getFxrpAssetManager();
        assetManager.redeem{value: _executorFee} (
            _lots,
            xrplOwner,
            _executor
        );
        // require(redeemedAmount == amount, "Failed to fully redeem");
        emit Redeemed(_lots, _executor, _executorFee);
    }

    /// @inheritdoc IIPersonalAccount
    function reserveCollateral(
        uint256 _lots,
        address _agentVault,
        address payable _executor,
        uint256 _executorFee
    ) external payable onlyController nonReentrant {
        IAssetManager assetManager = _getFxrpAssetManager();

        AgentInfo.Info memory agentInfo = assetManager.getAgentInfo(
            _agentVault
        );
        require(agentInfo.status == AgentInfo.Status.NORMAL, AgentNotAvailable());

        uint256 collateralReservationFee = assetManager
            .collateralReservationFee(_lots);
        uint256 totalFee = collateralReservationFee + _executorFee;
        require(msg.value >= totalFee, InsufficientFundsForCollateralReservation(collateralReservationFee));
        uint256 reservationId = assetManager.reserveCollateral{
            value: collateralReservationFee + _executorFee
        } (_agentVault, _lots, agentInfo.feeBIPS, _executor);
        assert(reservationId > 0);
        emit CollateralReserved(_lots, _agentVault, _executor, _executorFee, reservationId);
    }

    /////////////////////////////// UUPS UPGRADABLE ///////////////////////////////
    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /**
     * @inheritdoc UUPSUpgradeable
     * @dev Only governance can call this method.
     */
    function upgradeToAndCall(address newImplementation, bytes memory data)
        public payable override
        onlyProxy
        onlyController
    {
        super.upgradeToAndCall(newImplementation, data);
    }

    /**
     * Unused. Present just to satisfy UUPSUpgradeable requirement.
     * The real check is in onlyController modifier on upgradeToAndCall.
     */
    function _authorizeUpgrade(address newImplementation) internal override {}

    /////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////
    function _getFxrpAssetManager() internal view returns (IAssetManager) {
        address assetManagerAddress = ContractRegistry.getContractAddressByName("AssetManagerFXRP");
        IAssetManager assetManager = IAssetManager(assetManagerAddress);
        require(address(assetManager) != address(0), FxrpAssetManagerNotSet());
        return assetManager;
    }
}
