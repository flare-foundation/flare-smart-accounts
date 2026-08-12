// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IOFT,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    OFTLimit,
    OFTFeeDetail
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

/**
 * @title MockOft
 * @notice Minimal lock/unlock OFT adapter: pulls the token from the sender the way the real
 * adapter does, so tests can assert that the sweep approved and actually transferred the FXRP.
 */
contract MockOft is IOFT {
    using SafeERC20 for IERC20;

    bytes32 public constant GUID = bytes32(uint256(0xabcdef));

    IERC20 public immutable underlyingToken;
    uint256 public nativeFee;
    uint8 public sharedDecimalsValue = 6;
    mapping(uint32 eid => bytes32 peer) public peers;

    SendParam public lastSendParam;
    uint256 public lastValue;
    address public lastRefundAddress;

    constructor(IERC20 _token, uint256 _nativeFee) {
        underlyingToken = _token;
        nativeFee = _nativeFee;
    }

    function setNativeFee(uint256 _nativeFee) external {
        nativeFee = _nativeFee;
    }

    function setSharedDecimals(uint8 _sharedDecimals) external {
        sharedDecimalsValue = _sharedDecimals;
    }

    function setPeer(uint32 _eid, bytes32 _peer) external {
        peers[_eid] = _peer;
    }

    /// @inheritdoc IOFT
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata,
        address _refundAddress
    )
        external payable
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        // lock/unlock adapter: pull the tokens from the sender
        underlyingToken.safeTransferFrom(msg.sender, address(this), _sendParam.amountLD);

        lastSendParam = _sendParam;
        lastValue = msg.value;
        lastRefundAddress = _refundAddress;

        return (
            MessagingReceipt({guid: GUID, nonce: 1, fee: MessagingFee(msg.value, 0)}),
            OFTReceipt({amountSentLD: _sendParam.amountLD, amountReceivedLD: _sendParam.amountLD})
        );
    }

    /// @inheritdoc IOFT
    function quoteSend(
        SendParam calldata,
        bool
    )
        external view
        returns (MessagingFee memory)
    {
        return MessagingFee({nativeFee: nativeFee, lzTokenFee: 0});
    }

    /// @inheritdoc IOFT
    function token()
        external view
        returns (address)
    {
        return address(underlyingToken);
    }

    /// @inheritdoc IOFT
    /// @dev Defaults to 6, matching FXRP, so nothing is lost to shared-decimal dust.
    function sharedDecimals()
        external view
        returns (uint8)
    {
        return sharedDecimalsValue;
    }

    /// @inheritdoc IOFT
    function quoteOFT(
        SendParam calldata _sendParam
    )
        external pure
        returns (OFTLimit memory, OFTFeeDetail[] memory, OFTReceipt memory)
    {
        return (
            OFTLimit({minAmountLD: 0, maxAmountLD: type(uint256).max}),
            new OFTFeeDetail[](0),
            OFTReceipt({amountSentLD: _sendParam.amountLD, amountReceivedLD: _sendParam.amountLD})
        );
    }

    /// @inheritdoc IOFT
    /// @dev The deployed FXRP adapter is a lock/unlock adapter, so it requires approval.
    function approvalRequired()
        external pure
        returns (bool)
    {
        return true;
    }

    /// @inheritdoc IOFT
    function oftVersion()
        external pure
        returns (bytes4, uint64)
    {
        return (0x02e49c2c, 1);
    }
}
