// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LoanForkFixture} from "../utils/LoanForkFixture.sol";
import {ILoanSubaccountRemote} from "../../contracts/userInterfaces/ILoanSubaccountRemote.sol";
import {IMorpho} from "../../contracts/smartAccounts/interface/IMorpho.sol";
import {IOracle} from "../../contracts/smartAccounts/interface/IOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MorphoMath} from "../../contracts/smartAccounts/library/MorphoMath.sol";
import {LoanMath} from "../../contracts/smartAccounts/library/LoanMath.sol";

/// @dev Canonical Morpho's liquidation entry, which the MIT mirror has no reason to declare: it
/// is used here only to make Morpho's own health check judge the quoted liquidation price.
interface IMorphoLiquidate {
    function liquidate(
        IMorpho.MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    )
        external
        returns (uint256, uint256);
}

/**
 * @title LoanSubaccountRemoteMorphoForkTest
 * @notice The loan account against the real FXRP/RLUSD market on canonical Morpho Blue, at a
 * pinned block. The unit suites prove the arithmetic against a mock whose rate a test chose;
 * these prove the same arithmetic against Morpho's own adaptive model, its share rounding, its
 * liquidity and its oracle - the premises the cover gate and the five views rest on. Canonical
 * liquidation is here for the same reason (SA-04): the boundary and what it leaves behind, both
 * of Morpho's input modes, collateral exhaustion into bad debt, self-liquidation past the cover
 * gate, and the fee state a real liquidation leaves stale. A mock cannot answer those - it has
 * no incentive factor and no bad-debt path - so they are asserted against Morpho or not at all.
 *
 * One property of the real market shapes the suite: the oracle's feed goes stale some hours past
 * the pinned block, and `price()` then reverts. A test that needs a live price therefore warps at
 * most {ORACLE_WINDOW}, where the feed answered in every run and on every endpoint tried; a test
 * that wants a dead oracle takes the feed away with a mock and asserts the price was live first,
 * so the refusal it checks is caused by the oracle dying rather than inherited from a long warp.
 * Where exactly the feed expires is the feed's business and is not asserted here.
 */
contract LoanSubaccountRemoteMorphoForkTest is LoanForkFixture {
    /// @dev 10,000 FXRP of collateral, worth about 14,524.7 RLUSD at the pinned price.
    uint256 private constant COLLATERAL = 10_000e6;
    /// @dev A warp the feed answered across every run and endpoint tried; see the note above.
    uint256 private constant ORACLE_WINDOW = 6 hours;
    /// @dev Morpho's oracle scale: `loanAmount = collateral * price / 1e36`.
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    /// @dev Canonical Morpho's liquidation incentive inputs (`Morpho.sol`, `ConstantsLib.sol`):
    /// `LIF = min(1.15, 1 / (1 - 0.3 · (1 - lltv)))`, which at this market's 77% is ~1.0741.
    uint256 private constant LIQUIDATION_CURSOR = 0.3e18;
    uint256 private constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 1.15e18;

    function setUp() public {
        _setUpForkFixture();
    }

    function testTheForkHoldsTheMarketThePremisesWereVerifiedAgainst() public onlyForked {
        // the mirror decodes canonical Morpho's real return data, and the id the account computes
        // is the market's own - the 2026-09-03 premise check, kept as a test
        assertEq(_marketId(), 0x4fa31e3f8ba345227d44e1cf48559eea53a90dd5311dc006984c060f2f311d96);
        assertEq(params.loanToken, RLUSD);
        assertEq(params.collateralToken, FXRP);
        assertEq(params.oracle, MARKET_ORACLE);
        assertEq(params.irm, MARKET_IRM);
        assertEq(params.lltv, MARKET_LLTV);
        assertEq(IERC20Metadata(FXRP).decimals(), 6);
        assertEq(IERC20Metadata(RLUSD).decimals(), 18);
        // the block was pinned for these; if they ever fail the block moved under the suite
        assertGt(_marketLiquidity(), 100_000e18, "the market must have liquidity to borrow from");
        assertGt(_elapsedSinceAccrual(), 1 hours, "the market must have interest not yet accrued");
        assertGt(IOracle(MARKET_ORACLE).price(), 0, "the oracle must be live at the pinned block");
        // and the window the rest of the suite relies on: a live price this far past the block
        vm.warp(block.timestamp + ORACLE_WINDOW);
        assertGt(IOracle(MARKET_ORACLE).price(), 0, "the oracle must still answer inside the window");
    }

    function testProjectedDebtMatchesCanonicalAccrualOnTheRealMarket() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 1_000e18);
        // let the adaptive model run over a period long enough to matter, then compare the view's
        // projection with what canonical `accrueInterest` actually writes at the same timestamp
        vm.warp(block.timestamp + 30 days);
        ILoanSubaccountRemote.LoanPosition memory position =
            ILoanSubaccountRemote(address(account)).getLoanPosition();
        // the feed is long stale by now, which the view reports rather than reverting on; the
        // debt is what this test is about, and projecting it reads no oracle
        assertEq(position.oraclePrice, 0, "the feed is stale after 30 days, as the view reports");

        // what Morpho itself would charge to close the position, accrued and converted by Morpho
        uint256 owed = _debtFromCanonicalRepayment();
        assertEq(position.debt, owed, "the projection must equal what Morpho itself asks, to the unit");
        assertGt(owed, 1_000e18, "the real model must have charged interest");
    }

    function testProjectedDebtTracksChangedUtilization() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 1_000e18);
        uint256 before = ILoanSubaccountRemote(address(account)).getLoanPosition().debt;

        // a large external borrow moves utilization, which moves the adaptive model's rate; the
        // projection must follow the market rather than a rate captured earlier
        _whaleBorrow(_marketLiquidity() / 2);

        vm.warp(block.timestamp + 30 days);
        uint256 projected = ILoanSubaccountRemote(address(account)).getLoanPosition().debt;
        assertEq(
            projected, _debtFromCanonicalRepayment(), "the projection must follow the market's own rate"
        );
        assertGt(projected, before, "interest must have accrued");
    }

    function testBorrowLimitIsExactAgainstTheRealCover() public onlyForked {
        deal(FXRP, address(account), COLLATERAL);
        _deliver(1, COLLATERAL, _deposit(), 0);

        ILoanSubaccountRemote.LoanLimits memory limits =
            ILoanSubaccountRemote(address(account)).getLoanLimits(0);
        assertGt(limits.maxBorrowByCover, 0, "the collateral must support some borrow");
        assertLt(limits.maxBorrowByCover, limits.marketLiquidity, "cover must be the binding bound here");
        // the quote is the market's free liquidity, not its size
        (uint128 totalSupplyAssets, , uint128 totalBorrowAssets, , , ) = morpho.market(_marketId());
        assertEq(
            limits.marketLiquidity,
            totalSupplyAssets - totalBorrowAssets,
            "liquidity is supply minus borrow"
        );
        assertLt(limits.marketLiquidity, totalSupplyAssets, "and it is not the total supply");

        // one unit past the bound is refused by our gate, on the real oracle's price, with the
        // numbers previewBorrow quotes for that same amount
        ILoanSubaccountRemote.BorrowPreview memory over =
            ILoanSubaccountRemote(address(account)).previewBorrow(limits.maxBorrowByCover + 1, 0);
        assertFalse(over.coverSatisfied);
        _deliverExpectingRefusal(
            2,
            _borrow(bytes32("over"), limits.maxBorrowByCover + 1),
            0,
            over.requiredCover,
            over.collateralValue
        );
        // and the bound itself executes
        _deliver(3, 0, _borrow(bytes32("at-the-bound"), limits.maxBorrowByCover), 0);
        assertEq(IERC20(RLUSD).balanceOf(parent), limits.maxBorrowByCover);
    }

    function testLiquidityBoundsTheBorrowWhereCoverDoesNot() public onlyForked {
        // enough collateral that the cover gate would allow far more than the market holds, so
        // the binding bound is Morpho's own liquidity and the refusal is Morpho's, not ours
        uint256 collateral = 1_000_000e6;
        deal(FXRP, address(account), collateral);
        _deliver(1, collateral, _deposit(), 0);

        ILoanSubaccountRemote.LoanLimits memory limits =
            ILoanSubaccountRemote(address(account)).getLoanLimits(0);
        uint256 liquidity = limits.marketLiquidity;
        assertGt(limits.maxBorrowByCover, liquidity, "cover must not be the binding bound here");

        // one unit past the free liquidity is refused by canonical Morpho itself
        (bytes memory message, bytes32 guid) =
            _packet(address(account), 2, 0, _borrow(bytes32("drain"), liquidity + 1));
        vm.prank(address(endpoint));
        vm.expectRevert(bytes("insufficient liquidity"));
        ILoanSubaccountRemote(address(account)).lzCompose(address(oft), guid, message, address(this), "");

        // and the whole of it borrows, leaving the market fully utilized
        _deliver(3, 0, _borrow(bytes32("all-of-it"), liquidity), 0);
        assertEq(IERC20(RLUSD).balanceOf(parent), liquidity);
        assertEq(_marketLiquidity(), 0, "the market is drained to the unit the quote named");
    }

    function testPreviewBorrowAgreesWithTheRealMarket() public onlyForked {
        deal(FXRP, address(account), COLLATERAL);
        _deliver(1, COLLATERAL, _deposit(), 0);
        uint256 amount = ILoanSubaccountRemote(address(account)).getLoanLimits(0).maxBorrowByCover / 2;

        ILoanSubaccountRemote.BorrowPreview memory preview =
            ILoanSubaccountRemote(address(account)).previewBorrow(amount, 0);
        assertTrue(preview.coverSatisfied);

        _deliver(2, 0, _borrow(bytes32("half"), amount), 0);
        // what Morpho actually owes, converted by Morpho itself, must be what the preview quoted
        assertEq(_debtFromCanonicalRepayment(), preview.debtAfter, "debtAfter must match the executed borrow");
        // and the collateral's value against an independent figure - Morpho's own collateral at
        // the oracle's own price, on Morpho's scale - rather than one account view against another
        uint256 expectedValue =
            (uint256(_collateral()) * IOracle(MARKET_ORACLE).price()) / ORACLE_PRICE_SCALE;
        assertEq(preview.collateralValue, expectedValue, "the preview values the real collateral");
        assertEq(
            ILoanSubaccountRemote(address(account)).getLoanPosition().collateralValue,
            expectedValue,
            "and so does the position view"
        );
    }

    function testMorphoRefusesABorrowPastItsOwnLine() public onlyForked {
        deal(FXRP, address(account), COLLATERAL);
        _deliver(1, COLLATERAL, _deposit(), 0);
        uint256 collateralValue =
            ILoanSubaccountRemote(address(account)).getLoanPosition().collateralValue;

        // past Morpho's own 77% line its health check refuses first, inside its `borrow`, so the
        // account can fail with the market's error and not only with ours
        uint256 pastMorpho = (collateralValue * MARKET_LLTV) / WAD + 1e18;
        (bytes memory message, bytes32 guid) =
            _packet(address(account), 2, 0, _borrow(bytes32("unhealthy"), pastMorpho));
        vm.prank(address(endpoint));
        vm.expectRevert(bytes("insufficient collateral"));
        ILoanSubaccountRemote(address(account)).lzCompose(address(oft), guid, message, address(this), "");
    }

    function testPreviewWithdrawMinimumTopUpIsExactWithLiveDebt() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 5_000e18);
        // inside the oracle's window, so the gate values the remainder at a live price and the
        // boundary this test is about is the cover line, not a dead feed
        vm.warp(block.timestamp + ORACLE_WINDOW);
        assertGt(ILoanSubaccountRemote(address(account)).getLoanPosition().oraclePrice, 0, "live price");

        // more than the free collateral, so clearing the gate needs a partial repayment
        uint256 amount = ILoanSubaccountRemote(address(account)).getLoanLimits(0).maxWithdraw + 1_000e6;
        ILoanSubaccountRemote.WithdrawPreview memory preview =
            ILoanSubaccountRemote(address(account)).previewWithdraw(amount);
        assertFalse(preview.coverSatisfied, "this withdrawal must not be free to leave");
        assertGt(preview.minimumTopUp, 0);
        assertLt(
            preview.minimumTopUp,
            _debtFromCanonicalRepayment(),
            "the quote must be a partial repayment, not the whole debt"
        );
        assertGt(preview.remainingValue, 0, "the remainder is valued at a live price");

        // one unit short of the quoted top-up still fails the gate
        uint256 snapshot = vm.snapshotState();
        _repayWith(preview.minimumTopUp - 1);
        ILoanSubaccountRemote.WithdrawPreview memory short =
            ILoanSubaccountRemote(address(account)).previewWithdraw(amount);
        assertFalse(short.coverSatisfied);
        _deliverExpectingRefusal(
            9,
            _withdraw(bytes32("short"), amount, 0),
            RETURN_VALUE,
            short.requiredCover,
            short.remainingValue
        );
        vm.revertToState(snapshot);

        // and the quoted top-up exactly clears it, with debt still live on the real market
        _repayWith(preview.minimumTopUp);
        assertTrue(ILoanSubaccountRemote(address(account)).previewWithdraw(amount).coverSatisfied);
        _deliver(9, 0, _withdraw(bytes32("exact"), amount, 0), RETURN_VALUE);
        assertEq(_collateral(), COLLATERAL - amount);
        assertGt(_shares(), 0, "the position must still be borrowing - this was a partial repayment");
        assertGt(_debt(), 0);
    }

    function testMaxWithdrawBoundaryIsExact() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 5_000e18);
        vm.warp(block.timestamp + ORACLE_WINDOW);

        uint256 free = ILoanSubaccountRemote(address(account)).getLoanLimits(0).maxWithdraw;
        assertGt(free, 0);
        assertLt(free, COLLATERAL, "a live borrow must hold some collateral back");

        // one unit past the quote is refused, the quote itself leaves
        ILoanSubaccountRemote.WithdrawPreview memory over =
            ILoanSubaccountRemote(address(account)).previewWithdraw(free + 1);
        assertFalse(over.coverSatisfied);
        _deliverExpectingRefusal(
            9, _withdraw(bytes32("over"), free + 1, 0), RETURN_VALUE, over.requiredCover, over.remainingValue
        );
        assertTrue(ILoanSubaccountRemote(address(account)).previewWithdraw(free).coverSatisfied);
        _deliver(9, 0, _withdraw(bytes32("exact"), free, 0), RETURN_VALUE);
        assertEq(_collateral(), COLLATERAL - free);
    }

    function testPreviewRepayMatchesRepayWithTheRealMarketsShares() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 1_000e18);
        // repayment and its preview read no oracle, so a long period is fine here
        vm.warp(block.timestamp + 45 days);

        deal(RLUSD, address(account), 400e18);
        ILoanSubaccountRemote.RepayPreview memory preview =
            ILoanSubaccountRemote(address(account)).previewRepay(0);

        uint256 feeBefore = IERC20(RLUSD).balanceOf(collector);
        ILoanSubaccountRemote(address(account)).repay();

        assertEq(IERC20(RLUSD).balanceOf(collector) - feeBefore, preview.feePaid, "fee share");
        assertEq(
            _debtFromCanonicalRepayment(), preview.debtAfter, "debt after the real repayment, as Morpho puts it"
        );
        assertEq(IERC20(RLUSD).balanceOf(address(account)), 0, "the whole payment is allocated");
    }

    function testDeadOracleRefusesTheWithdrawalAndRepayStillClosesThePosition() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 1_000e18);
        vm.warp(block.timestamp + ORACLE_WINDOW);
        // the price is live right up to the moment the feed is taken away, so the refusal below
        // is caused by the oracle dying and not inherited from a long warp
        assertGt(ILoanSubaccountRemote(address(account)).getLoanPosition().oraclePrice, 0, "live before");
        assertTrue(
            ILoanSubaccountRemote(address(account)).previewWithdraw(1e6).coverSatisfied, "free before"
        );

        vm.mockCallRevert(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), "oracle down");
        assertEq(ILoanSubaccountRemote(address(account)).getLoanPosition().oraclePrice, 0, "dead after");
        ILoanSubaccountRemote.WithdrawPreview memory dead =
            ILoanSubaccountRemote(address(account)).previewWithdraw(1e6);
        assertFalse(dead.coverSatisfied);
        _deliverExpectingRefusal(
            9, _withdraw(bytes32("dead"), 1e6, 0), RETURN_VALUE, dead.requiredCover, dead.remainingValue
        );

        // a borrow has no oracle-free route: Morpho's own health check reads the price first and
        // the feed's failure propagates, so the account cannot add debt while the oracle is dead
        (bytes memory borrowMessage, bytes32 borrowGuid) =
            _packet(address(account), 11, 0, _borrow(bytes32("blind"), 1e18));
        vm.prank(address(endpoint));
        vm.expectRevert(bytes("oracle down"));
        ILoanSubaccountRemote(address(account)).lzCompose(address(oft), borrowGuid, borrowMessage, address(this), "");

        // repayment reads no oracle, so the way out stays open with the oracle still dead
        ILoanSubaccountRemote.RepayPreview memory preview =
            ILoanSubaccountRemote(address(account)).previewRepay(0);
        deal(RLUSD, address(account), preview.closingTopUp);
        ILoanSubaccountRemote(address(account)).repay();
        assertEq(_debt(), 0, "the debt closes without the oracle");

        // debt-free and with nothing collectible, the collateral leaves oracle-free too
        _deliver(10, 0, _withdraw(bytes32("free"), COLLATERAL, 0), RETURN_VALUE);
        assertEq(_collateral(), 0);
    }

    function testLiquidationPriceIsMorphosEdgeOnTheRealMarket() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 5_000e18);
        vm.warp(block.timestamp + ORACLE_WINDOW);
        uint256 edge = ILoanSubaccountRemote(address(account)).getLoanPosition().liquidationPrice;
        assertGt(edge, 0);
        assertLt(edge, IOracle(MARKET_ORACLE).price(), "the position is not at its edge yet");

        // canonical Morpho is what judges the edge, not our own health figure: its liquidation
        // refuses a healthy position, so at the quoted price it must refuse and one unit below it
        // must go through. Comparing the quote with our own health factor would only show the two
        // formulas agreeing with each other
        address liquidator = makeAddr("liquidator");
        deal(RLUSD, liquidator, 1_000_000e18);
        vm.prank(liquidator);
        IERC20(RLUSD).approve(MORPHO, type(uint256).max);

        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(edge));
        assertGe(
            ILoanSubaccountRemote(address(account)).getLoanPosition().morphoHealthFactor,
            WAD,
            "our own figure agrees the position is healthy at the edge"
        );
        vm.prank(liquidator);
        vm.expectRevert(bytes("position is healthy"));
        IMorphoLiquidate(MORPHO).liquidate(params, address(account), 1e6, 0, "");

        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(edge - 1));
        uint256 collateralBefore = _collateral();
        vm.prank(liquidator);
        IMorphoLiquidate(MORPHO).liquidate(params, address(account), 1e6, 0, "");
        assertEq(_collateral(), collateralBefore - 1e6, "one unit below the quote Morpho seizes collateral");
    }

    /**
     * @dev SA-06's accepted risk, measured on the real market. The cover gate values collateral
     * at the market's own oracle and `IOracle` is `price()` alone - no round, no timestamp - so a
     * price that is stale high, or manipulated high, is simply believed. The gate then permits a
     * withdrawal it would refuse at the true price, and the Flare fee is left standing on
     * collateral worth less than `requiredCover`.
     *
     * This is not a disagreement with Morpho: both read the same feed, so Morpho's own health
     * check is fooled identically and the position stays borrowable. That is why the acceptance
     * is a judgement about the feed rather than something the gate can defend, and why the
     * mitigation is an off-chain review of the oracle, recorded before launch.
     */
    function testAStaleHighOracleLetsTheFeeClaimExitUnderSecured() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 5_000e18);
        vm.warp(block.timestamp + ORACLE_WINDOW);
        uint256 truePrice = IOracle(MARKET_ORACLE).price();
        uint256 honestMax = ILoanSubaccountRemote(address(account)).getLoanLimits(0).maxWithdraw;
        assertGt(honestMax, 0, "some withdrawal is allowed at the true price");

        // the feed prints twice the real price - stale from a spike, or pushed there
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(2 * truePrice));
        uint256 inflatedMax = ILoanSubaccountRemote(address(account)).getLoanLimits(0).maxWithdraw;
        assertGt(inflatedMax, honestMax, "the inflated price buys a larger exit");

        // that same withdrawal, delivered at the honest price, is refused by the gate itself -
        // asserted on the packet rather than on the preview, since the preview is a separate path
        // and a broken gate would still quote correctly. Asked here rather than after the fact,
        // because once the exit has happened every further withdrawal is refused anyway
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(truePrice));
        ILoanSubaccountRemote.WithdrawPreview memory honest =
            ILoanSubaccountRemote(address(account)).previewWithdraw(inflatedMax);
        assertFalse(honest.coverSatisfied, "the true price does not support it");
        _deliverExpectingRefusal(
            9,
            _withdraw(bytes32("honest"), inflatedMax, 0),
            RETURN_VALUE,
            honest.requiredCover,
            honest.remainingValue
        );

        // the very same withdrawal under the inflated price is not refused at all: it executes
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(2 * truePrice));
        _deliver(10, 0, _withdraw(bytes32("stale-high"), inflatedMax, 0), RETURN_VALUE);
        assertEq(_collateral(), COLLATERAL - inflatedMax, "the collateral left on the inflated price");

        // back at the true price, what remains no longer covers what the gate demands
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(truePrice));
        ILoanSubaccountRemote.LoanPosition memory position =
            ILoanSubaccountRemote(address(account)).getLoanPosition();
        assertGt(position.feeDebtX18, 0, "there is a fee claim to leave under-secured");
        assertLt(
            position.collateralValue,
            position.requiredCover,
            "the position the gate just permitted is under its own cover requirement"
        );
        assertGt(
            position.requiredCover - position.collateralValue,
            1e18,
            "and the shortfall is real value, not a rounding edge"
        );
    }

    /**
     * @dev The junior claim's premise, on the real market. A liquidation that closes the whole
     * debt at Morpho's own edge does not take the whole collateral, so the Flare fee still has
     * something to stand on afterwards. The residue is the incentive's complement: at the edge
     * the debt is 77% of the collateral's value and the liquidator takes that times ~1.0741, so
     * about 17% of the collateral stays behind. Nothing in the accounts enforces this - it is
     * Morpho's arithmetic - which is exactly why it is asserted against Morpho rather than
     * restated in a comment.
     */
    function testFullDebtLiquidationAtTheEdgeLeavesCollateralForTheFeeClaim() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 5_000e18);
        vm.warp(block.timestamp + ORACLE_WINDOW);
        uint256 edge = ILoanSubaccountRemote(address(account)).getLoanPosition().liquidationPrice;
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(edge - 1));

        uint256 collateralBefore = _collateral();
        uint256 feeBefore = ILoanSubaccountRemote(address(account)).getLoanPosition().feeDebtX18;
        assertGt(feeBefore, 0, "a fee accrued over the warp, so there is a claim to secure");

        // accrue first, so the totals read here are the ones the liquidation itself will use,
        // and the two conversions below can be computed rather than inferred from its return
        morpho.accrueInterest(params);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho.market(_marketId());
        uint128 shares = _shares();
        uint256 sharesDown = Math.mulDiv(
            shares,
            uint256(totalBorrowAssets) + MorphoMath.VIRTUAL_ASSETS,
            uint256(totalBorrowShares) + MorphoMath.VIRTUAL_SHARES
        );
        uint256 sharesUp = MorphoMath.toAssetsUp(shares, totalBorrowAssets, totalBorrowShares);
        (uint256 seized, uint256 repaid) = _liquidateRepayingShares(shares);

        assertEq(_debt(), 0, "the whole debt is closed");
        assertEq(_collateral(), collateralBefore - seized, "and only the seized collateral left");
        assertGt(_collateral(), 0, "a full-debt liquidation at the edge leaves collateral behind");

        // canonical Morpho rounds these two apart, and in opposite directions: the seizure is
        // computed from the shares rounded DOWN to assets, the payment from the same shares
        // rounded UP. Taking the reference from the returned payment would fold the second
        // rounding into the first and only pass because the collateral's six decimals hide it
        uint256 incentive = _liquidationIncentiveFactor();
        assertGt(sharesUp, sharesDown, "the two conversions differ here, so which feeds which matters");
        assertEq(repaid, sharesUp, "the payment is the repaid shares rounded up");
        assertEq(
            seized,
            Math.mulDiv(Math.mulDiv(sharesDown, incentive, WAD), ORACLE_PRICE_SCALE, edge - 1),
            "and the seizure is the shares rounded down, times the incentive, quoted at the price"
        );
        // and the residue as a share of the collateral: 1 - lltv x LIF, about 17.3% here
        assertApproxEqRel(
            _collateral(),
            Math.mulDiv(collateralBefore, WAD - Math.mulDiv(MARKET_LLTV, incentive, WAD), WAD),
            0.01e18,
            "the residue is the incentive's complement"
        );
        // the claim survives the liquidation: still owed, and still with collateral under it
        ILoanSubaccountRemote.LoanPosition memory after_ =
            ILoanSubaccountRemote(address(account)).getLoanPosition();
        assertGe(after_.feeDebtX18, feeBefore, "the fee claim is untouched by the liquidation");
        assertGt(after_.collateralValue, 0, "and it is no longer a junior claim on nothing");
    }

    /**
     * @dev The other end of the same scale: a price far enough below the edge that seizing every
     * unit of collateral cannot cover the debt. Canonical Morpho then writes the shortfall off as
     * bad debt rather than leaving a dust position, so the account is left owing nothing and
     * holding nothing - and the Flare fee, whose only security was that collateral, becomes an
     * unsecured claim. That is the accepted junior-claim risk, pinned here with real numbers.
     */
    function testCollateralExhaustionRealizesBadDebtAndUnsecuresTheFee() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 5_000e18);
        vm.warp(block.timestamp + ORACLE_WINDOW);
        uint256 debtBefore = _debt();
        uint256 incentive = _liquidationIncentiveFactor();

        // a price at which the whole collateral, after the incentive, is worth less than the debt
        uint256 exhausting =
            Math.mulDiv(Math.mulDiv(debtBefore, incentive, WAD), ORACLE_PRICE_SCALE, COLLATERAL) / 2;
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(exhausting));

        (uint256 seized, uint256 repaid) = _liquidateSeizing(_collateral());
        assertEq(seized, COLLATERAL, "the liquidator took every unit of collateral");
        assertLt(repaid, debtBefore, "and it did not cover the debt");

        assertEq(_collateral(), 0, "no collateral left");
        assertEq(_shares(), 0, "and no shares: Morpho wrote the shortfall off rather than leaving dust");
        ILoanSubaccountRemote.LoanPosition memory position =
            ILoanSubaccountRemote(address(account)).getLoanPosition();
        assertEq(position.debt, 0, "the account reports the written-off debt as gone");
        assertEq(position.collateralValue, 0);
        assertGt(position.feeDebtX18, 0, "the fee claim outlives the collateral that secured it");
    }

    /**
     * @dev The boundary the exhaustion test above sits far below, and it separates three regimes
     * rather than two. Found by closing on the flip rather than assumed, to a single wei of
     * price. One wei above, Morpho refuses to seize the whole collateral, because the repayment
     * it implies exceeds the debt, and closing the debt outright leaves collateral with the
     * lenders whole. At the boundary the seizure just fits and costs them exactly one wei. Below,
     * the write-off grows. So exhaustion and bad debt are not separated by a price: crossing the
     * line is what starts the loss, and the loss starts at its smallest.
     */
    function testTheExhaustionBoundaryIsWhereTheLendersLossBegins() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 5_000e18);
        vm.warp(block.timestamp + ORACLE_WINDOW);
        uint256 collateral = _collateral();
        // accrue first: the liquidation would, and an estimate off by six hours of interest is
        // off by far more than the bracket below is wide
        morpho.accrueInterest(params);
        uint256 debtBefore = _debt();
        // one wei of quoted collateral value, expressed as a price step
        uint256 step = Math.ceilDiv(ORACLE_PRICE_SCALE, collateral);
        uint256 estimate =
            Math.mulDiv(Math.mulDiv(debtBefore, _liquidationIncentiveFactor(), WAD), ORACLE_PRICE_SCALE, collateral);

        // bracket the flip, then close on it: seizing everything reverts above and succeeds below
        uint256 allowed = estimate - 10_000 * step;
        uint256 refused = estimate + 10_000 * step;
        assertFalse(_seizingEverythingReverts(allowed), "the bracket's low end must allow the seizure");
        assertTrue(_seizingEverythingReverts(refused), "and its high end must refuse it");
        while (refused - allowed > 1) {
            uint256 mid = allowed + (refused - allowed) / 2;
            if (_seizingEverythingReverts(mid)) {
                refused = mid;
            } else {
                allowed = mid;
            }
        }
        assertEq(refused - allowed, 1, "the two prices are one wei apart: this is the boundary itself");

        // the lenders' loss is the honest measure of a write-off: `repaid` rounds up, so equal
        // repaid figures do not mean every share was covered. With interest already accrued in
        // this block, any fall in the supply total is bad debt and nothing else
        uint256 supplyBefore = _totalSupplyAssets();

        // above it: the collateral is worth more debt than exists, so Morpho will not take it
        // all, and closing the debt outright leaves the rest of the collateral behind
        uint256 snapshot = vm.snapshotState();
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(refused));
        _liquidateRepayingShares(_shares());
        assertGt(_collateral(), 0, "above the boundary a full-debt liquidation still leaves collateral");
        assertEq(_shares(), 0, "with the debt closed");
        assertEq(_totalSupplyAssets(), supplyBefore, "and the lenders lose nothing");
        vm.revertToState(snapshot);

        // at it: the seizure just fits, and the loss it leaves is the smallest there is
        snapshot = vm.snapshotState();
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(allowed));
        (uint256 seized, ) = _liquidateSeizing(collateral);
        assertEq(seized, collateral, "the whole collateral went");
        assertEq(_collateral(), 0);
        assertEq(_shares(), 0, "and the remainder was written off rather than left as dust");
        uint256 lossAtBoundary = supplyBefore - _totalSupplyAssets();
        assertEq(lossAtBoundary, 1, "one wei: the boundary is where the loss begins, not where it is zero");
        vm.revertToState(snapshot);

        // one wei of quoted value under it: the same seizure falls further short
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(allowed - step));
        (, uint256 shortRepaid) = _liquidateSeizing(collateral);
        assertLt(shortRepaid, debtBefore, "below the boundary the seizure no longer covers the debt");
        assertEq(_collateral(), 0);
        assertEq(_shares(), 0);
        assertGt(
            supplyBefore - _totalSupplyAssets(),
            lossAtBoundary,
            "and the write-off grows as the price falls"
        );
    }

    /**
     * @dev Both of canonical Morpho's liquidation input modes, and what separates them. Each
     * conversion rounds against the liquidator on its own - naming shares floors the seizure,
     * naming a seizure ceils the shares - but the pair is not a round trip: asking for the
     * seizure that naming the shares produced repays slightly *less*, because that seizure was
     * already floored to whole base units of a six-decimal token. The gap is bounded by what one
     * such unit is worth and it favours the liquidator, so the choice of mode is worth a fraction
     * of a cent. Pinned because the residue the fee claim relies on comes out of these same
     * conversions.
     */
    function testTheTwoLiquidationInputModesDifferOnlyBySubUnitRounding() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 5_000e18);
        vm.warp(block.timestamp + ORACLE_WINDOW);
        uint256 edge = ILoanSubaccountRemote(address(account)).getLoanPosition().liquidationPrice;
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(edge - 1));
        uint128 half = _shares() / 2;

        uint256 snapshot = vm.snapshotState();
        (uint256 seizedByShares, uint256 repaidByShares) = _liquidateRepayingShares(half);
        uint256 collateralLeft = _collateral();
        uint256 debtLeft = _debt();
        vm.revertToState(snapshot);

        // the same seizure, asked for the other way round
        (uint256 seizedByAssets, uint256 repaidByAssets) = _liquidateSeizing(seizedByShares);
        assertEq(seizedByAssets, seizedByShares, "the seizure asked for is the seizure taken");
        assertEq(_collateral(), collateralLeft, "so the borrower keeps the same collateral either way");
        assertGt(_debt(), 0, "a partial liquidation leaves the position open");

        assertLe(repaidByAssets, repaidByShares, "naming the seizure repays no more than naming the shares");
        assertGe(_debt(), debtLeft, "which leaves the borrower owing a shade more, not less");
        // the whole of the difference is the seizure being floored to whole base units of a
        // six-decimal collateral token, so one such unit, quoted at the price, bounds it
        assertLt(
            repaidByShares - repaidByAssets,
            Math.mulDiv(1, edge - 1, ORACLE_PRICE_SCALE),
            "and the difference is under one unit of collateral: rounding, not a discount"
        );
    }

    /**
     * @dev What a real liquidation does to the fee state, with the market moving underneath it.
     * The fee is charged on `feePrincipal`, snapshotted at the last checkpoint; a liquidation
     * repays debt without going through the account, so the principal is left describing a debt
     * that no longer exists. The stored state is stale until someone calls the permissionless
     * `checkpointFee`, while the views project past it - so a caller reading `getLoanFeeState`
     * alone would under-report, which is the distinction this pins.
     */
    function testFeeStateGoesStaleAfterALiquidationUntilCheckpoint() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 5_000e18);
        // another borrower moves utilization, so the interest arriving is the adaptive model's
        _whaleBorrow(200_000e18);
        vm.warp(block.timestamp + ORACLE_WINDOW);

        uint256 edge = ILoanSubaccountRemote(address(account)).getLoanPosition().liquidationPrice;
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(edge - 1));
        _liquidateRepayingShares(_shares() / 2);

        (uint256 principal, uint256 storedFeeX18, , uint64 lastCheckpoint, uint64 floorRate, ) =
            ILoanSubaccountRemote(address(account)).getLoanFeeState();
        assertGt(
            principal,
            _debtFromCanonicalRepayment(),
            "the fee principal still describes the pre-liquidation debt"
        );
        uint256 projected = ILoanSubaccountRemote(address(account)).getLoanPosition().feeDebtX18;
        assertGt(projected, storedFeeX18, "the projection is ahead of the stored state");

        // the reconciliation is permissionless and needs no privileged caller
        vm.prank(makeAddr("anyone"));
        ILoanSubaccountRemote(address(account)).checkpointFee();

        (uint256 reconciled, uint256 feeAfterX18, , , , ) =
            ILoanSubaccountRemote(address(account)).getLoanFeeState();
        // the expectation is computed here rather than read back, because the projection and the
        // checkpoint run the same code: comparing them would pass a build that suppressed both.
        // With the principal above the live debt the interest term clamps to zero, leaving the
        // floor over the period since the last checkpoint
        assertEq(
            feeAfterX18 - storedFeeX18,
            Math.mulDiv(principal * floorRate, vm.getBlockTimestamp() - lastCheckpoint, LoanMath.YEAR),
            "the checkpoint folds in exactly the floor on the stale principal"
        );
        assertEq(feeAfterX18, projected, "and it is what the view projected in the same block");
        assertEq(
            reconciled,
            _debtFromCanonicalRepayment(),
            "and re-snapshots the principal on the debt Morpho itself would charge"
        );
    }

    /**
     * @dev Checkpointing at once versus letting it wait - the comparison SA-04 asks for, and the
     * reason a front end has to watch for liquidations rather than leave the account to notice.
     * The floor is priced on `feePrincipal`, and a liquidation leaves that describing a debt that
     * no longer exists, so every second before the checkpoint is billed at the old size. The
     * delayed figure is asserted exactly: with the principal above the live debt the market
     * interest term clamps to zero, which leaves the floor alone.
     */
    function testCheckpointingLateAfterALiquidationCostsMoreThanCheckpointingAtOnce() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 5_000e18);
        vm.warp(block.timestamp + ORACLE_WINDOW);
        uint256 edge = ILoanSubaccountRemote(address(account)).getLoanPosition().liquidationPrice;
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(edge - 1));
        _liquidateRepayingShares(_shares() / 2);

        (uint256 stalePrincipal, uint256 feeAtLiquidation, , uint64 lastCheckpoint, uint64 floorRate, ) =
            ILoanSubaccountRemote(address(account)).getLoanFeeState();
        uint256 waited = 1 hours;

        // checkpoint at once, then let the same hour pass on the reconciled principal
        uint256 snapshot = vm.snapshotState();
        ILoanSubaccountRemote(address(account)).checkpointFee();
        uint256 feeAfterFirst = _billTheFirstPeriod(stalePrincipal, feeAtLiquidation, lastCheckpoint, floorRate);
        vm.warp(vm.getBlockTimestamp() + waited);
        uint256 feeIfPrompt = _billTheSecondPeriod(feeAfterFirst, waited);
        vm.revertToState(snapshot);

        // or let the hour pass first, with the principal still describing the closed debt
        vm.warp(vm.getBlockTimestamp() + waited);
        ILoanSubaccountRemote(address(account)).checkpointFee();
        (, uint256 feeIfLate, , , , ) = ILoanSubaccountRemote(address(account)).getLoanFeeState();

        // the late checkpoint prices its whole period - everything since the last one, not just
        // the hour waited - at the floor on the principal it still held
        assertEq(
            feeIfLate - feeAtLiquidation,
            Math.mulDiv(stalePrincipal * floorRate, vm.getBlockTimestamp() - lastCheckpoint, LoanMath.YEAR),
            "the whole period is billed at the floor on the pre-liquidation principal"
        );
        assertLt(feeIfPrompt, feeIfLate, "and the prompt path's same hour on the live debt costs less");
        assertLe(
            feeIfLate - feeIfPrompt,
            Math.mulDiv(stalePrincipal * floorRate, waited, LoanMath.YEAR),
            "the delay costs at most that hour at the stale size - the two differ in nothing else"
        );
    }

    /**
     * @dev The accepted junior-claim risk, demonstrated rather than asserted in prose: once the
     * position is liquidatable, the user can take their own collateral out through Morpho, past
     * the cover gate that exists to keep the fee secured. The same collateral cannot leave
     * through the account's own withdrawal in that state. Morpho's health condition is the only
     * thing standing in the way, and it is not ours to set.
     */
    function testSelfLiquidationTakesCollateralPastTheCoverGate() public onlyForked {
        _openOnTheRealMarket(COLLATERAL, 5_000e18);
        vm.warp(block.timestamp + ORACLE_WINDOW);
        uint256 edge = ILoanSubaccountRemote(address(account)).getLoanPosition().liquidationPrice;
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(edge - 1));

        // the rail refuses: unhealthy on Morpho's line is far past our own cover requirement
        ILoanSubaccountRemote.WithdrawPreview memory refused =
            ILoanSubaccountRemote(address(account)).previewWithdraw(1e6);
        assertFalse(refused.coverSatisfied, "the cover gate refuses a withdrawal in this state");
        _deliverExpectingRefusal(
            9, _withdraw(bytes32("blocked"), 1e6, 0), RETURN_VALUE, refused.requiredCover, refused.remainingValue
        );

        // the borrower is the liquidator: the RLUSD it borrowed is already sitting on `parent`
        uint256 collateralBefore = _collateral();
        deal(RLUSD, parent, 10_000e18);
        vm.startPrank(parent);
        IERC20(RLUSD).approve(MORPHO, type(uint256).max);
        (uint256 seized, ) = IMorphoLiquidate(MORPHO).liquidate(params, address(account), 0, _shares() / 2, "");
        vm.stopPrank();

        assertGt(seized, 1e6, "and takes out more than the withdrawal that was just refused");
        assertEq(_collateral(), collateralBefore - seized);
        assertEq(IERC20(FXRP).balanceOf(parent), seized, "the collateral is the user's own again");
        assertGt(
            ILoanSubaccountRemote(address(account)).getLoanPosition().feeDebtX18,
            0,
            "with the fee still owed against what is left"
        );
    }

    // helpers below the tests they serve
    // solhint-disable-next-line ordering
    function _repayWith(uint256 _amount) private {
        deal(RLUSD, address(account), _amount);
        ILoanSubaccountRemote(address(account)).repay();
    }

    /**
     * @dev The debt canonical Morpho itself puts on the position right now: repaying every share
     * makes Morpho accrue and convert with its own arithmetic, and the assets it asks for are the
     * answer. Taken under a snapshot, so the position is left as it was. Using this instead of
     * the fixture's `_debt()` keeps our own share conversion out of the comparison.
     */
    function _debtFromCanonicalRepayment() private returns (uint256 assetsRepaid) {
        uint256 snapshot = vm.snapshotState();
        uint128 shares = _shares();
        address payer = makeAddr("payer");
        deal(RLUSD, payer, 100_000_000e18);
        vm.startPrank(payer);
        IERC20(RLUSD).approve(MORPHO, type(uint256).max);
        (assetsRepaid, ) = IMorpho(MORPHO).repay(params, 0, shares, address(account), "");
        vm.stopPrank();
        vm.revertToState(snapshot);
    }

    /// @dev Would seizing the entire collateral at `_price` be refused? Asked under a snapshot,
    /// so the position is left exactly as it was and the answer can be asked repeatedly.
    function _seizingEverythingReverts(
        uint256 _price
    )
        private
        returns (bool _reverted)
    {
        uint256 snapshot = vm.snapshotState();
        vm.mockCall(MARKET_ORACLE, abi.encodeWithSelector(IOracle.price.selector), abi.encode(_price));
        address probe = makeAddr("boundary probe");
        deal(RLUSD, probe, 100_000_000e18);
        vm.startPrank(probe);
        IERC20(RLUSD).approve(MORPHO, type(uint256).max);
        try IMorphoLiquidate(MORPHO).liquidate(params, address(account), _collateral(), 0, "") {
            _reverted = false;
        } catch {
            _reverted = true;
        }
        vm.stopPrank();
        vm.revertToState(snapshot);
    }

    /// @dev Checkpoints again and asserts the period just closed: this one is billed on the
    /// reconciled principal, with the interest the position really earned over it, so a build
    /// that skipped the second checkpoint - or priced it on the stale principal - fails here.
    function _billTheSecondPeriod(
        uint256 _feeBefore,
        uint256 _elapsed
    )
        private
        returns (uint256 _feeNow)
    {
        (uint256 principal, , , , uint64 floorRate, uint64 spreadRate) =
            ILoanSubaccountRemote(address(account)).getLoanFeeState();
        // accrue on the market first, so the interest below is Morpho's own figure
        morpho.accrueInterest(params);
        uint256 liveDebt = _debt();
        uint256 interestX18 = (liveDebt > principal ? liveDebt - principal : 0) * WAD;
        ILoanSubaccountRemote(address(account)).checkpointFee();
        (, _feeNow, , , , ) = ILoanSubaccountRemote(address(account)).getLoanFeeState();
        assertEq(
            _feeNow - _feeBefore,
            Math.max(
                Math.mulDiv(principal * floorRate, _elapsed, LoanMath.YEAR),
                interestX18 + Math.mulDiv(principal * spreadRate, _elapsed, LoanMath.YEAR)
            ) - interestX18,
            "the second period is billed on the reconciled principal and the interest it earned"
        );
    }

    /// @dev A third party liquidates by naming the borrow shares to repay; Morpho decides the
    /// seizure. Returns Morpho's own `(seizedAssets, repaidAssets)`.
    function _liquidateRepayingShares(
        uint128 _shareCount
    )
        private
        returns (uint256 _seized, uint256 _repaid)
    {
        return _liquidateAs(makeAddr("share liquidator"), 0, _shareCount);
    }

    /// @dev The other input mode: the liquidator names the collateral to seize.
    function _liquidateSeizing(
        uint256 _seizedAssets
    )
        private
        returns (uint256 _seized, uint256 _repaid)
    {
        return _liquidateAs(makeAddr("asset liquidator"), _seizedAssets, 0);
    }

    function _liquidateAs(
        address _liquidator,
        uint256 _seizedAssets,
        uint128 _shareCount
    )
        private
        returns (uint256 _seized, uint256 _repaid)
    {
        deal(RLUSD, _liquidator, 10_000_000e18);
        vm.startPrank(_liquidator);
        IERC20(RLUSD).approve(MORPHO, type(uint256).max);
        (_seized, _repaid) =
            IMorphoLiquidate(MORPHO).liquidate(params, address(account), _seizedAssets, _shareCount, "");
        vm.stopPrank();
    }

    /// @dev Moves utilization by opening a large position of its own on the real market.
    function _whaleBorrow(uint256 _amount) private {
        address whale = makeAddr("whale");
        deal(FXRP, whale, 20_000_000e6);
        vm.startPrank(whale);
        IERC20(FXRP).approve(MORPHO, type(uint256).max);
        IMorpho(MORPHO).supplyCollateral(params, 20_000_000e6, whale, "");
        IMorpho(MORPHO).borrow(params, _amount, 0, whale, whale);
        vm.stopPrank();
    }

    /**
     * @dev Delivers a packet the cover gate must refuse with exactly `_required` against
     * `_remaining`, and pins that nothing moved. Asserting the arguments is the point: they are
     * the numbers the matching preview quoted, so preview and refusal agree to the unit.
     */
    function _deliverExpectingRefusal(
        uint64 _nonce,
        bytes memory _payload,
        uint256 _value,
        uint256 _required,
        uint256 _remaining
    )
        private
    {
        uint256 debtBefore = _debt();
        uint256 collateralBefore = _collateral();
        // the expectation has to sit on the compose itself: queueing the packet is a separate
        // call that succeeds, and it would otherwise absorb the expectation
        (bytes memory message, bytes32 guid) = _packet(address(account), _nonce, 0, _payload);
        // any value travels with the compose and, under the prank, leaves the endpoint's own
        // balance - which the mock has none of until it is given some
        vm.deal(address(endpoint), _value);
        vm.prank(address(endpoint));
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccountRemote.InsufficientRemainingCollateral.selector, _required, _remaining
            )
        );
        ILoanSubaccountRemote(address(account)).lzCompose{value: _value}(
            address(oft), guid, message, address(this), ""
        );
        assertEq(_debt(), debtBefore, "a refused action must change nothing");
        assertEq(_collateral(), collateralBefore, "a refused action must change nothing");
    }

    /// @dev The period a checkpoint just billed, when the principal sits above the live debt:
    /// the market interest term clamps to zero, leaving the floor alone. Returns the fee now.
    function _billTheFirstPeriod(
        uint256 _principal,
        uint256 _feeBefore,
        uint64 _lastCheckpoint,
        uint64 _floorRate
    )
        private view
        returns (uint256 _feeNow)
    {
        (, _feeNow, , , , ) = ILoanSubaccountRemote(address(account)).getLoanFeeState();
        assertEq(
            _feeNow - _feeBefore,
            Math.mulDiv(_principal * _floorRate, vm.getBlockTimestamp() - _lastCheckpoint, LoanMath.YEAR),
            "the first period is the floor on the pre-liquidation principal"
        );
    }

    /// @dev The market's supply total, which is what a write-off comes out of.
    function _totalSupplyAssets() private view returns (uint256) {
        (uint128 totalSupplyAssets, , , , , ) = morpho.market(_marketId());
        return totalSupplyAssets;
    }

    /// @dev Canonical Morpho's incentive factor for this market's LLTV, computed the way
    /// `Morpho.liquidate` computes it rather than pasted as a number.
    function _liquidationIncentiveFactor() private pure returns (uint256) {
        uint256 factor = Math.mulDiv(WAD, WAD, WAD - Math.mulDiv(LIQUIDATION_CURSOR, WAD - MARKET_LLTV, WAD));
        return factor < MAX_LIQUIDATION_INCENTIVE_FACTOR ? factor : MAX_LIQUIDATION_INCENTIVE_FACTOR;
    }
}
