// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {
    ILoanSubaccountRemote,
    ACTION_BORROW,
    ACTION_WITHDRAW,
    ACTION_DEPOSIT_COLLATERAL,
    DESTINATION_KIND_EVM
} from "../../userInterfaces/ILoanSubaccountRemote.sol";
import {IComposeTransportFacet} from "../../userInterfaces/facets/IComposeTransportFacet.sol";
import {ILoanMarketsFacet} from "../../userInterfaces/facets/ILoanMarketsFacet.sol";
import {
    ISubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ISubaccountsFacet.sol";
import {ISubaccount} from "../../userInterfaces/ISubaccount.sol";
import {ACTION_REDEEM_HOME, REDEEM_HOME_TTL} from "../../userInterfaces/ILoanSubaccount.sol";
import {PAYLOAD_VERSION_1} from "../../userInterfaces/IComposeReceiverAccountBase.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IMorpho} from "../interface/IMorpho.sol";
import {ComposeReceiverAccountBase} from "./ComposeReceiverAccountBase.sol";

/**
 * @title LoanSubaccountRemote contract
 * @notice The loan-chain-side subaccount implementation (Ethereum, at launch): same frozen
 * proxy and CREATE2 address as the Flare-side account, resolved per type through the
 * controller-as-beacon.
 * The account operates on exactly **one Morpho market for its whole life** — the market its
 * subaccount type is bound to (write-once in the settings), so the address itself commits to
 * the pool. Every authorized action arrives through the authenticated `lzCompose` (see
 * {ComposeReceiverAccountBase}) sent by this same account on Flare, with one exception: the
 * parent Personal Account (the mirror, itself compose-driven) holds one narrow direct
 * authority — the signed exit {sweepToOrigin}, which can only send idle FXRP to this
 * account's own fixed Flare address, never redirect funds or touch collateral or debt.
 * Everything else is permissionless movement along fixed rails — into the account's own
 * position, or loan-token surplus to the parent — so no caller ever chooses a destination,
 * a market, or an amount source.
 * It has no native rail: the only protocol-delivered native is a withdraw delivery's compose
 * value (the return leg's fee), spent or forwarded to the parent mirror within the same call;
 * a plain send reverts, and a balance landing without a call (pre-deployment funding, an LZ
 * native drop, a force-send) strands until a beacon upgrade adds a rail - accepted.
 */
contract LoanSubaccountRemote is ILoanSubaccountRemote, ComposeReceiverAccountBase {
    using SafeERC20 for IERC20;

    /// @dev Morpho's virtual-share offsets for share/asset conversion.
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    /// @notice Parent Personal Account address (the same address on every chain; on this
    /// chain it carries no code until its compose-driven mirror is created).
    address public parentPersonalAccount;
    /// @notice Subaccount type.
    uint256 public subaccountType;

    // deliberately no receive(): the only protocol-delivered native is a withdraw delivery's
    // compose value, spent or forwarded to the parent mirror within the same call, so plain
    // native sends revert at the sender; native landing without a call (pre-deployment
    // funding, an LZ native drop, a force-send) strands - accepted, upgradeable

    modifier onlyParent() {
        // the parent is the mirror Personal Account: this method is reached only through a
        // user-signed cross-chain user operation executed by the mirror
        require(msg.sender == parentPersonalAccount, OnlyParent());
        _;
    }

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

    /// @inheritdoc ILoanSubaccountRemote
    function repay()
        external
        nonReentrant
        returns (uint256 _assets)
    {
        // no pause gate: repaying moves the position toward safety, and must stay available
        ILoanMarketsFacet.Market memory market = _myMarket();
        IERC20 loanToken = IERC20(market.marketParams.loanToken);
        uint256 balance = loanToken.balanceOf(address(this));
        require(balance > 0, NothingToRepay());

        // shares first: the debt-free surplus path must not depend on interest accrual (a
        // reverting IRM must not trap recoverable tokens)
        if (_borrowSharesOf(market) > 0) {
            // accrue first, so the clamp compares against the live debt
            IMorpho(market.morpho).accrueInterest(market.marketParams);
            (uint128 borrowShares, uint256 fullDebt) = _debtOf(market);
            if (balance >= fullDebt) {
                // the balance covers the whole debt: close by exact borrow shares (no
                // over-repay revert)
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

        // once the debt is gone - closed by this call, or already zero (an external
        // liquidation, tokens arriving after the close) - the remaining balance is the
        // user's surplus and leaves to the parent; while debt remains it stays repayment
        // material. Best-effort by design: a parent the token refuses (RLUSD can freeze
        // addresses) must never roll back the repayment that just succeeded, so a failed
        // push leaves the surplus here for a later repay to retry
        uint256 surplus = loanToken.balanceOf(address(this));
        if (surplus > 0 && _borrowSharesOf(market) == 0) {
            if (loanToken.trySafeTransfer(parentPersonalAccount, surplus)) {
                emit LoanSurplusRecovered(parentPersonalAccount, surplus);
            } else {
                emit LoanSurplusRetained(parentPersonalAccount, surplus);
            }
        }
    }

    /// @inheritdoc ILoanSubaccountRemote
    function depositIdleFxrp()
        external
        nonReentrant
        returns (uint256 _amount)
    {
        ILoanMarketsFacet.Market memory market = _myMarket();
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

    /// @inheritdoc ILoanSubaccountRemote
    function sweepToOrigin(
        bytes calldata _extraOptions
    )
        external payable
        onlyParent
        nonReentrant
        returns (uint256 _amount)
    {
        IComposeTransportFacet.Transport memory transport = _getTransport();
        // every exit from this chain rides the OFT itself, so an OFT incident must stop it
        _checkNotPaused();

        // the OFT's own underlying is the authoritative FXRP identity on this chain
        IERC20 fxrp = IERC20(IOFT(transport.oft).token());
        _amount = fxrp.balanceOf(address(this));
        require(_amount > 0, NothingToSweep());

        // per-call value accounting: exactly the quoted fee is spent, only this call's excess
        // is refunded - pre-existing native on the account never subsidizes a caller
        _bridgeHome(transport, _amount, _extraOptions, msg.value, msg.sender);
    }

    /// @inheritdoc ISubaccount
    function controllerAddress()
        external view
        override(ILoanSubaccountRemote, ComposeReceiverAccountBase)
        returns (address)
    {
        return controller;
    }

    /// @inheritdoc ISubaccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon; it resolves the implementation for this subaccount type
        return ISubaccountsFacet(controller).implementationForType(subaccountType);
    }

    /// @dev The subaccount's action set (see {ComposeReceiverAccountBase._dispatch}).
    function _dispatch(
        uint8 _action,
        bytes memory _actionData,
        bytes32 _guid,
        uint256 _amountLD
    )
        internal override
    {
        if (_action == ACTION_BORROW) {
            _executeBorrow(_actionData, _guid, _amountLD);
        } else if (_action == ACTION_WITHDRAW) {
            // pause-gated - the atomic withdrawal exits over the OFT, and the compose stays
            // queued at the endpoint and re-delivers after unpausing (borrow and deposit gate
            // themselves after their terminal skips)
            _checkNotPaused();
            _executeWithdraw(_actionData, _guid);
        } else if (_action == ACTION_DEPOSIT_COLLATERAL) {
            _executeDepositCollateral(_actionData, _guid, _amountLD);
        } else {
            revert UnsupportedAction(_action);
        }
    }

    /// @dev The withdraw action spends compose value in the same call - the return leg's
    /// LayerZero fee, with the excess pushed to the parent mirror - so it opts in; every
    /// other action must not carry value (a mistaken delivery stays retriable without it).
    function _acceptsComposeValue(
        uint8 _action
    )
        internal pure override
        returns (bool)
    {
        return _action == ACTION_WITHDRAW;
    }

    /// @dev A borrow on the account's one market: exactly the authenticated bridged amount (if
    /// any) becomes collateral, and the debt increase disburses to the destination. Gating
    /// failures revert, not skip - a temporary window must not consume the packet.
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
        require(borrowAmount > 0, ZeroAmount());
        require(operationId != bytes32(0), InvalidOperationId());
        // terminal gates come first, so a duplicate or expired delivery finalizes even when
        // borrowing is disabled or the market is not yet registered, instead of reverting
        // forever
        if (_skipped(operationId, deadline, _guid)) return;
        // a debt increase respects the pause and the per-type borrow switch
        _checkNotPaused();
        require(!ILoanMarketsFacet(controller).isLoanBorrowingDisabled(subaccountType), BorrowingDisabled());
        usedOperations[operationId] = true;

        _supplyAndBorrow(_bridgedAmount, destinationKind, destination, borrowAmount);
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

    /// @dev A pure collateral deposit on the account's one market: exactly the authenticated
    /// bridged amount becomes collateral. While paused it needs live debt - defending a
    /// position stays available, new exposure waits (a revert, not a skip, so the packet is
    /// not consumed by a temporary window).
    function _executeDepositCollateral(
        bytes memory _actionData,
        bytes32 _guid,
        uint256 _bridgedAmount
    )
        private
    {
        (bytes32 operationId, uint64 deadline) = abi.decode(_actionData, (bytes32, uint64));
        require(_bridgedAmount > 0, ZeroAmount());
        require(operationId != bytes32(0), InvalidOperationId());
        if (_skipped(operationId, deadline, _guid)) return;
        if (IPauseFacet(controller).isPaused()) {
            require(_borrowSharesOf(_myMarket()) > 0, IPauseFacet.IsPaused());
        }
        usedOperations[operationId] = true;

        _supplyAndBorrow(_bridgedAmount, 0, bytes32(0), 0);
        emit CollateralDeposited(parentPersonalAccount, operationId, _bridgedAmount, _guid);
    }

    /// @dev The asset moves of the borrow and deposit actions, separated from the decodes to
    /// keep stack depth flat: supply the bridged amount (if any), then borrow and disburse
    /// (if any).
    function _supplyAndBorrow(
        uint256 _bridgedAmount,
        uint8 _destinationKind,
        bytes32 _destination,
        uint256 _borrowAmount
    )
        private
    {
        ILoanMarketsFacet.Market memory market = _myMarket();
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
            // a clean zero-padded, non-zero EVM address that is not this account (the
            // proceeds could only repay the new debt); the parent Personal Account - the
            // user's own compose-driven account on this chain - is a valid target
            address destinationAddress = address(uint160(uint256(_destination)));
            require(
                uint256(_destination) >> 160 == 0 &&
                    destinationAddress != address(0) &&
                    destinationAddress != address(this),
                InvalidDestination()
            );
            (uint256 assetsBorrowed, ) = IMorpho(market.morpho).borrow(
                market.marketParams, _borrowAmount, 0, address(this), address(this)
            );
            IERC20(market.marketParams.loanToken).safeTransfer(destinationAddress, assetsBorrowed);
        }
    }

    /// @dev The atomic withdrawal: withdraws collateral from the position and bridges exactly
    /// that amount home with the redeem-home compose, in the same execution - no idle window
    /// between the two, so the redeposit race cannot touch a withdrawal. The compose value
    /// delivered with the action pays the return leg's LayerZero fee (quoted live against the
    /// signed `returnOptions`); the excess goes to the parent mirror. Too little value
    /// reverts, and the delivery stays retriable - fee quotes drift both ways. Morpho
    /// enforces position health.
    function _executeWithdraw(
        bytes memory _actionData,
        bytes32 _guid
    )
        private
    {
        (
            bytes32 operationId,
            uint64 deadline,
            uint256 amount,
            uint256 minComposeValue,
            bytes memory returnOptions
        ) = abi.decode(_actionData, (bytes32, uint64, uint256, uint256, bytes));
        require(amount > 0, ZeroAmount());
        require(operationId != bytes32(0), InvalidOperationId());
        // the signed delivery floor comes before every consuming branch: delivery is
        // permissionless and the value unauthenticated, so a below-floor delivery (a
        // zero-value front-run of an expiring packet, say) must revert and stay retriable
        // rather than consume the packet with the prepaid value undelivered
        require(msg.value >= minComposeValue, InsufficientDeliveryValue(minComposeValue));
        // terminal gates next, so a duplicate or expired delivery finalizes even when
        // the market is not yet registered, instead of reverting forever; its value must not
        // strand on an account with no native rail
        if (_skipped(operationId, deadline, _guid)) {
            _sweepValueToParent(msg.value);
            return;
        }
        ILoanMarketsFacet.Market memory market = _myMarket();
        usedOperations[operationId] = true;

        IMorpho(market.morpho).withdrawCollateral(
            market.marketParams, amount, address(this), address(this)
        );
        emit CollateralWithdrawn(parentPersonalAccount, operationId, amount, _guid);

        // the return leg, in the same execution; the fee rode in as compose value
        uint256 excess =
            _bridgeHome(_getTransport(), amount, returnOptions, msg.value, parentPersonalAccount);
        if (excess > 0) {
            emit NativeSweptToParent(parentPersonalAccount, excess);
        }
    }

    /// @dev The soft gates shared by all actions (see {ComposeReceiverAccountBase._terminalSkipReason}):
    /// a duplicate id or a stale deadline completes the delivery without executing; the
    /// bridged FXRP stays for the fixed rails.
    function _skipped(
        bytes32 _operationId,
        uint64 _deadline,
        bytes32 _guid
    )
        private
        returns (bool)
    {
        uint8 reason = _terminalSkipReason(_operationId, _deadline);
        if (reason == 0) {
            return false;
        }
        emit LoanActionSkipped(parentPersonalAccount, _operationId, reason, _guid);
        return true;
    }

    /// @dev The shared bridge-home core of {sweepToOrigin} and the withdraw action: sends
    /// exactly `_amount` FXRP to this account's own Flare address with the redeem-home
    /// compose (a deadline, this block time plus `REDEEM_HOME_TTL`, and nothing else), so
    /// the Flare twin redeems at most this amount on arrival. The account is its own
    /// destination (same address on every chain); decimals match (validated in the
    /// transport), so `minAmountLD` equals `amountLD`. `_options` carry the Flare-side gas
    /// and, optionally, the redemption's executor fee as compose value. Exactly the quoted
    /// fee is spent from `_value`; the excess goes to `_excessTo` (the caller on the sweep
    /// rail, the parent mirror on the withdraw action).
    function _bridgeHome(
        IComposeTransportFacet.Transport memory _transport,
        uint256 _amount,
        bytes memory _options,
        uint256 _value,
        address _excessTo
    )
        private
        returns (uint256 _excess)
    {
        // a peer mutation on the OFT after configuration must fail closed
        require(
            IOAppCore(_transport.oft).peers(_transport.originEid) == _transport.originPeer,
            WrongOriginPeer()
        );
        SendParam memory sendParam = SendParam({
            dstEid: _transport.originEid,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: _options,
            composeMsg: abi.encode(
                PAYLOAD_VERSION_1,
                ACTION_REDEEM_HOME,
                abi.encode(uint64(block.timestamp) + REDEEM_HOME_TTL)
            ),
            oftCmd: ""
        });

        MessagingFee memory fee = IOFT(_transport.oft).quoteSend(sendParam, false);
        require(_value >= fee.nativeFee, InsufficientFundsForSweep(fee.nativeFee));

        IERC20 fxrp = IERC20(IOFT(_transport.oft).token());
        fxrp.forceApprove(_transport.oft, _amount);
        // two false positives on this call: slither arbitrary-send-eth (recipient is the
        // governance-set OFT, value capped by the _value check above) and solhint
        // check-send-result (this is the OFT's `send`, not address.send; it reverts on failure)
        // slither-disable-start arbitrary-send-eth
        // solhint-disable-next-line check-send-result
        (MessagingReceipt memory receipt, ) = IOFT(_transport.oft).send{value: fee.nativeFee}(
            sendParam,
            fee,
            _excessTo
        );
        // slither-disable-end arbitrary-send-eth
        fxrp.forceApprove(_transport.oft, 0);

        _excess = _value - fee.nativeFee;
        if (_excess > 0) {
            // the excess never strands here (no native rail): back to the sweep caller, or
            // forward to the parent mirror for the withdraw action (which emits for it)
            // slither-disable-start arbitrary-send-eth
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = _excessTo.call{value: _excess}("");
            // slither-disable-end arbitrary-send-eth
            require(success, RefundFailed());
        }

        emit FXrpSweptToOrigin(parentPersonalAccount, _amount, _transport.originEid, receipt.guid);
    }

    /// @dev Forwards a terminally skipped withdraw delivery's compose value to the parent
    /// mirror: it must not strand on an account with no native rail, and msg.sender on this
    /// path is the endpoint - never a refund target.
    function _sweepValueToParent(
        uint256 _value
    )
        private
    {
        if (_value == 0) return;
        // slither-disable-start arbitrary-send-eth
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = parentPersonalAccount.call{value: _value}("");
        // slither-disable-end arbitrary-send-eth
        require(success, RefundFailed());
        emit NativeSweptToParent(parentPersonalAccount, _value);
    }

    /// @dev The account's one market, bound write-once to its type. If its Morpho stops
    /// answering, this account's debt-gated paths block - inherent to where the position
    /// lives; hence the operational policy of only canonical immutable Morpho Blue deployments.
    function _myMarket()
        private view
        returns (ILoanMarketsFacet.Market memory _market)
    {
        _market = ILoanMarketsFacet(controller).getLoanMarket(subaccountType);
        require(
            _market.morpho != address(0),
            ILoanMarketsFacet.MarketNotRegistered(subaccountType)
        );
    }

    /// @dev The account's live borrow shares on its market - the exact test for "is there
    /// any debt", read live from Morpho every time (nothing is cached).
    function _borrowSharesOf(
        ILoanMarketsFacet.Market memory _market
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
        ILoanMarketsFacet.Market memory _market
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
