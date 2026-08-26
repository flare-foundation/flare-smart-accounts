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
    ILoanChainSubaccount,
    PAYLOAD_VERSION_1,
    ACTION_BORROW,
    ACTION_WITHDRAW,
    ACTION_SET_RECOVERY,
    DESTINATION_KIND_EVM,
    SKIP_REASON_DUPLICATE,
    SKIP_REASON_EXPIRED,
    SKIP_REASON_STALE_EPOCH
} from "../../userInterfaces/ILoanChainSubaccount.sol";
import {ILoanChainSettingsFacet} from "../../userInterfaces/facets/ILoanChainSettingsFacet.sol";
import {
    ISubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ISubaccountsFacet.sol";
import {ISubaccount} from "../../userInterfaces/ISubaccount.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IMorpho} from "../interface/IMorpho.sol";

/**
 * @title LoanChainSubaccount contract
 * @notice The loan-chain-side subaccount implementation (Ethereum, at launch): same frozen
 * proxy and CREATE2 address as the Flare-side account, resolved per type through the
 * controller-as-beacon.
 * The account operates on exactly **one Morpho market for its whole life** — the market its
 * subaccount type is bound to (write-once in the settings), so the address itself commits to
 * the pool. The parent Personal Account exists only on Flare, so every authorized action
 * arrives through {lzCompose}, and everything else is permissionless movement along fixed
 * rails — no caller ever chooses a destination, a market, or an amount source.
 */
contract LoanChainSubaccount is ILoanChainSubaccount, ReentrancyGuardTransient {
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
    /// @inheritdoc ILoanChainSubaccount
    mapping(bytes32 operationId => bool used) public usedOperations;
    /// @inheritdoc ILoanChainSubaccount
    address public recoveryDestination;
    /// @inheritdoc ILoanChainSubaccount
    uint64 public recoveryEpoch;

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controllerAddress = EMPTY_ADDRESS;
    }

    /// @dev Native can arrive as a bridge refund; {recoverNative} is its exit. The
    /// implementation contract itself (never initialized, no parent) rejects it.
    receive() external payable {
        require(parentPersonalAccount != address(0), NotInitialized());
    }

    /// @inheritdoc ISubaccount
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
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ISubaccountsFacet.InvalidSubaccountType());

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

        ILoanChainSettingsFacet.Transport memory transport = _getTransport();
        _authenticate(transport, _from, _guid, _message);

        (uint8 version, uint8 action, bytes memory actionData) =
            abi.decode(_message.composeMsg(), (uint8, uint8, bytes));
        require(version == PAYLOAD_VERSION_1, UnsupportedPayloadVersion(version));
        if (action == ACTION_BORROW) {
            _executeBorrow(actionData, _guid, _message.amountLD());
        } else if (action == ACTION_WITHDRAW) {
            // pause-gated; the compose stays queued at the endpoint and re-delivers after
            // unpausing (the borrow action gates itself - its top-up form is pause-exempt)
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

    /// @inheritdoc ILoanChainSubaccount
    function repay()
        external
        nonReentrant
        returns (uint256 _assets)
    {
        // no pause gate: repaying moves the position toward safety, and must stay available
        ILoanChainSettingsFacet.Market memory market = _myMarket();
        IERC20 loanToken = IERC20(market.marketParams.loanToken);
        uint256 balance = loanToken.balanceOf(address(this));
        require(balance > 0, NothingToRepay());

        // accrue first, so the clamp compares against the live debt
        IMorpho(market.morpho).accrueInterest(market.marketParams);
        (uint128 borrowShares, uint256 fullDebt) = _debtOf(market);
        require(borrowShares > 0, NothingToRepay());

        if (balance >= fullDebt) {
            // the balance covers the whole debt: close by exact borrow shares (no over-repay
            // revert); the surplus stays on the account for recoverLoanToken
            loanToken.forceApprove(market.morpho, fullDebt);
            (_assets, ) = IMorpho(market.morpho).repay(
                market.marketParams, 0, borrowShares, address(this), ""
            );
        } else {
            loanToken.forceApprove(market.morpho, balance);
            (_assets, ) = IMorpho(market.morpho).repay(
                market.marketParams, balance, 0, address(this), ""
            );
        }
        loanToken.forceApprove(market.morpho, 0);
        emit LoanRepaid(parentPersonalAccount, _assets);
    }

    /// @inheritdoc ILoanChainSubaccount
    function depositIdleFxrp()
        external
        nonReentrant
        returns (uint256 _amount)
    {
        ILoanChainSettingsFacet.Market memory market = _myMarket();
        // defending an indebted position survives a pause, like repayment; a debt-free
        // deposit is new exposure and waits out the pause
        if (_borrowSharesOf(market) == 0) {
            _checkNotPaused();
        }

        IERC20 fxrp = IERC20(market.marketParams.collateralToken);
        _amount = fxrp.balanceOf(address(this));
        require(_amount > 0, NothingToDeposit());

        fxrp.forceApprove(market.morpho, _amount);
        IMorpho(market.morpho).supplyCollateral(market.marketParams, _amount, address(this), "");
        emit IdleFxrpDeposited(parentPersonalAccount, _amount);
    }

    /// @inheritdoc ILoanChainSubaccount
    function sweepToOrigin()
        external payable
        nonReentrant
        returns (uint256 _amount)
    {
        ILoanChainSettingsFacet.Transport memory transport = _getTransport();
        // every exit from this chain rides the OFT itself, so an OFT incident must stop it
        _checkNotPaused();

        // the OFT's own underlying is the authoritative FXRP identity on this chain
        IERC20 fxrp = IERC20(IOFT(transport.fxrpOft).token());
        _amount = fxrp.balanceOf(address(this));
        require(_amount > 0, NothingToSweep());
        // a peer mutation on the OFT after configuration must fail closed
        require(
            IOAppCore(transport.fxrpOft).peers(transport.originEid) == transport.originPeer,
            WrongOriginPeer()
        );

        // the account is its own destination (same address on every chain); decimals match
        // (validated in the transport), so `minAmountLD` equals `amountLD`
        SendParam memory sendParam = SendParam({
            dstEid: transport.originEid,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        // per-call value accounting: exactly the quoted fee is spent, only this call's excess
        // is refunded - pre-existing native on the account never subsidizes a caller
        MessagingFee memory fee = IOFT(transport.fxrpOft).quoteSend(sendParam, false);
        require(msg.value >= fee.nativeFee, InsufficientFundsForSweep(fee.nativeFee));

        fxrp.forceApprove(transport.fxrpOft, _amount);
        // two false positives on this call: slither arbitrary-send-eth (recipient is the
        // governance-set OFT, value capped by the msg.value check above) and solhint
        // check-send-result (this is the OFT's `send`, not address.send; it reverts on failure)
        // slither-disable-start arbitrary-send-eth
        // solhint-disable-next-line check-send-result
        (MessagingReceipt memory receipt, ) = IOFT(transport.fxrpOft).send{value: fee.nativeFee}(
            sendParam,
            fee,
            msg.sender
        );
        // slither-disable-end arbitrary-send-eth
        fxrp.forceApprove(transport.fxrpOft, 0);

        uint256 excess = msg.value - fee.nativeFee;
        if (excess > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = msg.sender.call{value: excess}("");
            require(success, RefundFailed());
        }

        emit FXrpSweptToOrigin(parentPersonalAccount, _amount, transport.originEid, receipt.guid);
    }

    /// @inheritdoc ILoanChainSubaccount
    function recoverToken(
        address _token
    )
        external
        nonReentrant
        returns (uint256 _amount)
    {
        address destination = _recoveryDestination();
        // the market's loan and collateral tokens move only on their own rails
        ILoanChainSettingsFacet.Market memory market = _myMarket();
        require(
            _token != market.marketParams.loanToken &&
                _token != market.marketParams.collateralToken,
            ProtectedToken(_token)
        );

        _amount = IERC20(_token).balanceOf(address(this));
        require(_amount > 0, NothingToRecover());
        IERC20(_token).safeTransfer(destination, _amount);
        emit TokenRecovered(parentPersonalAccount, _token, _amount, destination);
    }

    /// @inheritdoc ILoanChainSubaccount
    function recoverLoanToken()
        external
        nonReentrant
        returns (uint256 _amount)
    {
        address destination = _recoveryDestination();
        // while the position has debt, the balance is repayment material, not surplus;
        // collateral never leaves through recovery at all
        ILoanChainSettingsFacet.Market memory market = _myMarket();
        require(_borrowSharesOf(market) == 0, OutstandingDebt());

        _amount = IERC20(market.marketParams.loanToken).balanceOf(address(this));
        require(_amount > 0, NothingToRecover());
        IERC20(market.marketParams.loanToken).safeTransfer(destination, _amount);
        emit TokenRecovered(parentPersonalAccount, market.marketParams.loanToken, _amount, destination);
    }

    /// @inheritdoc ILoanChainSubaccount
    function recoverNative()
        external
        nonReentrant
        returns (uint256 _amount)
    {
        address destination = _recoveryDestination();
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

    /// @inheritdoc ISubaccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon; it resolves the implementation for this subaccount type
        return ISubaccountsFacet(controllerAddress).implementationForType(subaccountType);
    }

    /// @dev A borrow or pure collateral top-up on the account's one market: exactly the
    /// authenticated bridged amount becomes collateral; a debt increase disburses to the
    /// destination. Gating failures revert, not skip - a temporary window must not consume
    /// the packet.
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
            uint8 destinationKind,
            bytes32 destination,
            uint256 borrowAmount
        ) = abi.decode(_actionData, (bytes32, uint64, uint8, bytes32, uint256));
        require(_bridgedAmount > 0 || borrowAmount > 0, ZeroAmount());
        require(operationId != bytes32(0), InvalidOperationId());
        // terminal gates come first, so a duplicate or expired delivery finalizes even when
        // borrowing is disabled or the market is not yet registered, instead of reverting
        // forever
        if (_skipped(operationId, deadline, _guid)) return;
        // debt increases respect the pause and the per-type borrow switch; paused top-ups
        // need live debt - defending a position stays available, new exposure waits
        if (borrowAmount > 0) {
            _checkNotPaused();
            require(
                !_facet().isLoanChainBorrowingDisabled(subaccountType),
                BorrowingDisabled()
            );
        } else if (IPauseFacet(controllerAddress).isPaused()) {
            require(_borrowSharesOf(_myMarket()) > 0, IPauseFacet.IsPaused());
        }
        usedOperations[operationId] = true;

        _performBorrow(_bridgedAmount, destinationKind, destination, borrowAmount);
        emit LoanOpened(
            parentPersonalAccount,
            operationId,
            _bridgedAmount,
            borrowAmount,
            destinationKind,
            destination,
            _guid
        );
    }

    /// @dev The borrow's asset moves, separated from the decode to keep stack depth flat.
    function _performBorrow(
        uint256 _bridgedAmount,
        uint8 _destinationKind,
        bytes32 _destination,
        uint256 _borrowAmount
    )
        private
    {
        ILoanChainSettingsFacet.Market memory market = _myMarket();
        if (_bridgedAmount > 0) {
            IERC20 fxrp = IERC20(market.marketParams.collateralToken);
            uint256 balance = fxrp.balanceOf(address(this));
            // the credit can have been moved before delivery (the accepted race); this cap
            // stops a signed action from absorbing more than its own credit
            require(balance >= _bridgedAmount, InsufficientComposeBalance(_bridgedAmount, balance));
            fxrp.forceApprove(market.morpho, _bridgedAmount);
            IMorpho(market.morpho).supplyCollateral(
                market.marketParams, _bridgedAmount, address(this), ""
            );
        }
        if (_borrowAmount > 0) {
            // only the EVM/ERC-20 form is implemented; the Wormhole-to-XRPL kind is reserved
            require(
                _destinationKind == DESTINATION_KIND_EVM,
                UnsupportedDestinationKind(_destinationKind)
            );
            // a clean zero-padded, non-zero EVM address - and neither address in scope when
            // composing: not this account (the proceeds could only repay the new debt), not
            // the parent Personal Account (no code and no key on this chain)
            address destinationAddress = address(uint160(uint256(_destination)));
            require(
                uint256(_destination) >> 160 == 0 &&
                    destinationAddress != address(0) &&
                    destinationAddress != address(this) &&
                    destinationAddress != parentPersonalAccount,
                InvalidDestination()
            );
            (uint256 assetsBorrowed, ) = IMorpho(market.morpho).borrow(
                market.marketParams, _borrowAmount, 0, address(this), address(this)
            );
            IERC20(market.marketParams.loanToken).safeTransfer(destinationAddress, assetsBorrowed);
        }
    }

    /// @dev Withdraws collateral to the account itself; the idle FXRP then leaves along
    /// the fixed rails, whichever runs first (the accepted ordering race - a redeposit can
    /// undo it at gas cost; see {ILoanChainSubaccount.depositIdleFxrp}). Morpho enforces
    /// position health.
    function _executeWithdraw(
        bytes memory _actionData,
        bytes32 _guid
    )
        private
    {
        (bytes32 operationId, uint64 deadline, uint256 amount) =
            abi.decode(_actionData, (bytes32, uint64, uint256));
        require(amount > 0, ZeroAmount());
        require(operationId != bytes32(0), InvalidOperationId());
        // terminal gates come first, so a duplicate or expired delivery finalizes even when
        // the market is not yet registered, instead of reverting forever
        if (_skipped(operationId, deadline, _guid)) return;
        ILoanChainSettingsFacet.Market memory market = _myMarket();
        usedOperations[operationId] = true;

        IMorpho(market.morpho).withdrawCollateral(
            market.marketParams, amount, address(this), address(this)
        );
        emit CollateralWithdrawn(parentPersonalAccount, operationId, amount, _guid);
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
            // expiry is curable with a fresh deadline; staleness only with a new epoch -
            // so the id is retired, keeping ids one-intent-one-id
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

    /// @dev The soft gates shared by all actions: a duplicate (already-consumed) id or a
    /// stale deadline completes the delivery without executing; the bridged FXRP stays for
    /// the fixed rails. Expiry leaves the id unconsumed for a retry with a fresh deadline.
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

    /// @dev The full authentication checklist: the caller must be the endpoint, the sender
    /// the configured FXRP OFT, the source chain the origin, the source-chain sender this
    /// account itself, and the delivered GUID must recompute from the pinned origin peer
    /// (the compose wrapper alone does not commit to the source OApp, so this last check is
    /// what defeats a temporarily swapped OFT peer).
    function _authenticate(
        ILoanChainSettingsFacet.Transport memory _transport,
        address _from,
        bytes32 _guid,
        bytes calldata _message
    )
        private view
    {
        require(msg.sender == _transport.lzEndpoint, OnlyEndpoint());
        require(_from == _transport.fxrpOft, WrongComposeSender(_from));
        uint32 srcEid = _message.srcEid();
        require(srcEid == _transport.originEid, WrongSourceEid(srcEid));
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
            address(uint160(uint256(_transport.originPeer))),
            IMessagingChannel(_transport.lzEndpoint).eid(),
            bytes32(uint256(uint160(_transport.fxrpOft)))
        );
        require(_guid == expectedGuid, WrongGuid(_guid));
    }

    /// @dev The account's one market, bound write-once to its type. If its Morpho stops
    /// answering, this account's debt-gated paths block - inherent to where the position
    /// lives; hence the operational policy of only canonical immutable Morpho Blue deployments.
    function _myMarket()
        private view
        returns (ILoanChainSettingsFacet.Market memory _market)
    {
        _market = _facet().getLoanChainMarket(subaccountType);
        require(
            _market.morpho != address(0),
            ILoanChainSettingsFacet.MarketNotRegistered(subaccountType)
        );
    }

    /// @dev The account's live borrow shares on its market - the exact test for "is there
    /// any debt", read live from Morpho every time (nothing is cached).
    function _borrowSharesOf(
        ILoanChainSettingsFacet.Market memory _market
    )
        private view
        returns (uint128 _borrowShares)
    {
        (, _borrowShares, ) = IMorpho(_market.morpho).position(
            keccak256(abi.encode(_market.marketParams)), address(this)
        );
    }

    /// @dev The account's live borrow shares and the assets needed to close them, using
    /// Morpho's canonical rounded-up share conversion with virtual offsets.
    function _debtOf(
        ILoanChainSettingsFacet.Market memory _market
    )
        private view
        returns (uint128 _borrowShares, uint256 _fullDebt)
    {
        bytes32 marketId = keccak256(abi.encode(_market.marketParams));
        (, _borrowShares, ) = IMorpho(_market.morpho).position(marketId, address(this));
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) =
            IMorpho(_market.morpho).market(marketId);
        _fullDebt = _toAssetsUp(_borrowShares, totalBorrowAssets, totalBorrowShares);
    }

    function _recoveryDestination()
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
        // top-ups (indebted-position targets) never route through this gate
        require(!IPauseFacet(controllerAddress).isPaused(), IPauseFacet.IsPaused());
    }

    function _getTransport()
        private view
        returns (ILoanChainSettingsFacet.Transport memory _transport)
    {
        _transport = _facet().getLoanChainTransport();
        require(
            _transport.lzEndpoint != address(0),
            ILoanChainSettingsFacet.LoanChainTransportNotConfigured()
        );
    }

    function _facet()
        private view
        returns (ILoanChainSettingsFacet)
    {
        return ILoanChainSettingsFacet(controllerAddress);
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
