// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {ExecutorOptions} from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/ExecutorOptions.sol";
import {PersonalAccountRemote} from "../../contracts/smartAccounts/implementation/PersonalAccountRemote.sol";
import {MasterAccountController} from "../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IIMasterAccountController} from "../../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {IDiamond} from "../../contracts/diamond/interfaces/IDiamond.sol";
import {DiamondArgs} from "../../contracts/diamond/implementation/Diamond.sol";
import {PersonalAccountsFacet} from "../../contracts/smartAccounts/facets/PersonalAccountsFacet.sol";
import {ComposeTransportFacet} from "../../contracts/smartAccounts/facets/ComposeTransportFacet.sol";
import {PauseFacet} from "../../contracts/smartAccounts/facets/PauseFacet.sol";
import {IPersonalAccountRemote, PA_ACTION_EXECUTE} from "../../contracts/userInterfaces/IPersonalAccountRemote.sol";
import {
    IComposeReceiverAccountBase,
    PAYLOAD_VERSION_1
} from "../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";
import {IComposeTransportFacet} from "../../contracts/userInterfaces/facets/IComposeTransportFacet.sol";
import {IIComposeTransportFacet} from "../../contracts/smartAccounts/interface/IIComposeTransportFacet.sol";
import {FeeOftAdapter} from "../../contracts/mock/FeeOftAdapter.sol";
import {FeeOftToken} from "../../contracts/mock/FeeOftToken.sol";
import {MintableERC20} from "../../contracts/mock/MintableERC20.sol";
import {RelayLzEndpoint} from "../../contracts/mock/RelayLzEndpoint.sol";
import {RelayLzExecutor} from "../../contracts/mock/RelayLzExecutor.sol";
import {FacetsDeploy} from "../utils/FacetsDeploy.t.sol";

/**
 * @title PersonalAccountRemoteOftFundingTest
 * @notice Native drops reach a real frozen Personal Account proxy, and receive gas/value are
 * independent from compose gas/value. Token credit and compose use the actual OFT implementations.
 * @dev The source twin is represented by pranking its address into the source OFT's send, so this
 * suite covers destination behavior, not Flare instruction authentication. The executor driver
 * decodes canonical options but does not model live quoting, service scheduling or gas pricing.
 * Gas amounts here distinguish successful and deliberately starved calls, not production presets.
 */
contract PersonalAccountRemoteOftFundingTest is FacetsDeploy {

    uint32 private constant ORIGIN_EID = 30295;
    uint32 private constant DESTINATION_EID = 30101;
    uint128 private constant DROP = 0.05 ether;
    uint128 private constant RECEIVE_GAS = 700_000;
    uint128 private constant COMPOSE_GAS = 900_000;
    uint256 private constant CREDIT = 1e6;
    bytes32 private constant OPERATION_ID = keccak256("native funding operation");

    MintableERC20 private homeToken;
    FeeOftAdapter private homeAdapter;
    FeeOftToken private remoteToken;
    RelayLzEndpoint private homeEndpoint;
    RelayLzEndpoint private remoteEndpoint;
    RelayLzExecutor private delivery;
    PersonalAccountRemote private personalAccount;
    IIMasterAccountController private controller;
    address private recipient;

    function setUp() public {
        vm.deal(address(this), 100 ether);
        _deployController();
        homeEndpoint = new RelayLzEndpoint(ORIGIN_EID, 0);
        remoteEndpoint = new RelayLzEndpoint(DESTINATION_EID, 0);
        homeToken = new MintableERC20("FXRP", "FXRP", 6);
        homeAdapter = new FeeOftAdapter(address(homeToken), address(homeEndpoint), address(this));
        remoteToken = new FeeOftToken("FXRP", "FXRP", address(remoteEndpoint), address(this));
        homeAdapter.setPeer(DESTINATION_EID, bytes32(uint256(uint160(address(remoteToken)))));
        remoteToken.setPeer(ORIGIN_EID, bytes32(uint256(uint160(address(homeAdapter)))));
        delivery = new RelayLzExecutor();

        PersonalAccountRemote implementation = new PersonalAccountRemote();
        controller.setPersonalAccountImplementation(address(implementation));
        personalAccount = PersonalAccountRemote(payable(controller.createPersonalAccount("rNativeDropRecipient")));
        IIComposeTransportFacet(address(controller)).setComposeTransport(
            IComposeTransportFacet.Transport(
                address(remoteEndpoint),
                address(remoteToken),
                ORIGIN_EID,
                bytes32(uint256(uint160(address(homeAdapter))))
            )
        );
        recipient = makeAddr("native call recipient");
        assertEq(address(personalAccount).balance, 0);
        assertEq(personalAccount.implementation(), address(implementation));
    }

    function testNativeDropFundsTheRealProxyAndItsAuthenticatedValueCall() public {
        bytes memory options = _options(RECEIVE_GAS, 0, COMPOSE_GAS, 0, DROP);
        _send(options, DROP);
        RelayLzEndpoint.Packet memory packet = homeEndpoint.packetAt(0);

        delivery.nativeDrop{value: DROP}(packet.options, 100_000);
        assertEq(address(personalAccount).balance, DROP);
        assertEq(address(remoteToken).balance, 0);
        bytes memory message = _receivePacket(0);
        assertEq(remoteToken.balanceOf(address(personalAccount)), CREDIT);

        _compose(packet, message, 0);
        assertEq(recipient.balance, DROP, "the signed call spends the native drop");
        assertEq(address(personalAccount).balance, 0);
        assertTrue(personalAccount.usedOperations(OPERATION_ID));
        _assertQueue(packet.guid, bytes32(uint256(1)));
    }

    function testReceiveValueFundsTheOftAndCannotFundThePersonalAccountCall() public {
        _send(_options(RECEIVE_GAS, DROP, COMPOSE_GAS, 0, 0), DROP);
        RelayLzEndpoint.Packet memory packet = homeEndpoint.packetAt(0);
        bytes memory message = _receivePacket(DROP);
        assertEq(address(remoteToken).balance, DROP, "receive value stays at the receiving OFT");
        assertEq(address(personalAccount).balance, 0);
        assertEq(remoteToken.balanceOf(address(personalAccount)), CREDIT);

        vm.expectRevert(abi.encodeWithSelector(IPersonalAccountRemote.CallFailed.selector, 0, bytes("")));
        _compose(packet, message, 0);
        assertFalse(personalAccount.usedOperations(OPERATION_ID));
        _assertQueue(packet.guid, keccak256(message));

        // A later ordinary transfer funds the account; retry consumes the original compose,
        // without repeating receive or crediting the token for a second time.
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = address(personalAccount).call{value: DROP}("");
        assertTrue(success);
        _compose(packet, message, 0);
        assertEq(recipient.balance, DROP);
        assertEq(remoteToken.balanceOf(address(personalAccount)), CREDIT);
        assertEq(address(remoteToken).balance, DROP);
    }

    function testComposeValueIsRejectedAndZeroValueRetryConsumesTheQueuedCall() public {
        _send(_options(RECEIVE_GAS, 0, COMPOSE_GAS, DROP, 0), 0);
        RelayLzEndpoint.Packet memory packet = homeEndpoint.packetAt(0);
        bytes memory message = _receivePacket(0);

        vm.expectRevert(IComposeReceiverAccountBase.NonZeroComposeValue.selector);
        _compose(packet, message, DROP);
        assertFalse(personalAccount.usedOperations(OPERATION_ID));
        assertEq(address(personalAccount).balance, 0);
        assertEq(address(delivery).balance, 0, "the failed compose refunds its caller atomically");
        assertEq(address(remoteToken).balance, 0);
        _assertQueue(packet.guid, keccak256(message));

        // The endpoint permits a manual retry with different execution funding: options are
        // executor instructions, not an endpoint requirement to attach the mistaken value.
        remoteEndpoint.lzCompose(address(remoteToken), address(personalAccount), packet.guid, 0, message, "");
        assertTrue(personalAccount.usedOperations(OPERATION_ID));
        _assertQueue(packet.guid, bytes32(uint256(1)));
    }

    function testExtraComposeGasCannotRescueAStarvedReceiveAndReceiveCanRetry() public {
        _send(_options(100, 0, 2_000_000, 0, 0), 0);
        RelayLzEndpoint.Packet memory packet = homeEndpoint.packetAt(0);

        vm.expectRevert(bytes(""));
        delivery.deliverReceive(remoteEndpoint, homeEndpoint, 0);
        assertFalse(remoteEndpoint.received(packet.guid));
        assertEq(remoteToken.balanceOf(address(personalAccount)), 0);
        _assertQueue(packet.guid, bytes32(0));

        vm.recordLogs();
        remoteEndpoint.deliverFrom(homeEndpoint, 0);
        bytes memory message = _composeMessage(vm.getRecordedLogs());
        assertTrue(remoteEndpoint.received(packet.guid));
        assertEq(remoteToken.balanceOf(address(personalAccount)), CREDIT);
        _compose(packet, message, 0);
        assertTrue(personalAccount.usedOperations(OPERATION_ID));
    }

    function testExtraReceiveGasCannotRescueAStarvedComposeAndCreditAndDropSurvive() public {
        _send(_options(2_000_000, 0, 100, 0, DROP), DROP);
        RelayLzEndpoint.Packet memory packet = homeEndpoint.packetAt(0);
        delivery.nativeDrop{value: DROP}(packet.options, 100_000);
        bytes memory message = _receivePacket(0);

        vm.expectRevert(bytes(""));
        _compose(packet, message, 0);
        assertTrue(remoteEndpoint.received(packet.guid));
        assertFalse(personalAccount.usedOperations(OPERATION_ID));
        assertEq(remoteToken.balanceOf(address(personalAccount)), CREDIT);
        assertEq(address(personalAccount).balance, DROP);
        assertEq(recipient.balance, 0);
        _assertQueue(packet.guid, keccak256(message));

        remoteEndpoint.lzCompose(address(remoteToken), address(personalAccount), packet.guid, 0, message, "");
        assertEq(recipient.balance, DROP);
        assertEq(remoteToken.balanceOf(address(personalAccount)), CREDIT);
        assertTrue(personalAccount.usedOperations(OPERATION_ID));
        _assertQueue(packet.guid, bytes32(uint256(1)));
    }

    function _send(
        bytes memory _optionsValue,
        uint256 _callValue
    )
        private
    {
        IPersonalAccountRemote.Call[] memory calls = new IPersonalAccountRemote.Call[](1);
        calls[0] = IPersonalAccountRemote.Call(recipient, _callValue, "");
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            PA_ACTION_EXECUTE,
            abi.encode(OPERATION_ID, uint64(vm.getBlockTimestamp() + 1 hours), calls)
        );
        homeToken.mint(address(personalAccount), CREDIT);
        vm.startPrank(address(personalAccount));
        homeToken.approve(address(homeAdapter), CREDIT);
        // solhint-disable-next-line check-send-result
        homeAdapter.send(
            SendParam({
                dstEid: DESTINATION_EID,
                to: bytes32(uint256(uint160(address(personalAccount)))),
                amountLD: CREDIT,
                minAmountLD: CREDIT,
                extraOptions: _optionsValue,
                composeMsg: payload,
                oftCmd: ""
            }),
            MessagingFee(0, 0),
            address(personalAccount)
        );
        vm.stopPrank();
    }

    function _deployController() private {
        controller = IIMasterAccountController(address(new MasterAccountController(
            deployBaseFacets(), DiamondArgs(address(this), address(0), "")
        )));
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](3);
        cuts[0] = _buildFacetCut(
            address(new PersonalAccountsFacet()), "PersonalAccountsFacet", IDiamond.FacetCutAction.Add
        );
        cuts[1] = _buildFacetCut(address(new PauseFacet()), "PauseFacet", IDiamond.FacetCutAction.Add);
        cuts[2] = _buildFacetCut(
            address(new ComposeTransportFacet()), "ComposeTransportFacet", IDiamond.FacetCutAction.Add
        );
        controller.diamondCut(cuts, address(0), "");
    }

    function _receivePacket(
        uint256 _value
    )
        private
        returns (bytes memory)
    {
        vm.recordLogs();
        delivery.deliverReceive{value: _value}(remoteEndpoint, homeEndpoint, 0);
        return _composeMessage(vm.getRecordedLogs());
    }

    function _compose(
        RelayLzEndpoint.Packet memory _packet,
        bytes memory _message,
        uint256 _value
    )
        private
    {
        delivery.deliverCompose{value: _value}(
            remoteEndpoint,
            address(remoteToken),
            address(personalAccount),
            _packet.guid,
            _message,
            _packet.options
        );
    }

    function _assertQueue(
        bytes32 _guid,
        bytes32 _expected
    )
        private view
    {
        assertEq(
            remoteEndpoint.composeQueue(address(remoteToken), address(personalAccount), _guid, 0),
            _expected
        );
    }

    function _options(
        uint128 _receiveGas,
        uint128 _receiveValue,
        uint128 _composeGas,
        uint128 _composeValue,
        uint128 _drop
    )
        private view
        returns (bytes memory _result)
    {
        _result = abi.encodePacked(
            uint16(3),
            _option(1, ExecutorOptions.encodeLzReceiveOption(_receiveGas, _receiveValue)),
            _option(3, ExecutorOptions.encodeLzComposeOption(0, _composeGas, _composeValue))
        );
        if (_drop > 0) {
            _result = abi.encodePacked(
                _result,
                _option(
                    2,
                    ExecutorOptions.encodeNativeDropOption(_drop, bytes32(uint256(uint160(address(personalAccount)))))
                )
            );
        }
    }

    function _composeMessage(
        Vm.Log[] memory _logs
    )
        private view
        returns (bytes memory _message)
    {
        bytes32 composeSent = keccak256("ComposeSent(address,address,bytes32,uint16,bytes)");
        for (uint256 i = 0; i < _logs.length; i++) {
            if (_logs[i].emitter == address(remoteEndpoint) && _logs[i].topics[0] == composeSent) {
                (address from, address to,,, bytes memory message) =
                    abi.decode(_logs[i].data, (address, address, bytes32, uint16, bytes));
                assertEq(from, address(remoteToken));
                assertEq(to, address(personalAccount));
                return message;
            }
        }
        revert("no compose message");
    }

    function _option(
        uint8 _kind,
        bytes memory _body
    )
        private pure
        returns (bytes memory)
    {
        return abi.encodePacked(uint8(1), uint16(_body.length + 1), _kind, _body);
    }
}
