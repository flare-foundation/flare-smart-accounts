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
 * @notice Flare-side deterministic staging account for loan-related assets owned by a Personal
 * Account. Its parent sends the typed loan instructions; anyone may sweep idle FXRP home, and
 * authenticated bridge-back FXRP from its loan-chain twin is redeemed on arrival
 * ({ComposeReceiverAccountBase}, with the transport read from the bridge settings).
 * @dev No native rail: no `receive()` and no native exit. The one protocol-delivered native is
 * the compose value of its own twin's bridge-back, forwarded whole within the same call (a
 * revert unwinds it), so a plain send reverts at the sender. Native landing without a call
 * (pre-deployment funding of the predicted address, a force-send) strands deliberately - nobody
 * in the protocol causes it, and the beacon-upgradeable implementation can add an exit if it
 * ever matters. The controller (MasterAccountController Diamond) is the beacon: the proxy and
 * this contract resolve the implementation per subaccount type through {implementationForType}.
 */
contract LoanSubaccount is ILoanSubaccount, ComposeReceiverAccountBase {
    using SafeERC20 for IERC20;

    // storage: slots 0-1 are the shared base prefix (controller, usedOperations); this
    // proxy lineage's own fields start at slot 2. Only the chain-local lineage must keep its
    // layout - the chains share the address, not the layout
    /// @notice Parent Personal Account address.
    address public parentPersonalAccount;
    /// @notice Subaccount type.
    uint256 public subaccountType;

    /// @dev Restricted calls arrive through the parent's signed user operation. The parent is
    /// fixed at deployment and is part of this account's address.
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
        // a public sweep must fund the configured executor fee, including the dust branch;
        // this bounds the accepted permissionless-direction griefing
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
        // mirror the remote static checks before paying the bridge fee. V1 supports only a
        // clean, non-zero EVM destination other than this subaccount (the parent - the user's
        // own loan-chain account - is a valid target)
        {
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
        }
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
        // require a non-zero signed delivery-value floor: it is what makes the prepaid return
        // fee reach the loan chain, where delivery is permissionless and the value
        // unauthenticated. destinationOptions are processed here, by the OFT at quote time;
        // only returnOptions first reach a validator remotely, which is why a bad blob there
        // is the frozen-options residual
        require(
            _operationId != bytes32(0) && _deadline >= block.timestamp && _amount > 0 &&
                _options.minComposeValue > 0,
            InvalidLoanInstruction()
        );
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_WITHDRAW,
            abi.encode(
                _operationId,
                _deadline,
                _amount,
                _options.minComposeValue,
                _options.maxFeeFxrp,
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

    /// @dev Derives the inbound bridge-back transport by reversing the configured Flare route:
    /// the same OFT adapter, endpoint and pinned peer the forward moves send with, read as
    /// origin instead of destination.
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

        // the parent pulls and redeems exactly this amount, so it is the recorded redeemer and
        // every outcome remains with the user; the whole fee rides along for the executor
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
