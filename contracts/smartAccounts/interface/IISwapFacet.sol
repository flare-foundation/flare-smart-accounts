// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

import {ISwapFacet} from "../../userInterfaces/facets/ISwapFacet.sol";

/**
 * @title IISwapFacet
 * @notice Internal interface for the SwapFacet contract.
 */
interface IISwapFacet is ISwapFacet {

    /**
     * @notice Sets swap parameters.
     * @param _uniswapV3Router The Uniswap V3 router address.
     * @param _stableCoin StableCoin (USDT0, USDX,...) token address.
     * @param _wNatStableCoinPoolFeeTierPPM The WNAT/StableCoin pool fee tier
              (in PPM - supported values: 100, 500, 3000, 10000).
     * @param _stableCoinFXrpPoolFeeTierPPM The StableCoin/FXRP pool fee tier
              (in PPM - supported values: 100, 500, 3000, 10000).
     * @param _maxSlippagePPM The maximum slippage allowed for swaps (in PPM).
     * @param _stableCoinUsdFeedId The StableCoin/USD feed ID as in FTSO.
     * @param _wNatUsdFeedId The WNAT/USD feed ID as in FTSO.
     * Can only be called by the owner.
     */
    function setSwapParams(
        address _uniswapV3Router,
        address _stableCoin,
        uint24 _wNatStableCoinPoolFeeTierPPM,
        uint24 _stableCoinFXrpPoolFeeTierPPM,
        uint24 _maxSlippagePPM,
        bytes21 _stableCoinUsdFeedId,
        bytes21 _wNatUsdFeedId
    )
        external;
}