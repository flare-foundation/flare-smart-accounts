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
     * @param _usdt0 USDT0 token address.
     * @param _wNatUsdt0PoolFeeTierPPM The WNAT/USDT0 pool fee tier (in PPM - supported values: 100, 500, 3000, 10000).
     * @param _usdt0FXrpPoolFeeTierPPM The USDT0/FXRP pool fee tier (in PPM - supported values: 100, 500, 3000, 10000).
     * @param _maxSlippagePPM The maximum slippage allowed for swaps (in PPM).
     * Can only be called by the owner.
     */
    function setSwapParams(
        address _uniswapV3Router,
        address _usdt0,
        uint24 _wNatUsdt0PoolFeeTierPPM,
        uint24 _usdt0FXrpPoolFeeTierPPM,
        uint24 _maxSlippagePPM
    )
        external;
}