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
import {IOracle} from "../interface/IOracle.sol";
import {ComposeReceiverAccountBase} from "./ComposeReceiverAccountBase.sol";

/**
 * @title LoanSubaccountRemote contract
 * @notice The loan-chain-side subaccount implementation (Ethereum, at launch): same frozen
 * proxy and CREATE2 address as the Flare-side account, resolved per type through the
 * controller-as-beacon. Authenticated compose actions ({ComposeReceiverAccountBase}), sent by
 * this same account on Flare, operate on its type's write-once Morpho market - so the address
 * itself commits to the pool. Repayment, idle-collateral deposit and the fee checkpoint are
 * permissionless fixed rails; the one narrow direct authority is the parent's signed exit
 * {sweepToOrigin}, which can only send idle FXRP to this account's own fixed Flare address,
 * never redirect funds or touch collateral or debt. On the permissionless and cleanup rails
 * every destination is fixed on-chain - the account's own position, the parent, the
 * governance-set fee recipient, or this account's own address on Flare - so no caller ever
 * chooses a destination, a market or an amount source. The one user-chosen destination is a
 * signed borrow's disbursement, authorized by the XRPL signature its payload carries.
 * @dev No native rail: the only protocol-delivered native is a withdraw delivery's compose
 * value (the return leg's fee), spent or forwarded to the parent within the same call, so a
 * plain send reverts; native landing without a call (pre-deployment funding, an LZ native
 * drop, a force-send) strands until a beacon upgrade adds a rail - accepted.
 */
contract LoanSubaccountRemote is ILoanSubaccountRemote, ComposeReceiverAccountBase {
    using SafeERC20 for IERC20;

    /// @dev Morpho's virtual-share offsets for share/asset conversion.
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;
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

    /// @notice Parent Personal Account address (the same address on every chain; on this
    /// chain it carries no code until its remote Personal Account is created).
    address public parentPersonalAccount;
    /// @notice Subaccount type.
    uint256 public subaccountType;

    // fee state, appended after the existing fields (layout-safe): the canonical principal at
    // the last checkpoint, the WAD fee carry, and the checkpoint clock and rate snapshot the
    // next period is priced at
    uint256 private feePrincipal;
    uint256 private flareDebtX18;
    uint64 private feeLastCheckpoint;
    uint64 private feeSnapshotFloor;
    uint64 private feeSnapshotSpread;

    // deliberately no receive() and no native exit: a withdraw delivery's compose value is
    // spent or forwarded in-call; pre-deployment, dropped or force-sent native strands

    modifier onlyParent() {
        // the parent is the remote Personal Account: this method is reached only through a
        // user-signed cross-chain user operation executed by the parent
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

        // fee checkpoint before, re-sync after. Shares first: the debt-free paths must not
        // depend on accrual (a reverting IRM must not trap recoverable tokens)
        _checkpointFee(market);
        if (_borrowSharesOf(market) > 0) {
            // accrue first, so the clamp compares against the live debt (idempotent after
            // the checkpoint's accrual)
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
            _syncFeePrincipal(market);
            emit LoanRepaid(parentPersonalAccount, _assets);
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
        // check the fee claim against the full position (the sweep moves idle FXRP, not the
        // position): under-secured blocks - settle through repay or a withdraw first. A live
        // principal checkpoints first; zero principal and zero collectible need no
        // Morpho/oracle read, and debt-free dust is forgiven rather than blocking
        if (feePrincipal != 0) {
            _checkpointFee(_myMarket());
        }
        if (flareDebtX18 / WAD != 0) {
            require(
                _exitLeavesFeeSecured(_myMarket(), 0),
                OutstandingLoanFee(flareDebtX18 / WAD)
            );
        } else {
            _forgiveFeeDust();
        }

        // the OFT's own underlying is the authoritative FXRP identity on this chain
        IERC20 fxrp = IERC20(IOFT(transport.oft).token());
        _amount = fxrp.balanceOf(address(this));
        require(_amount > 0, NothingToSweep());

        // per-call value accounting: exactly the quoted fee is spent, only this call's excess
        // is refunded - pre-existing native on the account never subsidizes a caller
        _bridgeHome(transport, _amount, _extraOptions, msg.value, msg.sender);
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
            _executeWithdraw(_actionData, _guid);
        } else if (_action == ACTION_DEPOSIT_COLLATERAL) {
            _executeDepositCollateral(_actionData, _guid, _amountLD);
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

    /// @dev Supplies the authenticated bridged amount (if any) as collateral and borrows on the
    /// type's market, disbursing to the destination. Temporary debt gates revert rather than
    /// skip, so the packet stays retriable.
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
        // and configured fee terms (the recipient is the activation marker); a revert, not
        // a skip, so the packet stays retriable
        require(
            ILoanMarketsFacet(controller).getLoanFeeTerms(subaccountType).feeRecipient != address(0),
            FeeTermsNotConfigured()
        );
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

    /// @dev Supplies exactly the authenticated bridged amount as collateral, without changing
    /// debt. During a pause only an indebted position may receive it - defending stays
    /// available, new exposure waits - and a temporary rejection reverts, leaving the packet
    /// retriable.
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

    /// @dev The atomic withdrawal: withdraws collateral and bridges the net amount home with
    /// the redeem-home compose in the same execution - no idle window, so the redeposit race
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
            uint256 maxFeeFxrp,
            bytes memory returnOptions
        ) = abi.decode(_actionData, (bytes32, uint64, uint256, uint256, uint256, bytes));
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
        // the secured-claim gate: checkpoint, then collect only when this withdrawal would
        // leave the fee under-secured - FXRP deducted from the withdrawal itself, under the
        // signed cap
        _checkpointFee(market);
        uint256 fxrpFee = 0;
        address feeRecipient = address(0);
        if (!_exitLeavesFeeSecured(market, amount)) {
            (fxrpFee, feeRecipient) = _settleFeeInFxrp(market, maxFeeFxrp, amount);
        }
        usedOperations[operationId] = true;

        IMorpho(market.morpho).withdrawCollateral(
            market.marketParams, amount, address(this), address(this)
        );
        if (fxrpFee > 0) {
            IERC20(market.marketParams.collateralToken).safeTransfer(feeRecipient, fxrpFee);
        }
        emit CollateralWithdrawn(parentPersonalAccount, operationId, amount, _guid);

        // the return leg (net of an FXRP-mode fee), in the same execution; the LayerZero fee
        // rode in as compose value
        uint256 excess = _bridgeHome(
            _getTransport(), amount - fxrpFee, returnOptions, msg.value, parentPersonalAccount
        );
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
    /// exactly `_amount` FXRP to this account's own Flare address (same address on every
    /// chain) with the redeem-home compose - a deadline, this block time plus
    /// `REDEEM_HOME_TTL`, and nothing else - so the Flare twin redeems at most this amount on
    /// arrival. Equal validated decimals allow `minAmountLD == amountLD`. `_options` carry the
    /// Flare-side gas and, optionally, the redemption's executor fee as compose value. Exactly
    /// the quoted fee is spent from `_value` and the excess goes to `_excessTo` (the caller on
    /// the sweep rail, the parent on the withdraw action).
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
            // forward to the parent for the withdraw action (which emits for it)
            // slither-disable-start arbitrary-send-eth
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = _excessTo.call{value: _excess}("");
            // slither-disable-end arbitrary-send-eth
            require(success, RefundFailed());
        }

        emit FXrpSweptToOrigin(parentPersonalAccount, _amount, _transport.originEid, receipt.guid);
    }

    /// @dev Forwards a skipped withdraw's compose value to the parent: the endpoint is not a
    /// valid refund target, and this account has no native exit.
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
            ILoanMarketsFacet(controller).getLoanFeeTerms(subaccountType);
        feeLastCheckpoint = uint64(block.timestamp);
        feeSnapshotFloor = terms.feeFloor;
        feeSnapshotSpread = terms.feeSpread;
        emit LoanFeeCheckpointed(parentPersonalAccount, feePrincipal, feeDeltaX18);
    }

    /// @dev The secured-claim rule: the exit passes uncollected while the collateral that
    /// would remain, valued at the market oracle's price, covers FEE_SECURITY_FACTOR times
    /// the collectible fee. Zero collectible needs no reads at all (and forgives debt-free
    /// dust); a zero, dead or reverting oracle values the security at nothing and falls
    /// through to the settlement branch (a parked exit is settled through repay, oracle-free).
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

    /// @dev The withdraw gate's settlement: the collectible fee converts at the market
    /// oracle's price - the same write-once oracle the market's liquidations price by,
    /// rounded up so the overcollection stays below one FXRP base unit - and the caller
    /// deducts the returned amount from the withdrawn collateral before the bridge-back.
    /// The signed cap is the user's price protection (a worse price reverts, retriable); a
    /// dead or zero-priced oracle parks the exit - settle through repay (send loan tokens to
    /// the account, the free direction), then retry. The fee clears for every whole collectible unit - no partial
    /// settlement; a sub-unit X18 remainder can survive while principal lives (debt-free
    /// exits forgive it).
    function _settleFeeInFxrp(
        ILoanMarketsFacet.Market memory _market,
        uint256 _maxFeeFxrp,
        uint256 _withdrawAmount
    )
        private
        returns (uint256 _fxrpFee, address _feeRecipient)
    {
        uint256 collectible = flareDebtX18 / WAD;
        if (collectible > 0) {
            uint256 price = 0;
            try IOracle(_market.marketParams.oracle).price() returns (uint256 _price) {
                price = _price;
            } catch {
                revert OracleUnavailable();
            }
            require(price > 0, InvalidOraclePrice());
            _fxrpFee = Math.mulDiv(collectible, ORACLE_PRICE_SCALE, price, Math.Rounding.Ceil);
            require(_fxrpFee <= _maxFeeFxrp, FxrpFeeAboveSignedCap(_fxrpFee, _maxFeeFxrp));
            require(_fxrpFee < _withdrawAmount, FxrpFeeExceedsWithdrawal(_fxrpFee, _withdrawAmount));
            flareDebtX18 -= collectible * WAD;
            _feeRecipient =
                ILoanMarketsFacet(controller).getLoanFeeTerms(subaccountType).feeRecipient;
            emit LoanFeeCollectedFxrp(_feeRecipient, _fxrpFee, collectible, price);
        }
        _forgiveFeeDust();
    }

    /// @dev A sub-unit remainder on a debt-free position can never be transferred (ERC-20
    /// moves whole units) and never grows again - a raw-zero gate would park the exits
    /// forever over dust, so it is forgiven when a gate passes.
    function _forgiveFeeDust()
        private
    {
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
        emit LoanFeePrincipalSynced(parentPersonalAccount, feePrincipal);
    }

    /// @dev The tail of {repay}: pay `min(collectible, balance)` to the fee recipient -
    /// best-effort, held while paused, never rolling back the repayment; the fee debt
    /// shrinks only by the successfully requested transfer (conventional ERC-20 semantics
    /// are a registration policy) - then reserve as much of the still-outstanding fee as the
    /// remaining balance covers (a later repay retries that reservation without a new top-up;
    /// an uncovered shortfall needs new funds) and send only the unreserved balance to the
    /// parent, once debt-free. Debt implies a configured recipient.
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
            address recipient =
                ILoanMarketsFacet(controller).getLoanFeeTerms(subaccountType).feeRecipient;
            if (!IPauseFacet(controller).isPaused()) {
                uint256 payment = Math.min(collectible, balance);
                if (_loanToken.trySafeTransfer(recipient, payment)) {
                    flareDebtX18 -= payment * WAD;
                    balance -= payment;
                    collectible = flareDebtX18 / WAD;
                    emit LoanFeeCollected(recipient, payment);
                }
            }
            uint256 reserved = Math.min(collectible, balance);
            if (reserved > 0) {
                balance -= reserved;
                emit LoanFeeReserved(recipient, reserved);
            }
        }

        // best-effort: a parent the token refuses (RLUSD can freeze addresses) must never
        // roll back the repayment - a failed push waits here for a later repay
        if (balance > 0 && _borrowSharesOf(_market) == 0) {
            if (_loanToken.trySafeTransfer(parentPersonalAccount, balance)) {
                emit LoanSurplusRecovered(parentPersonalAccount, balance);
            } else {
                emit LoanSurplusRetained(parentPersonalAccount, balance);
            }
        }
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

    /// @dev The account's collateral on its market, a plain Morpho storage read.
    function _collateralOf(
        ILoanMarketsFacet.Market memory _market
    )
        private view
        returns (uint128 _collateral)
    {
        (, , _collateral) = IMorpho(_market.morpho).position(
            keccak256(abi.encode(_market.marketParams)), address(this)
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
