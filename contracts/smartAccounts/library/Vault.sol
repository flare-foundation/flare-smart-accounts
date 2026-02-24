// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";

library Vault {

    function deposit(
        IIPersonalAccount _personalAccount,
        uint256 _vaultType,
        address _vault,
        uint256 _amount
    )
        internal
    {
        uint256 shares = _personalAccount.deposit(_vaultType, _vault, _amount);
        emit IInstructionsFacet.Deposited(
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
        emit IInstructionsFacet.Redeemed(
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
        emit IInstructionsFacet.WithdrawalClaimed(
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
        (uint256 claimableEpoch, uint256 year, uint256 month, uint256 day) =
            _personalAccount.requestRedeem(_vault, _shares);
        emit IInstructionsFacet.RedeemRequested(
            address(_personalAccount),
            _vault,
            _shares,
            claimableEpoch,
            year,
            month,
            day
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
        (uint256 year, uint256 month, uint256 day) = getDate(_date);
        (uint256 shares, uint256 amount) = _personalAccount.claim(_vault, year, month, day);
        emit IInstructionsFacet.Claimed(
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

    function getDate(
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
