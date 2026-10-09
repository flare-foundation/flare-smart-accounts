// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOFT, SendParam, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {
    MessagingFee,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";
import {IMessagingComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessagingComposer.sol";
import {IMessagingChannel} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessagingChannel.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {LoanForkFixture} from "../utils/LoanForkFixture.sol";
import {MockLzEndpoint} from "../../contracts/mock/MockLzEndpoint.sol";
import {MockOft} from "../../contracts/mock/MockOft.sol";
import {ACTION_WITHDRAW, ACTION_REDEEM_HOME} from "../../contracts/userInterfaces/ILoanSubaccount.sol";
import {PAYLOAD_VERSION_1} from "../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";

/**
 * @title LoanDeliveryGasForkTest
 * @notice Part C, item 3 of the runbook: the gas each loan action takes when LayerZero delivers it
 * on Ethereum, measured on a mainnet fork rather than estimated. Everything on the delivery path is
 * the deployed contract: the endpoint, the FXRP OFT, Morpho, the market's oracle and rate model,
 * and RLUSD. Only the source side is played: the endpoint is impersonated to hand the OFT its
 * verified packet, as the receive library would.
 *
 * Each action is delivered in LayerZero's two steps, and each step is measured on its own: the
 * OFT's `lzReceive` credits the FXRP and queues the compose at the endpoint, and the endpoint's
 * `lzCompose` runs it. The withdraw's return leg leaves through the OFT's real `send`, priced by
 * the real send library and workers. The `lzCompose` figure is the endpoint call the executor's
 * compose gas pays for. The `lzReceive` figure is the OFT's call alone: the endpoint's own
 * verification around it, which the receive gas also pays for, is not in it.
 *
 * Each step is its own top-level call, so it pays cold storage prices, as it would in its own
 * delivery transaction: a step does not inherit warm slots from the one before it.
 * The assertions hold each step under the delivery options clients sign today; the printed
 * figures are what the presets are chosen from.
 */
contract LoanDeliveryGasForkTest is LoanForkFixture {
    /// @dev The canonical LayerZero V2 endpoint on Ethereum.
    address private constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    /// @dev Flare's FXRP OFT adapter, the Ethereum OFT's peer for Flare.
    address private constant FLARE_FXRP_ADAPTER = 0xd70659a6396285BF7214d7Ea9673184e7C72E07E;
    /// @dev The Flare controller's executor fee, the compose value a redeem-home must carry.
    uint128 private constant FLARE_EXECUTOR_FEE = 10 ether;

    /// @dev The delivery options clients sign today, on both legs.
    uint256 private constant RECEIVE_GAS = 200_000;
    uint256 private constant COMPOSE_GAS = 1_000_000;

    uint256 private constant COLLATERAL = 10_000e6;
    /// @dev Between debt-bearing steps; three of them stay inside the oracle's live window.
    uint256 private constant STEP = 1 hours;

    address private executor;
    uint64 private nonce;

    function setUp() public {
        _setUpForkFixture();
        executor = makeAddr("executor");
        vm.deal(executor, 10 ether);
    }

    function testTheRailIsTheLiveOne() public onlyForked {
        // a moved peer, endpoint or eid would make every figure below a measurement of something else
        assertEq(IOAppCore(FXRP).peers(ORIGIN_EID), originPeer);
        assertEq(address(IOAppCore(FXRP).endpoint()), LZ_ENDPOINT);
        assertEq(IMessagingChannel(LZ_ENDPOINT).eid(), DESTINATION_EID);
        assertEq(IOFT(FXRP).token(), FXRP);
    }

    function testEachLoanActionFitsTheSignedDeliveryOptions() public onlyForked {
        _measure("deposit, first", COLLATERAL, _deposit(), 0);
        _assertSupplied(COLLATERAL);

        uint256 parentBefore = IERC20(RLUSD).balanceOf(parent);
        _measure("borrow, no credit", 0, _borrow(bytes32("borrow-1"), 1_000e18), 0);
        assertEq(IERC20(RLUSD).balanceOf(parent), parentBefore + 1_000e18, "the borrow reaches the parent");

        // each debt-bearing step comes an hour after the last, so the checkpoint accrues interest
        // and fee rather than taking its zero-elapsed branch
        (uint256 debt, uint256 feeDebt) = _accrualMark();
        vm.warp(vm.getBlockTimestamp() + STEP);
        _measure("deposit, with debt", 1_000e6, _deposit(), 0);
        _assertSupplied(COLLATERAL + 1_000e6);
        _assertAccrued(debt, feeDebt);

        (debt, feeDebt) = _accrualMark();
        vm.warp(vm.getBlockTimestamp() + STEP);
        _measure("borrow, with credit", 1_000e6, _borrow(bytes32("borrow-2"), 500e18), 0);
        _assertSupplied(COLLATERAL + 2_000e6);
        assertEq(IERC20(RLUSD).balanceOf(parent), parentBefore + 1_500e18, "the second borrow reaches the parent");
        _assertAccrued(debt, feeDebt);

        (debt, feeDebt) = _accrualMark();
        vm.warp(vm.getBlockTimestamp() + STEP);
        uint64 outboundBefore = IMessagingChannel(LZ_ENDPOINT).outboundNonce(FXRP, ORIGIN_EID, originPeer);
        (bytes memory withdrawal, uint256 returnFee) = _withdrawHome(bytes32("withdraw-1"), 1_000e6);
        _measure("withdraw, sent home", 0, withdrawal, returnFee);
        _assertSupplied(COLLATERAL + 1_000e6);
        assertEq(
            IMessagingChannel(LZ_ENDPOINT).outboundNonce(FXRP, ORIGIN_EID, originPeer),
            outboundBefore + 1,
            "one packet leaves for Flare with the withdrawn FXRP"
        );
        _assertAccrued(debt, feeDebt);
    }

    /// @dev Points the transport at the deployed endpoint and OFT, and the origin at Flare's
    /// adapter, which is what the OFT's peer for Flare is.
    function _setUpRemoteDependencies() internal override {
        super._setUpRemoteDependencies();
        endpoint = MockLzEndpoint(LZ_ENDPOINT);
        oft = MockOft(FXRP);
        originPeer = bytes32(uint256(uint160(FLARE_FXRP_ADAPTER)));
    }

    /// @dev Delivers one action in LayerZero's two steps, prints what each took, and holds each
    /// under the option clients sign for it.
    function _measure(
        string memory _label,
        uint256 _credit,
        bytes memory _payload,
        uint256 _value
    )
        private
    {
        (uint256 receiveGas, uint256 composeGas) = _deliverOnTheRealRail(_credit, _payload, _value);
        emit log_named_uint(string.concat(_label, ": lzReceive"), receiveGas);
        emit log_named_uint(string.concat(_label, ": lzCompose"), composeGas);
        assertLt(receiveGas, RECEIVE_GAS, string.concat(_label, ": lzReceive exceeds the signed gas"));
        assertLt(composeGas, COMPOSE_GAS, string.concat(_label, ": lzCompose exceeds the signed gas"));
    }

    function _deliverOnTheRealRail(
        uint256 _credit,
        bytes memory _payload,
        uint256 _value
    )
        private
        returns (uint256 _receiveGas, uint256 _composeGas)
    {
        nonce++;
        bytes32 guid = GUID.generate(
            nonce,
            ORIGIN_EID,
            FLARE_FXRP_ADAPTER,
            DESTINATION_EID,
            bytes32(uint256(uint160(FXRP)))
        );
        bytes32 self = bytes32(uint256(uint160(address(account))));
        // the account is its own Flare twin's address, so it is both the recipient and the
        // compose sender; FXRP's shared and local decimals are equal, so the amount is unscaled
        bytes memory packet = abi.encodePacked(self, uint64(_credit), self, _payload);

        vm.recordLogs();
        vm.prank(LZ_ENDPOINT);
        // capped at the signed gas, as the executor caps its endpoint call: forwarding loses a
        // 64th per frame, so a step can need more gas to start than it uses
        ILayerZeroReceiver(FXRP).lzReceive{gas: RECEIVE_GAS}(
            Origin(ORIGIN_EID, originPeer, nonce),
            guid,
            packet,
            executor,
            ""
        );
        _receiveGas = vm.lastCallGas().gasTotalUsed;

        bytes memory composeMessage = _queuedCompose();
        vm.prank(executor);
        IMessagingComposer(LZ_ENDPOINT).lzCompose{gas: COMPOSE_GAS, value: _value}(
            FXRP,
            address(account),
            guid,
            0,
            composeMessage,
            ""
        );
        _composeGas = vm.lastCallGas().gasTotalUsed;
    }

    /// @dev The compose message the OFT queued, exactly as the endpoint holds it.
    function _queuedCompose()
        private
        returns (bytes memory)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == LZ_ENDPOINT && logs[i].topics[0] == IMessagingComposer.ComposeSent.selector) {
                (, , , , bytes memory message) = abi.decode(logs[i].data, (address, address, bytes32, uint16, bytes));
                return message;
            }
        }
        revert("the OFT queued no compose");
    }

    /// @dev The step's own credit is supplied, not left idle for a later step to supply.
    function _assertSupplied(
        uint256 _expected
    )
        private view
    {
        assertEq(_collateral(), _expected, "the collateral is supplied");
        assertEq(IERC20(FXRP).balanceOf(address(account)), 0, "and none is left idle");
    }

    /// @dev The debt and the fee debt before a step, for {_assertAccrued}.
    function _accrualMark()
        private view
        returns (uint256 _debtNow, uint256 _feeDebtX18)
    {
        _debtNow = _debt();
        (, _feeDebtX18, , , , ) = account.getLoanFeeState();
    }

    /// @dev The step accrued the market's interest and the fee, and checkpointed at this block.
    function _assertAccrued(
        uint256 _debtBefore,
        uint256 _feeDebtBefore
    )
        private view
    {
        (, uint256 feeDebtX18, , uint64 lastCheckpoint, , ) = account.getLoanFeeState();
        assertGt(_debt(), _debtBefore, "interest accrued into the debt");
        assertGt(feeDebtX18, _feeDebtBefore, "the fee accrued");
        assertEq(lastCheckpoint, vm.getBlockTimestamp(), "and the checkpoint ran at this block");
    }

    /// @dev A withdraw home with the return options a client signs, and the value that pays for the
    /// return leg: the OFT's own quote for the send the account will make.
    function _withdrawHome(
        bytes32 _id,
        uint256 _amount
    )
        private view
        returns (bytes memory _payload, uint256 _returnFee)
    {
        bytes memory returnOptions = _options(RECEIVE_GAS, COMPOSE_GAS, FLARE_EXECUTOR_FEE);
        SendParam memory sendParam = SendParam({
            dstEid: ORIGIN_EID,
            to: bytes32(uint256(uint160(address(account)))),
            amountLD: _amount,
            minAmountLD: 0,
            extraOptions: returnOptions,
            composeMsg: abi.encode(PAYLOAD_VERSION_1, ACTION_REDEEM_HOME, bytes("")),
            oftCmd: ""
        });
        (, , OFTReceipt memory receipt) = IOFT(FXRP).quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;
        MessagingFee memory fee = IOFT(FXRP).quoteSend(sendParam, false);
        _returnFee = fee.nativeFee;
        _payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_WITHDRAW,
            abi.encode(
                _id,
                uint64(vm.getBlockTimestamp() + 1 hours),
                _amount,
                receipt.amountReceivedLD,
                _returnFee,
                returnOptions
            )
        );
    }

    /// @dev Type-3 options: lzReceive gas, then index-0 lzCompose gas with a compose value.
    function _options(
        uint256 _receiveGas,
        uint256 _composeGas,
        uint128 _composeValue
    )
        private pure
        returns (bytes memory)
    {
        bytes memory lzReceivePayload = abi.encodePacked(uint128(_receiveGas));
        bytes memory lzComposePayload = abi.encodePacked(uint16(0), uint128(_composeGas), _composeValue);
        return abi.encodePacked(
            uint16(3),
            uint8(1), uint16(1 + lzReceivePayload.length), uint8(1), lzReceivePayload,
            uint8(1), uint16(1 + lzComposePayload.length), uint8(3), lzComposePayload
        );
    }
}
