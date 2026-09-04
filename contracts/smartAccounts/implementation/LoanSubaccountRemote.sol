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
import {ACTION_REDEEM_HOME, REDEEM_HOME_TTL} from "../../userInterfaces/IBridgingSubaccount.sol";
import {PAYLOAD_VERSION_1} from "../../userInterfaces/IComposeReceiverAccountBase.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IMorpho} from "../interface/IMorpho.sol";
import {IOracle} from "../interface/IOracle.sol";
import {MorphoMath} from "../library/MorphoMath.sol";
import {SubaccountBase} from "./SubaccountBase.sol";
import {ComposeReceiverAccountBase} from "./ComposeReceiverAccountBase.sol";

/**
 * @title LoanSubaccountRemote contract
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
contract LoanSubaccountRemote is ILoanSubaccountRemote, SubaccountBase, ComposeReceiverAccountBase {
    using SafeERC20 for IERC20;

    /// @dev Fee arithmetic: annual WAD rates over a fixed 365-day year.
    uint256 private constant WAD = 1e18;
    uint256 private constant YEAR = 365 days;
    /// @dev Morpho's oracle scale: `loanAmount = mulDiv(collateralAmount, price, 1e36)`.
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    /// @dev The secured-claim gate's headroom: an exit passes uncollected while the remaining
    /// collateral is worth this multiple of the collectible fee. It allows for the fee's growth
    /// until the next gate event and for price drift, and is deliberately not
    /// liquidation-proof (the accepted junior-claim risk).
    uint256 private constant FEE_SECURITY_FACTOR = 3;

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
                uint256 feeShare = Math.mulDiv(balance, collectible, fullDebt + collectible);
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

    /// @inheritdoc ILoanSubaccountRemote
    function checkpointFee()
        external
        nonReentrant
    {
        // permissionless, pause-exempt: also the liquidated account's relief (the floor
        // accrues on the stale principal until someone checkpoints)
        _checkpointFee(_myMarket());
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
        emit IdleFxrpDeposited(_parentAccount(), _amount);
    }

    /// @inheritdoc ILoanSubaccountRemote
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
        } else {
            revert UnsupportedAction(_action);
        }
    }

    /// @dev The withdraw action spends compose value in the same call - the return leg's
    /// LayerZero fee, with the excess pushed to the parent - so it opts in; every
    /// other action must not carry value (a mistaken delivery stays retriable without it).
    function _acceptsComposeValue(
        uint8 _action
    )
        internal pure override
        returns (bool)
    {
        return _action == ACTION_WITHDRAW;
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
        require(!ILoanMarketsFacet(controllerAddress).isLoanBorrowingDisabled(_accountType()), BorrowingDisabled());
        // and configured fee terms (the recipient is the activation marker); a revert, not
        // a skip, so the packet stays retriable
        require(
            ILoanMarketsFacet(controllerAddress).getLoanFeeTerms(_accountType()).feeRecipient != address(0),
            FeeTermsNotConfigured()
        );
        _markOperationUsed(operationId);

        uint256 supplied = _supplyAndBorrow(destinationKind, destination, borrowAmount);
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
        if (IPauseFacet(controllerAddress).isPaused()) {
            require(_borrowSharesOf(_myMarket()) > 0, IPauseFacet.IsPaused());
        }

        uint256 supplied = _supplyAndBorrow(0, bytes32(0), 0);
        emit CollateralDeposited(_parentAccount(), supplied, _guid);
    }

    /// @dev The asset moves of the borrow and deposit actions, separated from the decodes to
    /// keep stack depth flat: supply the whole idle FXRP balance (if any), then borrow and
    /// disburse (if any). Returns the amount supplied.
    function _supplyAndBorrow(
        uint8 _destinationKind,
        bytes32 _destination,
        uint256 _borrowAmount
    )
        private
        returns (uint256 _supplied)
    {
        ILoanMarketsFacet.Market memory market = _myMarket();
        IERC20 fxrp = IERC20(market.marketParams.collateralToken);
        // every FXRP on this account is the user's own and has one route, the position: the
        // packet's credit and any residue (a skipped packet's credit, a direct send) that would
        // otherwise wait for the permissionless rail all go in. That rail can also have
        // deposited the credit before delivery (the accepted race), leaving nothing idle; the
        // borrow below is authorized against the position as it stands, within its deadline
        // and Morpho's health check
        _supplied = fxrp.balanceOf(address(this));
        if (_supplied > 0) {
            fxrp.forceApprove(market.morpho, _supplied);
            IMorpho(market.morpho).supplyCollateral(
                market.marketParams, _supplied, address(this), ""
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
            // fee checkpoint before, re-sync after: an unsynced new principal would read
            // as market interest at the next checkpoint
            _checkpointFee(market);
            (uint256 assetsBorrowed, ) = IMorpho(market.morpho).borrow(
                market.marketParams, _borrowAmount, 0, address(this), address(this)
            );
            _syncFeePrincipal(market);
            IERC20(market.marketParams.loanToken).safeTransfer(destinationAddress, assetsBorrowed);
        }
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
        // pause after the terminal gates (duplicates and expired packets finalize during a
        // pause); the exit itself waits - it rides the OFT
        _checkNotPaused();
        ILoanMarketsFacet.Market memory market = _myMarket();
        // the secured-claim gate: a live fee principal checkpoints first (zero principal has
        // nothing to accrue and no snapshot worth refreshing - a borrow re-baselines itself),
        // then the withdrawal is refused (retriably) if it would leave the fee under-secured -
        // the fee is paid in loan tokens through repay, never taken from the collateral
        if (feePrincipal != 0) {
            _checkpointFee(market);
        }
        require(_exitLeavesFeeSecured(market, amount), OutstandingLoanFee(flareDebtX18 / WAD));
        _markOperationUsed(operationId);

        IMorpho(market.morpho).withdrawCollateral(
            market.marketParams, amount, address(this), address(this)
        );
        emit CollateralWithdrawn(_parentAccount(), operationId, amount, _guid);

        // the return leg, in the same execution; the LayerZero fee rode in as compose value
        // and its excess goes to the parent
        _bridgeHome(_getTransport(), amount, returnOptions, msg.value);
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

    /// @dev The withdraw action's return leg: sends exactly `_amount` FXRP to this account's
    /// own Flare address (same address on every chain) with the redeem-home compose - a
    /// deadline, this block time plus `REDEEM_HOME_TTL`, and nothing else - so the Flare twin
    /// redeems at most this amount on arrival. Equal validated decimals allow
    /// `minAmountLD == amountLD`. `_options` carry the Flare-side gas and, optionally, the
    /// redemption's executor fee as compose value. Exactly the quoted fee is spent from
    /// `_value` and the excess is forwarded to the parent (the endpoint is no refund target).
    function _bridgeHome(
        IComposeTransportFacet.Transport memory _transport,
        uint256 _amount,
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
        if (_value == 0) return;
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
        ILoanMarketsFacet.Market memory _market
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
                uint256 interestX18 = (liveDebt > principal ? liveDebt - principal : 0) * WAD;
                uint256 owedX18 = Math.max(
                    Math.mulDiv(principal * feeSnapshotFloor, elapsed, YEAR),
                    interestX18 + Math.mulDiv(principal * feeSnapshotSpread, elapsed, YEAR)
                );
                feeDeltaX18 = owedX18 - interestX18;
                flareDebtX18 += feeDeltaX18;
                feePrincipal = liveDebt;
            }
        }
        ILoanMarketsFacet.FeeTerms memory terms =
            ILoanMarketsFacet(controllerAddress).getLoanFeeTerms(_accountType());
        feeLastCheckpoint = uint64(block.timestamp);
        feeSnapshotFloor = terms.feeFloor;
        feeSnapshotSpread = terms.feeSpread;
        emit LoanFeeCheckpointed(_parentAccount(), feePrincipal, feeDeltaX18);
    }

    /// @dev The secured-claim rule: the exit passes uncollected while the collateral that
    /// would remain, valued at the market oracle's price, covers FEE_SECURITY_FACTOR times
    /// the collectible fee. Zero collectible needs no reads at all (and forgives debt-free
    /// dust); a zero, dead or reverting oracle values the security at nothing, so the exit is
    /// refused (the fee is settled through repay, oracle-free, and the exit retried).
    function _exitLeavesFeeSecured(
        ILoanMarketsFacet.Market memory _market,
        uint256 _withdrawAmount
    )
        private
        returns (bool)
    {
        uint256 collectible = flareDebtX18 / WAD;
        if (collectible == 0) {
            _forgiveFeeDust();
            return true;
        }
        uint256 collateral = _collateralOf(_market);
        uint256 remaining = collateral > _withdrawAmount ? collateral - _withdrawAmount : 0;
        if (remaining == 0) return false;
        uint256 price = 0;
        try IOracle(_market.marketParams.oracle).price() returns (uint256 _price) {
            price = _price;
        } catch {
            price = 0;
        }
        if (price == 0) return false;
        return Math.mulDiv(remaining, price, ORACLE_PRICE_SCALE)
            >= FEE_SECURITY_FACTOR * collectible;
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
        ILoanMarketsFacet.Market memory _market
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
        ILoanMarketsFacet.Market memory _market,
        IERC20 _loanToken
    )
        private
    {
        uint256 balance = _loanToken.balanceOf(address(this));
        if (balance == 0) return;

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
        if (!_loanToken.trySafeTransfer(_recipient, _amount)) return 0;
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
        return ILoanMarketsFacet(controllerAddress).getLoanFeeTerms(_accountType()).feeRecipient;
    }

    /// @dev The account's one market, bound write-once to its type. If its Morpho stops
    /// answering, this account's debt-gated paths block - inherent to where the position
    /// lives; hence the operational policy of only canonical immutable Morpho Blue deployments
    /// of the pinned v1.0.0 implementation (any other needs the conformance verification repeated).
    function _myMarket()
        private view
        returns (ILoanMarketsFacet.Market memory _market)
    {
        _market = ILoanMarketsFacet(controllerAddress).getLoanMarket(_accountType());
        require(
            _market.morpho != address(0),
            ILoanMarketsFacet.MarketNotRegistered(_accountType())
        );
    }

    /// @dev The account's collateral on its market, a plain Morpho storage read.
    function _collateralOf(
        ILoanMarketsFacet.Market memory _market
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
        ILoanMarketsFacet.Market memory _market
    )
        private view
        returns (uint128 _borrowShares)
    {
        (, _borrowShares, ) = IMorpho(_market.morpho).position(
            MorphoMath.marketId(_market.marketParams), address(this)
        );
    }

    /// @dev The account's live borrow shares and the assets needed to close them, using
    /// Morpho's rounded-up share conversion with virtual offsets ({MorphoMath}, pinned to
    /// upstream `SharesMathLib`).
    function _debtOf(
        ILoanMarketsFacet.Market memory _market
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
}
