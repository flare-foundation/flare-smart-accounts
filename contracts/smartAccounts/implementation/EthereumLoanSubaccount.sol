// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {IMessagingChannel} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessagingChannel.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {
    IEthereumLoanSubaccount,
    PAYLOAD_VERSION_1,
    ACTION_BORROW,
    ACTION_WITHDRAW,
    ACTION_SET_RECOVERY,
    DESTINATION_KIND_EVM,
    SKIP_REASON_DUPLICATE,
    SKIP_REASON_EXPIRED,
    SKIP_REASON_STALE_EPOCH
} from "../../userInterfaces/IEthereumLoanSubaccount.sol";
import {IEthereumLoanSettingsFacet} from "../../userInterfaces/facets/IEthereumLoanSettingsFacet.sol";
import {
    ILoanSubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ILoanSubaccountsFacet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IMorpho} from "../interface/IMorpho.sol";

/**
 * @title EthereumLoanSubaccount contract
 * @notice The Ethereum-side loan subaccount implementation: same frozen proxy and CREATE2
 * address as the Flare-side account, resolved per type through the controller-as-beacon.
 * The parent Personal Account exists only on Flare, so every authorized action arrives
 * through {lzCompose}, and everything else is permissionless movement along fixed rails —
 * no caller ever chooses a destination. Positions live in permanently registered routes, so
 * changing the active route never strands a position; composed actions and the bridge-back
 * additionally need the transport configured.
 */
contract EthereumLoanSubaccount is IEthereumLoanSubaccount, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using OFTComposeMsgCodec for bytes;

    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;
    /// @dev Morpho's virtual-share offsets for share/asset conversion.
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    /// @notice MasterAccountController address.
    address public controllerAddress;
    /// @notice Parent Personal Account address (a Flare-side address; no code on this chain).
    address public parentPersonalAccount;
    /// @notice Subaccount type.
    uint256 public subaccountType;
    /// @inheritdoc IEthereumLoanSubaccount
    mapping(bytes32 operationId => bool used) public usedOperations;
    /// @inheritdoc IEthereumLoanSubaccount
    address public recoveryDestination;
    /// @inheritdoc IEthereumLoanSubaccount
    uint64 public recoveryEpoch;
    /// @inheritdoc IEthereumLoanSubaccount
    bytes32 public debtRouteId;
    /// @inheritdoc IEthereumLoanSubaccount
    mapping(bytes32 routeId => bool borrowed) public isBorrowedRoute;
    /// @dev Routes this account ever borrowed on, append-only. Informational only (backs
    /// {getBorrowedRoutes}); debt checks read the scalar {debtRouteId} pointer instead.
    bytes32[] private _borrowedRoutes;

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controllerAddress = EMPTY_ADDRESS;
    }

    /// @dev Native can arrive as a bridge refund; {recoverNative} is its exit. The
    /// implementation contract itself (never initialized, no parent) rejects it.
    receive() external payable {
        require(parentPersonalAccount != address(0), NotInitialized());
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function initialize(
        address _controllerAddress,
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        external
    {
        require(controllerAddress == address(0), AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        require(_parentPersonalAccount != address(0), InvalidParentPersonalAccount());
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ILoanSubaccountsFacet.InvalidSubaccountType());

        controllerAddress = _controllerAddress;
        parentPersonalAccount = _parentPersonalAccount;
        subaccountType = _subaccountType;

        emit LoanSubaccountInitialized(_controllerAddress, _parentPersonalAccount, _subaccountType);
    }

    /// @inheritdoc ILayerZeroComposer
    /// @dev The authenticated entry point for loan actions; {_authenticate} holds the full
    /// checklist. The executor and extra data are untrusted and ignored. A failing message
    /// reverts and stays retriable at the endpoint; its tokens are already on this account.
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    )
        external payable
        nonReentrant
    {
        // the loan flow never sends compose value; rejecting it keeps a mistaken delivery
        // retriable through the endpoint without value
        require(msg.value == 0, NonZeroComposeValue());

        IEthereumLoanSettingsFacet.Settings memory settings = _getSettings();
        _authenticate(settings, _from, _guid, _message);

        (uint8 version, uint8 action, bytes memory actionData) =
            abi.decode(_message.composeMsg(), (uint8, uint8, bytes));
        require(version == PAYLOAD_VERSION_1, UnsupportedPayloadVersion(version));
        if (action == ACTION_BORROW) {
            _executeBorrow(actionData, _guid, _message.amountLD());
        } else if (action == ACTION_WITHDRAW) {
            // asset-moving actions are pause-gated; the compose stays queued at the endpoint
            // and can be re-delivered after unpausing (the borrow action gates itself, since
            // its pure-top-up form is pause-exempt)
            _checkNotPaused();
            _executeWithdraw(actionData, _guid);
        } else if (action == ACTION_SET_RECOVERY) {
            // deliberately allowed while paused: rotating a compromised recovery destination
            // is configuration toward safety, and outward recovery is paused meanwhile - the
            // rotation must not have to wait for (and race) an unpause
            _executeSetRecovery(actionData, _guid);
        } else {
            revert UnsupportedAction(action);
        }
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function repay(
        bytes32 _routeId
    )
        external
        nonReentrant
        returns (uint256 _assets)
    {
        // no pause gate: repaying moves the position toward safety, and must stay available
        IEthereumLoanSettingsFacet.Route memory route = _getRegisteredRoute(_routeId);
        IERC20 loanToken = IERC20(route.marketParams.loanToken);
        uint256 balance = loanToken.balanceOf(address(this));
        require(balance > 0, NothingToRepay());

        // accrue first, so the clamp compares against the live debt
        IMorpho(route.morpho).accrueInterest(route.marketParams);
        (uint128 borrowShares, uint256 fullDebt) = _debtOf(route);
        require(borrowShares > 0, NothingToRepay());

        if (balance >= fullDebt) {
            // the balance covers the whole debt: repay by exact borrow shares, which closes
            // the position without the over-repay revert; the surplus stays on the account
            // for recoverLoanToken
            loanToken.forceApprove(route.morpho, fullDebt);
            (_assets, ) = IMorpho(route.morpho).repay(
                route.marketParams, 0, borrowShares, address(this), ""
            );
        } else {
            loanToken.forceApprove(route.morpho, balance);
            (_assets, ) = IMorpho(route.morpho).repay(
                route.marketParams, balance, 0, address(this), ""
            );
        }
        loanToken.forceApprove(route.morpho, 0);
        if (debtRouteId == _routeId) {
            (uint128 remainingShares, ) = _debtOf(route);
            if (remainingShares == 0) {
                delete debtRouteId;
            }
        }
        emit LoanRepaid(parentPersonalAccount, _routeId, _assets);
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function depositIdleFxrp()
        external
        nonReentrant
        returns (uint256 _amount)
    {
        // the route with live debt wins (a top-up credit whose compose failed must not be
        // diverted from the position that may need it) and that defensive case survives a
        // pause; a debt-free account deposits into the active route - new exposure, pause-gated
        bytes32 targetRouteId = _liveDebtRoute();
        if (targetRouteId == bytes32(0)) {
            _checkNotPaused();
            targetRouteId = _facet().getActiveRouteId();
            require(targetRouteId != bytes32(0), EthereumLoanSettingsNotConfigured());
        }

        IEthereumLoanSettingsFacet.Route memory route = _facet().getRoute(targetRouteId);
        IERC20 fxrp = IERC20(route.marketParams.collateralToken);
        _amount = fxrp.balanceOf(address(this));
        require(_amount > 0, NothingToDeposit());

        fxrp.forceApprove(route.morpho, _amount);
        IMorpho(route.morpho).supplyCollateral(route.marketParams, _amount, address(this), "");
        emit IdleFxrpDeposited(parentPersonalAccount, targetRouteId, _amount);
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function syncDebtRoute()
        external
        nonReentrant
        returns (bytes32 _routeId)
    {
        return _liveDebtRoute();
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function sweepToOrigin()
        external payable
        nonReentrant
        returns (uint256 _amount)
    {
        IEthereumLoanSettingsFacet.Settings memory settings = _getSettings();
        // every exit from this chain rides the OFT itself, so an OFT incident must stop it
        _checkNotPaused();

        // the OFT's own underlying is the authoritative FXRP identity on this chain
        IERC20 fxrp = IERC20(IOFT(settings.fxrpOft).token());
        _amount = fxrp.balanceOf(address(this));
        require(_amount > 0, NothingToSweep());
        // a peer mutation on the OFT after configuration must fail closed
        require(
            IOAppCore(settings.fxrpOft).peers(settings.originEid) == settings.originPeer,
            WrongOriginPeer()
        );

        // this account has the same address on every chain, so it is its own destination;
        // FXRP and the OFT share decimals (validated in the settings), so `minAmountLD` can
        // equal `amountLD`
        SendParam memory sendParam = SendParam({
            dstEid: settings.originEid,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        // per-call value accounting: exactly the quoted fee is spent, only this call's excess
        // is refunded - pre-existing native on the account never subsidizes a caller
        MessagingFee memory fee = IOFT(settings.fxrpOft).quoteSend(sendParam, false);
        require(msg.value >= fee.nativeFee, InsufficientFundsForSweep(fee.nativeFee));

        fxrp.forceApprove(settings.fxrpOft, _amount);
        // two false positives on this call: slither arbitrary-send-eth (recipient is the
        // governance-set OFT, value capped by the msg.value check above) and solhint
        // check-send-result (this is the OFT's `send`, not address.send; it reverts on failure)
        // slither-disable-start arbitrary-send-eth
        // solhint-disable-next-line check-send-result
        (MessagingReceipt memory receipt, ) = IOFT(settings.fxrpOft).send{value: fee.nativeFee}(
            sendParam,
            fee,
            msg.sender
        );
        // slither-disable-end arbitrary-send-eth
        fxrp.forceApprove(settings.fxrpOft, 0);

        uint256 excess = msg.value - fee.nativeFee;
        if (excess > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = msg.sender.call{value: excess}("");
            require(success, RefundFailed());
        }

        emit FXrpSweptToOrigin(parentPersonalAccount, _amount, settings.originEid, receipt.guid);
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function recoverToken(
        address _token
    )
        external
        nonReentrant
        returns (uint256 _amount)
    {
        address destination = _recoveryDestinationOrRevert();
        // loan and collateral tokens of registered routes move only on their own rails
        require(!_facet().isProtectedToken(_token), ProtectedToken(_token));

        _amount = IERC20(_token).balanceOf(address(this));
        require(_amount > 0, NothingToRecover());
        IERC20(_token).safeTransfer(destination, _amount);
        emit TokenRecovered(parentPersonalAccount, _token, _amount, destination);
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function recoverLoanToken(
        address _token
    )
        external
        nonReentrant
        returns (uint256 _amount)
    {
        address destination = _recoveryDestinationOrRevert();
        // as long as any route lending this token has debt, the balance is repayment
        // material, not surplus; collateral tokens never leave through recovery at all
        _checkNoOutstandingDebt(_token);

        _amount = IERC20(_token).balanceOf(address(this));
        require(_amount > 0, NothingToRecover());
        IERC20(_token).safeTransfer(destination, _amount);
        emit TokenRecovered(parentPersonalAccount, _token, _amount, destination);
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function recoverNative()
        external
        nonReentrant
        returns (uint256 _amount)
    {
        address destination = _recoveryDestinationOrRevert();
        _amount = address(this).balance;
        require(_amount > 0, NothingToRecover());

        // false positive (arbitrary-send-eth): the recipient is the authenticated recovery
        // destination stored by a user-signed action - not caller-chosen
        // slither-disable-start arbitrary-send-eth
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = destination.call{value: _amount}("");
        // slither-disable-end arbitrary-send-eth
        require(success, NativeRecoveryFailed());
        emit NativeRecovered(parentPersonalAccount, _amount, destination);
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function getBorrowedRoutes()
        external view
        returns (bytes32[] memory)
    {
        return _borrowedRoutes;
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon; it resolves the implementation for this subaccount type
        return ILoanSubaccountsFacet(controllerAddress).loanImplementationForType(subaccountType);
    }

    /// @dev Decodes and executes a borrow or pure collateral top-up: exactly the
    /// authenticated bridged amount becomes collateral. A debt increase disburses to the
    /// payload's destination and requires the active route — a revert, not a skip, so a
    /// delivery during a temporary configuration window cannot consume the packet; a
    /// top-up works against any registered route.
    function _executeBorrow(
        bytes memory _actionData,
        bytes32 _guid,
        uint256 _bridgedAmount
    )
        private
    {
        (
            bytes32 operationId,
            uint64 deadline,
            bytes32 routeId,
            uint8 destinationKind,
            bytes32 destination,
            uint256 borrowAmount
        ) = abi.decode(_actionData, (bytes32, uint64, bytes32, uint8, bytes32, uint256));
        require(_bridgedAmount > 0 || borrowAmount > 0, ZeroAmount());
        require(operationId != bytes32(0), InvalidOperationId());
        // terminal gates come first, so a duplicate or expired delivery finalizes even for a
        // route that is no longer active, instead of reverting forever
        if (_skipped(operationId, deadline, _guid)) return;
        // only a debt increase is bound to the active route and the pause; a pure top-up
        // works against any registered route and, while paused, only against the route
        // carrying live debt - defense, like repayment. A top-up into a debt-free route is
        // new exposure and waits out the pause like everything else
        if (borrowAmount > 0) {
            _checkNotPaused();
            require(_facet().getActiveRouteId() == routeId, RouteNotActive(routeId));
        } else if (IPauseFacet(controllerAddress).isPaused()) {
            require(_liveDebtRoute() == routeId, IPauseFacet.IsPaused());
        }
        usedOperations[operationId] = true;

        _performBorrow(routeId, _bridgedAmount, destinationKind, destination, borrowAmount);
        emit LoanOpened(
            parentPersonalAccount,
            operationId,
            routeId,
            _bridgedAmount,
            borrowAmount,
            destinationKind,
            destination,
            _guid
        );
    }

    /// @dev The borrow's asset moves, separated from the decode to keep stack depth flat.
    function _performBorrow(
        bytes32 _routeId,
        uint256 _bridgedAmount,
        uint8 _destinationKind,
        bytes32 _destination,
        uint256 _borrowAmount
    )
        private
    {
        IEthereumLoanSettingsFacet.Route memory route = _getRegisteredRoute(_routeId);
        if (_bridgedAmount > 0) {
            IERC20 fxrp = IERC20(route.marketParams.collateralToken);
            uint256 balance = fxrp.balanceOf(address(this));
            // the credited tokens can have been moved before this delivery (documented,
            // accepted race); this is a cap, not provenance - every balance here is the same
            // account's own - but it stops a signed action from absorbing more than its credit
            require(balance >= _bridgedAmount, InsufficientComposeBalance(_bridgedAmount, balance));
            fxrp.forceApprove(route.morpho, _bridgedAmount);
            IMorpho(route.morpho).supplyCollateral(
                route.marketParams, _bridgedAmount, address(this), ""
            );
        }
        if (_borrowAmount > 0) {
            // only the EVM/ERC-20 form is implemented; the Wormhole-to-XRPL kind is reserved
            require(
                _destinationKind == DESTINATION_KIND_EVM,
                UnsupportedDestinationKind(_destinationKind)
            );
            // the destination must be a clean zero-padded, non-zero EVM address, and neither
            // address already in scope when a payload is composed: this account (the proceeds
            // could only repay the debt just opened) and the parent Personal Account (no code
            // and no key on this chain - the disbursement would be unrecoverable)
            address destinationAddress = address(uint160(uint256(_destination)));
            require(
                uint256(_destination) >> 160 == 0 &&
                    destinationAddress != address(0) &&
                    destinationAddress != address(this) &&
                    destinationAddress != parentPersonalAccount,
                InvalidDestination()
            );
            // one outstanding debt route at a time: with several indebted routes sharing the
            // loan token, a permissionless repayment could pick the safer position while the
            // liquidation-sensitive one starves - close the old loan before opening a new one
            _checkNoOtherDebtRoute(_routeId);
            if (!isBorrowedRoute[_routeId]) {
                isBorrowedRoute[_routeId] = true;
                _borrowedRoutes.push(_routeId);
            }
            debtRouteId = _routeId;
            (uint256 assetsBorrowed, ) = IMorpho(route.morpho).borrow(
                route.marketParams, _borrowAmount, 0, address(this), address(this)
            );
            IERC20(route.marketParams.loanToken).safeTransfer(destinationAddress, assetsBorrowed);
        }
    }

    /// @dev Withdraws collateral from the account's own position to the account itself; the
    /// idle FXRP can then be redeposited or bridged back along the fixed rails. Works against
    /// any registered route, so positions stay withdrawable however the active configuration
    /// changes. Morpho enforces the resulting position health.
    function _executeWithdraw(
        bytes memory _actionData,
        bytes32 _guid
    )
        private
    {
        (bytes32 operationId, uint64 deadline, bytes32 routeId, uint256 amount) =
            abi.decode(_actionData, (bytes32, uint64, bytes32, uint256));
        require(amount > 0, ZeroAmount());
        require(operationId != bytes32(0), InvalidOperationId());
        // terminal gates come first, so a duplicate or expired delivery finalizes even for an
        // unknown route, instead of reverting forever
        if (_skipped(operationId, deadline, _guid)) return;
        IEthereumLoanSettingsFacet.Route memory route = _getRegisteredRoute(routeId);
        usedOperations[operationId] = true;

        IMorpho(route.morpho).withdrawCollateral(
            route.marketParams, amount, address(this), address(this)
        );
        emit CollateralWithdrawn(parentPersonalAccount, operationId, routeId, amount, _guid);
    }

    /// @dev Stores the recovery destination for the permissionless recovery rails. The epoch
    /// must be strictly greater than the stored one: deliveries are unordered, and an older
    /// authenticated update must not overwrite a newer destination.
    function _executeSetRecovery(
        bytes memory _actionData,
        bytes32 _guid
    )
        private
    {
        (bytes32 operationId, uint64 deadline, uint64 epoch, bytes32 destination) =
            abi.decode(_actionData, (bytes32, uint64, uint64, bytes32));
        require(operationId != bytes32(0), InvalidOperationId());
        // same destination rules as the borrow disbursement: recovering to this account is
        // a no-op, and the parent Personal Account holds no code and no key on this chain
        address destinationAddress = address(uint160(uint256(destination)));
        require(
            uint256(destination) >> 160 == 0 &&
                destinationAddress != address(0) &&
                destinationAddress != address(this) &&
                destinationAddress != parentPersonalAccount,
            InvalidDestination()
        );
        if (_skipped(operationId, deadline, _guid)) return;
        if (epoch <= recoveryEpoch) {
            // unlike an expired intent (curable by refreshing the deadline, a non-economic
            // field), staleness can only be cured by changing the epoch itself - so the id
            // is retired here, keeping ids one-intent-one-id
            usedOperations[operationId] = true;
            emit LoanActionSkipped(
                parentPersonalAccount, operationId, SKIP_REASON_STALE_EPOCH, _guid
            );
            return;
        }
        usedOperations[operationId] = true;

        recoveryDestination = destinationAddress;
        recoveryEpoch = epoch;
        emit RecoveryDestinationSet(parentPersonalAccount, recoveryDestination, epoch, _guid);
    }

    /// @dev The soft gates shared by all actions: a duplicate (already-consumed) operation id
    /// or a stale deadline completes the delivery without executing, leaving the bridged FXRP
    /// on the fixed rails. An expired skip leaves the id unconsumed, so the same intent can
    /// retry under it with a fresh deadline.
    function _skipped(
        bytes32 _operationId,
        uint64 _deadline,
        bytes32 _guid
    )
        private
        returns (bool)
    {
        uint8 reason;
        if (usedOperations[_operationId]) {
            reason = SKIP_REASON_DUPLICATE;
        } else if (block.timestamp > _deadline) {
            reason = SKIP_REASON_EXPIRED;
        } else {
            return false;
        }
        emit LoanActionSkipped(parentPersonalAccount, _operationId, reason, _guid);
        return true;
    }

    /// @dev Reverts unless `_token` is the pinned loan token and the account has no live
    /// debt (stray tokens use `recoverToken`; collateral never leaves through recovery).
    /// The debt check reads the single lazily-cleared pointer - one external call, and no
    /// unrelated historical route can block it; see {_liveDebtRoute}.
    function _checkNoOutstandingDebt(
        address _token
    )
        private
    {
        // tokens are pinned across routes; the scalar view avoids copying the route array
        (address pinnedLoanToken, ) = _facet().getPinnedTokens();
        require(pinnedLoanToken != address(0) && _token == pinnedLoanToken, ProtectedToken(_token));
        bytes32 liveDebtRoute = _liveDebtRoute();
        require(liveDebtRoute == bytes32(0), OutstandingDebt(liveDebtRoute));
    }

    /// @dev Reverts if a route other than `_routeId` carries live debt; see the comment at
    /// the call site in {_performBorrow}.
    function _checkNoOtherDebtRoute(
        bytes32 _routeId
    )
        private
    {
        bytes32 liveDebtRoute = _liveDebtRoute();
        require(
            liveDebtRoute == bytes32(0) || liveDebtRoute == _routeId,
            OutstandingDebt(liveDebtRoute)
        );
    }

    /// @dev The route currently carrying debt, or zero. Set when a borrow opens debt,
    /// cleared lazily here against the live position, so an external liquidation (never
    /// observed directly) cannot leave a stale pointer. Only the pointed route is queried -
    /// unpointed routes can never block - but the pointed Morpho must answer `position()`,
    /// or every debt-gated path stays blocked; hence the (operational, not on-chain) policy
    /// of registering only canonical immutable Morpho Blue deployments.
    function _liveDebtRoute()
        private
        returns (bytes32)
    {
        bytes32 pointed = debtRouteId;
        if (pointed == bytes32(0)) return bytes32(0);
        IEthereumLoanSettingsFacet.Route memory route = _facet().getRoute(pointed);
        (, uint128 borrowShares, ) = IMorpho(route.morpho).position(
            keccak256(abi.encode(route.marketParams)), address(this)
        );
        if (borrowShares == 0) {
            delete debtRouteId;
            return bytes32(0);
        }
        return pointed;
    }

    /// @dev The full authentication checklist: the caller must be the endpoint, the sender
    /// the configured FXRP OFT, the source chain the origin, the source-chain sender this
    /// account itself, and the delivered GUID must recompute from the pinned origin peer
    /// (the compose wrapper alone does not commit to the source OApp, so this last check is
    /// what defeats a temporarily swapped OFT peer).
    function _authenticate(
        IEthereumLoanSettingsFacet.Settings memory _settings,
        address _from,
        bytes32 _guid,
        bytes calldata _message
    )
        private view
    {
        require(msg.sender == _settings.lzEndpoint, OnlyEndpoint());
        require(_from == _settings.fxrpOft, WrongComposeSender(_from));
        uint32 srcEid = _message.srcEid();
        require(srcEid == _settings.originEid, WrongSourceEid(srcEid));
        // the canonical OFT codec records the source-chain caller of `send`; only this account
        // itself bridges composed FXRP here, so any other sender's payload must not execute
        bytes32 composeFrom = _message.composeFrom();
        require(
            composeFrom == bytes32(uint256(uint160(address(this)))),
            WrongComposeFrom(composeFrom)
        );
        // bind the message to the pinned origin peer: the endpoint computed the GUID from the
        // true packet header, so it cannot match unless the sender was exactly the pinned peer
        bytes32 expectedGuid = GUID.generate(
            _message.nonce(),
            srcEid,
            address(uint160(uint256(_settings.originPeer))),
            IMessagingChannel(_settings.lzEndpoint).eid(),
            bytes32(uint256(uint160(_settings.fxrpOft)))
        );
        require(_guid == expectedGuid, WrongGuid(_guid));
    }

    /// @dev The account's live borrow shares on a route and the assets needed to close them,
    /// using Morpho's canonical rounded-up share conversion with virtual offsets.
    function _debtOf(
        IEthereumLoanSettingsFacet.Route memory _route
    )
        private view
        returns (uint128 _borrowShares, uint256 _fullDebt)
    {
        bytes32 marketId = keccak256(abi.encode(_route.marketParams));
        (, _borrowShares, ) = IMorpho(_route.morpho).position(marketId, address(this));
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) =
            IMorpho(_route.morpho).market(marketId);
        _fullDebt = _toAssetsUp(_borrowShares, totalBorrowAssets, totalBorrowShares);
    }

    function _getRegisteredRoute(
        bytes32 _routeId
    )
        private view
        returns (IEthereumLoanSettingsFacet.Route memory _route)
    {
        _route = _facet().getRoute(_routeId);
        require(_route.morpho != address(0), RouteNotRegistered(_routeId));
    }

    function _recoveryDestinationOrRevert()
        private view
        returns (address _destination)
    {
        // outward recovery is a forward move: the pause stops it
        _checkNotPaused();
        _destination = recoveryDestination;
        require(_destination != address(0), RecoveryDestinationNotSet());
    }

    function _checkNotPaused()
        private view
    {
        // outward and exposure-increasing moves stop while paused; repayment and defensive
        // top-ups (live-debt targets) never route through this gate
        require(!IPauseFacet(controllerAddress).isPaused(), IPauseFacet.IsPaused());
    }

    function _getSettings()
        private view
        returns (IEthereumLoanSettingsFacet.Settings memory _settings)
    {
        _settings = _facet().getEthereumLoanSettings();
        require(_settings.lzEndpoint != address(0), EthereumLoanSettingsNotConfigured());
    }

    function _facet()
        private view
        returns (IEthereumLoanSettingsFacet)
    {
        return IEthereumLoanSettingsFacet(controllerAddress);
    }

    function _toAssetsUp(
        uint256 _shares,
        uint256 _totalAssets,
        uint256 _totalShares
    )
        private pure
        returns (uint256)
    {
        // Morpho's SharesMathLib.toAssetsUp: full-precision mulDiv with the virtual offsets,
        // so the intermediate product cannot overflow at uint128 extremes
        return Math.mulDiv(
            _shares,
            _totalAssets + VIRTUAL_ASSETS,
            _totalShares + VIRTUAL_SHARES,
            Math.Rounding.Ceil
        );
    }
}
