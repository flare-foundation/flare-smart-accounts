// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";


library Vault {

    function deposit(
        IIPersonalAccount _personalAccount,
        address _vault,
        uint256 _amount
    )
        internal
    {
        uint256 shares = _personalAccount.deposit(_vault, _amount);
        emit IMasterAccountController.Deposited(
            address(_personalAccount),
            _vault,
            _amount,
            shares
        );
    }

    function redeem(
        IIPersonalAccount _personalAccount,
        address _vault,
        uint256 _shares
    )
        internal
    {
        uint256 amount = _personalAccount.redeem(_vault, _shares);
        emit IMasterAccountController.Redeemed(
            address(_personalAccount),
            _vault,
            _shares,
            amount
        );
    }

    function claimWithdrawal(
        IIPersonalAccount _personalAccount,
        address _vault,
        uint256 _period
    )
        internal
        returns (uint256 _amount)
    {
        _amount = _personalAccount.claimWithdraw(_vault, _period);
        emit IMasterAccountController.WithdrawalClaimed(
            address(_personalAccount),
            _vault,
            _period,
            _amount
        );
    }

    function requestRedeem(
        IIPersonalAccount _personalAccount,
        address _vault,
        uint256 _shares
    )
        internal
    {
        (uint256 amount, uint256 claimableEpoch) = _personalAccount.requestRedeem(_vault, _shares);
        emit IMasterAccountController.RedeemRequested(
            address(_personalAccount),
            _vault,
            _shares,
            amount,
            claimableEpoch
        );
    }

    function claim(
        IIPersonalAccount _personalAccount,
        address _vault,
        uint256 _date
    )
        internal
        returns (uint256)
    {
        (uint256 year, uint256 month, uint256 day) = _getDate(_date);
        (uint256 shares, uint256 amount) = _personalAccount.claim(_vault, year, month, day);
        emit IMasterAccountController.Claimed(
            address(_personalAccount),
            _vault,
            year,
            month,
            day,
            shares,
            amount
        );
        return amount;
    }

    function _getDate(
        uint256 _value
    )
        internal pure
        returns (uint256 _year, uint256 _month, uint256 _day)
    {
        _year = (_value / 10000) % 10000;
        _month = (_value / 100) % 100;
        _day = _value % 100;
    }
}
