// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {IMorphoLoanSubaccountRemote} from "../../userInterfaces/IMorphoLoanSubaccountRemote.sol";
import {
    ACTION_BORROW,
    ACTION_WITHDRAW,
    ACTION_DEPOSIT_COLLATERAL,
    ACTION_CANCEL,
    ACTION_REDEEM_HOME,
    DESTINATION_KIND_EVM
} from "../../userInterfaces/ILoanSubaccount.sol";
import {IComposeTransportFacet} from "../../userInterfaces/facets/IComposeTransportFacet.sol";
import {IMorphoLoanMarketsFacet} from "../../userInterfaces/facets/IMorphoLoanMarketsFacet.sol";
import {PAYLOAD_VERSION_1} from "../../userInterfaces/IComposeReceiverAccountBase.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IMorpho} from "../interface/IMorpho.sol";
import {IIrm} from "../interface/IIrm.sol";
import {IOracle} from "../interface/IOracle.sol";
import {MorphoMath} from "../library/MorphoMath.sol";
import {LoanMath} from "../library/LoanMath.sol";
import {SubaccountBase} from "./SubaccountBase.sol";
import {ComposeReceiverAccountBase} from "./ComposeReceiverAccountBase.sol";

/**
 * @title MorphoLoanSubaccountRemote contract
 * @notice The loan-chain-side subaccount implementation (Ethereum, at launch): same frozen
 * proxy and CREATE2 address as the Flare-side account, resolved per type through the
 * controller-as-beacon. Authenticated compose actions ({ComposeReceiverAccountBase}), sent by
 * this same account on Flare, operate on its type's write-once Morpho market - so the address
 * itself commits to the pool. Repayment, idle-collateral deposit and the fee checkpoint are
 * permissionless fixed rails, and nothing here is parent-callable: Morpho collateral and debt
 * move only behind the compose authentication. Idle FXRP has
 * one route, into the position ({depositIdleFxrp}), from where the signed withdraw action
 * brings it home under the position's ordinary conditions. Across the rails and the signed
 * actions every destination is fixed on-chain - the account's own position, the parent, the
 * governance-set fee recipient, or (the withdraw's return leg) this account's own address on
 * Flare - so no caller ever
 * chooses a destination, a market or an amount source. The one user-chosen destination is a
 * signed borrow's disbursement, authorized by the XRPL signature its payload carries.
 * @dev No native rail: the only protocol-delivered native is a withdraw delivery's compose
 * value (the return leg's fee), spent or forwarded to the parent within the same call, so a
 * plain send reverts; native landing without a call (pre-deployment funding, an LZ native
 * drop, a force-send) strands until a beacon upgrade adds a rail - accepted.
 */
contract MorphoLoanSubaccountRemote is IMorphoLoanSubaccountRemote, SubaccountBase, ComposeReceiverAccountBase {
    using SafeERC20 for IERC20;

    /// @dev The market's borrow side brought to the current block, and this account's position
    /// on it, as the read surface needs them: the accrued totals, the pool's remaining liquidity,
    /// the account's shares, collateral and live debt.
    struct MarketView {
        uint256 shares;
        uint256 collateral;
        uint256 totalBorrowAssets;
        uint256 totalBorrowShares;
        uint256 liquidity;
        uint256 debt;
    }

    /// @dev WAD fixed point, the fee carry's precision (the fee formulas themselves live in
    /// {LoanMath}, shared with the read surface).
    uint256 private constant WAD = LoanMath.WAD;
    /// @dev Morpho's oracle scale: `loanAmount = mulDiv(collateralAmount, price, 1e36)`.
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;

    // this lineage's own linear state starts right after ControlledAccountBase's slot 0 (the
    // bases' other state is namespaced): the canonical principal at the last checkpoint, the
    // WAD fee carry, and the checkpoint clock and rate snapshot the next period is priced at
    uint256 private feePrincipal;
    uint256 private flareDebtX18;
    uint64 private feeLastCheckpoint;
    uint64 private feeSnapshotFloor;
    uint64 private feeSnapshotSpread;

    // deliberately no receive() and no native exit: a withdraw delivery's compose value is
    // spent or forwarded in-call; pre-deployment, dropped or force-sent native strands

    /// @inheritdoc IMorphoLoanSubaccountRemote
    function repay()
        external
        nonReentrant
        returns (uint256 _assets)
    {
        // no pause gate: repaying moves the position toward safety, and must stay available
        IMorphoLoanMarketsFacet.Market memory market = _myMarket();
        IERC20 loanToken = IERC20(market.marketParams.loanToken);
        uint256 balance = loanToken.balanceOf(address(this));
        require(balance > 0, NothingToRepay());

        // fee checkpoint before, re-sync after. Shares first: the debt-free paths must not
        // depend on accrual (a reverting IRM must not trap recoverable tokens)
        _checkpointFee(market);
        if (_borrowSharesOf(market) > 0) {
            // accrue first, so the clamp compares against the live debt (idempotent after
            // the checkpoint's accrual)
            IMorpho(market.morpho).accrueInterest(market.marketParams);
            (uint128 borrowShares, uint256 fullDebt) = _debtOf(market);
            uint256 collectible = flareDebtX18 / WAD;
            if (balance < fullDebt + collectible) {
                // a payment short of debt plus fee is split pro rata between the two: the
                // fee's share (rounded down, the remainder to the debt) is paid first,
                // best-effort - refused by the token (a frozen recipient), it stays in the
                // balance and repays debt (if that closes the debt, the tail below retries
                // the remainder and reserves what still cannot be paid); what the tail
                // cannot pay either stays owed
                uint256 feeShare = LoanMath.feeShare(balance, fullDebt, collectible);
                if (feeShare > 0) {
                    address recipient = _feeRecipient();
                    uint256 paid = _payFee(loanToken, recipient, feeShare);
                    if (paid == 0) {
                        emit LoanFeeDeferred(recipient, feeShare);
                    }
                    balance -= paid;
                }
            }
            if (balance >= fullDebt) {
                // the balance covers the whole debt (from the split when the paid share's
                // round-down leaves exactly the debt, or when a deferred share leaves the
                // full payment available): close by exact borrow shares (no over-repay
                // revert) - Morpho pulls exactly the debt, the tail handles any remainder
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
            _syncFeePrincipal(market);
            emit LoanRepaid(_parentAccount(), _assets);
        }

        _collectFeeAndPushSurplus(market, loanToken);
    }

    /// @inheritdoc IMorphoLoanSubaccountRemote
    function checkpointFee()
        external
        nonReentrant
    {
        // permissionless, pause-exempt: also the liquidated account's relief (the floor
        // accrues on the stale principal until someone checkpoints)
        _checkpointFee(_myMarket());
    }

    /// @inheritdoc IMorphoLoanSubaccountRemote
    function depositIdleFxrp()
        external
        nonReentrant
        returns (uint256 _amount)
    {
        IMorphoLoanMarketsFacet.Market memory market = _myMarket();
        _checkDepositAllowed(market);
        _amount = _supplyBalance(market);
        require(_amount > 0, NothingToDeposit());
        emit IdleFxrpDeposited(_parentAccount(), _amount);
    }

    /// @inheritdoc IMorphoLoanSubaccountRemote
    function getLoanFeeState()
        external view
        returns (
            uint256 _principal,
            uint256 _feeDebtX18,
            uint256 _collectible,
            uint64 _lastCheckpoint,
            uint64 _feeFloor,
            uint64 _feeSpread
        )
    {
        return (
            feePrincipal,
            flareDebtX18,
            flareDebtX18 / WAD,
            feeLastCheckpoint,
            feeSnapshotFloor,
            feeSnapshotSpread
        );
    }

    /// @inheritdoc IMorphoLoanSubaccountRemote
    function getLoanPosition()
        external view
        returns (LoanPosition memory _position)
    {
        IMorphoLoanMarketsFacet.Market memory market = _myMarket();
        MarketView memory view_ = _marketView(market);
        _position.collateral = view_.collateral;
        _position.idleCollateral = IERC20(market.marketParams.collateralToken).balanceOf(address(this));
        _position.idleLoanToken = IERC20(market.marketParams.loanToken).balanceOf(address(this));
        _position.debt = view_.debt;
        _position.feeDebtX18 = _projectedFeeX18(view_.debt);
        _position.oraclePrice = _oraclePrice(market);
        _position.collateralValue =
            Math.mulDiv(view_.collateral, _position.oraclePrice, ORACLE_PRICE_SCALE);
        _position.lltv = market.marketParams.lltv;
        _position.requiredCover =
            LoanMath.requiredCover(view_.debt, _position.feeDebtX18 / WAD, market.marketParams.lltv);
        _position.morphoHealthFactor = view_.debt == 0
            ? type(uint256).max
            : Math.mulDiv(Math.mulDiv(_position.collateralValue, market.marketParams.lltv, WAD), WAD, view_.debt);
        _position.liquidationPrice = _liquidationPrice(view_.debt, view_.collateral, market.marketParams.lltv);
    }

    /// @inheritdoc IMorphoLoanSubaccountRemote
    function getLoanLimits(
        uint256 _additionalCollateral
    )
        external view
        returns (LoanLimits memory _limits)
    {
        IMorphoLoanMarketsFacet.Market memory market = _myMarket();
        MarketView memory view_ = _marketView(market);
        uint256 collectible = _projectedFeeX18(view_.debt) / WAD;
        uint256 price = _oraclePrice(market);
        _limits.marketLiquidity = view_.liquidity;
        _limits.maxWithdraw = _maxWithdraw(view_, collectible, price, market.marketParams.lltv);
        uint256 supplied = view_.collateral
            + IERC20(market.marketParams.collateralToken).balanceOf(address(this))
            + _additionalCollateral;
        _limits.maxBorrowByCover = _maxBorrow(
            view_, collectible, Math.mulDiv(supplied, price, ORACLE_PRICE_SCALE), market.marketParams.lltv
        );
    }

    /// @inheritdoc IMorphoLoanSubaccountRemote
    function previewRepay(
        uint256 _additionalLoanToken
    )
        external view
        returns (RepayPreview memory _preview)
    {
        IMorphoLoanMarketsFacet.Market memory market = _myMarket();
        // shares-first, as repay is: a debt-free account's preview reads no rate model, so it
        // stays available where repay does - the fee-only settlement and the surplus recovery
        // of an account whose market's IRM has died
        MarketView memory view_;
        if (_borrowSharesOf(market) != 0) {
            view_ = _marketView(market);
        }
        uint256 collectible = _projectedFeeX18(view_.debt) / WAD;
        uint256 idle = IERC20(market.marketParams.loanToken).balanceOf(address(this));
        _preview = _simulateRepay(view_, collectible, idle + _additionalLoanToken);
        uint256 owed = view_.debt + collectible;
        _preview.closingTopUp = owed > idle ? owed - idle : 0;
    }

    /// @inheritdoc IMorphoLoanSubaccountRemote
    function previewWithdraw(
        uint256 _amount
    )
        external view
        returns (WithdrawPreview memory _preview)
    {
        IMorphoLoanMarketsFacet.Market memory market = _myMarket();
        MarketView memory view_ = _marketView(market);
        uint256 collectible = _projectedFeeX18(view_.debt) / WAD;
        uint256 lltv = market.marketParams.lltv;
        _preview.requiredCover = LoanMath.requiredCover(view_.debt, collectible, lltv);
        _preview.remainingValue = _remainingValue(view_.collateral, _amount, _oraclePrice(market));
        _preview.coverSatisfied =
            _preview.requiredCover == 0 || _preview.remainingValue >= _preview.requiredCover;
        if (!_preview.coverSatisfied) {
            uint256 idle = IERC20(market.marketParams.loanToken).balanceOf(address(this));
            _preview.minimumTopUp = _minimumTopUp(view_, collectible, idle, _preview.remainingValue, lltv);
        }
    }

    /// @inheritdoc IMorphoLoanSubaccountRemote
    function previewBorrow(
        uint256 _amount,
        uint256 _additionalCollateral
    )
        external view
        returns (BorrowPreview memory _preview)
    {
        IMorphoLoanMarketsFacet.Market memory market = _myMarket();
        MarketView memory view_ = _marketView(market);
        uint256 supplied = view_.collateral
            + IERC20(market.marketParams.collateralToken).balanceOf(address(this))
            + _additionalCollateral;
        _preview.collateralValue = Math.mulDiv(supplied, _oraclePrice(market), ORACLE_PRICE_SCALE);
        _preview.debtAfter = _debtAfterBorrow(view_, _amount);
        _preview.requiredCover =
            LoanMath.requiredCover(_preview.debtAfter, _projectedFeeX18(view_.debt) / WAD, market.marketParams.lltv);
        _preview.coverSatisfied = _preview.collateralValue >= _preview.requiredCover;
        _preview.marketLiquidity = view_.liquidity;
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
            _executeBorrow(_actionData, _guid);
        } else if (_action == ACTION_WITHDRAW) {
            _executeWithdraw(_actionData, _guid);
        } else if (_action == ACTION_DEPOSIT_COLLATERAL) {
            _executeDepositCollateral(_guid, _amountLD);
        } else if (_action == ACTION_CANCEL) {
            _executeCancel(_actionData, _guid);
        } else {
            revert UnsupportedAction(_action);
        }
    }

    /// @dev The withdraw action spends compose value in the same call - the return leg's
    /// LayerZero fee, with the excess pushed to the parent - so it opts in; every
    /// other action must not carry value (a mistaken delivery stays retriable without it).
    /// @dev Adding `ACTION_BORROW` here is what enables a destination kind that pays for its own
    /// onward delivery, and it must account for the native in three places, not one: a
    /// SUCCESSFUL EVM disbursement would then be allowed to carry value it never spends (this
    /// path leaves native untouched, and the account has no rail to recover it, so that value
    /// must be refused or refunded), a terminal skip already sweeps to the parent, and whatever
    /// the onward delivery leaves unspent must go the same way.
    function _acceptsComposeValue(
        uint8 _action
    )
        internal pure override
        returns (bool)
    {
        return _action == ACTION_WITHDRAW;
    }

    /// @dev Consumes an operation id so the borrow or withdraw packet carrying it can never
    /// execute. Deliberately minimal: no pause check (revoking an authority is not new
    /// exposure), no deadline (a late cancellation is unnecessary or still correct), no market
    /// or terms read, nothing moved. An id already consumed - the original executed first, or
    /// this cancellation was delivered twice - finalizes without an event rather than
    /// reverting, so a lost race cannot leave the packet retriable forever.
    function _executeCancel(
        bytes memory _actionData,
        bytes32 _guid
    )
        private
    {
        bytes32 operationId = abi.decode(_actionData, (bytes32));
        require(operationId != bytes32(0), InvalidOperationId());
        if (_operationUsed(operationId)) {
            return;
        }
        _markOperationUsed(operationId);
        emit LoanActionCancelled(_parentAccount(), operationId, _guid);
    }

    /// @dev Supplies the whole idle FXRP balance (if any) as collateral and borrows on the
    /// type's market, disbursing to the destination. Temporary debt gates revert rather than
    /// skip, so the packet stays retriable.
    function _executeBorrow(
        bytes memory _actionData,
        bytes32 _guid
    )
        private
    {
        (
            bytes32 operationId,
            uint64 deadline,
            uint8 destinationKind,
            bytes32 destination,
            uint256 borrowAmount,
            uint256 minComposeValue
        ) = abi.decode(_actionData, (bytes32, uint64, uint8, bytes32, uint256, uint256));
        require(borrowAmount > 0, ZeroAmount());
        require(operationId != bytes32(0), InvalidOperationId());
        // the floor is reserved for a kind that pays for its own onward delivery; the EVM
        // disbursement spends nothing here, so naming one is a malformed instruction (the
        // Flare sender refuses it too, before the bridge fee)
        if (destinationKind == DESTINATION_KIND_EVM) {
            require(minComposeValue == 0, UnexpectedDeliveryValueFloor());
        }
        // the signed delivery floor comes before every consuming branch, as in the withdraw:
        // delivery is permissionless and the value unauthenticated, so a below-floor delivery
        // must revert and stay retriable rather than consume the packet with the prepaid value
        // undelivered. No kind V1 supports carries value, so today this can only refuse a
        // packet naming a floor for a kind that is unsupported anyway
        require(msg.value >= minComposeValue, InsufficientDeliveryValue(minComposeValue));
        // terminal gates come first, so a duplicate or expired delivery finalizes even when
        // borrowing is disabled or the market is not yet registered, instead of reverting
        // forever; its value must not strand on an account with no native rail
        if (_skipped(operationId, deadline, _guid)) {
            _sweepValueToParent(msg.value);
            return;
        }
        // a debt increase respects the pause and the per-type borrow switch
        _checkNotPaused();
        require(
            !IMorphoLoanMarketsFacet(controllerAddress).isLoanBorrowingDisabled(_accountType()),
            BorrowingDisabled()
        );
        // and configured fee terms (the recipient is the activation marker); a revert, not
        // a skip, so the packet stays retriable
        require(
            IMorphoLoanMarketsFacet(controllerAddress).getLoanFeeTerms(_accountType()).feeRecipient != address(0),
            FeeTermsNotConfigured()
        );
        _markOperationUsed(operationId);

        IMorphoLoanMarketsFacet.Market memory market = _myMarket();
        uint256 supplied = _supplyBalance(market);
        _borrowTo(market, destinationKind, destination, borrowAmount);
        emit LoanOpened(
            _parentAccount(),
            operationId,
            supplied,
            borrowAmount,
            destinationKind,
            destination,
            _guid
        );
    }

    /// @dev Supplies the whole idle FXRP balance as collateral - the authenticated bridged
    /// amount and any residue - without changing debt. The action carries no operation id and
    /// no deadline: a deposit only adds the user's own collateral, which the permissionless
    /// rail can do with the same tokens anyway, so a re-issued one (a new packet - a delivered
    /// compose cannot replay) deposits again and a late one
    /// is harmless (the same reasoning that leaves the Flare redeem-home id-less). During a
    /// pause only an indebted position may receive it - defending stays available, new
    /// exposure waits - and a temporary rejection reverts, leaving the packet retriable.
    function _executeDepositCollateral(
        bytes32 _guid,
        uint256 _bridgedAmount
    )
        private
    {
        require(_bridgedAmount > 0, ZeroAmount());
        IMorphoLoanMarketsFacet.Market memory market = _myMarket();
        _checkDepositAllowed(market);
        // the credit already sits on the account (the OFT delivered it a transaction ago), so
        // it goes in with whatever else is here; the rail may already have deposited it (the
        // accepted race), in which case nothing is left to supply and that is fine
        uint256 supplied = _supplyBalance(market);
        emit CollateralDeposited(_parentAccount(), supplied, _guid);
    }

    /// @dev Supplies the account's whole FXRP balance as collateral and returns the amount, zero
    /// when nothing is here. Every FXRP on this account is the user's own and has one route, the
    /// position: a packet's freshly delivered credit, a skipped packet's credit, a direct send -
    /// there is no distinction to draw, so all of it goes in. The permissionless rail may have
    /// put a credit into the position before its packet is delivered (the accepted race),
    /// leaving nothing to supply; a message-only borrow arrives with nothing idle by design.
    function _supplyBalance(
        IMorphoLoanMarketsFacet.Market memory _market
    )
        private
        returns (uint256 _supplied)
    {
        IERC20 fxrp = IERC20(_market.marketParams.collateralToken);
        _supplied = fxrp.balanceOf(address(this));
        if (_supplied > 0) {
            fxrp.forceApprove(_market.morpho, _supplied);
            IMorpho(_market.morpho).supplyCollateral(
                _market.marketParams, _supplied, address(this), ""
            );
        }
    }

    /// @dev Borrows `_amount` on the position as it stands and sends it to the destination.
    /// The fee is checkpointed before and its principal re-synced after (an unsynced new
    /// principal would read as market interest at the next checkpoint), and the cover gate runs
    /// on the resulting position before anything leaves: a borrow past it reverts, retriably,
    /// with nothing sent. Morpho's own health check ran inside the borrow; the gate implies
    /// it, so it is the binding one whenever Morpho passed.
    function _borrowTo(
        IMorphoLoanMarketsFacet.Market memory _market,
        uint8 _destinationKind,
        bytes32 _destination,
        uint256 _amount
    )
        private
    {
        // only the EVM/ERC-20 form is implemented; the Wormhole-to-XRPL kind is reserved
        require(
            _destinationKind == DESTINATION_KIND_EVM,
            UnsupportedDestinationKind(_destinationKind)
        );
        // a clean zero-padded, non-zero EVM address that is not this account (the proceeds
        // could only repay the new debt); the parent Personal Account - the user's own
        // compose-driven account on this chain - is a valid target
        address destinationAddress = address(uint160(uint256(_destination)));
        require(
            uint256(_destination) >> 160 == 0 &&
                destinationAddress != address(0) &&
                destinationAddress != address(this),
            InvalidDestination()
        );
        _checkpointFee(_market);
        (uint256 assetsBorrowed, ) = IMorpho(_market.morpho).borrow(
            _market.marketParams, _amount, 0, address(this), address(this)
        );
        _syncFeePrincipal(_market);
        _requirePositionCovered(_market, 0);
        IERC20(_market.marketParams.loanToken).safeTransfer(destinationAddress, assetsBorrowed);
    }

    /// @dev The atomic withdrawal: withdraws collateral and bridges the withdrawn amount home
    /// with the redeem-home compose in the same execution - no idle window, so the redeposit race
    /// cannot touch a withdrawal. The delivered compose value pays the return leg's live quote
    /// against the signed `returnOptions`, with the excess to the parent; too little value or
    /// any other failure reverts and leaves the delivery retriable. Morpho enforces position
    /// health.
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
            uint256 minAmount,
            uint256 minComposeValue,
            bytes memory returnOptions
        ) = abi.decode(_actionData, (bytes32, uint64, uint256, uint256, uint256, bytes));
        require(amount > 0, ZeroAmount());
        require(operationId != bytes32(0), InvalidOperationId());
        // the arrival floor the sender signed for the return leg: the adapter is fee-capable
        // and this quote happens after the instruction was signed, so the allowance travels
        // with it rather than being read here
        require(
            minAmount > 0 && minAmount <= amount,
            InvalidMinAmountReceived(amount, minAmount)
        );
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
        // pause after the terminal gates (duplicates and expired packets finalize during a
        // pause); the exit itself waits - it rides the OFT
        _checkNotPaused();
        IMorphoLoanMarketsFacet.Market memory market = _myMarket();
        // the cover gate: a live fee principal checkpoints first (zero principal has nothing to
        // accrue and no snapshot worth refreshing - a borrow re-baselines itself), then the
        // withdrawal is refused (retriably) unless the collateral it leaves covers the position
        // - debt and fee are paid in loan tokens through repay, never taken from the collateral
        if (feePrincipal != 0) {
            _checkpointFee(market);
        }
        _requirePositionCovered(market, amount);
        _markOperationUsed(operationId);

        IMorpho(market.morpho).withdrawCollateral(
            market.marketParams, amount, address(this), address(this)
        );
        emit CollateralWithdrawn(_parentAccount(), operationId, amount, _guid);

        // the return leg, in the same execution; the LayerZero fee rode in as compose value
        // and its excess goes to the parent
        _bridgeHome(_getTransport(), amount, minAmount, returnOptions, msg.value);
    }

    /// @dev The soft gates shared by the borrow and the withdraw - the deposit carries no id and no
    /// deadline (see {ComposeReceiverAccountBase._terminalSkipReason}):
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
        emit LoanActionSkipped(_parentAccount(), _operationId, reason, _guid);
        return true;
    }

    /// @dev The withdraw action's return leg: sends `_amount` FXRP to this account's
    /// own Flare address (same address on every chain) with the redeem-home compose - the
    /// action and nothing else - and the Flare twin redeems whatever it then holds, this
    /// arrival included, at the price of its own public rail. `_amount` is gross and
    /// `_minAmount` the floor the sender signed on what must arrive; equal validated decimals
    /// mean the two differ only by the fee-capable adapter's cut, and a cut above the allowance
    /// reverts the delivery (retriable) rather than taking it from the user's collateral.
    /// `_options` carry the Flare-side gas and, as compose value, the redemption's executor
    /// fee - at least the Flare controller's configured fee, or the redeem-home parks until a
    /// delivery brings it or anyone sweeps (the operator, for a packet a fee change caught in
    /// flight). Exactly the quoted fee is spent from `_value` and the excess is forwarded to the
    /// parent (the endpoint is no refund target).
    function _bridgeHome(
        IComposeTransportFacet.Transport memory _transport,
        uint256 _amount,
        uint256 _minAmount,
        bytes memory _options,
        uint256 _value
    )
        private
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
            minAmountLD: _minAmount,
            extraOptions: _options,
            composeMsg: abi.encode(PAYLOAD_VERSION_1, ACTION_REDEEM_HOME, bytes("")),
            oftCmd: ""
        });

        MessagingFee memory fee = IOFT(_transport.oft).quoteSend(sendParam, false);
        require(_value >= fee.nativeFee, InsufficientFundsForBridgeHome(fee.nativeFee));

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
            _parentAccount()
        );
        // slither-disable-end arbitrary-send-eth
        fxrp.forceApprove(_transport.oft, 0);

        emit FXrpBridgedToOrigin(_parentAccount(), _amount, _transport.originEid, receipt.guid);
        // the excess never strands here (no native rail)
        _sweepValueToParent(_value - fee.nativeFee);
    }

    /// @dev Forwards compose value to the parent - a skipped withdraw's whole value, or the
    /// return leg's excess over the quoted fee: the endpoint is not a valid refund target, and
    /// this account has no native exit.
    function _sweepValueToParent(
        uint256 _value
    )
        private
    {
        if (_value == 0) {
            return;
        }
        // slither-disable-start arbitrary-send-eth
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = _parentAccount().call{value: _value}("");
        // slither-disable-end arbitrary-send-eth
        require(success, RefundFailed());
        emit NativeSweptToParent(_parentAccount(), _value);
    }

    /// @dev Prices the elapsed period at the SNAPSHOTTED terms - `owed = max(floor·P·T,
    /// I + spread·P·T)` with `I = max(0, D − P)`, so an external repayment or liquidation
    /// counts as zero interest and the delta never underflows - then re-baselines: principal
    /// to the live debt, clock to now, snapshot to the current terms. The re-baseline runs
    /// on EVERY checkpoint (a first borrow must accrue at current terms, not stale ones).
    /// Shares-first: zero principal makes no Morpho call; a zero elapsed period skips the
    /// fee math but still re-reads the debt raw (a same-block checkpoint after an external
    /// repayment must not keep a stale base); zero live shares settle at `D = 0` without
    /// touching the IRM.
    function _checkpointFee(
        IMorphoLoanMarketsFacet.Market memory _market
    )
        private
    {
        uint256 feeDeltaX18 = 0;
        uint256 principal = feePrincipal;
        if (principal != 0) {
            uint256 elapsed = block.timestamp - feeLastCheckpoint;
            if (elapsed == 0) {
                (, feePrincipal) = _debtOf(_market);
            } else {
                uint256 liveDebt = 0;
                if (_borrowSharesOf(_market) > 0) {
                    IMorpho(_market.morpho).accrueInterest(_market.marketParams);
                    (, liveDebt) = _debtOf(_market);
                }
                feeDeltaX18 = LoanMath.feeDeltaX18(
                    principal, liveDebt, elapsed, feeSnapshotFloor, feeSnapshotSpread
                );
                flareDebtX18 += feeDeltaX18;
                feePrincipal = liveDebt;
            }
        }
        IMorphoLoanMarketsFacet.FeeTerms memory terms =
            IMorphoLoanMarketsFacet(controllerAddress).getLoanFeeTerms(_accountType());
        feeLastCheckpoint = uint64(block.timestamp);
        feeSnapshotFloor = terms.feeFloor;
        feeSnapshotSpread = terms.feeSpread;
        emit LoanFeeCheckpointed(_parentAccount(), feePrincipal, feeDeltaX18);
    }

    /// @dev The cover gate, shared by the withdraw (on the remainder after `_collateralOut`) and
    /// the borrow (on the post-borrow position, `_collateralOut == 0`): the collateral left in
    /// the position, valued at the market oracle's price, must cover {LoanMath.requiredCover} of
    /// the live debt and the collectible fee - Morpho's liquidation line with a fixed headroom, so
    /// the gate implies Morpho's health check and a fresh loan is gated at `EXIT_HEADROOM / LLTV`
    /// of its debt. The debt read here is accrued: the caller's checkpoint, or the borrow just
    /// made, brought it forward. With nothing owed the gate reads no oracle (and forgives
    /// debt-free dust); a zero, dead or reverting oracle values the remainder at nothing, so
    /// the action is refused - a withdrawal is then settled through repay, oracle-free, and
    /// retried, while a borrow needs the oracle back (Morpho, whose check ran first inside the
    /// borrow, reads it too). Reverts `InsufficientRemainingCollateral` with the two numbers.
    function _requirePositionCovered(
        IMorphoLoanMarketsFacet.Market memory _market,
        uint256 _collateralOut
    )
        private
    {
        (, uint256 debt) = _debtOf(_market);
        uint256 requiredCover =
            LoanMath.requiredCover(debt, flareDebtX18 / WAD, _market.marketParams.lltv);
        if (requiredCover == 0) {
            _forgiveFeeDust();
            return;
        }
        uint256 remainingValue =
            _remainingValue(_collateralOf(_market), _collateralOut, _oraclePrice(_market));
        require(
            remainingValue >= requiredCover,
            InsufficientRemainingCollateral(requiredCover, remainingValue)
        );
    }

    /// @dev A sub-unit remainder on a debt-free position can never be transferred (ERC-20
    /// moves whole units) and never grows again - a raw-zero gate would park the exit
    /// forever over dust, so it is forgiven when a gate passes with nothing collectible.
    /// Reached only then, so the remainder is sub-unit by construction; a whole unit or more
    /// is a collectible fee and is never forgiven.
    function _forgiveFeeDust()
        private
    {
        // only on a debt-free position: a live principal still accrues. The caller has
        // established that nothing is collectible, so what is left is below one base unit
        if (feePrincipal == 0 && flareDebtX18 > 0) {
            emit LoanFeeRemainderForgiven(flareDebtX18);
            flareDebtX18 = 0;
        }
    }

    /// @dev Re-reads the canonical debt after a Morpho borrow or repayment - never the
    /// requested amount (shares and rounding matter). The clock stays: the action's
    /// checkpoint just set it.
    function _syncFeePrincipal(
        IMorphoLoanMarketsFacet.Market memory _market
    )
        private
    {
        (, feePrincipal) = _debtOf(_market);
        emit LoanFeePrincipalSynced(_parentAccount(), feePrincipal);
    }

    /// @dev The tail of {repay}, over the balance a closed or debt-free position leaves: pay
    /// `min(collectible, balance)` to the fee recipient ({_payFee}, best-effort, never rolling
    /// back the repayment), then reserve as much of the still-outstanding fee as the remaining
    /// balance covers (a later repay retries that reservation without a new top-up; an
    /// uncovered shortfall needs new funds) and send only the unreserved balance to the
    /// parent, once debt-free.
    function _collectFeeAndPushSurplus(
        IMorphoLoanMarketsFacet.Market memory _market,
        IERC20 _loanToken
    )
        private
    {
        uint256 balance = _loanToken.balanceOf(address(this));
        if (balance == 0) {
            return;
        }

        uint256 collectible = flareDebtX18 / WAD;
        if (collectible > 0) {
            address recipient = _feeRecipient();
            balance -= _payFee(_loanToken, recipient, Math.min(collectible, balance));
            uint256 reserved = Math.min(flareDebtX18 / WAD, balance);
            if (reserved > 0) {
                balance -= reserved;
                emit LoanFeeReserved(recipient, reserved);
            }
        }

        // best-effort: a parent the token refuses (RLUSD can freeze addresses) must never
        // roll back the repayment - a failed push waits here for a later repay
        if (balance > 0 && _borrowSharesOf(_market) == 0) {
            if (_loanToken.trySafeTransfer(_parentAccount(), balance)) {
                emit LoanSurplusRecovered(_parentAccount(), balance);
            } else {
                emit LoanSurplusRetained(_parentAccount(), balance);
            }
        }
    }

    /// @dev Pays `_amount` (non-zero) of the collectible fee from this account's balance to
    /// the fee recipient, best-effort: nothing moves when the token refuses the recipient
    /// (RLUSD can freeze addresses), so a repayment never rolls back; the fee debt shrinks
    /// only by the successfully requested transfer (conventional ERC-20 semantics are a
    /// registration policy). Not held by the pause: the money goes to Flare's own recipient,
    /// where an overcharge would be refundable, and holding it only made the paused route
    /// debt-first. Returns the amount paid - zero when nothing moved.
    function _payFee(
        IERC20 _loanToken,
        address _recipient,
        uint256 _amount
    )
        private
        returns (uint256)
    {
        if (!_loanToken.trySafeTransfer(_recipient, _amount)) {
            return 0;
        }
        flareDebtX18 -= _amount * WAD;
        emit LoanFeeCollected(_recipient, _amount);
        return _amount;
    }

    /// @dev The type's governance-set fee recipient. Debt, or a collectible fee, implies it
    /// is configured: the terms are the borrow activation marker.
    function _feeRecipient()
        private view
        returns (address)
    {
        return IMorphoLoanMarketsFacet(controllerAddress).getLoanFeeTerms(_accountType()).feeRecipient;
    }

    /// @dev The account's one market, bound write-once to its type. If its Morpho stops
    /// answering, this account's debt-gated paths block - inherent to where the position
    /// lives; hence the operational policy of only canonical immutable Morpho Blue deployments
    /// of the pinned v1.0.0 implementation (any other needs the conformance verification repeated).
    function _myMarket()
        private view
        returns (IMorphoLoanMarketsFacet.Market memory _market)
    {
        _market = IMorphoLoanMarketsFacet(controllerAddress).getLoanMarket(_accountType());
        require(
            _market.morpho != address(0),
            IMorphoLoanMarketsFacet.MarketNotRegistered(_accountType())
        );
    }

    /// @dev The account's collateral on its market, a plain Morpho storage read.
    function _collateralOf(
        IMorphoLoanMarketsFacet.Market memory _market
    )
        private view
        returns (uint128 _collateral)
    {
        (, , _collateral) = IMorpho(_market.morpho).position(
            MorphoMath.marketId(_market.marketParams), address(this)
        );
    }

    /// @dev The account's live borrow shares on its market - the exact test for "is there
    /// any debt", read live from Morpho every time (nothing is cached).
    function _borrowSharesOf(
        IMorphoLoanMarketsFacet.Market memory _market
    )
        private view
        returns (uint128 _borrowShares)
    {
        (, _borrowShares, ) = IMorpho(_market.morpho).position(
            MorphoMath.marketId(_market.marketParams), address(this)
        );
    }

    /// @dev The pause rule shared by the two collateral deposits: defending an indebted position
    /// survives a pause, like repayment, while a debt-free deposit is new exposure and waits it
    /// out. Debt increases and withdrawals never route through here - they stop outright. The
    /// pause is read first, on every deposit: unpaused - the common case - that is one
    /// controller read and no position read, and a controller that cannot answer the pause
    /// question refuses every deposit, indebted or not, the same fail-closed posture as
    /// {_checkNotPaused}.
    function _checkDepositAllowed(
        IMorphoLoanMarketsFacet.Market memory _market
    )
        private view
    {
        if (IPauseFacet(controllerAddress).isPaused()) {
            require(_borrowSharesOf(_market) > 0, IPauseFacet.IsPaused());
        }
    }

    /// @dev The account's live borrow shares and the assets needed to close them, using
    /// Morpho's rounded-up share conversion with virtual offsets ({MorphoMath}, pinned to
    /// upstream `SharesMathLib`).
    function _debtOf(
        IMorphoLoanMarketsFacet.Market memory _market
    )
        private view
        returns (uint128 _borrowShares, uint256 _fullDebt)
    {
        bytes32 marketId = MorphoMath.marketId(_market.marketParams);
        (, _borrowShares, ) = IMorpho(_market.morpho).position(marketId, address(this));
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) =
            IMorpho(_market.morpho).market(marketId);
        _fullDebt = MorphoMath.toAssetsUp(_borrowShares, totalBorrowAssets, totalBorrowShares);
    }

    /// @dev The market oracle's price, zero when the oracle is dead, reverting or answers zero -
    /// the gate's own treatment, so a quote reads the collateral the way the gate will.
    function _oraclePrice(
        IMorphoLoanMarketsFacet.Market memory _market
    )
        private view
        returns (uint256)
    {
        try IOracle(_market.marketParams.oracle).price() returns (uint256 _price) {
            return _price;
        } catch {
            return 0;
        }
    }

    /// @dev The market brought forward to this block the way Morpho's own accrual will bring it -
    /// the rate model's view rate compounded over the time since the market's last update, added
    /// to the borrow and supply totals within their uint128 bounds (a market without a rate model
    /// earns nothing) - and this account's shares, collateral and the debt those shares represent
    /// on the accrued totals. Reverts where the rate model does: every debt-bearing action would.
    function _marketView(
        IMorphoLoanMarketsFacet.Market memory _market
    )
        private view
        returns (MarketView memory _view)
    {
        bytes32 marketId = MorphoMath.marketId(_market.marketParams);
        (, uint128 shares, uint128 collateral) = IMorpho(_market.morpho).position(marketId, address(this));
        IMorpho.Market memory market;
        (
            market.totalSupplyAssets,
            market.totalSupplyShares,
            market.totalBorrowAssets,
            market.totalBorrowShares,
            market.lastUpdate,
            market.fee
        ) = IMorpho(_market.morpho).market(marketId);
        uint256 totalBorrowAssets = market.totalBorrowAssets;
        uint256 totalSupplyAssets = market.totalSupplyAssets;
        uint256 elapsed = block.timestamp - market.lastUpdate;
        if (elapsed != 0 && _market.marketParams.irm != address(0)) {
            uint256 rate = IIrm(_market.marketParams.irm).borrowRateView(_market.marketParams, market);
            uint256 interest =
                MorphoMath.wMulDown(totalBorrowAssets, MorphoMath.wTaylorCompounded(rate, elapsed));
            // canonical accrual adds into uint128 totals and reverts past them: so does the
            // projection, rather than quoting a position the accrual could not reach
            totalBorrowAssets = SafeCast.toUint128(totalBorrowAssets + interest);
            totalSupplyAssets = SafeCast.toUint128(totalSupplyAssets + interest);
        }
        _view.shares = shares;
        _view.collateral = collateral;
        _view.totalBorrowAssets = totalBorrowAssets;
        _view.totalBorrowShares = market.totalBorrowShares;
        _view.liquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
        _view.debt = MorphoMath.toAssetsUp(shares, totalBorrowAssets, market.totalBorrowShares);
    }

    /// @dev The fee as a checkpoint in this block would leave it: the carry plus the running
    /// period priced at the snapshotted terms against `_liveDebt` ({LoanMath.feeDeltaX18}, zero
    /// with no principal or no elapsed time - exactly {_checkpointFee}'s arithmetic).
    function _projectedFeeX18(
        uint256 _liveDebt
    )
        private view
        returns (uint256)
    {
        return flareDebtX18
            + LoanMath.feeDeltaX18(
                feePrincipal, _liveDebt, block.timestamp - feeLastCheckpoint, feeSnapshotFloor, feeSnapshotSpread
            );
    }

    /// @dev The largest withdrawal the cover passes: the collateral above the amount that, at
    /// `_price`, is worth the cover (rounded up so the floor-valued remainder still covers). The
    /// whole collateral when nothing is owed; nothing under a dead oracle otherwise.
    function _maxWithdraw(
        MarketView memory _view,
        uint256 _collectible,
        uint256 _price,
        uint256 _lltv
    )
        private pure
        returns (uint256)
    {
        uint256 required = LoanMath.requiredCover(_view.debt, _collectible, _lltv);
        if (required == 0) {
            return _view.collateral;
        }
        if (_price == 0) {
            return 0;
        }
        uint256 keep = Math.mulDiv(required, ORACLE_PRICE_SCALE, _price, Math.Rounding.Ceil);
        return _view.collateral > keep ? _view.collateral - keep : 0;
    }

    /// @dev The lowest oracle price at which Morpho's health check still passes: its value floors
    /// twice (the collateral's value, then that value at the LLTV), so the price is the smallest
    /// that keeps the floored value at or above `ceil(debt / LLTV)`. Zero when debt-free; the
    /// maximum value with debt and no collateral.
    function _liquidationPrice(
        uint256 _debt,
        uint256 _collateral,
        uint256 _lltv
    )
        private pure
        returns (uint256)
    {
        if (_debt == 0) {
            return 0;
        }
        if (_collateral == 0) {
            return type(uint256).max;
        }
        uint256 minimumValue = Math.mulDiv(_debt, WAD, _lltv, Math.Rounding.Ceil);
        return Math.mulDiv(minimumValue, ORACLE_PRICE_SCALE, _collateral, Math.Rounding.Ceil);
    }

    /// @dev The largest further borrow the cover passes against `_value` of collateral. The
    /// closed form - the claim the value covers, less the debt and the fee's weight - ignores
    /// Morpho's share rounding on the way in and out, so the exact bound is found by bisection on
    /// the post-borrow debt as {_borrowTo} will see it: zero passes (the position is
    /// covered, or the closed form would be zero) and two past the closed form fails (one beyond
    /// what a share of rounding can add; were it ever to pass, the result would be a passing,
    /// non-maximal amount, never an unsafe one).
    function _maxBorrow(
        MarketView memory _view,
        uint256 _collectible,
        uint256 _value,
        uint256 _lltv
    )
        private pure
        returns (uint256)
    {
        uint256 allowedClaim = Math.mulDiv(_value, _lltv, LoanMath.EXIT_HEADROOM);
        uint256 owed = _view.debt + LoanMath.FEE_WEIGHT * _collectible;
        if (allowedClaim <= owed) {
            return 0;
        }
        uint256 low = 0;
        uint256 high = allowedClaim - owed + 2;
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            if (LoanMath.requiredCover(_debtAfterBorrow(_view, mid), _collectible, _lltv) <= _value) {
                low = mid;
            } else {
                high = mid;
            }
        }
        return low;
    }

    /// @dev The debt after borrowing `_more` on the accrued market: Morpho rounds the new shares
    /// up on the way in and the debt up on the way out.
    function _debtAfterBorrow(
        MarketView memory _view,
        uint256 _more
    )
        private pure
        returns (uint256)
    {
        uint256 sharesUp = MorphoMath.toSharesUp(_more, _view.totalBorrowAssets, _view.totalBorrowShares);
        return MorphoMath.toAssetsUp(
            _view.shares + sharesUp, _view.totalBorrowAssets + _more, _view.totalBorrowShares + sharesUp
        );
    }

    /// @dev {repay}'s allocation of `_payment`, assuming every fee transfer succeeds: with live
    /// shares, the pro-rata fee share first when the payment is short of debt plus fee, then the
    /// debt (closed by shares when the rest covers it, otherwise repaid by assets with Morpho's
    /// rounding), then the tail - the collectible from what is left, a reservation for the rest,
    /// the surplus to the parent only once debt-free.
    function _simulateRepay(
        MarketView memory _view,
        uint256 _collectible,
        uint256 _payment
    )
        private pure
        returns (RepayPreview memory _preview)
    {
        uint256 balance = _payment;
        uint256 collectible = _collectible;
        uint256 debt = _view.debt;
        if (_view.shares != 0 && balance != 0) {
            if (balance < debt + collectible) {
                uint256 share = LoanMath.feeShare(balance, debt, collectible);
                _preview.feePaid = share;
                collectible -= share;
                balance -= share;
            }
            if (balance >= debt) {
                _preview.debtPaid = debt;
                debt = 0;
            } else {
                _preview.debtPaid = balance;
                uint256 repaidShares =
                    MorphoMath.toSharesDown(balance, _view.totalBorrowAssets, _view.totalBorrowShares);
                debt = MorphoMath.toAssetsUp(
                    _view.shares - repaidShares,
                    _view.totalBorrowAssets - balance,
                    _view.totalBorrowShares - repaidShares
                );
            }
            balance -= _preview.debtPaid;
        }
        if (balance != 0 && collectible != 0) {
            uint256 paid = Math.min(collectible, balance);
            _preview.feePaid += paid;
            collectible -= paid;
            balance -= paid;
            balance -= Math.min(collectible, balance);
        }
        if (balance != 0 && debt == 0) {
            _preview.surplus = balance;
        }
        _preview.debtAfter = debt;
        _preview.collectibleAfter = collectible;
    }

    /// @dev The smallest top-up whose {repay} (with `_idle` already on the account) leaves a
    /// position the cover passes at `_valueLeft`: a binary search over the top-up, since
    /// every unit paid shrinks both claims; closing both claims (debt plus collectible less the
    /// idle balance) always suffices, so the search is bounded.
    function _minimumTopUp(
        MarketView memory _view,
        uint256 _collectible,
        uint256 _idle,
        uint256 _valueLeft,
        uint256 _lltv
    )
        private pure
        returns (uint256)
    {
        uint256 owed = _view.debt + _collectible;
        uint256 high = owed > _idle ? owed - _idle : 0;
        uint256 low = 0;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (_coveredAfterRepay(_view, _collectible, _idle + mid, _valueLeft, _lltv)) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return low;
    }

    /// @dev Whether the position {_simulateRepay} leaves after `_payment` is covered by
    /// `_valueLeft`.
    function _coveredAfterRepay(
        MarketView memory _view,
        uint256 _collectible,
        uint256 _payment,
        uint256 _valueLeft,
        uint256 _lltv
    )
        private pure
        returns (bool)
    {
        RepayPreview memory outcome = _simulateRepay(_view, _collectible, _payment);
        uint256 required = LoanMath.requiredCover(outcome.debtAfter, outcome.collectibleAfter, _lltv);
        return required == 0 || _valueLeft >= required;
    }

    /// @dev The value, in loan tokens, of the collateral left after `_collateralOut` at `_price`,
    /// rounded down; nothing when nothing is left.
    function _remainingValue(
        uint256 _collateral,
        uint256 _collateralOut,
        uint256 _price
    )
        private pure
        returns (uint256)
    {
        uint256 remaining = _collateral > _collateralOut ? _collateral - _collateralOut : 0;
        return Math.mulDiv(remaining, _price, ORACLE_PRICE_SCALE);
    }
}
