// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {IBridgingSubaccount} from "../../userInterfaces/IBridgingSubaccount.sol";
import {IComposeTransportFacet} from "../../userInterfaces/facets/IComposeTransportFacet.sol";
import {IBridgeRoutesFacet} from "../../userInterfaces/facets/IBridgeRoutesFacet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {SubaccountBase} from "./SubaccountBase.sol";
import {ComposeReceiverAccountBase} from "./ComposeReceiverAccountBase.sol";

/**
 * @title BridgingSubaccountBase
 * @notice What every Flare subaccount type that bridges FXRP to its own address on a remote
 * chain shares, and nothing else: the forward-move core ({_bridgeToSelf} - the type's route,
 * the live peer re-check, the exact quoted fee) and the compose ingress of its own remote
 * twin's messages, authenticated against the transport derived from that same route
 * ({_getTransport}). What an arriving action does is the type's to say ({_dispatch}), as are
 * the parent-driven instructions built over {_bridgeToSelf}; whether the type also redeems
 * its idle FXRP is a separate base ({RedeemingSubaccountBase}), which a type extends beside
 * this one.
 * @dev No `receive()` and no native exit: no protocol flow leaves native here (the bridge
 * refunds its caller, and whatever value a compose carries is the type's to spend or forward
 * within the same call). No state of its own: the type's route is read live from the
 * controller.
 */
abstract contract BridgingSubaccountBase is IBridgingSubaccount, SubaccountBase, ComposeReceiverAccountBase {
    using SafeERC20 for IERC20;

    /// @dev Shared forward-move core of the type's instructions: bridges exactly `_amount` FXRP
    /// over LayerZero to this account's own address on its type's remote chain, so every entry
    /// point shares the same guards by construction. A zero amount is a message-only send that
    /// skips the FAssets-registry lookup, the balance read and the approval (the adapter still
    /// runs a zero-value pull on the token); the destination is never caller-chosen.
    /// Exactly the quoted fee is spent; the caller's excess is returned.
    function _bridgeToSelf(
        uint256 _amount,
        bytes memory _extraOptions,
        bytes memory _composeMsg
    )
        internal
        returns (uint32 _destinationEid, bytes32 _guid)
    {
        // only a token-bearing send resolves FXRP through the registry and reads the balance; a
        // message-only send (a borrow against existing collateral, a withdraw) skips both
        IERC20 fxrp = _amount > 0
            ? ContractRegistry.getAssetManagerFXRP().fAsset()
            : IERC20(address(0));
        if (_amount > 0) {
            uint256 balance = fxrp.balanceOf(address(this));
            require(_amount <= balance, AmountExceedsBalance(_amount, balance));
        }

        // the forward move is the incident-containment surface: pausing the controller stops
        // bridging out immediately, while the backward sweep stays available so assets can
        // always exit toward the user's own XRPL address
        require(!IPauseFacet(controllerAddress).isPaused(), IPauseFacet.IsPaused());

        (address fxrpOft, uint32 destinationEid, bytes32 destinationPeer) =
            IBridgeRoutesFacet(controllerAddress).getSubaccountTypeRoute(_accountType());
        require(
            fxrpOft != address(0) && destinationEid != 0 && destinationPeer != bytes32(0),
            BridgeRouteNotConfigured()
        );
        // a peer mutation on the OFT after configuration must fail closed, not deliver the
        // locked FXRP to an unknown remote OApp
        require(
            IOAppCore(fxrpOft).peers(destinationEid) == destinationPeer,
            WrongDestinationPeer()
        );

        // this account has the same address on every chain, so it is its own destination;
        // FXRP and the OFT share 6 decimals, so the full amount arrives and `minAmountLD`
        // can equal `amountLD`
        SendParam memory sendParam = SendParam({
            dstEid: destinationEid,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: _extraOptions,
            composeMsg: _composeMsg,
            oftCmd: ""
        });

        MessagingFee memory fee = IOFT(fxrpOft).quoteSend(sendParam, false);
        require(msg.value >= fee.nativeFee, InsufficientFundsForBridge(fee.nativeFee));

        // the OFT is a lock/unlock adapter, so it must be approved to pull the FXRP
        if (_amount > 0) {
            fxrp.forceApprove(fxrpOft, _amount);
        }
        // two false positives on this call: slither arbitrary-send-eth (recipient is the
        // governance-set OFT, value capped by the msg.value check above) and solhint
        // check-send-result (this is the OFT's `send`, not address.send; it reverts on failure)
        // slither-disable-start arbitrary-send-eth
        // solhint-disable-next-line check-send-result
        (MessagingReceipt memory receipt, ) = IOFT(fxrpOft).send{value: fee.nativeFee}(
            sendParam,
            fee,
            msg.sender
        );
        // slither-disable-end arbitrary-send-eth
        if (_amount > 0) {
            fxrp.forceApprove(fxrpOft, 0);
        }

        // return the caller's excess, so it is not stranded on an account with no native exit
        uint256 excess = msg.value - fee.nativeFee;
        if (excess > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = msg.sender.call{value: excess}("");
            require(success, RefundFailed());
        }

        _destinationEid = destinationEid;
        _guid = receipt.guid;
    }

    /// @dev Derives the inbound bridge-back transport by reversing its type's bridge route:
    /// the same OFT adapter, endpoint and pinned peer the forward moves send with, read as
    /// origin instead of destination.
    function _getTransport()
        internal view override
        returns (IComposeTransportFacet.Transport memory _transport)
    {
        (address fxrpOft, uint32 destinationEid, bytes32 destinationPeer) =
            IBridgeRoutesFacet(controllerAddress).getSubaccountTypeRoute(_accountType());
        require(
            fxrpOft != address(0) && destinationEid != 0 && destinationPeer != bytes32(0),
            BridgeRouteNotConfigured()
        );
        _transport = IComposeTransportFacet.Transport({
            lzEndpoint: address(IOAppCore(fxrpOft).endpoint()),
            oft: fxrpOft,
            originEid: destinationEid,
            originPeer: destinationPeer
        });
    }
}
