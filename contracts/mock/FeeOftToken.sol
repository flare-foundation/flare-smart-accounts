// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Fee} from "@layerzerolabs/oft-evm/contracts/Fee.sol";

/**
 * @title FeeOftToken
 * @notice The mint/burn end of the FXRP route, using LayerZero's `OFT` and `Fee`.
 * @dev The debit bodies reproduce the verified Ethereum `OFTFeeUpgradeable` implementation:
 * retain the fee in this token contract and burn only the net. Ordinary storage replaces its
 * namespaced fee balance; the fixture omits upgrade and fee-withdrawal machinery. Minting is
 * available only through the vendored receive path, never through an open test-only mint.
 */
contract FeeOftToken is OFT, Fee {

    uint256 public feeBalance;

    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    )
        Ownable(msg.sender)
        OFT(_name, _symbol, _lzEndpoint, _delegate)
    {
    }

    function decimals()
        public pure override
        returns (uint8)
    {
        return 6;
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
                uint256 fee = amountSentLD - amountReceivedLD;
                feeBalance += fee;
                _transfer(_from, address(this), fee);
            }
        }
        _burn(_from, amountReceivedLD);
    }

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
