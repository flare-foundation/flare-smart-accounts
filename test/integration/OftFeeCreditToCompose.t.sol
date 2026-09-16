// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOFT, SendParam, MessagingFee, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {
    MessagingParams,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {MintableERC20} from "../../contracts/mock/MintableERC20.sol";
import {FeeOftToken} from "../../contracts/mock/FeeOftToken.sol";
import {FeeOftAdapter} from "../../contracts/mock/FeeOftAdapter.sol";
import {RelayLzEndpoint} from "../../contracts/mock/RelayLzEndpoint.sol";
import {PAYLOAD_VERSION_1} from "../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";
import {ACTION_DEPOSIT_COLLATERAL} from "../../contracts/userInterfaces/ILoanSubaccount.sol";
import {ACTION_REDEEM_HOME} from "../../contracts/userInterfaces/ILoanSubaccount.sol";

/**
 * @title OftFeeCreditToComposeTest
 * @notice The bridge link the account suites take as given: what a fee-capable OFT debits, what it
 * credits on the far side, and what that credit becomes inside the compose message. Both ends here
 * use a lock/unlock adapter at home and a mint/burn OFT remotely. Their debit overrides follow
 * the verified fee variants; packet creation, receiving, credit, encoding and compose queue are
 * LayerZero implementations. Endpoint verification is simulated by relaying recorded packets.
 * Nothing here hand-builds a delivered packet or credits the remote token directly.
 *
 * This is the transport half of the evidence. The account half - what each action does with the
 * authenticated amount - stays in the unit and adversarial suites, which build the same packet by
 * hand; {testTheRealPacketIsByteIdenticalToTheHandBuiltForm} is what ties the two together, so
 * those suites are testing the real wire format rather than an assumed one.
 */
contract OftFeeCreditToComposeTest is Test {

    uint32 private constant HOME_EID = 30295;
    uint32 private constant REMOTE_EID = 30101;
    uint256 private constant NATIVE_FEE = 0.01 ether;
    /// @dev 1% in basis points, the shape the deployed adapters' `Fee` mixin takes.
    uint16 private constant ONE_PERCENT_BPS = 100;
    uint256 private constant GROSS = 100e6;
    uint256 private constant NET = 99e6;

    MintableERC20 private homeToken;
    RelayLzEndpoint private homeEndpoint;
    RelayLzEndpoint private remoteEndpoint;
    FeeOftAdapter private homeOft;
    FeeOftToken private remoteOft;

    address private account;

    // the vendored codec takes `bytes calldata`, so the reads go through external calls rather
    // than being reimplemented here - the decoding stays LayerZero's
    function amountLD(
        bytes calldata _message
    )
        external pure
        returns (uint256)
    {
        return OFTComposeMsgCodec.amountLD(_message);
    }

    function composeFrom(
        bytes calldata _message
    )
        external pure
        returns (bytes32)
    {
        return OFTComposeMsgCodec.composeFrom(_message);
    }

    function srcEid(
        bytes calldata _message
    )
        external pure
        returns (uint32)
    {
        return OFTComposeMsgCodec.srcEid(_message);
    }

    function innerPayload(
        bytes calldata _message
    )
        external pure
        returns (bytes memory)
    {
        return OFTComposeMsgCodec.composeMsg(_message);
    }

    function setUp() public {
        // FXRP is 6 decimals on every chain, which is what makes the conversion rate one
        homeToken = new MintableERC20("FXRP", "FXRP", 6);
        homeEndpoint = new RelayLzEndpoint(HOME_EID, NATIVE_FEE);
        remoteEndpoint = new RelayLzEndpoint(REMOTE_EID, NATIVE_FEE);
        homeOft = new FeeOftAdapter(address(homeToken), address(homeEndpoint), address(this));
        remoteOft = new FeeOftToken("FXRP", "FXRP", address(remoteEndpoint), address(this));
        homeOft.setPeer(REMOTE_EID, bytes32(uint256(uint160(address(remoteOft)))));
        remoteOft.setPeer(HOME_EID, bytes32(uint256(uint160(address(homeOft)))));

        // the subaccount has the same address on both chains, so one stand-in serves as sender and
        // recipient; it only has to hold and approve the token
        account = makeAddr("subaccount");
        homeToken.mint(account, 1_000e6);
        vm.deal(account, 10 ether);
    }

    /// The whole chain in one test: 100 requested with a 1% fee leaves 100, arrives as 99, and the
    /// compose message the receiving OFT queues carries exactly that 99.
    function testAFeeBearingSendCreditsTheNetAmountAndComposesThatSameNumber() public {
        homeOft.setDefaultFeeBps(ONE_PERCENT_BPS);
        bytes memory payload = _depositPayload();

        uint256 accountBefore = homeToken.balanceOf(account);
        uint256 adapterBefore = homeToken.balanceOf(address(homeOft));
        uint256 remoteBefore = remoteOft.balanceOf(account);

        OFTReceipt memory receipt = _send(homeOft, REMOTE_EID, GROSS, NET, payload);

        // the source debits the GROSS amount and reports the net as what will arrive
        assertEq(receipt.amountSentLD, GROSS, "the gross amount is what leaves");
        assertEq(receipt.amountReceivedLD, NET, "the net amount is what is promised");
        assertEq(accountBefore - homeToken.balanceOf(account), GROSS, "the sender paid gross");
        assertEq(
            homeToken.balanceOf(address(homeOft)) - adapterBefore,
            GROSS,
            "the adapter holds the gross, fee included"
        );

        // deliver the packet the source endpoint recorded, and read what the far side did
        bytes memory composeMsg = _relayHomeToRemote(0);
        assertEq(homeOft.feeBalance(), GROSS - NET);
        assertEq(remoteOft.totalSupply(), NET, "credit minted the net on the token side");
        assertEq(remoteOft.decimalConversionRate(), 1);
        assertFalse(remoteOft.approvalRequired());

        assertEq(
            remoteOft.balanceOf(account) - remoteBefore,
            NET,
            "the destination credited exactly the net amount"
        );
        assertEq(
            this.amountLD(composeMsg),
            NET,
            "the compose message carries the credited amount, not the requested one"
        );
        assertEq(
            this.composeFrom(composeMsg),
            bytes32(uint256(uint160(account))),
            "and the source-chain sender, which is what the receiver authenticates"
        );
        assertEq(this.srcEid(composeMsg), HOME_EID, "tagged with the origin chain");
        assertEq(
            this.innerPayload(composeMsg),
            payload,
            "the payload rides through untouched"
        );
    }

    /// The signed floor is the boundary, and it is exact: 99 passes, 100 does not.
    function testTheSignedFloorIsExactAtTheNetAmount() public {
        homeOft.setDefaultFeeBps(ONE_PERCENT_BPS);

        // one unit above what the fee leaves is refused, by the real `_debitView`
        _sendExpectingSlippage(homeOft, REMOTE_EID, GROSS, NET + 1, NET);

        // and the whole amount back - the rule this release replaced - is refused too
        _sendExpectingSlippage(homeOft, REMOTE_EID, GROSS, GROSS, NET);

        // exactly the net amount goes through
        OFTReceipt memory receipt = _send(homeOft, REMOTE_EID, GROSS, NET, _depositPayload());
        assertEq(receipt.amountReceivedLD, NET);
    }

    /// A refused send moves nothing and queues nothing - the revert is atomic at the source.
    function testARefusedSendDebitsNothingAndQueuesNoPacket() public {
        homeOft.setDefaultFeeBps(ONE_PERCENT_BPS);
        uint256 accountBefore = homeToken.balanceOf(account);
        uint256 adapterBefore = homeToken.balanceOf(address(homeOft));

        _sendExpectingSlippage(homeOft, REMOTE_EID, GROSS, GROSS, NET);

        assertEq(homeToken.balanceOf(account), accountBefore, "the sender kept its tokens");
        assertEq(homeToken.balanceOf(address(homeOft)), adapterBefore, "the adapter took nothing");
        assertEq(homeEndpoint.packetCount(), 0, "and no packet was recorded");
        assertEq(homeOft.feeBalance(), 0);
        assertEq(homeEndpoint.outboundNonce(address(homeOft), REMOTE_EID, _remotePeer()), 0);
    }

    /// The return leg, with the fee on the other adapter: the withdraw's bridge-back credits the
    /// net on the home chain and composes the redeem-home action against that same number.
    function testTheReturnLegCreditsTheNetAndComposesTheRedeemHomeAction() public {
        // Seed the remote balance through the real home lock and remote mint.
        _send(homeOft, REMOTE_EID, GROSS, GROSS, _depositPayload());
        _relayHomeToRemote(0);
        remoteOft.setDefaultFeeBps(ONE_PERCENT_BPS);
        bytes memory payload = _redeemHomePayload();

        uint256 homeBefore = homeToken.balanceOf(account);
        OFTReceipt memory receipt = _send(remoteOft, HOME_EID, GROSS, NET, payload);
        assertEq(receipt.amountSentLD, GROSS);
        assertEq(receipt.amountReceivedLD, NET);

        bytes memory composeMsg = _relayRemoteToHome(0);

        assertEq(
            homeToken.balanceOf(account) - homeBefore,
            NET,
            "the home chain credited the net withdrawal"
        );
        assertEq(
            this.amountLD(composeMsg),
            NET,
            "and the compose carries that net credit, never the gross"
        );
        (uint8 version, uint8 action, ) =
            abi.decode(this.innerPayload(composeMsg), (uint8, uint8, bytes));
        assertEq(version, PAYLOAD_VERSION_1);
        assertEq(action, ACTION_REDEEM_HOME);
        assertEq(this.srcEid(composeMsg), REMOTE_EID);
        assertEq(remoteOft.balanceOf(account), 0, "the remote sender paid gross");
        assertEq(remoteOft.feeBalance(), GROSS - NET, "the remote fee was retained");
        assertEq(remoteOft.balanceOf(address(remoteOft)), GROSS - NET);
        assertEq(remoteOft.totalSupply(), GROSS - NET, "only the bridged net was burned");
        assertEq(homeToken.balanceOf(address(homeOft)), GROSS - NET, "retained tokens stay backed");
    }

    function testTheReturnFloorRefusesBeforeBurningOrRetainingFees() public {
        _send(homeOft, REMOTE_EID, GROSS, GROSS, _depositPayload());
        _relayHomeToRemote(0);
        remoteOft.setDefaultFeeBps(ONE_PERCENT_BPS);

        _sendExpectingSlippage(remoteOft, HOME_EID, GROSS, NET + 1, NET);
        assertEq(remoteOft.balanceOf(account), GROSS);
        assertEq(remoteOft.totalSupply(), GROSS);
        assertEq(remoteOft.feeBalance(), 0);
        assertEq(remoteOft.balanceOf(address(remoteOft)), 0);
        assertEq(remoteEndpoint.packetCount(), 0);
    }

    /// With no default fee or destination override configured, gross and net coincide.
    function testWithoutAFeeTheGrossAndNetCoincide() public {
        bytes memory payload = _depositPayload();
        OFTReceipt memory receipt = _send(homeOft, REMOTE_EID, GROSS, GROSS, payload);
        assertEq(receipt.amountSentLD, GROSS);
        assertEq(receipt.amountReceivedLD, GROSS, "no fee, so the full amount is promised");

        bytes memory composeMsg = _relayHomeToRemote(0);
        assertEq(this.amountLD(composeMsg), GROSS);
    }

    /// The tie to every other suite. The unit and adversarial tests build their compose packets by
    /// hand; this asserts the real OFT produces those exact bytes and that exact GUID for the same
    /// inputs, so what they authenticate against is the real wire format.
    function testTheRealPacketIsByteIdenticalToTheHandBuiltForm() public {
        homeOft.setDefaultFeeBps(ONE_PERCENT_BPS);
        bytes memory payload = _depositPayload();
        _send(homeOft, REMOTE_EID, GROSS, NET, payload);

        RelayLzEndpoint.Packet memory packet = homeEndpoint.packetAt(0);
        bytes memory composeMsg = _relayHomeToRemote(0);

        // Independent wire layout: uint64 nonce, uint32 source, uint256 credit, sender, payload.
        bytes memory expectedMessage = abi.encodePacked(
            packet.nonce, HOME_EID, NET, bytes32(uint256(uint160(account))), payload
        );
        assertEq(composeMsg, expectedMessage, "the hand-built compose encoding is the real one");

        bytes32 expectedGuid = keccak256(abi.encodePacked(
            packet.nonce, HOME_EID, bytes32(uint256(uint160(address(homeOft)))),
            REMOTE_EID, bytes32(uint256(uint160(address(remoteOft))))
        ));
        assertEq(packet.guid, expectedGuid, "and so is the hand-built GUID");
    }

    function testReceiveFailureDoesNotCreditOrQueueAndTheSamePacketCanRetry() public {
        homeOft.setDefaultFeeBps(ONE_PERCENT_BPS);
        _send(homeOft, REMOTE_EID, GROSS, NET, _depositPayload());
        RelayLzEndpoint.Packet memory packet = homeEndpoint.packetAt(0);
        remoteOft.setPeer(HOME_EID, bytes32(uint256(1)));

        vm.expectRevert(abi.encodeWithSelector(
            IOAppCore.OnlyPeer.selector, HOME_EID, bytes32(uint256(uint160(address(homeOft))))
        ));
        remoteEndpoint.deliverFrom(homeEndpoint, 0);
        assertFalse(remoteEndpoint.received(packet.guid));
        assertEq(remoteOft.totalSupply(), 0, "failed receive minted nothing");
        assertEq(remoteEndpoint.composeQueue(address(remoteOft), account, packet.guid, 0), bytes32(0));
        assertEq(homeToken.balanceOf(account), 1_000e6 - GROSS, "source send is already final");

        remoteOft.setPeer(HOME_EID, bytes32(uint256(uint160(address(homeOft)))));
        _relayHomeToRemote(0);
        assertEq(remoteOft.balanceOf(account), NET);
        assertEq(homeEndpoint.packetCount(), 1, "retry sends no new source packet");
    }

    function testUnlockFailureCanRetryWithoutBurningAgain() public {
        _send(homeOft, REMOTE_EID, GROSS, GROSS, _depositPayload());
        _relayHomeToRemote(0);
        _send(remoteOft, HOME_EID, GROSS, GROSS, _redeemHomePayload());
        RelayLzEndpoint.Packet memory packet = remoteEndpoint.packetAt(0);
        // Simulate missing lock-side backing: the real token transfer, not the relay, must refuse.
        homeToken.burn(address(homeOft), GROSS);
        vm.expectRevert(abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientBalance.selector, address(homeOft), 0, GROSS
        ));
        homeEndpoint.deliverFrom(remoteEndpoint, 0);
        assertFalse(homeEndpoint.received(packet.guid));
        assertEq(homeEndpoint.composeQueue(address(homeOft), account, packet.guid, 0), bytes32(0));
        assertEq(remoteOft.totalSupply(), 0, "the source already burned the net");

        homeToken.mint(address(homeOft), GROSS);
        _relayRemoteToHome(0);
        assertEq(homeToken.balanceOf(account), 1_000e6);
        assertEq(remoteEndpoint.packetCount(), 1);
        assertEq(remoteOft.totalSupply(), 0);
    }

    function testDeliveredReceiveCannotCreditTheSamePacketTwice() public {
        _send(homeOft, REMOTE_EID, GROSS, GROSS, _depositPayload());
        bytes memory message = _relayHomeToRemote(0);
        RelayLzEndpoint.Packet memory packet = homeEndpoint.packetAt(0);
        vm.expectRevert(abi.encodeWithSelector(RelayLzEndpoint.PacketAlreadyReceived.selector, packet.guid));
        remoteEndpoint.deliverFrom(homeEndpoint, 0);
        assertEq(remoteOft.balanceOf(account), GROSS);
        assertEq(remoteOft.totalSupply(), GROSS);
        assertEq(remoteEndpoint.composeQueue(address(remoteOft), account, packet.guid, 0), keccak256(message));
    }

    function testRelayRejectsInconsistentPacketHeader() public {
        _send(homeOft, REMOTE_EID, GROSS, GROSS, _depositPayload());
        RelayLzEndpoint.Packet memory packet = homeEndpoint.packetAt(0);
        vm.expectRevert(RelayLzEndpoint.InvalidPacketHeader.selector);
        remoteEndpoint.deliver(HOME_EID, account, address(remoteOft), packet);
        vm.expectRevert(RelayLzEndpoint.InvalidPacketHeader.selector);
        remoteEndpoint.deliver(HOME_EID, address(homeOft), account, packet);
        vm.expectRevert(RelayLzEndpoint.InvalidPacketHeader.selector);
        remoteEndpoint.deliver(HOME_EID + 1, address(homeOft), address(remoteOft), packet);
        assertEq(remoteOft.totalSupply(), 0);
    }

    function testRelayNoncesBelongToEachSenderAndReceiverChannel() public {
        vm.deal(address(this), 1 ether);
        bytes32 receiver = _remotePeer();
        MessagingParams memory params = MessagingParams(REMOTE_EID, receiver, "", "", false);
        // A packet from another OApp cannot advance this adapter's channel.
        _recordEndpointSend(params);
        _send(homeOft, REMOTE_EID, GROSS, GROSS, _depositPayload());
        assertEq(homeEndpoint.packetAt(0).nonce, 1);
        assertEq(homeEndpoint.packetAt(1).nonce, 1);
        params.receiver = bytes32(uint256(2));
        _recordEndpointSend(params);
        assertEq(homeEndpoint.packetAt(2).nonce, 1, "another receiver opens another channel");
        params.receiver = receiver;
        _recordEndpointSend(params);
        assertEq(homeEndpoint.packetAt(3).nonce, 2);
        assertEq(homeEndpoint.outboundNonce(address(homeOft), REMOTE_EID, receiver), 1);
    }


    function _recordEndpointSend(
        MessagingParams memory _params
    )
        private
    {
        // The endpoint method returns a receipt; it is not address.send.
        // solhint-disable-next-line check-send-result
        MessagingReceipt memory receipt = homeEndpoint.send{value: NATIVE_FEE}(_params, address(this));
        assertEq(receipt.guid, homeEndpoint.packetAt(homeEndpoint.packetCount() - 1).guid);
    }

    function _send(
        IOFT _oft,
        uint32 _dstEid,
        uint256 _amount,
        uint256 _minAmount,
        bytes memory _payload
    )
        private
        returns (OFTReceipt memory _receipt)
    {
        _approve(_oft, _amount);
        vm.prank(account);
        // this is the OFT's `send`, not address.send - it reverts on failure and returns receipts
        // solhint-disable-next-line check-send-result
        (, _receipt) = _oft.send{value: NATIVE_FEE}(
            _sendParam(_dstEid, _amount, _minAmount, _payload),
            MessagingFee({nativeFee: NATIVE_FEE, lzTokenFee: 0}),
            account
        );
    }

    /// @dev The approval is a separate step so a revert expectation can sit on `send` itself
    /// rather than being consumed by the approval before it.
    function _approve(
        IOFT _oft,
        uint256 _amount
    )
        private
    {
        if (!_oft.approvalRequired()) {
            return;
        }
        // resolve the token before the prank: an external read in the argument list would
        // consume it, and the approval would then come from this test rather than the account
        address tokenAddress = _oft.token();
        vm.prank(account);
        IERC20(tokenAddress).approve(address(_oft), _amount);
    }

    function _sendExpectingSlippage(
        IOFT _oft,
        uint32 _dstEid,
        uint256 _amount,
        uint256 _minAmount,
        uint256 _received
    )
        private
    {
        _approve(_oft, _amount);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(IOFT.SlippageExceeded.selector, _received, _minAmount)
        );
        // solhint-disable-next-line check-send-result
        _oft.send{value: NATIVE_FEE}(
            _sendParam(_dstEid, _amount, _minAmount, _depositPayload()),
            MessagingFee({nativeFee: NATIVE_FEE, lzTokenFee: 0}),
            account
        );
    }

    /// @dev Delivers the recorded packet to the far OFT through the far endpoint and returns the
    /// compose message that OFT queued, read back from the real compose queue.
    function _relayHomeToRemote(
        uint256 _index
    )
        private
        returns (bytes memory)
    {
        return _relay(homeEndpoint, remoteEndpoint, homeOft, remoteOft, HOME_EID, _index);
    }

    function _relayRemoteToHome(
        uint256 _index
    )
        private
        returns (bytes memory)
    {
        return _relay(remoteEndpoint, homeEndpoint, remoteOft, homeOft, REMOTE_EID, _index);
    }

    function _relay(
        RelayLzEndpoint _source,
        RelayLzEndpoint _destination,
        IOFT _sourceOft,
        IOFT _destinationOft,
        uint32 _srcEid,
        uint256 _index
    )
        private
        returns (bytes memory _composeMsg)
    {
        RelayLzEndpoint.Packet memory packet = _source.packetAt(_index);
        vm.recordLogs();
        assertEq(_source.eid(), _srcEid);
        assertEq(packet.sender, address(_sourceOft));
        _destination.deliverFrom(_source, _index);
        // the compose message is whatever the receiving OFT handed its own endpoint, taken from
        // the canonical `ComposeSent` event rather than rebuilt here
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 composeSent = keccak256("ComposeSent(address,address,bytes32,uint16,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == composeSent) {
                assertEq(logs[i].emitter, address(_destination), "the receiving endpoint queued it");
                (address from, address to, bytes32 guid, uint16 index, bytes memory message) =
                    abi.decode(logs[i].data, (address, address, bytes32, uint16, bytes));
                assertEq(from, address(_destinationOft));
                assertEq(to, account);
                assertEq(guid, packet.guid);
                assertEq(index, 0);
                assertEq(_destination.composeQueue(from, to, guid, index), keccak256(message));
                assertTrue(_destination.received(guid));
                return message;
            }
        }
        revert("no compose message was queued");
    }

    function _sendParam(
        uint32 _dstEid,
        uint256 _amount,
        uint256 _minAmount,
        bytes memory _payload
    )
        private view
        returns (SendParam memory)
    {
        return SendParam({
            dstEid: _dstEid,
            to: bytes32(uint256(uint160(account))),
            amountLD: _amount,
            minAmountLD: _minAmount,
            extraOptions: "",
            composeMsg: _payload,
            oftCmd: ""
        });
    }

    function _redeemHomePayload()
        private pure
        returns (bytes memory)
    {
        return abi.encode(PAYLOAD_VERSION_1, ACTION_REDEEM_HOME, bytes(""));
    }
    function _remotePeer()
        private view
        returns (bytes32)
    {
        return bytes32(uint256(uint160(address(remoteOft))));
    }

    function _depositPayload()
        private pure
        returns (bytes memory)
    {
        return abi.encode(PAYLOAD_VERSION_1, ACTION_DEPOSIT_COLLATERAL, bytes(""));
    }


}
