// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AvailableAgentInfo.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IIVault} from "../interface/IIVault.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";
import {UniswapV3} from "../library/UniswapV3.sol";

/**
 * @title PersonalAccount contract
 * @notice Account controlled by MasterAccountController contract. It corresponds to an XRPL address.
 */
contract PersonalAccount is IIPersonalAccount, ReentrancyGuard {

    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;

    /// @notice MasterAccountController contract address
    address public controllerAddress;
    /// @notice XRPL address
    string public xrplOwner;

    modifier onlyController() {
        require(msg.sender == controllerAddress, OnlyController());
        _;
    }

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controllerAddress = EMPTY_ADDRESS;
    }

    /**
     * Proxyable initialization method. Can be called only once, from the proxy constructor
     * @param _controllerAddress MasterAccountController contract address
     * @param _xrplOwner XRPL address owner
     * @dev initialize is callable once by anyone (proxy constructor in practice)
     */
    function initialize(
        address _controllerAddress,
        string calldata _xrplOwner
    ) external {
        require(controllerAddress == address(0), AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        require(bytes(_xrplOwner).length > 0, InvalidXrplOwner());

        controllerAddress = _controllerAddress;
        xrplOwner = _xrplOwner;
    }

    /// @inheritdoc IIPersonalAccount
    function reserveCollateral(
        address _agentVault,
        uint256 _lots,
        address payable _executor,
        uint256 _executorFee
    )
        external payable
        onlyController nonReentrant
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
            _agentVault,
            _lots,
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
        external payable
        onlyController nonReentrant
        returns (uint256 _amount)
    {
        require(msg.value >= _executorFee, InsufficientFundsForRedeem(_executorFee));
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        _amount = assetManager.redeem{value: msg.value}(
            _lots,
            xrplOwner,
            _executor
        );
        emit Redeemed(_lots, _amount, _executor, _executorFee);
    }

    /// @inheritdoc IIPersonalAccount
    function deposit(
        address _vault,
        uint256 _assets
    )
        external
        onlyController nonReentrant
        returns (uint256 _shares)
    {
        address fxrp = IIVault(_vault).asset();
        require(IERC20(fxrp).approve(_vault, _assets), ApprovalFailed());
        emit Approved(fxrp, _vault, _assets);

        _shares = IIVault(_vault).deposit(_assets, address(this));
        emit Deposited(_vault, _assets, _shares);
    }

    /// @inheritdoc IIPersonalAccount
    function withdraw(
        address _vault,
        uint256 _assets
    )
        external
        onlyController nonReentrant
        returns (uint256 _shares)
    {
        _shares = IIVault(_vault).withdraw(
            _assets,
            address(this),
            address(this)
        );
        emit Withdrawn(_vault, _assets, _shares);
    }

    /// @inheritdoc IIPersonalAccount
    function claimWithdraw(
        address _vault,
        uint256 _period
    )
        external
        onlyController nonReentrant
        returns (uint256 _assets)
    {
        _assets = IIVault(_vault).claimWithdraw(_period);
        emit WithdrawalClaimed(_vault, _period, _assets);
    }

    /// @inheritdoc IIPersonalAccount
    function requestRedeem(
        address _vault,
        uint256 _shares
    )
        external
        onlyController nonReentrant
        returns (uint256 _assets, uint256 _claimableEpoch)
    {
        (_assets, _claimableEpoch) = IIVault(_vault).requestRedeem(
            _shares,
            address(this),
            address(this)
        );
        emit RedeemRequested(_vault, _shares, _assets, _claimableEpoch);
    }

    /// @inheritdoc IIPersonalAccount
    function claim(
        address _vault,
        uint256 _year,
        uint256 _month,
        uint256 _day
    )
        external
        onlyController nonReentrant
        returns (uint256 _shares, uint256 _assets)
    {
        (_shares, _assets) = IIVault(_vault).claim(
            _year,
            _month,
            _day,
            address(this)
        );
        emit Claimed(_vault, _year, _month, _day, _shares, _assets);
    }

    /// @inheritdoc IIPersonalAccount
    function executeSwap(
        address _uniswapV3Router,
        address _tokenIn,
        bytes21 _tokenInFeedId,
        address _tokenOut,
        bytes21 _tokenOutFeedId,
        uint24 _poolFeeTierPPM,
        uint24 _maxSlippagePPM
    )
        external
        onlyController nonReentrant
        returns (uint256 amountIn, uint256 amountOut)
    {
        (amountIn, amountOut) = UniswapV3.executeSwap(
            _uniswapV3Router,
            _tokenIn,
            _tokenInFeedId,
            _tokenOut,
            _tokenOutFeedId,
            _poolFeeTierPPM,
            _maxSlippagePPM
        );
        emit SwapExecuted(_tokenIn, _tokenOut, amountIn, amountOut);
    }

    /// @inheritdoc IPersonalAccount
    function implementation() external view returns (address) {
        // controller is the beacon
        return IBeacon(controllerAddress).implementation();
    }
}
