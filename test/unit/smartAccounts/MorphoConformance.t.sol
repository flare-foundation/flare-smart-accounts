// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IMorpho} from "../../../contracts/smartAccounts/interface/IMorpho.sol";
import {IOracle} from "../../../contracts/smartAccounts/interface/IOracle.sol";
import {IIrm} from "../../../contracts/smartAccounts/interface/IIrm.sol";
import {MorphoMath} from "../../../contracts/smartAccounts/library/MorphoMath.sol";
import {MockMorpho} from "../../../contracts/mock/MockMorpho.sol";
import {MockRawReturner} from "../../../contracts/mock/MockRawReturner.sol";

/**
 * @title MorphoConformanceTest
 * @notice Pins our hand-written Morpho Blue mirror (`IMorpho`, `IIrm`, `IOracle`) and arithmetic
 * (`MorphoMath`) to
 * the canonical `morpho-blue` v1.0.0 (commit 55d2d99304fb3fb930c688462ae2ccabb1d533ad), whose
 * source is GPL-2.0-or-later and therefore deliberately not a dependency of this MIT repository.
 * The expected values were produced once from the pinned upstream on 2026-09-03 - selectors with
 * `cast sig`, the market id from the live Ethereum FXRP/RLUSD market, the conversion vectors by
 * running upstream `SharesMathLib`, the return schemas from the upstream `Position` and `Market`
 * struct definitions - and are hardcoded here, so a later edit to the mirror's signatures, its
 * `position`/`market` return schemas, the id or the math that drifts from Morpho fails this
 * suite. Morpho Blue is immutable, so the target never moves; a different Morpho implementation
 * would need this verification repeated before registration.
 */
contract MorphoConformanceTest is Test {
    // the live Ethereum FXRP/RLUSD Morpho Blue market (verified on mainnet on 2026-09-02)
    address private constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address private constant FXRP = 0xCE6170EA245dC8D1f275A710a062b70f125F0110;
    address private constant ORACLE = 0x5AC03061500E0C97862a466a38a7e87FAC4Ac39D;
    address private constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 private constant LLTV = 0.77e18;
    bytes32 private constant LIVE_MARKET_ID =
        0x4fa31e3f8ba345227d44e1cf48559eea53a90dd5311dc006984c060f2f311d96;

    function testMirrorReturnSchemasDecodeCanonicalReturnData() public {
        // selectors say nothing about return types: canonical Morpho returns the `Position`
        // struct (uint256 supplyShares, uint128 borrowShares, uint128 collateral), the `Market`
        // struct (six uint128 words) and the oracle a uint256 - static tuples, one word each.
        // The function-type assignments pin the mirror's exact return types at compile time; the
        // boundary-sized raw words pin them at decode time (a narrower field would revert)
        MockRawReturner morpho = new MockRawReturner();
        function(bytes32, address) external view returns (uint256, uint128, uint128) position =
            IMorpho(address(morpho)).position;
        function(bytes32) external view
            returns (uint128, uint128, uint128, uint128, uint128, uint128) market =
            IMorpho(address(morpho)).market;
        function() external view returns (uint256) price = IOracle(address(morpho)).price;

        morpho.setReturnData(
            abi.encode(type(uint256).max, type(uint128).max, uint128(type(uint128).max - 1))
        );
        (uint256 supplyShares, uint128 borrowShares, uint128 collateral) =
            position(LIVE_MARKET_ID, address(this));
        assertEq(supplyShares, type(uint256).max);
        assertEq(borrowShares, type(uint128).max);
        assertEq(collateral, type(uint128).max - 1);

        morpho.setReturnData(
            abi.encode(
                type(uint128).max, uint128(type(uint128).max - 1), uint128(3), uint128(4),
                uint128(5), uint128(6)
            )
        );
        (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        ) = market(LIVE_MARKET_ID);
        assertEq(totalSupplyAssets, type(uint128).max);
        assertEq(totalSupplyShares, type(uint128).max - 1);
        assertEq(totalBorrowAssets, 3);
        assertEq(totalBorrowShares, 4);
        assertEq(lastUpdate, 5);
        assertEq(fee, 6);

        morpho.setReturnData(abi.encode(type(uint256).max));
        assertEq(price(), type(uint256).max);
    }

    function testMirrorSelectorsAreCanonical() public pure {
        // `Id` is a user-defined value type over bytes32 upstream, and `MarketParams` a
        // five-word tuple: both encode exactly as our plain types, which is what these
        // canonical selectors prove
        assertEq(IMorpho.supplyCollateral.selector, bytes4(0x238d6579));
        assertEq(IMorpho.withdrawCollateral.selector, bytes4(0x8720316d));
        assertEq(IMorpho.borrow.selector, bytes4(0x50d8cd4b));
        assertEq(IMorpho.repay.selector, bytes4(0x20b76e81));
        assertEq(IMorpho.accrueInterest.selector, bytes4(0x151c1ade));
        assertEq(IMorpho.position.selector, bytes4(0x93c52062));
        assertEq(IMorpho.market.selector, bytes4(0x5c60e39a));
        assertEq(IOracle.price.selector, bytes4(0xa035b1fe));
        // the rate model's two entry points take `MarketParams` and the six-word `Market`
        assertEq(IIrm.borrowRateView.selector, bytes4(0x8c00bf6b));
        assertEq(IIrm.borrowRate.selector, bytes4(0x9451fed4));
        // the mock's extra entry point, called by tests the way scripts call Morpho
        assertEq(MockMorpho.createMarket.selector, bytes4(0x8c1358a2));
    }

    function testMarketIdMatchesTheLiveMarket() public pure {
        // MarketParamsLib.id is keccak256(abi.encode(marketParams)): the id Morpho assigned to
        // the real FXRP/RLUSD market is the ground truth for both the struct layout and the hash
        IMorpho.MarketParams memory params = IMorpho.MarketParams({
            loanToken: RLUSD, collateralToken: FXRP, oracle: ORACLE, irm: IRM, lltv: LLTV
        });
        assertEq(MorphoMath.marketId(params), LIVE_MARKET_ID);
        assertEq(keccak256(abi.encode(params)), LIVE_MARKET_ID);
    }

    function testMarketStructIsTheCanonicalReturnSchema() public pure {
        // the `Market` struct decodes exactly the six words canonical `market(id)` returns, in
        // their order, and encodes back to them - what the rate model is handed
        bytes memory raw = abi.encode(
            uint128(1), uint128(2), uint128(3), uint128(4), uint128(5), uint128(6)
        );
        IMorpho.Market memory decoded = abi.decode(raw, (IMorpho.Market));
        assertEq(decoded.totalSupplyAssets, 1);
        assertEq(decoded.totalSupplyShares, 2);
        assertEq(decoded.totalBorrowAssets, 3);
        assertEq(decoded.totalBorrowShares, 4);
        assertEq(decoded.lastUpdate, 5);
        assertEq(decoded.fee, 6);
        assertEq(abi.encode(decoded), raw);
    }

    function testCompoundingMatchesUpstreamVectors() public pure {
        // (per-second WAD rate, seconds) -> upstream MathLib.wTaylorCompounded, the three-term
        // Taylor expansion each term rounded down; and wMulDown on the resulting factor
        assertEq(MorphoMath.wTaylorCompounded(0, 365 days), 0);
        assertEq(MorphoMath.wTaylorCompounded(0.05e18, 365 days), 653400420622696800000000000000000000);
        assertEq(MorphoMath.wTaylorCompounded(0.05e18, 1 days), 13446263520000000000000000000);
        assertEq(MorphoMath.wTaylorCompounded(3170979198, 365 days), 105166666653548106);
        assertEq(MorphoMath.wTaylorCompounded(3170979198, 12), 38051751099);
        assertEq(MorphoMath.wTaylorCompounded(1e16, 1e8), 166667166667666666666666666666666666);
        // 5% a year as a per-second rate: 1000 of debt earns 51.27 over the year
        assertEq(MorphoMath.wTaylorCompounded(1585489599, 365 days), 51270833327093113);
        assertEq(MorphoMath.wMulDown(1000e18, 51270833327093113), 51270833327093113000);
        assertEq(MorphoMath.wMulDown(3, 1e18 - 1), 2);
    }

    function testSharesMathMatchesUpstreamVectors() public pure {
        // (assets or shares, totalAssets, totalShares) -> upstream SharesMathLib results
        _assertVector(0, 0, 0, 0, 0, 0);
        _assertVector(1, 0, 0, 1_000_000, 1_000_000, 1);
        _assertVector(1000e18, 0, 0, 1e27, 1e27, 1e15);
        _assertVector(7e18, 1000e18, 1000e24, 7e24, 7e24, 7e12);
        _assertVector(123456789, 987654321, 555555555555, 69444568742, 69444568741, 219479);
        _assertVector(1e18, 3e18, 7e24, 2333333333333333332888889, 2333333333333333332888888, 428571428572);
        _assertVector(
            type(uint128).max, 1e30, 1e36,
            340282366920938463463374607431768211455000000,
            340282366920938463463374607431768211455000000,
            340282366920938463463374607431769
        );
    }

    function _assertVector(
        uint256 _amount,
        uint256 _totalAssets,
        uint256 _totalShares,
        uint256 _sharesUp,
        uint256 _sharesDown,
        uint256 _assetsUp
    )
        private pure
    {
        assertEq(MorphoMath.toSharesUp(_amount, _totalAssets, _totalShares), _sharesUp);
        assertEq(MorphoMath.toSharesDown(_amount, _totalAssets, _totalShares), _sharesDown);
        assertEq(MorphoMath.toAssetsUp(_amount, _totalAssets, _totalShares), _assetsUp);
    }
}
