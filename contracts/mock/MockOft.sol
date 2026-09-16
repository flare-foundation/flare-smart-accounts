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
 * adapter does, so tests can assert that the return leg approved and actually transferred the
 * FXRP. It is fee-capable like the deployed FXRP adapters (LayerZero's `Fee` mixin): with
 * `feeBps` set it credits less than it takes and enforces the caller's `minAmountLD`, which is
 * how a send that does not allow for the fee fails.
 */
contract MockOft is IOFT {
    using SafeERC20 for IERC20;

    bytes32 public constant GUID = bytes32(uint256(0xabcdef));

    IERC20 public immutable underlyingToken;
    uint256 public nativeFee;
    /// @notice The adapter's fee in basis points, as the `Fee` mixin's owner may set it.
    uint16 public feeBps;
    uint8 public sharedDecimalsValue = 6;
    /// @notice `OFTCore`'s own `decimalConversionRate`: the granularity a send is truncated to.
    /// One - local and shared representations equal - is what every deployed FXRP OFT answers and
    /// what the configuration guards require, so the send paths below model rate-one sends only.
    /// The deployed fee variants (`OFTFeeUpgradeable` on Ethereum, `OFTAdapterFeeUpgradeable` on
    /// Flare) debit the gross amount, take the fee from it and de-dust the remainder
    /// (`amountSentLD = _amountLD; amountReceivedLD = _removeDust(_amountLD - fee)`), keeping the
    /// dust as fees; at rate one that is exactly what this mock already does.
    uint256 public decimalConversionRate = 1;
    bytes4 public oftInterfaceId = 0x02e49c2c;
    uint64 public oftMessageVersion = 1;
    /// @notice The endpoint this OFT is wired to, as `IOAppCore.endpoint()` reports it.
    address public endpoint;
    mapping(uint32 eid => bytes32 peer) public peers;

    SendParam public lastSendParam;
    uint256 public lastValue;
    address public lastRefundAddress;

    /// @notice The send-time fee check the real endpoint performs (`LZ_InsufficientFee`): a quote
    /// that rose between the caller's `quoteSend` and its `send` fails the send.
    error NativeFeeBelowQuote(uint256 quoted, uint256 provided);


    constructor(
        IERC20 _token,
        uint256 _nativeFee
    ) {
        underlyingToken = _token;
        nativeFee = _nativeFee;
    }

    function setNativeFee(
        uint256 _nativeFee
    )
        external
    {
        nativeFee = _nativeFee;
    }

    function setSharedDecimals(
        uint8 _sharedDecimals
    )
        external
    {
        sharedDecimalsValue = _sharedDecimals;
    }

    /// @notice Skews the conversion rate away from one, as an `OFTCore` subclass constructed with
    /// local decimals that do not match its token does: the decimal answers stay truthful while
    /// the adapter still truncates. It exists for the configuration guards, which refuse such an
    /// adapter; the send paths here do not model truncation.
    function setDecimalConversionRate(
        uint256 _rate
    )
        external
    {
        decimalConversionRate = _rate;
    }

    function setPeer(
        uint32 _eid,
        bytes32 _peer
    )
        external
    {
        peers[_eid] = _peer;
    }

    function setOftVersion(
        bytes4 _interfaceId,
        uint64 _version
    )
        external
    {
        oftInterfaceId = _interfaceId;
        oftMessageVersion = _version;
    }

    function setEndpoint(
        address _endpoint
    )
        external
    {
        endpoint = _endpoint;
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
        // the endpoint charges the live fee, not the one the caller quoted earlier
        require(msg.value >= nativeFee, NativeFeeBelowQuote(nativeFee, msg.value));
        // a fee-capable adapter credits less than it takes, and refuses a send whose signed
        // floor the remainder would not meet
        uint256 received = _receivedFor(_sendParam.amountLD);
        require(
            received >= _sendParam.minAmountLD,
            SlippageExceeded(received, _sendParam.minAmountLD)
        );
        // lock/unlock adapter: pull the tokens from the sender
        underlyingToken.safeTransferFrom(msg.sender, address(this), _sendParam.amountLD);

        lastSendParam = _sendParam;
        lastValue = msg.value;
        lastRefundAddress = _refundAddress;

        return (
            MessagingReceipt({guid: GUID, nonce: 1, fee: MessagingFee(msg.value, 0)}),
            OFTReceipt({amountSentLD: _sendParam.amountLD, amountReceivedLD: received})
        );
    }

    /// @inheritdoc IOFT
    function quoteSend(
        SendParam calldata _sendParam,
        bool
    )
        external view
        returns (MessagingFee memory)
    {
        // the real adapter runs the same slippage check when quoting, so a send that would be
        // refused never reaches `send`
        uint256 received = _receivedFor(_sendParam.amountLD);
        require(
            received >= _sendParam.minAmountLD,
            SlippageExceeded(received, _sendParam.minAmountLD)
        );
        return MessagingFee({nativeFee: nativeFee, lzTokenFee: 0});
    }

    function setFeeBps(
        uint16 _feeBps
    )
        external
    {
        feeBps = _feeBps;
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
    function oftVersion()
        external view
        returns (bytes4, uint64)
    {
        return (oftInterfaceId, oftMessageVersion);
    }

    /// @inheritdoc IOFT
    function quoteOFT(
        SendParam calldata _sendParam
    )
        external view
        returns (OFTLimit memory, OFTFeeDetail[] memory, OFTReceipt memory)
    {
        return (
            OFTLimit({minAmountLD: 0, maxAmountLD: type(uint256).max}),
            new OFTFeeDetail[](0),
            OFTReceipt({
                amountSentLD: _sendParam.amountLD,
                amountReceivedLD: _receivedFor(_sendParam.amountLD)
            })
        );
    }

    /// @dev What the adapter would credit for `_amount`, after its fee.
    function _receivedFor(
        uint256 _amount
    )
        private view
        returns (uint256)
    {
        return _amount - (_amount * feeBps) / 10_000;
    }

    /// @inheritdoc IOFT
    /// @dev The deployed FXRP adapter is a lock/unlock adapter, so it requires approval.
    function approvalRequired()
        external pure
        returns (bool)
    {
        return true;
    }
}
