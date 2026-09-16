// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MessagingComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/MessagingComposer.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {
    MessagingParams,
    MessagingReceipt,
    MessagingFee,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";

/**
 * @title RelayLzEndpoint
 * @notice The endpoint half a two-chain test needs, built on LayerZero's own `MessagingComposer`
 * so the compose queue's rules are the real ones. It adds only what an OApp's send path touches -
 * `setDelegate`, `quote`, `send` - and records each outbound packet so a test can hand it to the
 * far endpoint's {deliver}, which invokes the receiver exactly as the real endpoint does.
 * @dev The GUID is computed with the canonical {GUID.generate} from the true packet header, so a
 * receiver that recomputes it (every compose receiver in this repository does) validates against
 * a real one. Verification, message libraries, executors and fee quoting are deliberately absent:
 * this models delivery, not consensus, and a test drives delivery itself. `deliverFrom` reads the
 * actual source record; successful receives cannot repeat, and a failed receive is retryable.
 * The explicit `deliver` entry point allows test injection but checks the complete packet header.
 */
contract RelayLzEndpoint is MessagingComposer {

    /// @dev `sender`, `dstEid` and `nonce` fill one slot exactly.
    struct Packet {
        address sender;
        uint32 dstEid;
        uint64 nonce;
        bytes32 receiver;
        bytes32 guid;
        bytes message;
        bytes options;
    }

    /// @notice This endpoint's own chain id, as `IMessagingChannel.eid()` reports it.
    uint32 public immutable eid;
    /// @notice The flat fee `quote` returns and `send` demands.
    uint256 public nativeFee;

    mapping(address oapp => address delegate) public delegates;
    mapping(address sender => mapping(uint32 dstEid => mapping(bytes32 receiver => uint64 nonce)))
        public outboundNonce;
    mapping(bytes32 guid => bool received) public received;

    Packet[] private packets;

    error NativeFeeBelowQuote(uint256 quoted, uint256 provided);
    error InvalidPacketHeader();
    error PacketAlreadyReceived(bytes32 guid);

    constructor(
        uint32 _eid,
        uint256 _nativeFee
    )
    {
        eid = _eid;
        nativeFee = _nativeFee;
    }

    function setNativeFee(
        uint256 _nativeFee
    )
        external
    {
        nativeFee = _nativeFee;
    }

    /// @notice `OAppCore`'s constructor calls this; nothing here reads it back.
    function setDelegate(
        address _delegate
    )
        external
    {
        delegates[msg.sender] = _delegate;
    }

    /// @notice Records the packet the sending OApp built and returns the receipt it expects.
    function send(
        MessagingParams calldata _params,
        address /* _refundAddress */
    )
        external payable
        returns (MessagingReceipt memory)
    {
        require(msg.value >= nativeFee, NativeFeeBelowQuote(nativeFee, msg.value));
        uint64 nonce = ++outboundNonce[msg.sender][_params.dstEid][_params.receiver];
        bytes32 guid = GUID.generate(nonce, eid, msg.sender, _params.dstEid, _params.receiver);
        packets.push(
            Packet({
                sender: msg.sender,
                dstEid: _params.dstEid,
                receiver: _params.receiver,
                message: _params.message,
                options: _params.options,
                guid: guid,
                nonce: nonce
            })
        );
        return MessagingReceipt({
            guid: guid,
            nonce: nonce,
            fee: MessagingFee({nativeFee: nativeFee, lzTokenFee: 0})
        });
    }

    /// @notice Delivers a packet this endpoint's counterpart recorded, as the real endpoint does:
    /// the receiver sees this endpoint as `msg.sender` and the true origin in `_origin`.
    function deliver(
        uint32 _srcEid,
        address _srcSender,
        address _receiver,
        Packet calldata _packet
    )
        external payable
    {
        require(_srcSender == _packet.sender, InvalidPacketHeader());
        require(bytes32(uint256(uint160(_receiver))) == _packet.receiver, InvalidPacketHeader());
        _deliver(_srcEid, _packet);
    }

    /// @notice Uses the source's recorded sender, receiver, payload and nonce without rebuilding them.
    function deliverFrom(
        RelayLzEndpoint _source,
        uint256 _index
    )
        external payable
    {
        _deliver(_source.eid(), _source.packetAt(_index));
    }

    function quote(
        MessagingParams calldata /* _params */,
        address /* _sender */
    )
        external view
        returns (MessagingFee memory)
    {
        return MessagingFee({nativeFee: nativeFee, lzTokenFee: 0});
    }

    function packetCount()
        external view
        returns (uint256)
    {
        return packets.length;
    }

    function packetAt(
        uint256 _index
    )
        external view
        returns (Packet memory)
    {
        return packets[_index];
    }

    function _deliver(
        uint32 _srcEid,
        Packet memory _packet
    )
        private
    {
        address receiver = address(uint160(uint256(_packet.receiver)));
        require(
            _packet.dstEid == eid && bytes32(uint256(uint160(receiver))) == _packet.receiver
                && _packet.guid == GUID.generate(
                    _packet.nonce, _srcEid, _packet.sender, eid, _packet.receiver
                ),
            InvalidPacketHeader()
        );
        require(!received[_packet.guid], PacketAlreadyReceived(_packet.guid));
        received[_packet.guid] = true;
        ILayerZeroReceiver(receiver).lzReceive{value: msg.value}(
            Origin({
                srcEid: _srcEid,
                sender: bytes32(uint256(uint160(_packet.sender))),
                nonce: _packet.nonce
            }),
            _packet.guid,
            _packet.message,
            msg.sender,
            ""
        );
    }

}
