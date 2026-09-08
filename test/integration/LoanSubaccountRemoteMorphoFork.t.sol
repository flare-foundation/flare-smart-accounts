// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LoanForkFixture} from "../utils/LoanForkFixture.sol";
import {ILoanSubaccountRemote} from "../../contracts/userInterfaces/ILoanSubaccountRemote.sol";
import {IMorpho} from "../../contracts/smartAccounts/interface/IMorpho.sol";
import {IOracle} from "../../contracts/smartAccounts/interface/IOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
 * liquidity and its oracle - the premises the cover gate and the five views rest on.
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
}
