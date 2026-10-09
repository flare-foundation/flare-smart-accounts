// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IMorpho} from "../../../contracts/smartAccounts/interface/IMorpho.sol";
import {MorphoMath} from "../../../contracts/smartAccounts/library/MorphoMath.sol";
import {MockMorphoSupplySide} from "../../../contracts/mock/MockMorphoSupplySide.sol";
import {TestnetLoanToken} from "../../../contracts/mock/TestnetLoanToken.sol";
import {DeploySepoliaMarket} from "../../../deployment/scripts/DeploySepoliaMarket.s.sol";
import {DeploySepoliaMarketHarness} from "../../utils/DeploySepoliaMarketHarness.sol";

/**
 * @title SepoliaMarketFundingTest
 * @notice What the funding phase does about a market's supply totals, at states the public Sepolia
 * Morpho will not reach on demand: interest waiting to be accrued, and a share price lifted so far
 * by past interest that Morpho's rounding costs a landed supply more than a base unit. Both decide
 * whether a rerun tops the seed up again, so both are driven here against a lender-side stand-in
 * with its totals under the test's control, and the phase's own conversions are Morpho's.
 */
contract SepoliaMarketFundingTest is Test {
    uint256 private constant SEED = 1e24;
    uint256 private constant SHARE_UNIT = 1e6;

    DeploySepoliaMarketHarness private harness;
    DeploySepoliaMarket.MarketConfig private config;
    MockMorphoSupplySide private morpho;
    TestnetLoanToken private loanToken;
    IMorpho.MarketParams private params;
    bytes32 private id;

    function setUp() public {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        harness = new DeploySepoliaMarketHarness();
        config = harness.loadConfig();
        morpho = new MockMorphoSupplySide();
        config.morpho = address(morpho);
        config.liquidity = SEED;
        loanToken = new TestnetLoanToken("Sepolia Rehearsal USD", "rUSD", 18, address(harness));
        params = IMorpho.MarketParams({
            loanToken: address(loanToken),
            collateralToken: config.collateralToken,
            oracle: address(0xDEC1),
            irm: config.irm,
            lltv: config.lltv
        });
        id = MorphoMath.marketId(params);
    }

    function testAPositionTheInterestHasCarriedPastTheSeedIsNotToppedUp() public {
        // the position is a token short of the seed as the totals stand, and a token and a half
        // past it once the interest waiting on the market is accrued. Which of the two the phase
        // sees is the difference between leaving a funded market alone and minting into it again
        morpho.setMarket(id, uint128(SEED), uint128(SEED * SHARE_UNIT));
        morpho.setSupplyShares(id, address(harness), (SEED - 1e18) * SHARE_UNIT);
        morpho.addPendingInterest(id, 25e17);
        assertLt(_suppliedAssets(), SEED, "the stale totals put the position under the seed");

        harness.fund(config, loanToken, params, id);

        assertEq(loanToken.totalSupply(), 0, "nothing was minted");
        assertGe(_suppliedAssets(), SEED, "the accrued position is past the seed");
        (,,,, uint128 lastUpdate,) = morpho.market(id);
        assertEq(lastUpdate, block.timestamp, "the phase accrued before it measured");
    }

    function testASeedIsAcceptedShortByTheShareRoundingAndByNothingMore() public {
        // a market whose share price interest has lifted far above one base unit: Morpho mints the
        // shares a supply buys rounded down, so what lands reads short of what went in by up to a
        // share's worth. The phase must take that supply as the seed - and take nothing less
        morpho.setMarket(id, 5e30, 1e24);
        uint256 oneShare = MorphoMath.toAssetsUp(1, 5e30, 1e24);
        assertGt(oneShare, 1, "a share is worth more than a base unit here");

        harness.fund(config, loanToken, params, id);

        uint256 supplied = _suppliedAssets();
        assertEq(loanToken.totalSupply(), SEED, "the whole seed was minted and supplied");
        assertLt(supplied, SEED, "and what it bought reads short of it");
        assertGe(supplied + oneShare, SEED, "by less than a share, which is all the phase allows");
    }

    function testASupplyShortByMoreThanTheShareRoundingIsRefused() public {
        // the line the phase draws is one share's worth, so what proves it is a supply just past
        // it: one share withheld on top of the rounding, which lands between one and two shares
        // short - refused here, and accepted by any allowance a share wider
        uint128 totalAssets = 5e30;
        uint128 totalShares = 1e24;
        morpho.setMarket(id, totalAssets, totalShares);
        uint256 oneShare = MorphoMath.toAssetsUp(1, totalAssets, totalShares);
        uint256 credited = MorphoMath.toSharesDown(SEED, totalAssets, totalShares) - 1;
        uint256 landed =
            MorphoMath.toAssetsUp(credited, totalAssets + uint128(SEED), totalShares + uint128(credited));
        assertGt(SEED - landed, oneShare, "the supply falls past what the rounding can explain");
        assertLe(SEED - landed, 2 * oneShare, "and not so far that a looser allowance would catch it");

        morpho.setUncreditedShares(1);
        vm.expectRevert(bytes("the supply did not bring the supplier's position to the configured liquidity"));
        harness.fund(config, loanToken, params, id);
    }

    function testASupplyThatCreditsNothingIsRefused() public {
        // the slack for rounding is not slack for a supply that went nowhere: the market takes the
        // tokens and credits no shares, and the phase says so rather than reporting a funded market
        morpho.setMarket(id, uint128(SEED), uint128(SEED * SHARE_UNIT));
        morpho.setCreditNothing(true);
        vm.expectRevert(bytes("the supply did not bring the supplier's position to the configured liquidity"));
        harness.fund(config, loanToken, params, id);
    }

    function testTheMintCoversOnlyWhatTheSupplierDoesNotHold() public {
        // an attempt that minted and stopped leaves tokens in hand; the next one mints the rest
        morpho.setMarket(id, uint128(SEED), uint128(SEED * SHARE_UNIT));
        vm.prank(address(harness));
        loanToken.mint(address(harness), SEED / 4);
        harness.fund(config, loanToken, params, id);
        assertEq(loanToken.totalSupply(), SEED, "one allocation between the two attempts");
        assertEq(loanToken.balanceOf(address(harness)), 0, "and none of it left idle");
        assertGe(_suppliedAssets(), SEED, "the position holds the seed");
    }

    function _suppliedAssets()
        private view
        returns (uint256)
    {
        (uint256 shares,,) = morpho.position(id, address(harness));
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = morpho.market(id);
        return MorphoMath.toAssetsUp(shares, totalSupplyAssets, totalSupplyShares);
    }
}
