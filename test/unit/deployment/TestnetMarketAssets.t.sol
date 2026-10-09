// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TestnetLoanToken} from "../../../contracts/mock/TestnetLoanToken.sol";
import {TestnetPriceFeed} from "../../../contracts/mock/TestnetPriceFeed.sol";
import {DeploySepoliaMarket} from "../../../deployment/scripts/DeploySepoliaMarket.s.sol";
import {DeploySepoliaMarketHarness} from "../../utils/DeploySepoliaMarketHarness.sol";
import {MarketRecordFixture} from "../../utils/MarketRecordFixture.sol";

/// @dev The burn shapes the loan token must not have; calling them proves their absence.
interface IBurnable {
    function burn(
        address _from,
        uint256 _amount
    )
        external;

    function burn(
        uint256 _amount
    )
        external;
}

/**
 * @title TestnetMarketAssetsTest
 * @notice The two contracts the Sepolia rehearsal market is built on live on a public testnet, so
 * what they refuse matters as much as what they do: only the owner mints the loan token and
 * nothing burns it, only the owner moves or fails a feed. Plus what the market script does with
 * them without a chain: its guards - Sepolia only, held to the wrapper's name, a phase it does not
 * know refused - what every phase demands of the assets the deployment record names, and the order
 * the reset moves the feeds in.
 */
contract TestnetMarketAssetsTest is MarketRecordFixture {
    uint256 private constant SEPOLIA = 11155111;
    uint256 private constant ETHEREUM = 1;
    uint256 private constant COSTON2 = 114;
    uint256 private constant UNKNOWN = 31337;
    address private constant OWNER = address(0xA11CE);
    address private constant STRANGER = address(0xB0B);
    // the records and manifests are this suite's own, never the deployment's, and one name per
    // test: the tests share a filesystem even where they share no state
    string private constant PHASES_RECORD = "deployment/output-internal/sepolia/record-unit-phases.json";
    string private constant ASSETS_RECORD = "deployment/output-internal/sepolia/record-unit-assets.json";
    string private constant OUTPUT_FILE = "deployment/output-internal/sepolia/market-unit-test.json";

    TestnetLoanToken private token;
    TestnetPriceFeed private feed;
    DeploySepoliaMarket private script;
    DeploySepoliaMarketHarness private harness;
    DeploySepoliaMarket.MarketConfig private config;

    function setUp() public {
        token = new TestnetLoanToken("Sepolia Rehearsal USD", "rUSD", 18, OWNER);
        feed = new TestnetPriceFeed(8, "FXRP / USD (rehearsal feed)", 2e8, OWNER);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        script = new DeploySepoliaMarket();
        harness = new DeploySepoliaMarketHarness();
        config = harness.loadConfig();
    }

    function testOnlyTheOwnerMintsAndNothingBurns() public {
        vm.prank(OWNER);
        token.mint(STRANGER, 5e18);
        assertEq(token.balanceOf(STRANGER), 5e18);
        assertEq(token.decimals(), 18);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        token.mint(STRANGER, 1);
        // no burn of any shape, tried by the funded holder itself and by the owner: the token has
        // no fallback, so a selector it does not implement reverts with no data at all, while a
        // burn that existed would go through for a funded holder, or fail with a typed error
        vm.prank(STRANGER);
        vm.expectRevert(bytes(""));
        IBurnable(address(token)).burn(1);
        vm.prank(OWNER);
        vm.expectRevert(bytes(""));
        IBurnable(address(token)).burn(STRANGER, 1);
        assertEq(token.balanceOf(STRANGER), 5e18, "the holder's balance is untouched");
    }

    function testOnlyTheOwnerMovesTheFeed() public {
        vm.warp(1_000_000);
        vm.prank(OWNER);
        feed.setAnswer(4e8);
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(roundId, 2, "each answer is a new round");
        assertEq(answer, 4e8);
        assertEq(updatedAt, 1_000_000);
        // a dated answer, for the stale-round demonstration: the answer is served with the date given
        vm.prank(OWNER);
        feed.setAnswerAt(3e8, 500_000);
        (roundId, answer,, updatedAt,) = feed.latestRoundData();
        assertEq(roundId, 3);
        assertEq(answer, 3e8);
        assertEq(updatedAt, 500_000);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        feed.setAnswer(1);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        feed.setAnswerAt(1, 1);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        feed.setFailing(true);
    }

    function testAFailingFeedRevertsEveryReadUntilLifted() public {
        vm.prank(OWNER);
        feed.setFailing(true);
        vm.expectRevert(TestnetPriceFeed.FeedFailing.selector);
        feed.latestRoundData();
        vm.expectRevert(TestnetPriceFeed.FeedFailing.selector);
        feed.getRoundData(1);
        // the answer survives the failure: lifting it serves the same round again
        vm.prank(OWNER);
        feed.setFailing(false);
        (uint80 roundId, int256 answer,,,) = feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, 2e8);
    }

    function testOnlyTheLatestRoundIsRetained() public {
        (uint80 roundId, int256 answer,,,) = feed.getRoundData(1);
        assertEq(roundId, 1);
        assertEq(answer, 2e8);
        vm.expectRevert(abi.encodeWithSelector(TestnetPriceFeed.NoSuchRound.selector, uint80(2)));
        feed.getRoundData(2);
        vm.prank(OWNER);
        feed.setAnswer(3e8);
        vm.expectRevert(abi.encodeWithSelector(TestnetPriceFeed.NoSuchRound.selector, uint80(1)));
        feed.getRoundData(1);
    }

    function testTheMarketScriptRunsOnSepoliaOnly() public {
        // a market over feeds we control has no place on a production chain, Ethereum included, so
        // the guard is the chain id rather than the loan-chain family
        uint256[3] memory refused = [ETHEREUM, COSTON2, UNKNOWN];
        for (uint256 i = 0; i < refused.length; i++) {
            vm.chainId(refused[i]);
            vm.expectRevert(bytes("the rehearsal market is a Sepolia-only deployment"));
            script.run("sepolia", "assets");
        }
        // and on Sepolia it is held to the name the wrapper dialed the RPC by, before any phase runs
        vm.chainId(SEPOLIA);
        vm.expectRevert(bytes("RPC chain is sepolia, not the named network ethereum"));
        script.run("ethereum", "assets");
    }

    function testAnUnknownPhaseIsRefused() public {
        vm.chainId(SEPOLIA);
        vm.expectRevert(bytes("unknown phase: assets | market | fund | reset-feeds"));
        script.run("sepolia", "everything");
    }

    function testTheAssetsPhaseIsHeldToCodeOwnerAndDecimals() public {
        // the phases mint and move feeds as the deployer, and the oracle's scale is built from the
        // decimals, so an asset handed to the phase is deployed over only if it is missing, and
        // accepted only as a contract the deployer owns with the configured decimals
        DeploySepoliaMarket.Assets memory recorded = _noAssets();
        recorded.loanToken = TestnetLoanToken(address(0xdead));
        vm.expectRevert(bytes("the recorded loan token has no code"));
        harness.deployAssets(config, address(harness), recorded);

        recorded = _noAssets();
        recorded.loanToken = new TestnetLoanToken("Other", "OTH", 18, STRANGER);
        vm.expectRevert(bytes("the recorded loan token is not the deployer's"));
        harness.deployAssets(config, address(harness), recorded);
        recorded = _noAssets();
        recorded.collateralFeed = new TestnetPriceFeed(8, "theirs", 2e8, STRANGER);
        vm.expectRevert(bytes("the recorded collateral feed is not the deployer's"));
        harness.deployAssets(config, address(harness), recorded);
        recorded = _noAssets();
        recorded.loanFeed = new TestnetPriceFeed(8, "theirs", 1e8, STRANGER);
        vm.expectRevert(bytes("the recorded loan feed is not the deployer's"));
        harness.deployAssets(config, address(harness), recorded);

        recorded = _noAssets();
        recorded.loanToken = new TestnetLoanToken("Six", "SIX", 6, address(harness));
        vm.expectRevert(bytes("the recorded loan token has other decimals than configured"));
        harness.deployAssets(config, address(harness), recorded);
        recorded = _noAssets();
        recorded.collateralFeed = new TestnetPriceFeed(18, "wide", 2e18, address(harness));
        vm.expectRevert(bytes("the recorded collateral feed has other decimals than configured"));
        harness.deployAssets(config, address(harness), recorded);
        recorded = _noAssets();
        recorded.loanFeed = new TestnetPriceFeed(18, "wide", 1e18, address(harness));
        vm.expectRevert(bytes("the recorded loan feed has other decimals than configured"));
        harness.deployAssets(config, address(harness), recorded);

        // and a complete, conforming record - what the phase itself deployed - deploys nothing more
        DeploySepoliaMarket.Assets memory ours = harness.deployAssets(config, address(harness), _noAssets());
        assertEq(ours.loanToken.owner(), address(harness));
        assertEq(ours.loanToken.decimals(), config.loanTokenDecimals);
        assertEq(ours.collateralFeed.decimals(), config.feedDecimals);
        DeploySepoliaMarket.Assets memory same = harness.deployAssets(config, address(harness), ours);
        assertEq(address(same.loanToken), address(ours.loanToken));
        assertEq(address(same.collateralFeed), address(ours.collateralFeed));
        assertEq(address(same.loanFeed), address(ours.loanFeed));
    }

    function testEveryLaterPhaseIsHeldToTheSameAssetsTheRecordNames() public {
        // the later phases read their addresses from the deployment record, so the record is where
        // a wrong asset would enter: each phase must hold what it reads to the same three demands,
        // and refuse before it touches Morpho at all
        DeploySepoliaMarket.Assets memory ours = harness.deployAssets(config, address(harness), _noAssets());
        _writeRecord(PHASES_RECORD, address(ours.loanToken), address(0xdead), address(ours.loanFeed), address(0));
        vm.expectRevert(bytes("the recorded collateral feed has no code"));
        harness.runPhase(config, "market", address(harness), PHASES_RECORD, OUTPUT_FILE);
        _writeRecord(
            PHASES_RECORD,
            address(new TestnetLoanToken("Theirs", "THR", 18, STRANGER)),
            address(ours.collateralFeed),
            address(ours.loanFeed),
            address(0)
        );
        vm.expectRevert(bytes("the recorded loan token is not the deployer's"));
        harness.runPhase(config, "fund", address(harness), PHASES_RECORD, OUTPUT_FILE);
        _writeRecord(
            PHASES_RECORD,
            address(ours.loanToken),
            address(ours.collateralFeed),
            address(new TestnetPriceFeed(18, "wide", 1e18, address(harness))),
            address(0)
        );
        vm.expectRevert(bytes("the recorded loan feed has other decimals than configured"));
        harness.runPhase(config, "reset-feeds", address(harness), PHASES_RECORD, OUTPUT_FILE);

        // an incomplete record - whichever piece is missing - and no record at all are the same
        // answer: run the assets phase
        _writeRecord(PHASES_RECORD, address(ours.loanToken), address(0), address(ours.loanFeed), address(0));
        vm.expectRevert(bytes("the assets are not all recorded: run the assets phase first"));
        harness.runPhase(config, "reset-feeds", address(harness), PHASES_RECORD, OUTPUT_FILE);
        _writeRecord(PHASES_RECORD, address(0), address(ours.collateralFeed), address(ours.loanFeed), address(0));
        vm.expectRevert(bytes("the assets are not all recorded: run the assets phase first"));
        harness.runPhase(config, "reset-feeds", address(harness), PHASES_RECORD, OUTPUT_FILE);
        vm.removeFile(PHASES_RECORD);
        vm.expectRevert(bytes("the assets are not all recorded: run the assets phase first"));
        harness.runPhase(config, "reset-feeds", address(harness), PHASES_RECORD, OUTPUT_FILE);

        // over a conforming record the phase runs, on the assets the record names by name
        _writeRecord(
            PHASES_RECORD, address(ours.loanToken), address(ours.collateralFeed), address(ours.loanFeed), address(0)
        );
        vm.prank(address(harness));
        ours.collateralFeed.setAnswer(9e8);
        harness.runPhase(config, "reset-feeds", address(harness), PHASES_RECORD, OUTPUT_FILE);
        (, int256 answer,,,) = ours.collateralFeed.latestRoundData();
        assertEq(answer, config.collateralInitialPrice, "the reset reached the feed the record names");
        vm.removeFile(PHASES_RECORD);
    }

    function testTheAssetsPhaseDeploysWhatTheRecordLacksAndNothingElse() public {
        // what the phase deploys is counted at the deployer's nonce, which no other assertion here
        // can be fooled about: three contracts over an empty record, none over a complete one
        if (vm.exists(ASSETS_RECORD)) {
            vm.removeFile(ASSETS_RECORD);
        }
        // the phase is driven the way the entry point drives it, with a deployer that is not the
        // script: what it deploys is the deployer's, not the running contract's
        address deployer = address(0xDE9);
        uint64 before = vm.getNonce(address(harness));
        harness.runPhase(config, "assets", deployer, ASSETS_RECORD, OUTPUT_FILE);
        assertEq(vm.getNonce(address(harness)), before + 3, "the loan token and both feeds");
        assertEq(harness.printedCount(), 3, "and a record line for each");
        assertEq(
            TestnetLoanToken(vm.computeCreateAddress(address(harness), before)).owner(),
            deployer,
            "the phase's deployments answer to the deployer it was given"
        );
        assertEq(TestnetPriceFeed(vm.computeCreateAddress(address(harness), before + 1)).owner(), deployer);
        assertEq(TestnetPriceFeed(vm.computeCreateAddress(address(harness), before + 2)).owner(), deployer);
        // the phase prints what it deployed rather than returning it, so the record this suite
        // writes is what the recorder would have written from that run
        DeploySepoliaMarket.Assets memory ours = harness.deployAssets(config, address(harness), _noAssets());
        _writeRecord(
            ASSETS_RECORD, address(ours.loanToken), address(ours.collateralFeed), address(ours.loanFeed), address(0)
        );
        before = vm.getNonce(address(harness));
        harness.runPhase(config, "assets", address(harness), ASSETS_RECORD, OUTPUT_FILE);
        assertEq(vm.getNonce(address(harness)), before, "a complete record leaves nothing to deploy");
        // and one missing piece is the only thing deployed
        _writeRecord(ASSETS_RECORD, address(ours.loanToken), address(0), address(ours.loanFeed), address(0));
        harness.runPhase(config, "assets", address(harness), ASSETS_RECORD, OUTPUT_FILE);
        assertEq(vm.getNonce(address(harness)), before + 1, "the collateral feed alone");
        vm.removeFile(ASSETS_RECORD);
    }

    function testWhatThePhaseDeploysBelongsToTheDeployerAndIsPrintedForTheRecorder() public {
        // the owner is the deployer, who is not the script: mint and every feed write are the
        // owner's alone, and a deployment owned by the running contract would leave the operator
        // with nothing to drive. And what the recorder learns is what the phase prints, one line
        // per new contract in the shape the recorder's own parser reads - so the addresses are
        // predicted from the deployer's nonce and the exact three lines demanded
        address deployer = address(0xDE9);
        DeploySepoliaMarket.Assets memory ours = harness.deployAssets(config, deployer, _noAssets());

        assertTrue(deployer != address(harness), "the deployer is not the script that ran");
        assertEq(ours.loanToken.owner(), deployer, "the loan token is the deployer's");
        assertEq(ours.collateralFeed.owner(), deployer, "the collateral feed is the deployer's");
        assertEq(ours.loanFeed.owner(), deployer, "the loan feed is the deployer's");
        assertEq(harness.printedCount(), 3, "one record line per new contract");
        _assertRecordLine(0, "TestnetLoanToken", "TestnetLoanToken.sol", address(ours.loanToken));
        _assertRecordLine(1, "TestnetFeedCollateralUsd", "TestnetPriceFeed.sol", address(ours.collateralFeed));
        _assertRecordLine(2, "TestnetFeedLoanUsd", "TestnetPriceFeed.sol", address(ours.loanFeed));

        // and a rerun over what it just deployed hands the recorder nothing further
        harness.deployAssets(config, deployer, ours);
        assertEq(harness.printedCount(), 3, "nothing was deployed, so nothing was recorded");
    }

    function testTheResetFailsTheCollateralFeedFirstAndRestoresItLast() public {
        DeploySepoliaMarket.Assets memory ours = harness.deployAssets(config, address(harness), _noAssets());
        vm.startPrank(address(harness));
        ours.collateralFeed.setAnswer(9e8);
        ours.loanFeed.setAnswer(3e8);
        ours.loanFeed.setFailing(true);
        vm.stopPrank();
        // each call is a transaction of its own on Sepolia, so the order is the guarantee: the
        // collateral feed fails before either answer moves and recovers after both have, so no
        // block prices the market against one answer restored and the other still in a scenario.
        // Nothing may come between them either - an early recovery would price exactly that state -
        // so the whole sequence is read back, in order and with nothing else in it
        vm.recordLogs();
        harness.resetFeeds(config, ours);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 5, "five writes, and no sixth");
        _assertFailingSet(logs[0], address(ours.collateralFeed), true);
        _assertAnswerSet(logs[1], address(ours.collateralFeed), config.collateralInitialPrice);
        _assertAnswerSet(logs[2], address(ours.loanFeed), config.loanInitialPrice);
        _assertFailingSet(logs[3], address(ours.loanFeed), false);
        _assertFailingSet(logs[4], address(ours.collateralFeed), false);
        (, int256 answer,,,) = ours.collateralFeed.latestRoundData();
        assertEq(answer, config.collateralInitialPrice, "the collateral answer is back and the feed serves it");
        (, answer,,,) = ours.loanFeed.latestRoundData();
        assertEq(answer, config.loanInitialPrice, "the loan answer is back and the feed serves it");
    }

    function testTheFeedReportsItsAnswerInTheAggregatorShape() public view {
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "FXRP / USD (rehearsal feed)");
        assertEq(feed.version(), 1);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, 2e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    /// @dev The record line the phase printed, in the shape
    /// `deployment/scripts/save-deployed-addresses.ts` parses: name, contract file, address.
    function _assertRecordLine(
        uint256 _index,
        string memory _name,
        string memory _contractFile,
        address _deployed
    )
        private view
    {
        assertEq(
            harness.printed(_index),
            string.concat("DEPLOYED: ", _name, ", ", _contractFile, ": ", vm.toString(_deployed))
        );
    }

    function _assertAnswerSet(
        Vm.Log memory _log,
        address _feed,
        int256 _answer
    )
        private pure
    {
        assertEq(_log.emitter, _feed, "the answer went to the other feed");
        assertEq(_log.topics[0], keccak256("AnswerSet(uint80,int256,uint256)"), "not an answer at all");
        (int256 answer,) = abi.decode(_log.data, (int256, uint256));
        assertEq(answer, _answer);
    }

    function _assertFailingSet(
        Vm.Log memory _log,
        address _feed,
        bool _failing
    )
        private pure
    {
        assertEq(_log.emitter, _feed, "the failure switch went to the other feed");
        assertEq(_log.topics[0], keccak256("FailingSet(bool)"), "not the failure switch at all");
        assertEq(abi.decode(_log.data, (bool)), _failing);
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
