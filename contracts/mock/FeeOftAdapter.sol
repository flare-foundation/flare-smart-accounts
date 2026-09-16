// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {Fee} from "@layerzerolabs/oft-evm/contracts/Fee.sol";

/**
 * @title FeeOftAdapter
 * @notice The lock/unlock end of the FXRP route, using LayerZero's `OFTAdapter` and `Fee`.
 * @dev The debit overrides reproduce `OFTAdapterFeeUpgradeable` from the verified Flare
 * implementation, with ordinary storage for the fee balance. The gross amount is locked and
 * its fee is removed before rounding the net.
 * Packet encoding, receiving, credit and compose encoding are the vendored implementations.
 * This fixture does not model the deployed proxy, its upgrade authority or fee withdrawal.
 *
 * `Ownable(msg.sender)` is passed explicitly because the vendored LayerZero contracts were
 * written against OpenZeppelin v4's no-argument `Ownable`, while this repository builds with v5.
 */
contract FeeOftAdapter is OFTAdapter, Fee {

    using SafeERC20 for IERC20;

    uint256 public feeBalance;

    constructor(
        address _token,
        address _lzEndpoint,
        address _delegate
    )
        Ownable(msg.sender)
        OFTAdapter(_token, _lzEndpoint, _delegate)
    {
    }

    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    )
        internal override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);
        if (amountSentLD > amountReceivedLD) {
            unchecked {
                feeBalance += amountSentLD - amountReceivedLD;
            }
        }
        innerToken.safeTransferFrom(_from, address(this), amountSentLD);
    }

    /// @dev The deployed fee variants' own body, comment included.
    function _debitView(
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    )
        internal view override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        amountSentLD = _amountLD;

        // @dev Apply the fee, then de-dust the amount afterwards.
        // This means the fee is taken from the amount before the dust is removed.
        uint256 fee = getFee(_dstEid, _amountLD);
        unchecked {
            amountReceivedLD = _removeDust(_amountLD - fee);
        }

        if (amountReceivedLD < _minAmountLD) {
            revert IOFT.SlippageExceeded(amountReceivedLD, _minAmountLD);
        }
    }
}
