// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DateUtils} from "./DateUtils.sol";

/// @title Vault
/// @notice This is the vault that is used by MasterAccountController contract only for demo purposes.
contract MyERC4626 is ERC4626 {

    /// @notice The duration of the time-lock for withdrawals (in seconds).
    uint256 public lagDuration;

    mapping(address receiverAddr => mapping(uint256 period => uint256 assets)) public pendingWithdrawAssets;
    mapping(address receiverAddr => mapping(uint256 period => uint256 shares)) public pendingWithdrawShares;
    mapping(address receiverAddr => mapping(uint256 period => uint256 timestamp)) public requestTimestamps;

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
        address ownerAddr,
        address receiverAddr,
        uint256 shares,
        uint256 assets,
        uint256 fee,
        uint256 year,
        uint256 month,
        uint256 day
    );

    event WithdrawalProcessed(
        uint256 assetsAmount,
        uint256 processedOn,
        address receiverAddr,
        uint256 requestedOn,
        bool wasBlacklisted
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
    {
    }

    /// firelight vault - using redeem + claimWithdraw
    function claimWithdraw(uint256 _period) public returns (uint256 _assets) {
        if (lagDuration > 0) {
            (uint256 year, uint256 month, uint256 day) = DateUtils.timestampToDate(block.timestamp + lagDuration);
            require(
                _getPeriodFromDate(year, month, day) > _period,
                "Too early"
            );
        }
        (, _assets, ) = _completeWithdraw(msg.sender, _period);
        emit CompleteWithdraw(msg.sender, _assets, _period);
    }

    /// upshift vault - using requestRedeem + claim
    function requestRedeem(
        uint256 _shares,
        address _receiver,
        address _owner
    )
        public
        returns (uint256 _assets, uint256 _claimableEpoch)
    {
        _assets = redeem(_shares, _receiver, _owner);
        // The time slot (cluster) of the lagged withdrawal
        (uint256 year, uint256 month, uint256 day) = DateUtils.timestampToDate(block.timestamp + lagDuration);

        // The withdrawal will be processed at the following epoch
        _claimableEpoch = DateUtils.timestampFromDateTime(year, month, day, 0, 0, 0);

        if (lagDuration == 0) {
            _claimableEpoch = block.timestamp;
            claim(year, month, day, _receiver);
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
        if (lagDuration > 0) {
            // Make sure withdrawals are processed at the expected epoch only.
            require(
                block.timestamp >= DateUtils.timestampFromDateTime(_year, _month, _day, 0, 0, 0),
                "Too early"
            );
        }
        uint256 period = _getPeriodFromDate(_year, _month, _day);
        uint256 requestTs;
        (_shares, _assets, requestTs) = _completeWithdraw(_receiverAddr, period);
        emit WithdrawalProcessed(_assets, block.timestamp, _receiverAddr, requestTs, false);
    }

    /// @notice Sets the lag duration for withdrawals.
    /// @param _lagDuration The new lag duration in seconds.
    function setLagDuration(uint256 _lagDuration) public {
        lagDuration = _lagDuration;
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

        (uint256 year, uint256 month, uint256 day) = DateUtils.timestampToDate(block.timestamp + lagDuration);
        uint256 period = _getPeriodFromDate(year, month, day);

        pendingWithdrawAssets[_receiver][period] += _assets;
        pendingWithdrawShares[_receiver][period] += _shares;
        requestTimestamps[_receiver][period] = block.timestamp;

        emit WithdrawRequest(_caller, _receiver, _owner, period, _assets, _shares);
        emit WithdrawalRequested(_owner, _receiver, _shares, _assets, 0, year, month, day);
    }

    function _completeWithdraw(
        address _receiverAddr,
        uint256 _period
    )
        internal
        returns (uint256 _shares, uint256 _assets, uint256 _requestTs)
    {
        _assets = pendingWithdrawAssets[_receiverAddr][_period];
        require(_assets > 0, "No pending withdraw");
        _shares = pendingWithdrawShares[_receiverAddr][_period];
        require(_shares > 0, "No pending withdraw shares");
        _requestTs = requestTimestamps[_receiverAddr][_period];
        delete pendingWithdrawAssets[_receiverAddr][_period];
        delete pendingWithdrawShares[_receiverAddr][_period];
        delete requestTimestamps[_receiverAddr][_period];
        SafeERC20.safeTransfer(IERC20(asset()), _receiverAddr, _assets);
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
        return DateUtils.timestampFromDateTime(year, month, day, 0, 0, 0) / 1 days;
    }
}
