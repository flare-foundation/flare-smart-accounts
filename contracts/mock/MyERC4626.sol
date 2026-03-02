// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DateUtils} from "./DateUtils.sol";

/// @title Vault
/// @notice This is the vault that is used by MasterAccountController contract only for demo purposes.
contract MyERC4626 is ERC4626 {

    uint256 public constant PERIOD_DURATION = 1 days;

    /// @notice The duration of the time-lock for withdrawals (in seconds).
    uint256 public lagDuration;
    /// @notice The total amount of assets pending withdrawal across all periods.
    uint256 public assetsPendingWithdraw;
    mapping(address receiverAddr => mapping(uint256 period => uint256 assets)) public pendingWithdrawAssets;
    mapping(address receiverAddr => mapping(uint256 period => uint256 shares)) public pendingWithdrawShares;
    mapping(address receiverAddr => mapping(uint256 period => uint256 timestamp)) public requestTimestamps;
    mapping(address receiverAddr => mapping(uint256 period => uint256 lag)) public pendingWithdrawLag;
    mapping (uint256 period => address[] receivers) private uniqueReceivers;
    mapping (address receiverAddr => mapping(uint256 period => uint256 index)) private receiverIndex;

    event Deposit(
        address assetIn,
        uint256 amountIn,
        uint256 shares,
        address indexed senderAddr,
        address indexed receiverAddr
    );

    event WithdrawRequest(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 period,
        uint256 assets,
        uint256 shares
    );

    event CompleteWithdraw(
        address indexed receiver,
        uint256 assets,
        uint256 period
    );

    event WithdrawalRequested(
        uint256 shares,
        address indexed holderAddr,
        address indexed receiverAddr
    );

    event WithdrawalProcessed(
        uint256 assetsAmount,
        address indexed receiverAddr
    );

    error InvalidAsset();
    error NoPendingWithdrawAssets();
    error NoPendingWithdrawShares();
    error InvalidPeriod();
    error TooEarly();
    error LagDurationZero();
    error InvalidReceiver(address receiverAddr, uint256 period);

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
    {
        lagDuration = 1 days;
    }

    /// firelight vault - using redeem + claimWithdraw
    function claimWithdraw(uint256 _period) public returns (uint256 _assets) {
        (uint256 year, uint256 month, uint256 day) = DateUtils.timestampToDate(block.timestamp);
        require(
            _period < _getPeriodFromDate(year, month, day), // cannot claim for current or future periods
            InvalidPeriod()
        );
        (, _assets, ) = _completeWithdraw(msg.sender, _period);
        _deleteReceiver(msg.sender, _period);
        emit CompleteWithdraw(msg.sender, _assets, _period);
    }

    /// upshift vault - multi asset deposit
    function deposit(
        address _assetIn,
        uint256 _amountIn,
        address _receiverAddr
    )
        public
        returns (uint256 _shares)
    {
        require(_assetIn == asset(), InvalidAsset());
        _shares = super.deposit(_amountIn, _receiverAddr);
        emit Deposit(_assetIn, _amountIn, _shares, msg.sender, _receiverAddr);
    }

    /// upshift vault - using requestRedeem + claim
    function requestRedeem(
        uint256 _shares,
        address _receiver
    )
        public
        returns (uint256 _claimableEpoch, uint256 _year, uint256 _month, uint256 _day)
    {
        // msg.sender is owner and receiver is the one who will claim later
        this.redeem(_shares, _receiver, msg.sender);
        // The time slot (cluster) of the lagged withdrawal
        (_year, _month, _day) = DateUtils.timestampToDate(block.timestamp + lagDuration);

        // The withdrawal will be processed at the following epoch
        if (lagDuration < PERIOD_DURATION) {
            // if lag duration is less than the period duration (1 day), claim is pending until the end of lag duration
            _claimableEpoch = block.timestamp + lagDuration;
        } else {
            _claimableEpoch = DateUtils.timestampFromDateTime(_year, _month, _day, 0, 0, 0);
        }
    }

    function claim(
        uint256 _year,
        uint256 _month,
        uint256 _day,
        address _receiverAddr
    )
        public
        returns (uint256 _shares, uint256 _assets)
    {
        // Make sure withdrawals are processed at the expected epoch only.
        require(
            block.timestamp >= DateUtils.timestampFromDateTime(_year, _month, _day, 0, 0, 0),
            TooEarly()
        );
        uint256 period = _getPeriodFromDate(_year, _month, _day);
        _requireLagElapsed(_receiverAddr, period);
        (_shares, _assets, ) = _completeWithdraw(_receiverAddr, period);
        _deleteReceiver(_receiverAddr, period);
        emit WithdrawalProcessed(_assets, _receiverAddr);
    }

    function processAllClaimsByDate(
        uint256 _year,
        uint256 _month,
        uint256 _day,
        uint256 _maxLimit
    )
        public
    {
        require(
            block.timestamp >= DateUtils.timestampFromDateTime(_year, _month, _day, 0, 0, 0),
            TooEarly()
        );
        uint256 period = _getPeriodFromDate(_year, _month, _day);
        uint256 length = uniqueReceivers[period].length;
        uint256 size = Math.min(_maxLimit, length);

        for (uint256 i = length; i > length - size; i--) {
            address receiverAddr = uniqueReceivers[period][i - 1];
            _requireLagElapsed(receiverAddr, period);
            (uint256 _shares, , ) = _completeWithdraw(receiverAddr, period);
            uniqueReceivers[period].pop();
            delete receiverIndex[receiverAddr][period];
            emit WithdrawalProcessed(_shares, receiverAddr);
        }
    }

    /// @notice Sets the lag duration for withdrawals.
    /// @param _lagDuration The new lag duration in seconds.
    function setLagDuration(uint256 _lagDuration) public {
        require(_lagDuration > 0, LagDurationZero());
        lagDuration = _lagDuration;
    }

    function uniqueReceiversLength(
        uint256 _period
    )
        public view
        returns (uint256)
    {
        return uniqueReceivers[_period].length;
    }

    /**
     * @notice Returns the total assets in the vault excluding those marked for withdrawal.
     * @return The total assets held by the vault.
     */
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - assetsPendingWithdraw;
    }

    ////////////////////////// firelight specific functions //////////////////////////

    struct PeriodConfiguration {
        uint48 epoch;
        uint48 duration;
        uint256 startingPeriod;
    }

    /**
     * @notice Returns the period configuration for the current period.
     * @return _periodConfig The period configuration corresponding to the current period.
     */
    function currentPeriodConfiguration()
        public view
        returns (PeriodConfiguration memory _periodConfig)
    {
        _periodConfig.epoch = 0;
        _periodConfig.duration = uint48(PERIOD_DURATION);
        _periodConfig.startingPeriod = 0;
    }

    /**
     * @notice Returns the current active period.
     * @return The current period number since contract deployment.
     */
    function currentPeriod()
        public view
        returns (uint256)
    {
        (uint256 year, uint256 month, uint256 day) = DateUtils.timestampToDate(block.timestamp);
        return _getPeriodFromDate(year, month, day);
    }

    ////////////////////////// upshift specific functions //////////////////////////
    /**
     * @notice Gets the total number of shares to burn at the date specified for a given receiver.
     * @dev This is a forecast on the amount of assets that can be claimed by a given party on the date specified.
     * @param _year The year.
     * @param _month The month.
     * @param _day The day.
     * @param _receiverAddr The address of the receiver.
     * @return _shares The total number of shares to burn at the date specified for a given receiver.
     */
    function getBurnableAmountByReceiver(
        uint256 _year,
        uint256 _month,
        uint256 _day,
        address _receiverAddr
    )
        external view
        returns (uint256 _shares)
    {
        uint256 period = _getPeriodFromDate(_year, _month, _day);
        _shares = pendingWithdrawShares[_receiverAddr][period];
    }

    /**
     * @notice Previews the deposit of a whitelisted asset.
     * @param _assetIn The asset to deposit
     * @param _amountIn The deposit amount
     * @return _shares The equivalent number of shares
     * @return _amountInReferenceTokens The deposit amount expressed in reference tokens
     */
    function previewDeposit(
        address _assetIn,
        uint256 _amountIn
    )
        external view
        returns (uint256 _shares, uint256 _amountInReferenceTokens)
    {
        require(_assetIn == asset(), InvalidAsset());
        _shares = super.previewDeposit(_amountIn);
        _amountInReferenceTokens = _amountIn;
    }

    /**
     * @notice Previews a redemption.
     * @param _shares The number of shares to redeem.
     * @param _isInstant Indicates whether the redemption is lagged or instant.
     * @return _assetsAmount The withdrawal amount without any applicable fees.
     * @return _assetsAfterFee The effective withdrawal amount.
     */
    function previewRedemption(
        uint256 _shares,
        bool _isInstant //solhint-disable no-unused-vars
    )
        external view
        returns (uint256 _assetsAmount, uint256 _assetsAfterFee)
    {
        _assetsAmount = super.previewRedeem(_shares);
        _assetsAfterFee = _assetsAmount;
    }

    /**
     * @notice Returns the current share price.
     * @return The share price.
     */
    function getSharePrice() external view returns (uint256) {
        uint256 shares = 10 ** decimals(); // 1 share
        return convertToAssets(shares);
    }

    /**
     * @notice Returns the address of the LP token.
     * @return The address of the LP token.
     */
    function lpTokenAddress() external view returns (address) {
        return address(this);
    }

    /**
     * @notice Returns total supply (for testing purposes).
     * @return The total supply.
    */
    function getTotalAssets() external view returns (uint256) {
        return totalSupply();
    }

    ////////////////////////// internal methods //////////////////////////
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

        (uint256 year, uint256 month, uint256 day) = DateUtils.timestampToDate(block.timestamp + lagDuration);
        uint256 period = _getPeriodFromDate(year, month, day);

        if (pendingWithdrawAssets[_receiver][period] == 0) {
            uniqueReceivers[period].push(_receiver);
            receiverIndex[_receiver][period] = uniqueReceivers[period].length;
        }

        assetsPendingWithdraw += _assets;
        pendingWithdrawAssets[_receiver][period] += _assets;
        pendingWithdrawShares[_receiver][period] += _shares;
        requestTimestamps[_receiver][period] = block.timestamp;
        pendingWithdrawLag[_receiver][period] = lagDuration;

        emit WithdrawRequest(_caller, _receiver, _owner, period, _assets, _shares);
        emit WithdrawalRequested(_shares, _owner, _receiver);
    }

    function _completeWithdraw(
        address _receiverAddr,
        uint256 _period
    )
        internal
        returns (uint256 _shares, uint256 _assets, uint256 _requestTs)
    {
        _assets = pendingWithdrawAssets[_receiverAddr][_period];
        require(_assets > 0, NoPendingWithdrawAssets());
        _shares = pendingWithdrawShares[_receiverAddr][_period];
        require(_shares > 0, NoPendingWithdrawShares());
        _requestTs = requestTimestamps[_receiverAddr][_period];
        assetsPendingWithdraw -= _assets;
        delete pendingWithdrawAssets[_receiverAddr][_period];
        delete pendingWithdrawShares[_receiverAddr][_period];
        delete requestTimestamps[_receiverAddr][_period];
        delete pendingWithdrawLag[_receiverAddr][_period];
        SafeERC20.safeTransfer(IERC20(asset()), _receiverAddr, _assets);
    }

    function _requireLagElapsed(
        address _receiverAddr,
        uint256 _period
    )
        internal
        view
    {
        uint256 requestTs = requestTimestamps[_receiverAddr][_period];
        uint256 lagAtRequest = pendingWithdrawLag[_receiverAddr][_period];
        if (lagAtRequest < PERIOD_DURATION && lagAtRequest > 0) {
            require(requestTs != 0, TooEarly());
            require(block.timestamp >= requestTs + lagAtRequest, TooEarly());
        }
    }

    function _deleteReceiver(
        address _receiverAddr,
        uint256 _period
    )
        internal
    {
        uint256 index = receiverIndex[_receiverAddr][_period];
        require(index != 0, InvalidReceiver(_receiverAddr, _period));
        uint256 length = uniqueReceivers[_period].length;
        delete receiverIndex[_receiverAddr][_period];
        if (index == length) {
            // remove the last element
            uniqueReceivers[_period].pop();
        } else {
            address lastReceiver = uniqueReceivers[_period][length - 1];
            // move the last element to the removed position
            uniqueReceivers[_period][index - 1] = lastReceiver;
            uniqueReceivers[_period].pop();
            // update moved receiver's index
            receiverIndex[lastReceiver][_period] = index;
        }
    }

    function _getPeriodFromDate(
        uint256 year,
        uint256 month,
        uint256 day
    )
        internal
        pure
        returns (uint256)
    {
        return DateUtils.timestampFromDateTime(year, month, day, 0, 0, 0) / PERIOD_DURATION;
    }
}
