// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LoanRemoteFixture} from "./LoanRemoteFixture.sol";
import {MockFreezableToken} from "../../contracts/mock/MockFreezableToken.sol";
import {MorphoMath} from "../../contracts/smartAccounts/library/MorphoMath.sol";
import {IMorphoLoanMarketsFacet} from "../../contracts/userInterfaces/facets/IMorphoLoanMarketsFacet.sol";

/**
 * @title LoanFeeHandler
 * @notice The invariant campaign's state machine over one `MorphoLoanSubaccountRemote`: bounded time,
 * interest, borrow, repay, external repayment, liquidation, withdraw, fee-terms, pause, freeze and
 * deposit actions, each checked against a reference computed here (the spec's accrual formula, the
 * emitted events, the balances) and recorded in sticky flags the invariants read.
 */
// solhint-disable-next-line max-states-count
contract LoanFeeHandler is LoanRemoteFixture {
    struct BeforeCall {
        uint256 principal;
        uint256 fee;
        uint256 expectedDelta;
        uint256 collectorBalance;
        uint256 parentBalance;
        bytes32 stateHash;
    }

    struct Checks {
        bool accounting;
        bool zeroPrincipal;
        bool feeTransfers;
        bool conservation;
        bool surplus;
        bool repayRemainder;
        bool exitSecurity;
        bool dust;
        bool elapsedTerms;
    }

    bytes32 private constant TRANSFER = keccak256(
        "Transfer(address,address,uint256)"
    );
    bytes32 private constant CHECKPOINT = keccak256(
        "LoanFeeCheckpointed(address,uint256,uint256)"
    );
    bytes32 private constant PRINCIPAL_SYNCED = keccak256(
        "LoanFeePrincipalSynced(address,uint256)"
    );
    bytes32 private constant COLLECTED = keccak256(
        "LoanFeeCollected(address,uint256)"
    );
    bytes32 private constant RESERVED = keccak256(
        "LoanFeeReserved(address,uint256)"
    );
    bytes32 private constant FORGIVEN = keccak256(
        "LoanFeeRemainderForgiven(uint256)"
    );
    bytes32 private constant SURPLUS = keccak256(
        "LoanSurplusRecovered(address,uint256)"
    );

    Checks public checks;
    uint64 private nonce;
    // the borrow shares at the account's last fee-base record, and whether a liquidation has
    // taken collateral since: observed from this handler's own actions and the account's events
    uint128 private recordedShares;
    bool private liquidatedSinceRecord;
    uint256 public initialSupply;
    uint256 public minted;
    uint256 public burned;
    uint256 public successfulBorrows;
    uint256 public successfulRepays;
    uint256 public successfulWithdrawals;
    uint256 public checkpoints;
    uint256 public externalRepayments;
    uint256 public liquidations;
    uint256 public termsChanges;
    uint256 public pauses;
    uint256 public freezes;
    uint256 public zeroPrincipalCheckpoints;
    uint256 public feeTransfers;
    uint256 public surplusPushes;
    uint256 public dustForfeitures;
    uint256 public successfulDeposits;
    uint256 public depositCheckpoints;
    uint256 public successfulFeeBearingWithdrawals;
    uint256 public elapsedTermsChangeCheckpoints;
    uint256 public feeReservations;
    bool public baselineCorrect = true;
    bool public depositsCorrect = true;
    bool public operationsCorrect = true;
    bool public reservationsCorrect = true;
    bool private pendingElapsedTermsChange;

    constructor() {
        _setUpRemoteFixture();
        _open(5_000e18);
        // the opening borrow recorded the account's fee base before any event is observed here
        recordedShares = _shares();
        nonce = 10;
        initialSupply = loanToken.totalSupply();
        checks = Checks(true, true, true, true, true, true, true, true, true);
        _checkBaseline();
    }

    /// Advances at most 30 days and queues at most 1% debt interest; the clock cannot overflow.
    /// Interest is queued only when time actually passed: Morpho's accrual is a pure function
    /// of elapsed time, so interest at zero elapsed is a state the real market cannot be in -
    /// and one the account's checkpoint rightly assumes away when it re-syncs the principal
    /// from stored totals in the same second (the zero-elapsed branch of `_checkpointFee`).
    function advanceTime(
        uint32 _elapsed,
        uint96 _interest
    )
        external
    {
        uint256 elapsed = bound(_elapsed, 0, 30 days);
        vm.warp(block.timestamp + elapsed);
        uint256 debt = _debt();
        if (debt != 0 && elapsed != 0) {
            morpho.addPendingInterest(
                MorphoMath.marketId(params),
                bound(_interest, 0, debt / 100)
            );
        }
        _checkConservation();
    }

    /// Sends a fresh authenticated borrow, preserving OFT credit even when execution is paused/unhealthy.
    function borrow(
        uint96 _amount,
        uint64 _collateralAmount
    )
        external
    {
        uint256 amount = bound(_amount, 1, 1_000e18);
        uint256 collateral = bound(_collateralAmount, 1, 1_000e6);
        uint256 collateralBefore = _collateral();
        fxrp.mint(address(account), collateral);
        uint256 idle = fxrp.balanceOf(address(account));
        BeforeCall memory beforeCall = _beforeCall();
        nonce++;
        bytes32 operationId = bytes32(uint256(nonce));
        (bytes memory message, bytes32 guid) = _queue(
            address(account),
            nonce,
            collateral,
            _borrow(operationId, amount)
        );
        vm.recordLogs();
        // Expected operational failures are caught; reference failures are sticky invariant flags.
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = address(endpoint).call(
            abi.encodeCall(
                endpoint.deliver,
                (address(oft), address(account), guid, message)
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (success) {
            successfulBorrows++;
            _checkEvents(beforeCall, logs, true);
            _checkBaseline();
            if (!_exitCovered()) {
                checks.exitSecurity = false;
            }
            if (
                !account.usedOperations(operationId) ||
                loanToken.balanceOf(parent) !=
                    beforeCall.parentBalance + amount ||
                _collateral() != collateralBefore + idle ||
                fxrp.balanceOf(address(account)) != 0
            ) {
                operationsCorrect = false;
            }
        } else {
            _checkFailure(beforeCall);
            if (
                account.usedOperations(operationId) ||
                loanToken.balanceOf(parent) != beforeCall.parentBalance ||
                _collateral() != collateralBefore ||
                fxrp.balanceOf(address(account)) != idle
            ) {
                operationsCorrect = false;
            }
        }
        _recordSupply(success ? logs : new Vm.Log[](0));
    }

    /// Permissionless checkpoints are checked against the pre-call principal and snapshotted rates.
    function checkpointFee() external {
        BeforeCall memory beforeCall = _beforeCall();
        vm.recordLogs();
        account.checkpointFee();
        checkpoints++;
        _checkEvents(beforeCall, vm.getRecordedLogs(), false);
        _checkBaseline();
        _checkConservation();
    }

    /// Covers partial, boundary, covering and debt-free reserve-retry repayments.
    function repay(
        uint96 _amount,
        uint8 _kind
    )
        external
    {
        BeforeCall memory beforeCall = _beforeCall();
        bool hadShares = _shares() != 0;
        uint256 expectedFee = (beforeCall.fee + beforeCall.expectedDelta) / WAD;
        uint256 debtWithPending =
            _debt() + morpho.pendingInterest(MorphoMath.marketId(params));
        uint256 amount =
            _kind % 3 == 0
                ? debtWithPending + expectedFee + bound(_amount, 1, 100e18)
                : bound(_amount, 1, 1_000e18);
        vm.recordLogs();
        loanToken.mint(address(account), amount);
        account.repay();
        successfulRepays++;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkEvents(beforeCall, logs, hadShares);
        _checkBaseline();
        if (
            loanToken.balanceOf(parent) > beforeCall.parentBalance &&
            _shares() != 0
        ) {
            checks.surplus = false;
        }
        if (_shares() != 0 && loanToken.balanceOf(address(account)) != 0) {
            checks.repayRemainder = false;
        }
        _recordSupply(logs);
    }

    /// An external donor changes canonical debt without updating the account's stored fee principal.
    function externalRepay(
        uint96 _fraction,
        bool _full
    )
        external
    {
        uint128 shares = _shares();
        if (shares == 0) {
            return;
        }
        uint256 selected = _full ? shares : bound(_fraction, 1, shares);
        uint256 funding =
            _debt() + morpho.pendingInterest(MorphoMath.marketId(params)) + 1;
        BeforeCall memory beforeCall = _beforeCall();
        vm.recordLogs();
        loanToken.mint(address(this), funding);
        loanToken.approve(address(morpho), funding);
        morpho.repay(params, 0, selected, address(account), "");
        externalRepayments++;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkEvents(beforeCall, logs, false);
        _recordSupply(logs);
    }

    /// A price drop makes the position unhealthy before a modeled partial or full liquidation.
    function liquidate(
        uint96 _fraction,
        bool _full
    )
        external
    {
        uint128 shares = _shares();
        uint256 collateral = _collateral();
        if (shares == 0 || collateral == 0) {
            return;
        }
        oracle.setPrice(Math.mulDiv(_debt(), 1e36, collateral));
        uint128 selected =
            _full ? shares : uint128(bound(_fraction, 1, shares));
        uint256 funding =
            _debt() + morpho.pendingInterest(MorphoMath.marketId(params)) + 1;
        BeforeCall memory beforeCall = _beforeCall();
        vm.recordLogs();
        loanToken.mint(address(this), funding);
        loanToken.approve(address(morpho), funding);
        morpho.simulatePartialLiquidation(params, address(account), selected);
        if (_collateral() < collateral) {
            liquidatedSinceRecord = true;
        }
        liquidations++;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkEvents(beforeCall, logs, false);
        _recordSupply(logs);
    }

    /// A successful withdraw must satisfy the exit gate; failed gates keep the operation unused.
    function withdraw(
        uint64 _amount
    )
        external
    {
        uint256 collateral = _collateral();
        if (collateral == 0) {
            return;
        }
        uint256 amount = bound(_amount, 1, collateral);
        BeforeCall memory beforeCall = _beforeCall();
        uint256 oftBalanceBefore = fxrp.balanceOf(address(oft));
        nonce++;
        bytes32 operationId = bytes32(uint256(nonce));
        (bytes memory message, bytes32 guid) = _queue(
            address(account),
            nonce,
            0,
            _withdraw(operationId, amount, RETURN_VALUE)
        );
        vm.recordLogs();
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = address(endpoint).call{value: RETURN_VALUE}(
            abi.encodeCall(
                endpoint.deliver,
                (address(oft), address(account), guid, message)
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (success) {
            successfulWithdrawals++;
            _checkEvents(beforeCall, logs, false);
            if (beforeCall.principal != 0) {
                _checkBaseline();
            }
            if ((beforeCall.fee + beforeCall.expectedDelta) / WAD != 0) {
                successfulFeeBearingWithdrawals++;
            }
            if (
                !account.usedOperations(operationId) ||
                _collateral() != collateral - amount ||
                fxrp.balanceOf(address(oft)) != oftBalanceBefore + amount
            ) {
                operationsCorrect = false;
            }
            if (!_exitCovered()) {
                checks.exitSecurity = false;
            }
        } else {
            _checkFailure(beforeCall);
            if (
                account.usedOperations(operationId) ||
                _collateral() != collateral ||
                fxrp.balanceOf(address(oft)) != oftBalanceBefore
            ) {
                operationsCorrect = false;
            }
        }
        _checkConservation();
    }

    /// A governance edit must leave the account's elapsed-period snapshot and fee untouched.
    function changeTerms(
        uint64 _floor,
        uint64 _spread
    )
        external
    {
        bytes32 oldState = _feeStateHash();
        (uint256 principal, , , uint64 timestamp, , ) = account.getLoanFeeState();
        if (principal != 0 && block.timestamp > timestamp) {
            pendingElapsedTermsChange = true;
        }
        uint64 feeFloor = uint64(bound(_floor, 0, WAD));
        uint64 feeSpread = uint64(bound(_spread, 0, WAD));
        _setTerms(1, feeFloor, feeSpread);
        termsChanges++;
        if (_feeStateHash() != oldState) {
            checks.elapsedTerms = false;
        }
        IMorphoLoanMarketsFacet.FeeTerms memory stored = controller.getLoanFeeTerms(
            1
        );
        if (
            stored.feeFloor != feeFloor ||
            stored.feeSpread != feeSpread ||
            stored.feeRecipient != collector
        ) {
            checks.elapsedTerms = false;
        }
        _checkConservation();
    }

    /// Pause state changes exercise the permitted repayment/checkpoint and blocked outward actions.
    function setPaused(
        bool _paused
    )
        external
    {
        if (controller.isPaused() == _paused) {
            return;
        }
        vm.prank(owner);
        if (_paused) {
            controller.pause();
        } else {
            controller.unpause();
        }
        pauses++;
        _checkConservation();
    }

    /// Issuer refusal at the fee recipient exercises deferred shares, reservations and later retries.
    function setRecipientFrozen(
        bool _frozen
    )
        external
    {
        MockFreezableToken(address(loanToken)).setFrozen(collector, _frozen);
        freezes++;
        _checkConservation();
    }

    /// Adds collateral only through the fixed public rail, including paused debt-bearing positions.
    /// With a principal the deposit checkpoints first; without one it leaves the fee state alone.
    function deposit(
        uint64 _amount
    )
        external
    {
        fxrp.mint(address(account), bound(_amount, 1, 1_000e6));
        BeforeCall memory beforeCall = _beforeCall();
        bytes32 oldFeeState = _feeStateHash();
        uint256 collateralBefore = _collateral();
        uint256 idle = fxrp.balanceOf(address(account));
        vm.recordLogs();
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = address(account).call(
            abi.encodeCall(account.depositIdleFxrp, ())
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (success) {
            successfulDeposits++;
            if (
                _collateral() != collateralBefore + idle ||
                fxrp.balanceOf(address(account)) != 0
            ) {
                depositsCorrect = false;
            }
            if (beforeCall.principal != 0) {
                depositCheckpoints++;
                _checkEvents(beforeCall, logs, false);
                _checkBaseline();
            } else if (_feeStateHash() != oldFeeState) {
                depositsCorrect = false;
            }
        } else {
            _checkFailure(beforeCall);
            if (
                _collateral() != collateralBefore ||
                fxrp.balanceOf(address(account)) != idle ||
                _feeStateHash() != oldFeeState
            ) {
                depositsCorrect = false;
            }
        }
        _checkConservation();
    }

    /// Exposes only stored accounting; no projection is mistaken for the collectible getter.
    function feeState(
    )
        external view
        returns (uint256 _principal, uint256 _fee, uint256 _collectible)
    {
        (_principal, _fee, _collectible, , , ) = account.getLoanFeeState();
    }

    function tokenTotals(
    )
        external view
        returns (uint256 _supply, uint256 _tracked)
    {
        return (loanToken.totalSupply(), _trackedBalances());
    }

    function _beforeCall(
    )
        private view
        returns (BeforeCall memory _before)
    {
        uint64 timestamp;
        uint64 floor;
        uint64 spread;
        (_before.principal, _before.fee, , timestamp, floor, spread) = account.getLoanFeeState();
        _before.stateHash = _feeStateHash();
        _before.collectorBalance = loanToken.balanceOf(collector);
        _before.parentBalance = loanToken.balanceOf(parent);
        uint256 elapsed = block.timestamp - timestamp;
        if (_before.principal == 0 || elapsed == 0) {
            return _before;
        }
        uint128 shares = _shares();
        (, , uint128 totalAssets, uint128 totalShares, , ) = morpho.market(
            MorphoMath.marketId(params)
        );
        // the account accrues before reading only while it owes; with no shares it reads the
        // stored totals, so pending interest counts only then
        uint256 assetsNow = uint256(totalAssets) + 1;
        if (shares > 0) {
            assetsNow += morpho.pendingInterest(MorphoMath.marketId(params));
        }
        uint256 debtReached = _valueUp(shares, assetsNow, totalShares);
        if (liquidatedSinceRecord) {
            uint256 held = _valueUp(recordedShares, assetsNow, totalShares);
            if (held > debtReached) {
                debtReached = held;
            }
        }
        uint256 interest =
            debtReached > _before.principal
                ? (debtReached - _before.principal) * WAD
                : 0;
        uint256 minimum = (_before.principal * uint256(floor) * elapsed) / YEAR;
        uint256 spreadCharge =
            (_before.principal * uint256(spread) * elapsed) / YEAR;
        _before.expectedDelta =
            minimum > interest + spreadCharge
                ? minimum - interest
                : spreadCharge;
    }

    // The preceding view builds the reference state consumed here.
    // solhint-disable-next-line ordering
    function _checkEvents(
        BeforeCall memory _before,
        Vm.Log[] memory _logs,
        bool _expectSync
    )
        private
    {
        uint256 added;
        uint256 paid;
        uint256 forgiven;
        uint256 synced;
        uint256 reserved;
        uint256 surplusAmount;
        bool pushed;
        bool recorded;
        for (uint256 i = 0; i < _logs.length; i++) {
            Vm.Log memory entry = _logs[i];
            if (entry.emitter != address(account) || entry.topics.length == 0) {
                continue;
            }
            if (entry.topics[0] == CHECKPOINT) {
                (, uint256 delta) = abi.decode(entry.data, (uint256, uint256));
                added += delta;
                if (delta != _before.expectedDelta) {
                    checks.elapsedTerms = false;
                }
                if (_before.principal == 0) {
                    zeroPrincipalCheckpoints++;
                } else {
                    recorded = true;
                }
                if (pendingElapsedTermsChange) {
                    elapsedTermsChangeCheckpoints++;
                    pendingElapsedTermsChange = false;
                }
            } else if (entry.topics[0] == PRINCIPAL_SYNCED) {
                synced++;
                recorded = true;
                if (abi.decode(entry.data, (uint256)) != _debt()) {
                    baselineCorrect = false;
                }
            } else if (entry.topics[0] == COLLECTED) {
                if (address(uint160(uint256(entry.topics[1]))) != collector) {
                    checks.feeTransfers = false;
                }
                paid += abi.decode(entry.data, (uint256));
                feeTransfers++;
            } else if (entry.topics[0] == RESERVED) {
                if (address(uint160(uint256(entry.topics[1]))) != collector) {
                    reservationsCorrect = false;
                }
                reserved += abi.decode(entry.data, (uint256));
                feeReservations++;
            } else if (entry.topics[0] == FORGIVEN) {
                uint256 dust = abi.decode(entry.data, (uint256));
                (uint256 principal, , , , , ) = account.getLoanFeeState();
                if (principal != 0 || dust >= WAD || dust == 0) {
                    checks.dust = false;
                }
                forgiven += dust;
                dustForfeitures++;
            } else if (entry.topics[0] == SURPLUS) {
                pushed = true;
                if (address(uint160(uint256(entry.topics[1]))) != parent) {
                    checks.surplus = false;
                }
                surplusAmount += abi.decode(entry.data, (uint256));
                surplusPushes++;
                if (_shares() != 0) {
                    checks.surplus = false;
                }
            }
        }
        (, uint256 afterFee, , , , ) = account.getLoanFeeState();
        if (_before.fee + added != afterFee + paid * WAD + forgiven) {
            checks.accounting = false;
        }
        if (_before.principal == 0 && added != 0) {
            checks.zeroPrincipal = false;
        }
        if (loanToken.balanceOf(collector) != _before.collectorBalance + paid) {
            checks.feeTransfers = false;
        }
        if (
            reserved != 0 &&
            (_shares() != 0 ||
                loanToken.balanceOf(address(account)) != reserved)
        ) {
            reservationsCorrect = false;
        }
        if (
            pushed &&
            loanToken.balanceOf(parent) != _before.parentBalance + surplusAmount
        ) {
            checks.surplus = false;
        }
        if (_expectSync != (synced == 1)) {
            baselineCorrect = false;
        }
        if (recorded) {
            recordedShares = _shares();
            liquidatedSinceRecord = false;
        }
    }

    /// Shares valued rounding up, at totals whose virtual asset is already included:
    /// the integer rational conversion, independent of the production share helper.
    function _valueUp(
        uint256 _shares,
        uint256 _assetsWithVirtual,
        uint256 _totalShares
    )
        private pure
        returns (uint256)
    {
        uint256 denominator = _totalShares + 1_000_000;
        return (_shares * _assetsWithVirtual + denominator - 1) / denominator;
    }

    /// The cover gate's reference: the collateral left, at the oracle's price, covers
    /// `(D + 2F) x 1.155 / LLTV` (rounded up) for the live debt and the collectible; with
    /// nothing owed, no cover is required.
    function _exitCovered(
    )
        private view
        returns (bool)
    {
        (, , uint256 collectible, , , ) = account.getLoanFeeState();
        uint256 required = Math.mulDiv(
            _debt() + 2 * collectible, 1.155e18, params.lltv, Math.Rounding.Ceil
        );
        return required == 0 || Math.mulDiv(_collateral(), oracle.price(), 1e36) >= required;
    }

    function _checkFailure(
        BeforeCall memory _before
    )
        private
    {
        if (_feeStateHash() != _before.stateHash) {
            checks.accounting = false;
        }
        if (loanToken.balanceOf(collector) != _before.collectorBalance) {
            checks.feeTransfers = false;
        }
    }

    function _recordSupply(
        Vm.Log[] memory _logs
    )
        private
    {
        for (uint256 i = 0; i < _logs.length; i++) {
            Vm.Log memory entry = _logs[i];
            if (
                entry.emitter != address(loanToken) ||
                entry.topics.length != 3 ||
                entry.topics[0] != TRANSFER
            ) {
                continue;
            }
            uint256 amount = abi.decode(entry.data, (uint256));
            if (entry.topics[1] == bytes32(0)) {
                minted += amount;
            }
            if (entry.topics[2] == bytes32(0)) {
                burned += amount;
            }
        }
        _checkConservation();
    }

    function _trackedBalances(
    )
        private view
        returns (uint256)
    {
        return loanToken.balanceOf(address(account)) + loanToken.balanceOf(address(morpho))
            + loanToken.balanceOf(collector) + loanToken.balanceOf(parent) + loanToken.balanceOf(address(this));
    }

    function _checkConservation() private {
        uint256 supply = loanToken.totalSupply();
        if (
            supply != _trackedBalances() ||
            initialSupply + minted != supply + burned
        ) {
            checks.conservation = false;
        }
    }

    function _checkBaseline() private {
        IMorphoLoanMarketsFacet.FeeTerms memory terms = controller.getLoanFeeTerms(1);
        (
            uint256 principal,
            ,
            ,
            uint64 timestamp,
            uint64 floor,
            uint64 spread
        ) = account.getLoanFeeState();
        if (
            principal != _debt() ||
            timestamp != block.timestamp ||
            floor != terms.feeFloor ||
            spread != terms.feeSpread
        ) {
            baselineCorrect = false;
        }
    }

    function _feeStateHash(
    )
        private view
        returns (bytes32)
    {
        (
            uint256 principal,
            uint256 fee,
            uint256 collectible,
            uint64 time,
            uint64 floor,
            uint64 spread
        ) = account.getLoanFeeState();
        return keccak256(abi.encode(principal, fee, collectible, time, floor, spread));
    }
}
