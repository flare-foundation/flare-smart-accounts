// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {ILoanSubaccount, ACTION_REDEEM_HOME} from "../../userInterfaces/ILoanSubaccount.sol";
import {PAYLOAD_VERSION_1} from "../../userInterfaces/IComposeReceiverAccountBase.sol";
import {IComposeTransportFacet} from "../../userInterfaces/facets/IComposeTransportFacet.sol";
import {
    ACTION_BORROW,
    ACTION_WITHDRAW,
    ACTION_DEPOSIT_COLLATERAL,
    DESTINATION_KIND_EVM
} from "../../userInterfaces/ILoanSubaccountRemote.sol";
import {ISubaccount} from "../../userInterfaces/ISubaccount.sol";
import {
    ISubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ISubaccountsFacet.sol";
import {ILoanBridgeSettingsFacet} from "../../userInterfaces/facets/ILoanBridgeSettingsFacet.sol";
import {IExecutorsFacet} from "../../userInterfaces/facets/IExecutorsFacet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";
import {ComposeReceiverAccountBase} from "./ComposeReceiverAccountBase.sol";

/**
 * @title LoanSubaccount contract
 * @notice Deterministic staging account for loan-related assets owned by a Personal Account.
 * It has no native rail: no `receive()`, no persistent native balance by any protocol flow, and no
 * native exit. The bridge refunds its caller and redemption outcomes land on the parent, so a
 * plain send reverts at the sender; the one protocol-delivered native is the compose value of
 * its own twin's bridge-back, forwarded whole within the same call (a revert unwinds it).
 * Native can otherwise land only without a call: value sent with an instruction to the predicted
 * address before the account existed, or a force-send. Both are very unlikely, neither is caused
 * by the protocol, and neither is worth a rail: such a balance strands, deliberately. As a last
 * resort, if it ever actually mattered, the implementation is beacon-upgradeable and an exit can
 * be added then.
 * It is also the compose receiver of its own loan-chain twin's bridge-back ({ComposeReceiverAccountBase}
 * with the transport read from the bridge settings): FXRP coming home is redeemed on arrival.
 * @dev The controller (MasterAccountController Diamond) is the beacon: the proxy and this
 * contract resolve the implementation per subaccount type through {implementationForType}.
 */
contract LoanSubaccount is ILoanSubaccount, ComposeReceiverAccountBase {
    using SafeERC20 for IERC20;

    // storage: slots 0-1 are the shared base prefix (controller, usedOperations); the same
    // layout as the loan-chain twin, so the two lineages read alike
    /// @notice Parent Personal Account address.
    address public parentPersonalAccount;
    /// @notice Subaccount type.
    uint256 public subaccountType;

    /// @dev Restricted methods are reached through FSA account abstraction: an XRPL-signed
    /// instruction drives the controller, which drives the parent Personal Account, which calls
    /// this subaccount. The parent is fixed at deployment and is part of this account's address.
    modifier onlyParent() {
        require(msg.sender == parentPersonalAccount, OnlyParent());
        _;
    }

    // deliberately no receive() and no native exit - see the contract notice

    /// @inheritdoc ISubaccount
    function initialize(
        address _controllerAddress,
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        external
    {
        _setController(_controllerAddress);
        require(_parentPersonalAccount != address(0), InvalidParentPersonalAccount());
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ISubaccountsFacet.InvalidSubaccountType());

        parentPersonalAccount = _parentPersonalAccount;
        subaccountType = _subaccountType;

        emit LoanSubaccountInitialized(_controllerAddress, _parentPersonalAccount, _subaccountType);
    }

    /// @inheritdoc ILoanSubaccount
    function sweepRedeem()
        external payable
        nonReentrant
        returns (uint256 _amount, uint256 _redeemedAmount)
    {
        // the permissionless rail costs the configured executor fee - paid to the FAssets
        // executor when a redemption happens, to the parent when it does not - so forcing the
        // backward direction is never gas-only (the accepted sweep-direction griefing bound)
        // slither-disable-next-line unused-return
        (, uint256 executorFee) = IExecutorsFacet(controller).getExecutorInfo();
        require(msg.value >= executorFee, InsufficientFundsForRedeem(executorFee));
        return _sweepRedeem(msg.value, type(uint256).max);
    }

    /// @inheritdoc ILoanSubaccount
    function borrow(
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        uint8 _destinationKind,
        bytes32 _destination,
        bytes32 _operationId,
        uint64 _deadline,
        bytes calldata _extraOptions
    )
        external payable
        onlyParent
        nonReentrant
    {
        // fail fast on Flare, before any bridge fee is paid; the loan chain re-validates. Only
        // the EVM destination form exists today: a clean non-zero address other than this
        // account (the parent - the user's own loan-chain account - is a valid target)
        address destinationAddress = address(uint160(uint256(_destination)));
        require(
            _operationId != bytes32(0) &&
                _deadline >= block.timestamp &&
                _borrowAmount > 0 &&
                _destinationKind == DESTINATION_KIND_EVM &&
                uint256(_destination) >> 160 == 0 &&
                destinationAddress != address(0) &&
                destinationAddress != address(this),
            InvalidLoanInstruction()
        );
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(_operationId, _deadline, _destinationKind, _destination, _borrowAmount)
        );
        (uint32 destinationEid, bytes32 guid) =
            _bridgeToSelf(_collateralAmount, _extraOptions, payload);
        emit BorrowInstructionSent(
            parentPersonalAccount,
            _operationId,
            _collateralAmount,
            _borrowAmount,
            _destinationKind,
            _destination,
            destinationEid,
            guid
        );
    }

    /// @inheritdoc ILoanSubaccount
    function depositCollateral(
        uint256 _amount,
        bytes32 _operationId,
        uint64 _deadline,
        bytes calldata _extraOptions
    )
        external payable
        onlyParent
        nonReentrant
    {
        require(
            _operationId != bytes32(0) && _deadline >= block.timestamp && _amount > 0,
            InvalidLoanInstruction()
        );
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_DEPOSIT_COLLATERAL,
            abi.encode(_operationId, _deadline)
        );
        (uint32 destinationEid, bytes32 guid) = _bridgeToSelf(_amount, _extraOptions, payload);
        emit CollateralDepositInstructionSent(
            parentPersonalAccount, _operationId, _amount, destinationEid, guid
        );
    }

    /// @inheritdoc ILoanSubaccount
    function withdraw(
        uint256 _amount,
        bytes32 _operationId,
        uint64 _deadline,
        WithdrawOptions calldata _options
    )
        external payable
        onlyParent
        nonReentrant
    {
        // the delivery-value floor is what makes the prepaid return fee reach the loan chain
        // (delivery is permissionless and the value unauthenticated), so a zero floor is a
        // mistake; the option blobs themselves are only checkable on the loan chain (the
        // accepted frozen-options residual)
        require(
            _operationId != bytes32(0) && _deadline >= block.timestamp && _amount > 0 &&
                _options.minComposeValue > 0,
            InvalidLoanInstruction()
        );
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_WITHDRAW,
            abi.encode(
                _operationId, _deadline, _amount, _options.minComposeValue,
                _options.returnOptions
            )
        );
        (uint32 destinationEid, bytes32 guid) = _bridgeToSelf(0, _options.destinationOptions, payload);
        emit WithdrawInstructionSent(
            parentPersonalAccount, _operationId, _amount, destinationEid, guid
        );
    }

    /// @inheritdoc ISubaccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon; it resolves the implementation for this subaccount type
        return ISubaccountsFacet(controller).implementationForType(subaccountType);
    }

    /// @inheritdoc ISubaccount
    function controllerAddress()
        external view
        override(ILoanSubaccount, ComposeReceiverAccountBase)
        returns (address)
    {
        return controller;
    }

    /// @dev The account's action set as a compose receiver (see {ComposeReceiverAccountBase._dispatch}):
    /// the redeem-home action of its own twin's bridge-back.
    function _dispatch(
        uint8 _action,
        bytes memory _actionData,
        bytes32 _guid,
        uint256 _amountLD
    )
        internal override
    {
        if (_action == ACTION_REDEEM_HOME) {
            _executeRedeemHome(_actionData, _guid, _amountLD);
        } else {
            revert UnsupportedAction(_action);
        }
    }

    /// @dev This receiver's transport is the Flare bridge settings seen from the other side: the
    /// FXRP OFT adapter and its endpoint, the loan chain as the origin, the pinned peer as the
    /// sender - the same values the forward moves send with.
    function _getTransport()
        internal view override
        returns (IComposeTransportFacet.Transport memory _transport)
    {
        (address fxrpOft, uint32 destinationEid, bytes32 destinationPeer) =
            ILoanBridgeSettingsFacet(controller).getLoanBridgeSettings();
        require(
            fxrpOft != address(0) && destinationEid != 0 && destinationPeer != bytes32(0),
            LoanBridgeNotConfigured()
        );
        _transport = IComposeTransportFacet.Transport({
            lzEndpoint: address(IOAppCore(fxrpOft).endpoint()),
            oft: fxrpOft,
            originEid: destinationEid,
            originPeer: destinationPeer
        });
    }

    /// @dev The redeem-home compose carries the executor fee as compose value and spends it in
    /// the same call; no other action exists here, and none may carry value.
    function _acceptsComposeValue(
        uint8 _action
    )
        internal pure override
        returns (bool)
    {
        return _action == ACTION_REDEEM_HOME;
    }

    /// @dev Redeem at most what this packet brought: the compose value is the executor fee
    /// (whatever the sender attached, zero included - the packet already cost it the LayerZero
    /// fee), the cap is the packet's authenticated amount, so no compose moves more than one
    /// packet's worth (FXRP is fungible; the cap bounds the amount, not the units). Past the
    /// sender-stamped deadline the packet skips terminally: nothing is redeemed, the balance is
    /// left for the public rail, the value joins the parent's float - a packet cannot outlive
    /// its delivery window as a standing instruction over later funds.
    function _executeRedeemHome(
        bytes memory _actionData,
        bytes32 _guid,
        uint256 _amountLD
    )
        private
    {
        uint64 deadline = abi.decode(_actionData, (uint64));
        if (block.timestamp > deadline) {
            if (msg.value > 0) {
                // slither-disable-next-line arbitrary-send-eth
                // solhint-disable-next-line avoid-low-level-calls
                (bool success, ) = parentPersonalAccount.call{value: msg.value}("");
                require(success, NativeSweepFailed());
                emit NativeSweptToParent(parentPersonalAccount, msg.value);
            }
            emit RedeemHomeSkipped(parentPersonalAccount, _guid);
            return;
        }
        _sweepRedeem(msg.value, _amountLD);
    }

    /// @dev The backward move, shared by the public {sweepRedeem} (whole balance) and the
    /// redeem-home compose (capped at the packet's authenticated amount): the amount goes to the parent,
    /// which redeems it with `_fee` as the executor fee; below the FAssets minimum it is pushed
    /// unredeemed and the fee joins the parent's float - the rail never fails on amount, and
    /// never refunds to `msg.sender` (on the compose path that would be the endpoint).
    function _sweepRedeem(
        uint256 _fee,
        uint256 _cap
    )
        private
        returns (uint256 _amount, uint256 _redeemedAmount)
    {
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        IERC20 fxrp = assetManager.fAsset();
        _amount = fxrp.balanceOf(address(this));
        if (_amount > _cap) {
            _amount = _cap;
        }
        require(_amount > 0, NothingToRedeem());

        if (_amount < assetManager.minimumRedeemAmountUBA()) {
            // FAssets would reject the redemption: the balance still goes home, unredeemed, and
            // the value joins the user's float on the parent. Whatever FAssets does not redeem
            // stays on the parent
            fxrp.safeTransfer(parentPersonalAccount, _amount);
            if (_fee > 0) {
                // false positive (arbitrary-send-eth): the recipient is the parent, fixed at
                // initialization and part of this account's address - not caller-chosen
                // slither-disable-next-line arbitrary-send-eth
                // solhint-disable-next-line avoid-low-level-calls
                (bool success, ) = parentPersonalAccount.call{value: _fee}("");
                require(success, NativeSweepFailed());
                emit NativeSweptToParent(parentPersonalAccount, _fee);
            }
            emit TokenSweptToParent(parentPersonalAccount, address(fxrp), _amount);
            return (_amount, 0);
        }

        // the parent redeems: it pulls exactly this amount and redeems exactly that, so it is
        // the recorded redeemer and every redemption outcome lands on it, under the user's
        // control; the whole fee rides along for the executor
        fxrp.forceApprove(parentPersonalAccount, _amount);
        _redeemedAmount = IPersonalAccount(parentPersonalAccount).redeemFromSubaccount{
            value: _fee
        }(_amount);

        emit FXrpRedeemed(parentPersonalAccount, _amount, _redeemedAmount);
    }

    /// @dev Shared forward-move core of {borrow}, {depositCollateral} and {withdraw}:
    /// bridges exactly `_amount` FXRP over LayerZero to this account's own address
    /// on the loan chain, so every entry point shares the same guards by construction. A zero
    /// amount is a message-only send (a withdraw, or a borrow against existing collateral); the
    /// destination is never caller-chosen.
    function _bridgeToSelf(
        uint256 _amount,
        bytes memory _extraOptions,
        bytes memory _composeMsg
    )
        private
        returns (uint32 _destinationEid, bytes32 _guid)
    {
        IERC20 fxrp = ContractRegistry.getAssetManagerFXRP().fAsset();
        uint256 balance = fxrp.balanceOf(address(this));
        require(_amount <= balance, AmountExceedsBalance(_amount, balance));

        // the forward move is the incident-containment surface: pausing the controller stops
        // bridging out immediately, while the backward sweep stays available so assets can
        // always exit toward the user's own XRPL address
        require(!IPauseFacet(controller).isPaused(), IPauseFacet.IsPaused());

        (address fxrpOft, uint32 destinationEid, bytes32 destinationPeer) =
            ILoanBridgeSettingsFacet(controller).getLoanBridgeSettings();
        require(
            fxrpOft != address(0) && destinationEid != 0 && destinationPeer != bytes32(0),
            LoanBridgeNotConfigured()
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
}
