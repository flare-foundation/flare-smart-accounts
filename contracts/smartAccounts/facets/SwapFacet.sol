// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IISwapFacet} from "../interface/IISwapFacet.sol";
import {ISwapFacet} from "../../userInterfaces/facets/ISwapFacet.sol";
import {Swap} from "../library/Swap.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title SwapFacet
 * @notice Facet for handling token swaps using Uniswap V3.
 */
contract SwapFacet is IISwapFacet, FacetBase {

    /// @notice FLR/USD feed IDs for price oracles
    bytes21 private constant FLR_USD_FEED_ID = 0x01464c522f55534400000000000000000000000000;
    /// @notice USDT/USD feed IDs for price oracles
    bytes21 private constant USDT_USD_FEED_ID = 0x01555344542f555344000000000000000000000000;
    /// @notice XRP/USD feed IDs for price oracles
    bytes21 private constant XRP_USD_FEED_ID = 0x015852502f55534400000000000000000000000000;

    /// @inheritdoc ISwapFacet
    function swapWNatForUsdt0(
        string calldata _xrplAddress
    )
        external nonReentrant
    {
        Swap.State storage state = Swap.getState();
        IIPersonalAccount personalAccount = PersonalAccounts.getOrCreatePersonalAccount(_xrplAddress);
        address tokenIn = address(ContractRegistry.getWNat());
        (uint256 amountIn, uint256 amountOut) = personalAccount.executeSwap(
            state.uniswapV3Router,
            tokenIn,
            FLR_USD_FEED_ID,
            state.usdt0,
            USDT_USD_FEED_ID,
            state.wNatUsdt0PoolFeeTierPPM,
            state.maxSlippagePPM
        );
        emit SwapExecuted(
            address(personalAccount),
            tokenIn,
            state.usdt0,
            _xrplAddress,
            amountIn,
            amountOut
        );
    }

    /// @inheritdoc ISwapFacet
    function swapUsdt0ForFAsset(
        string calldata _xrplAddress
    )
        external nonReentrant
    {
        Swap.State storage state = Swap.getState();
        IIPersonalAccount personalAccount = PersonalAccounts.getOrCreatePersonalAccount(_xrplAddress);
        address tokenOut = address(ContractRegistry.getAssetManagerFXRP().fAsset());
        (uint256 amountIn, uint256 amountOut) = personalAccount.executeSwap(
            state.uniswapV3Router,
            state.usdt0,
            USDT_USD_FEED_ID,
            tokenOut,
            XRP_USD_FEED_ID,
            state.usdt0FXrpPoolFeeTierPPM,
            state.maxSlippagePPM
        );
        emit SwapExecuted(
            address(personalAccount),
            state.usdt0,
            tokenOut,
            _xrplAddress,
            amountIn,
            amountOut
        );
    }

    /// @inheritdoc IISwapFacet
    function setSwapParams(
        address _uniswapV3Router,
        address _usdt0,
        uint24 _wNatUsdt0PoolFeeTierPPM,
        uint24 _usdt0FXrpPoolFeeTierPPM,
        uint24 _maxSlippagePPM
    )
        external
        onlyOwnerWithTimelock
    {
        require(_uniswapV3Router != address(0), InvalidUniswapV3Router());
        require(_usdt0 != address(0), InvalidUsdt0());
        require(
            _isPoolFeeTierPPMValid(_wNatUsdt0PoolFeeTierPPM) && _isPoolFeeTierPPMValid(_usdt0FXrpPoolFeeTierPPM),
            InvalidPoolFeeTierPPM()
        );
        require(_maxSlippagePPM <= 1e6, InvalidMaxSlippagePPM());
        Swap.State storage state = Swap.getState();
        state.uniswapV3Router = _uniswapV3Router;
        state.usdt0 = _usdt0;
        state.wNatUsdt0PoolFeeTierPPM = _wNatUsdt0PoolFeeTierPPM;
        state.usdt0FXrpPoolFeeTierPPM = _usdt0FXrpPoolFeeTierPPM;
        state.maxSlippagePPM = _maxSlippagePPM;
        emit SwapParamsSet(
            _uniswapV3Router,
            _usdt0,
            _wNatUsdt0PoolFeeTierPPM,
            _usdt0FXrpPoolFeeTierPPM,
            _maxSlippagePPM
        );
    }

    /// @inheritdoc ISwapFacet
    function getSwapParams()
        external view
        returns (
            address _uniswapV3Router,
            address _usdt0,
            uint24 _wNatUsdt0PoolFeeTierPPM,
            uint24 _usdt0FXrpPoolFeeTierPPM,
            uint24 _maxSlippagePPM
        )
    {
        Swap.State storage state = Swap.getState();
        _uniswapV3Router = state.uniswapV3Router;
        _usdt0 = state.usdt0;
        _wNatUsdt0PoolFeeTierPPM = state.wNatUsdt0PoolFeeTierPPM;
        _usdt0FXrpPoolFeeTierPPM = state.usdt0FXrpPoolFeeTierPPM;
        _maxSlippagePPM = state.maxSlippagePPM;
    }

    function _isPoolFeeTierPPMValid(uint24 _poolFeeTierPPM) internal pure returns (bool) {
        return _poolFeeTierPPM == 100 || _poolFeeTierPPM == 500 || _poolFeeTierPPM == 3000 || _poolFeeTierPPM == 10000;
    }
}
