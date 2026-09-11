// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {stdError} from "forge-std/Test.sol";
import {IMorpho} from "../../contracts/smartAccounts/interface/IMorpho.sol";
import {IOracle} from "../../contracts/smartAccounts/interface/IOracle.sol";
import {MorphoMath} from "../../contracts/smartAccounts/library/MorphoMath.sol";
import {TestnetLoanToken} from "../../contracts/mock/TestnetLoanToken.sol";
import {TestnetPriceFeed} from "../../contracts/mock/TestnetPriceFeed.sol";
import {DeploySepoliaMarket} from "../../deployment/scripts/DeploySepoliaMarket.s.sol";
import {
    IMorphoChainlinkOracleV2,
    IMorphoChainlinkOracleV2Factory,
    IMorphoMarketSetup
} from "../../deployment/scripts/SepoliaMarketInterfaces.sol";
import {DeploySepoliaMarketHarness} from "../utils/DeploySepoliaMarketHarness.sol";
import {MarketRecordFixture} from "../utils/MarketRecordFixture.sol";

/**
 * @title SepoliaMarketForkTest
 * @notice The market script's phases against the contracts they are written for - Morpho's own
 * oracle factory and the public Morpho instance on Sepolia - which no mock can stand in for: the
 * factory's signature, its registry, the oracle's wiring and scale and its reading of our feeds,
 * and the market's creation and funding. Skips itself unless `SEPOLIA_RPC_URL` is set; runs at the
 * latest block, since every assertion is about our own fresh deployments and about behavior the
 * factory and Morpho hold stable.
 */
contract SepoliaMarketForkTest is MarketRecordFixture {
    /// @dev One oracle's worth of factory arguments, as a struct so the eleven-argument call has
    /// the stack to spare under the legacy pipeline `forge coverage` builds with.
    struct Wiring {
        address baseVault;
        uint8 baseDecimals;
        address baseFeed1;
        address baseFeed2;
        address quoteVault;
        address quoteFeed1;
        address quoteFeed2;
        uint256 baseVaultSample;
        bytes32 salt;
    }

    uint256 private constant SEPOLIA = 11155111;
    address private constant STRANGER = address(0xB0B);
    // the suite's own manifest, beside the deployment's and never it
    string private constant FORK_OUTPUT_FILE = "deployment/output-internal/sepolia/market-fork-test.json";
    string private constant FORK_RECORD_FILE = "deployment/output-internal/sepolia/record-fork-test.json";
    // the tests of this suite run beside each other, so the phase driven by the record writes its
    // manifest under a name of its own
    string private constant FUND_OUTPUT_FILE = "deployment/output-internal/sepolia/market-fork-fund.json";
    string private constant MARKET_RECORD_FILE = "deployment/output-internal/sepolia/record-fork-market.json";
    string private constant MARKET_OUTPUT_FILE = "deployment/output-internal/sepolia/market-fork-market.json";

    DeploySepoliaMarketHarness private harness;
    DeploySepoliaMarket.MarketConfig private config;
    DeploySepoliaMarket.Assets private assets;
    IOracle private oracle;

    function setUp() public {
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        bool forked = bytes(rpcUrl).length > 0;
        vm.skip(!forked, "set SEPOLIA_RPC_URL to run the market script against the real factory and Morpho");
        if (!forked) {
            return;
        }
        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, SEPOLIA, "SEPOLIA_RPC_URL does not serve Sepolia");
        harness = new DeploySepoliaMarketHarness();
        config = harness.loadConfig();
        // a salt of our own, so a rerun of the suite never collides with the deployed oracle
        config.oracleSalt = _salt("the suite's own market");
        assets = harness.deployAssets(config, address(harness), _noAssets());
        oracle = harness.createOracle(config, assets, address(0));
    }

    function testEachFeedMovesThePriceIndependently() public {
        // the feeds are the harness's, so this test speaks as it
        vm.startPrank(address(harness));
        // collateral to $4: twice the price. Loan token to $2: back to 2e48, since the oracle
        // quotes collateral in loan tokens. A wiring that read one feed for both would not move so
        assets.collateralFeed.setAnswer(4e8);
        assertEq(oracle.price(), 4e48, "the collateral feed scales the price up");
        assets.loanFeed.setAnswer(2e8);
        assertEq(oracle.price(), 2e48, "the loan feed scales it back down");
        assets.loanFeed.setAnswer(1e8);
        assets.collateralFeed.setAnswer(2e8);
        assertEq(oracle.price(), 2e48, "and both back to the initial answers restores it");
        vm.stopPrank();
    }

    function testAZeroAnswerIsAZeroPriceOnTheCollateralSideAndARevertOnTheLoanSide() public {
        // the feeds are the harness's, so this test speaks as it
        vm.startPrank(address(harness));
        // Morpho's feed reader accepts a non-negative answer and nothing else about it: a zero
        // collateral answer is a price of zero - worthless collateral, not an error - while a zero
        // loan-token answer is the quote the price is divided by, and that division reverts
        assets.collateralFeed.setAnswer(0);
        assertEq(oracle.price(), 0, "a zero collateral answer is a zero price, not a refusal");
        assets.collateralFeed.setAnswer(2e8);
        assets.loanFeed.setAnswer(0);
        vm.expectRevert(stdError.divisionError);
        oracle.price();
        assets.loanFeed.setAnswer(1e8);
        assertEq(oracle.price(), 2e48, "both answers back, the price is back");
        vm.stopPrank();
    }

    function testAFailingFeedRevertsTheOracleUntilItRecovers() public {
        // the feeds are the harness's, so this test speaks as it
        vm.startPrank(address(harness));
        // a feed that reverts takes the oracle down with it, and lifting the failure brings it
        // straight back: the answer behind the failure was never touched
        assets.collateralFeed.setFailing(true);
        vm.expectRevert(TestnetPriceFeed.FeedFailing.selector);
        oracle.price();
        assets.collateralFeed.setFailing(false);
        assertEq(oracle.price(), 2e48, "the oracle recovers the moment the feed does");
        vm.stopPrank();
    }

    function testAStaleAnswerIsStillPriced() public {
        // the feeds are the harness's, so this test speaks as it
        vm.startPrank(address(harness));
        // the canonical reader deliberately omits freshness: an answer dated a year back is served
        // like any other. The rehearsal records this rather than assuming a staleness guard exists
        assets.collateralFeed.setAnswerAt(2e8, block.timestamp - 365 days);
        assertEq(oracle.price(), 2e48, "staleness alone does not make this oracle refuse a price");
        vm.stopPrank();
    }

    function testTheMarketIsCreatedOnceAndTheSeedIsTheSuppliersOwnAssets() public {
        (IMorpho.MarketParams memory params, bytes32 id) =
            harness.ensureMarket(config, address(assets.loanToken), address(oracle), FORK_OUTPUT_FILE);
        (,,,, uint128 lastUpdate,) = IMorpho(config.morpho).market(id);
        assertGt(lastUpdate, 0, "the market exists on Morpho");
        assertEq(params.oracle, address(oracle));
        assertEq(params.lltv, config.lltv);
        // the manifest goes where the caller says - here the suite's own file - and holds the id
        string memory manifest = vm.readFile(FORK_OUTPUT_FILE);
        assertEq(vm.parseJsonBytes32(manifest, ".id"), id, "the manifest names the market");
        assertEq(vm.parseJsonAddress(manifest, ".oracle"), address(oracle));
        assertEq(vm.parseJsonBytes32(manifest, ".oracleCodeHash"), address(oracle).codehash);
        vm.removeFile(FORK_OUTPUT_FILE);
        // a second pass finds the market and changes nothing about it
        (, bytes32 again) = harness.ensureMarket(config, address(assets.loanToken), address(oracle), FORK_OUTPUT_FILE);
        assertEq(again, id, "the same parameters are the same market");
        vm.removeFile(FORK_OUTPUT_FILE);

        // three things stand between this market and a seed the rehearsal can borrow against, and
        // none of them may make the phase call itself done: someone else's supply in the pool, a
        // single token supplied on the deployer's own behalf - shares in its position that are not
        // the seed - and an earlier attempt of ours that minted and stopped before supplying
        vm.startPrank(address(harness));
        assets.loanToken.mint(STRANGER, 100e18 + 1);
        assets.loanToken.mint(address(harness), config.liquidity / 2);
        vm.stopPrank();
        vm.startPrank(STRANGER);
        assets.loanToken.approve(config.morpho, 100e18 + 1);
        IMorphoMarketSetup(config.morpho).supply(params, 1, 0, address(harness), "");
        IMorphoMarketSetup(config.morpho).supply(params, 100e18, 0, STRANGER, "");
        vm.stopPrank();
        assertGt(_supplyShares(id, address(harness)), 0, "the token supplied on our behalf is in our position");

        harness.fund(config, assets.loanToken, params, id);
        assertGe(_suppliedAssets(id, address(harness)), config.liquidity, "the position holds the configured seed");
        // what the position is worth is read from accrued totals, not from whatever the market was
        // last left at: a position the borrowing has grown past the seed must not be topped up
        vm.warp(block.timestamp + 30 days);
        harness.fund(config, assets.loanToken, params, id);
        (,,,, uint128 accruedAt,) = IMorpho(config.morpho).market(id);
        assertEq(accruedAt, block.timestamp, "the phase accrued before it measured");
        assertEq(assets.loanToken.balanceOf(address(harness)), 0, "the shortfall alone was minted: nothing left idle");
        // the token supplied on our behalf counts toward the seed, so the mint is one short of the
        // configured liquidity: what exists is that liquidity and what the stranger was given
        assertEq(assets.loanToken.totalSupply(), config.liquidity + 100e18, "one allocation, not a second on top");
        (uint128 totalSupplyAssets,,,,,) = IMorpho(config.morpho).market(id);
        assertEq(totalSupplyAssets, config.liquidity + 100e18, "the market holds the stranger's supply and ours");
        // funding again is a no-op: the position already holds the seed, so nothing is minted twice
        uint256 supplyBefore = assets.loanToken.totalSupply();
        uint256 sharesBefore = _supplyShares(id, address(harness));
        harness.fund(config, assets.loanToken, params, id);
        assertEq(assets.loanToken.totalSupply(), supplyBefore, "no second mint");
        assertEq(_supplyShares(id, address(harness)), sharesBefore, "no second supply");
    }

    function testReusedAssetsAreNotRedeployedAndResetIsTheOnlyPhaseThatMovesFeeds() public {
        // the feeds are the harness's, so this test speaks as it
        vm.startPrank(address(harness));
        // a scenario in progress on both feeds: both answers moved, both feeds failing. The assets
        // phase over a complete record deploys nothing and leaves all of it in place
        assets.collateralFeed.setAnswer(9e8);
        assets.loanFeed.setAnswer(3e8);
        assets.collateralFeed.setFailing(true);
        assets.loanFeed.setFailing(true);
        DeploySepoliaMarket.Assets memory same = harness.deployAssets(config, address(harness), assets);
        assertEq(address(same.loanToken), address(assets.loanToken));
        assertEq(address(same.collateralFeed), address(assets.collateralFeed));
        assertEq(address(same.loanFeed), address(assets.loanFeed));
        vm.expectRevert(TestnetPriceFeed.FeedFailing.selector);
        assets.collateralFeed.latestRoundData();
        vm.expectRevert(TestnetPriceFeed.FeedFailing.selector);
        assets.loanFeed.latestRoundData();
        // the oracle phase over a recorded oracle holds it to the registry and the wiring, not to
        // the price - the feeds are failing right now - and creates nothing
        IOracle reused = harness.createOracle(config, assets, address(oracle));
        assertEq(address(reused), address(oracle));
        // only the explicit reset ends the scenario: both answers back, both failures lifted
        harness.resetFeeds(config, assets);
        (, int256 answer,,,) = assets.collateralFeed.latestRoundData();
        assertEq(answer, config.collateralInitialPrice, "the collateral answer is back");
        (, answer,,,) = assets.loanFeed.latestRoundData();
        assertEq(answer, config.loanInitialPrice, "the loan answer is back");
        assertEq(oracle.price(), 2e48, "the reset puts both feeds back and lifts both failures");
        vm.stopPrank();
    }

    function testAnOracleOverFeedsAtOtherPricesIsRefusedAtCreation() public {
        // the script's own check, not the suite's: a fresh oracle whose feeds do not carry the
        // configured initial answers is refused before it is recorded, so a mis-set feed cannot
        // become the market's oracle unnoticed
        DeploySepoliaMarket.MarketConfig memory other = config;
        other.collateralInitialPrice = 3e8;
        other.oracleSalt = _salt("other price");
        DeploySepoliaMarket.Assets memory fresh = harness.deployAssets(other, address(harness), _noAssets());
        vm.expectRevert(bytes("the fresh oracle does not price the initial feeds at the expected scale"));
        harness.createOracle(other, fresh, address(0));
    }

    function testTheFundPhaseHoldsTheRecordedOracleToTheMarketPhasesChecks() public {
        (, bytes32 id) = harness.ensureMarket(config, address(assets.loanToken), address(oracle), FUND_OUTPUT_FILE);
        vm.removeFile(FUND_OUTPUT_FILE);
        // a market is its parameters, so an oracle the market phase would refuse is another market:
        // the phase that moves the liquidity has to refuse it too, before the supply lands there
        Wiring memory w = _ourWiring();
        w.baseFeed1 = address(new TestnetPriceFeed(8, "someone else's", 2e8, address(this)));
        _writeRecord(FORK_RECORD_FILE, address(assets.loanToken), address(assets.collateralFeed),
            address(assets.loanFeed), _factoryOracle(w));
        vm.expectRevert(bytes("the oracle's base side is not the recorded collateral feed alone"));
        harness.runPhase(config, "fund", address(harness), FORK_RECORD_FILE, FUND_OUTPUT_FILE);
        // with no oracle recorded there is no market to fund at all
        _writeRecord(FORK_RECORD_FILE, address(assets.loanToken), address(assets.collateralFeed),
            address(assets.loanFeed), address(0));
        vm.expectRevert(bytes("no oracle recorded: run the market phase first"));
        harness.runPhase(config, "fund", address(harness), FORK_RECORD_FILE, FUND_OUTPUT_FILE);
        // and over the recorded oracle the seed lands in the configured market
        _writeRecord(FORK_RECORD_FILE, address(assets.loanToken), address(assets.collateralFeed),
            address(assets.loanFeed), address(oracle));
        harness.runPhase(config, "fund", address(harness), FORK_RECORD_FILE, FUND_OUTPUT_FILE);
        assertGe(_suppliedAssets(id, address(harness)), config.liquidity, "the seed is in the configured market");
        vm.removeFile(FORK_RECORD_FILE);
    }

    function testTheMarketPhaseOverARecordedOracleReusesItRatherThanBuildingAnother() public {
        _writeRecord(MARKET_RECORD_FILE, address(assets.loanToken), address(assets.collateralFeed),
            address(assets.loanFeed), address(oracle));
        // a salt no oracle was built under, so a phase that ignored the record would succeed in
        // building a second oracle over the same feeds rather than colliding with the first
        DeploySepoliaMarket.MarketConfig memory other = config;
        other.oracleSalt = _salt("a second oracle over the same feeds");
        harness.runPhase(other, "market", address(harness), MARKET_RECORD_FILE, MARKET_OUTPUT_FILE);
        // the manifest is what the runbook registers the market from, so every parameter in it is
        // read back, and the id recomputed from those parameters rather than taken on faith: it
        // must be the market that exists, over the recorded oracle and not one of the phase's own
        (IMorpho.MarketParams memory expected, bytes32 id) = _marketIdOf(address(oracle));
        string memory manifest = vm.readFile(MARKET_OUTPUT_FILE);
        IMorpho.MarketParams memory written = IMorpho.MarketParams({
            loanToken: vm.parseJsonAddress(manifest, ".loanToken"),
            collateralToken: vm.parseJsonAddress(manifest, ".collateralToken"),
            oracle: vm.parseJsonAddress(manifest, ".oracle"),
            irm: vm.parseJsonAddress(manifest, ".irm"),
            lltv: vm.parseJsonUint(manifest, ".lltv")
        });
        assertEq(written.loanToken, expected.loanToken, "the manifest names the loan token");
        assertEq(written.collateralToken, expected.collateralToken, "and the collateral token");
        assertEq(written.oracle, address(oracle), "and the recorded oracle, not one of the phase's own");
        assertEq(written.irm, expected.irm, "and the rate model");
        assertEq(written.lltv, expected.lltv, "and the liquidation ratio");
        assertEq(MorphoMath.marketId(written), id, "the parameters written are the market's own");
        assertEq(vm.parseJsonBytes32(manifest, ".id"), id, "as is the id beside them");
        assertEq(vm.parseJsonBytes32(manifest, ".oracleCodeHash"), address(oracle).codehash);
        (,,,, uint128 lastUpdate,) = IMorpho(config.morpho).market(id);
        assertGt(lastUpdate, 0, "and that market exists on Morpho");
        vm.removeFile(MARKET_OUTPUT_FILE);
        vm.removeFile(MARKET_RECORD_FILE);
    }

    function testTheInfrastructureIsCheckedBeforeAnythingIsBuiltOnIt() public {
        // the configuration names contracts nobody here controls, so each is held to what the
        // market needs of it before an oracle or a market is built on top
        DeploySepoliaMarket.MarketConfig memory other = config;
        other.collateralDecimals = 18;
        vm.expectRevert(bytes("the collateral token's decimals are not the configured ones"));
        harness.createOracle(other, assets, address(oracle));

        other = config;
        other.lltv = 0.771e18;
        assertFalse(IMorphoMarketSetup(config.morpho).isLltvEnabled(other.lltv), "an LLTV Morpho does not know");
        vm.expectRevert(bytes("the configured LLTV is not enabled on this Morpho"));
        harness.createOracle(other, assets, address(oracle));

        other = config;
        other.irm = address(assets.loanToken);
        vm.expectRevert(bytes("the configured IRM is not enabled on this Morpho"));
        harness.createOracle(other, assets, address(oracle));

        // an enabled rate model serving another Morpho is not a state Sepolia offers, so the last
        // check is put to the deployed model with its answer replaced
        vm.mockCall(config.irm, abi.encodeWithSignature("MORPHO()"), abi.encode(address(0xdead)));
        vm.expectRevert(bytes("the IRM serves another Morpho instance"));
        harness.createOracle(config, assets, address(oracle));
        vm.clearMockedCalls();
    }

    function testARecordedOracleIsHeldToTheFactory() public {
        // not the factory's at all: nothing else about it is even asked
        vm.expectRevert(bytes("the oracle is not one the factory made"));
        harness.createOracle(config, assets, address(assets.loanToken));
    }

    function testARecordedOracleIsHeldToEachPieceOfTheConfiguredWiring() public {
        // every deviation is the factory's own oracle, so only the wiring check stands between the
        // record and a market priced by something else. Each is one field away from ours, so each
        // comparison is what refuses it - a feed on the wrong side, a second feed stacked onto a
        // side (with no decimals of its own, so the scale is untouched and only the field differs),
        // a vault whose share price would stand in for the token's, or another token's decimals
        TestnetPriceFeed otherFeed = new TestnetPriceFeed(8, "someone else's", 2e8, address(this));
        TestnetPriceFeed unitFeed = new TestnetPriceFeed(0, "a feed of ones", 1, address(this));
        Wiring memory w = _ourWiring();
        w.baseFeed1 = address(otherFeed);
        _expectRefusal("the oracle's base side is not the recorded collateral feed alone", w);
        w = _ourWiring();
        w.baseFeed2 = address(unitFeed);
        _expectRefusal("the oracle's base side is not the recorded collateral feed alone", w);
        w = _ourWiring();
        w.quoteFeed1 = address(otherFeed);
        _expectRefusal("the oracle's quote side is not the recorded loan feed alone", w);
        w = _ourWiring();
        w.quoteFeed2 = address(unitFeed);
        _expectRefusal("the oracle's quote side is not the recorded loan feed alone", w);
        w = _ourWiring();
        w.baseVault = address(assets.loanToken);
        _expectRefusal("the oracle prices a vault's share, not the token", w);
        w = _ourWiring();
        w.quoteVault = address(assets.loanToken);
        _expectRefusal("the oracle prices a vault's share, not the token", w);
        w = _ourWiring();
        w.baseDecimals = 18;
        _expectRefusal("the oracle's scale is not the configured decimals'", w);
    }

    function testTheFactoryRefusesASideWithNoVaultAndASampleOfItsOwn() public {
        // why the wiring check reads no conversion sample: with no vault the factory's constructor
        // admits only one, so a sample worth checking cannot occur beside the vaults we require
        Wiring memory w = _ourWiring();
        w.baseVaultSample = 2;
        vm.expectRevert();
        _factoryOracle(w);
    }

    function testTheFactoryMakesAnOracleAtTheExpectedScaleAndWiring() public view {
        // the script asserted 2e48 itself at creation; this reads it back through the factory's
        // own registry and the oracle's immutables, and states the scale: 36 + 18 - 6 places for
        // a $2 collateral and a $1 loan token
        assertTrue(IMorphoChainlinkOracleV2Factory(config.oracleFactory).isMorphoChainlinkOracleV2(address(oracle)));
        assertEq(oracle.price(), 2e48);
        assertEq(oracle.price(), config.expectedOraclePrice);
        IMorphoChainlinkOracleV2 wiring = IMorphoChainlinkOracleV2(address(oracle));
        assertEq(wiring.BASE_FEED_1(), address(assets.collateralFeed), "the collateral feed is the base side");
        assertEq(wiring.QUOTE_FEED_1(), address(assets.loanFeed), "the loan feed is the quote side");
        assertEq(wiring.BASE_FEED_2(), address(0));
        assertEq(wiring.QUOTE_FEED_2(), address(0));
        assertEq(wiring.BASE_VAULT(), address(0));
        assertEq(wiring.QUOTE_VAULT(), address(0));
        assertEq(wiring.SCALE_FACTOR(), 1e48, "36 + 18 + 8 - 6 - 8 places");
    }

    /// @dev Builds `_wiring`'s oracle at the real factory and expects the script to refuse it with
    /// `_reason` when the record names it.
    function _expectRefusal(
        string memory _reason,
        Wiring memory _wiring
    )
        private
    {
        address built = _factoryOracle(_wiring);
        vm.expectRevert(bytes(_reason));
        harness.createOracle(config, assets, built);
    }

    /// @dev The factory call on its own, as in the script, so the legacy pipeline `forge coverage`
    /// builds with can lay its eleven arguments out.
    function _factoryOracle(
        Wiring memory _wiring
    )
        private
        returns (address)
    {
        return IMorphoChainlinkOracleV2Factory(config.oracleFactory).createMorphoChainlinkOracleV2(
            _wiring.baseVault,
            _wiring.baseVaultSample,
            _wiring.baseFeed1,
            _wiring.baseFeed2,
            _wiring.baseDecimals,
            _wiring.quoteVault,
            1,
            _wiring.quoteFeed1,
            _wiring.quoteFeed2,
            config.loanTokenDecimals,
            _wiring.salt
        );
    }

    function _ourWiring()
        private
        returns (Wiring memory)
    {
        return Wiring({
            baseVault: address(0),
            baseFeed1: address(assets.collateralFeed),
            baseFeed2: address(0),
            quoteVault: address(0),
            quoteFeed1: address(assets.loanFeed),
            quoteFeed2: address(0),
            baseVaultSample: 1,
            baseDecimals: config.collateralDecimals,
            salt: _salt("wiring")
        });
    }

    /// @dev A salt no rerun of the suite repeats: the factory deploys with `CREATE2`.
    function _salt(
        string memory _what
    )
        private
        returns (bytes32)
    {
        return keccak256(abi.encode(_what, block.number, address(this), vm.randomUint()));
    }

    function _marketIdOf(
        address _oracle
    )
        private view
        returns (IMorpho.MarketParams memory params, bytes32 id)
    {
        params = IMorpho.MarketParams({
            loanToken: address(assets.loanToken),
            collateralToken: config.collateralToken,
            oracle: _oracle,
            irm: config.irm,
            lltv: config.lltv
        });
        id = MorphoMath.marketId(params);
    }

    function _supplyShares(
        bytes32 _id,
        address _supplier
    )
        private view
        returns (uint256 shares)
    {
        (shares,,) = IMorpho(config.morpho).position(_id, _supplier);
    }

    function _suppliedAssets(
        bytes32 _id,
        address _supplier
    )
        private view
        returns (uint256)
    {
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = IMorpho(config.morpho).market(_id);
        return MorphoMath.toAssetsUp(_supplyShares(_id, _supplier), totalSupplyAssets, totalSupplyShares);
    }

    function _noAssets()
        private pure
        returns (DeploySepoliaMarket.Assets memory)
    {
        return DeploySepoliaMarket.Assets(
            TestnetLoanToken(address(0)), TestnetPriceFeed(address(0)), TestnetPriceFeed(address(0))
        );
    }
}
