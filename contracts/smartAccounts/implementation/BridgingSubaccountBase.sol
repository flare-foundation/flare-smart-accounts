// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {IBridgingSubaccount, ACTION_REDEEM_HOME} from "../../userInterfaces/IBridgingSubaccount.sol";
import {IComposeTransportFacet} from "../../userInterfaces/facets/IComposeTransportFacet.sol";
import {IBridgeRoutesFacet} from "../../userInterfaces/facets/IBridgeRoutesFacet.sol";
import {IExecutorsFacet} from "../../userInterfaces/facets/IExecutorsFacet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";
import {SubaccountBase} from "./SubaccountBase.sol";
import {ComposeReceiverAccountBase} from "./ComposeReceiverAccountBase.sol";

/**
 * @title BridgingSubaccountBase
 * @notice What every Flare subaccount type that bridges FXRP to its own address on a remote
 * chain shares: the forward-move core ({_bridgeToSelf} - the type's route, the live peer
 * re-check, the exact quoted fee), the one permissionless rail ({sweepRedeem} - home is the only
 * public direction), and the redeem-home compose of its own remote twin's bridge-back. A type
 * adds its parent-driven instructions on top: typed payload encoders over {_bridgeToSelf}.
 * @dev No `receive()` and no native exit: no protocol flow leaves native here (the bridge
 * refunds its caller, redemption outcomes land on the parent, and the compose value of the
 * bridge-back is forwarded within the same call). No state of its own: the type's route is read
 * live from the controller.
 */
abstract contract BridgingSubaccountBase is IBridgingSubaccount, SubaccountBase, ComposeReceiverAccountBase {
    using SafeERC20 for IERC20;

    /// @inheritdoc IBridgingSubaccount
    function sweepRedeem()
        external payable
        nonReentrant
        returns (uint256 _amount, uint256 _redeemedAmount)
    {
        // a public sweep must fund the configured executor fee, including the dust branch;
        // this bounds the accepted permissionless-direction griefing
        // slither-disable-next-line unused-return
        (, uint256 executorFee) = IExecutorsFacet(controllerAddress).getExecutorInfo();
        require(msg.value >= executorFee, InsufficientFundsForRedeem(executorFee));
        return _sweepRedeem(msg.value, type(uint256).max);
    }

    /// @dev The account's action set as a compose receiver (see {ComposeReceiverAccountBase._dispatch}):
    /// the redeem-home action of its own twin's bridge-back. A type with further inbound
    /// actions overrides and falls through to this for the shared one.
    function _dispatch(
        uint8 _action,
        bytes memory _actionData,
        bytes32 _guid,
        uint256 _amountLD
    )
        internal virtual override
    {
        if (_action == ACTION_REDEEM_HOME) {
            _executeRedeemHome(_actionData, _guid, _amountLD);
        } else {
            revert UnsupportedAction(_action);
        }
    }

    /// @dev Shared forward-move core of the type's instructions: bridges exactly `_amount` FXRP
    /// over LayerZero to this account's own address on its type's remote chain, so every entry
    /// point shares the same guards by construction. A zero amount is a message-only send; the
    /// destination is never caller-chosen. Exactly the quoted fee is spent; the caller's excess
    /// is returned.
    function _bridgeToSelf(
        uint256 _amount,
        bytes memory _extraOptions,
        bytes memory _composeMsg
    )
        internal
        returns (uint32 _destinationEid, bytes32 _guid)
    {
        IERC20 fxrp = ContractRegistry.getAssetManagerFXRP().fAsset();
        uint256 balance = fxrp.balanceOf(address(this));
        require(_amount <= balance, AmountExceedsBalance(_amount, balance));

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
        require(msg.value >= fee.nativeFee, InsufficientFundsForSweep(fee.nativeFee));

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

    /// @dev The redeem-home compose carries the executor fee as compose value and spends it in
    /// the same call; no other action here may carry value.
    function _acceptsComposeValue(
        uint8 _action
    )
        internal pure virtual override
        returns (bool)
    {
        return _action == ACTION_REDEEM_HOME;
    }

    /// @dev Before expiry, redeems at most the authenticated `_amountLD` (the cap limits the
    /// amount, not the token provenance - FXRP is fungible) with the compose value as the
    /// executor fee, zero included. After the sender-stamped deadline the packet skips
    /// terminally: the balance is left for {sweepRedeem} and the value goes to the parent, so a
    /// packet cannot outlive its delivery window as a standing instruction over later funds.
    function _executeRedeemHome(
        bytes memory _actionData,
        bytes32 _guid,
        uint256 _amountLD
    )
        private
    {
        address parent = _parentAccount();
        uint64 deadline = abi.decode(_actionData, (uint64));
        if (block.timestamp > deadline) {
            if (msg.value > 0) {
                // slither-disable-next-line arbitrary-send-eth
                // solhint-disable-next-line avoid-low-level-calls
                (bool success, ) = parent.call{value: msg.value}("");
                require(success, NativeSweepFailed());
                emit NativeSweptToParent(parent, msg.value);
            }
            emit RedeemHomeSkipped(parent, _guid);
            return;
        }
        _sweepRedeem(msg.value, _amountLD);
    }

    /// @dev Shared redemption core: the public rail uses the whole balance, a compose delivery
    /// caps it at the authenticated `amountLD`. The parent redeems the amount with `_fee` as
    /// the executor fee, or receives it unredeemed below the FAssets minimum, and receives all
    /// attached value - never `msg.sender`, which on the compose path is the endpoint.
    function _sweepRedeem(
        uint256 _fee,
        uint256 _cap
    )
        private
        returns (uint256 _amount, uint256 _redeemedAmount)
    {
        address parent = _parentAccount();
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        IERC20 fxrp = assetManager.fAsset();
        _amount = fxrp.balanceOf(address(this));
        if (_amount > _cap) {
            _amount = _cap;
        }
        require(_amount > 0, NothingToRedeem());

        if (_amount < assetManager.minimumRedeemAmountUBA()) {
            // FAssets rejects sub-minimum redemptions; send both the FXRP and the value to the
            // parent, where whatever FAssets does not redeem stays anyway
            fxrp.safeTransfer(parent, _amount);
            if (_fee > 0) {
                // false positive (arbitrary-send-eth): the recipient is the parent, fixed at
                // initialization and part of this account's address - not caller-chosen
                // slither-disable-next-line arbitrary-send-eth
                // solhint-disable-next-line avoid-low-level-calls
                (bool success, ) = parent.call{value: _fee}("");
                require(success, NativeSweepFailed());
                emit NativeSweptToParent(parent, _fee);
            }
            emit TokenSweptToParent(parent, address(fxrp), _amount);
            return (_amount, 0);
        }

        // the parent pulls and redeems exactly this amount, so it is the recorded redeemer and
        // every outcome remains with the user; the whole fee rides along for the executor
        fxrp.forceApprove(parent, _amount);
        _redeemedAmount = IPersonalAccount(parent).redeemFromSubaccount{value: _fee}(_amount);

        emit FXrpRedeemed(parent, _amount, _redeemedAmount);
    }

}
