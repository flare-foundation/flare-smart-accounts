// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IISwapFacet} from "../interface/IISwapFacet.sol";
import {ISwapFacet} from "../../userInterfaces/facets/ISwapFacet.sol";
import {Swap} from "../library/Swap.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {FacetBase} from "./FacetBase.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SwapFacet
 * @notice Facet for handling token swaps using Uniswap V3.
 */
contract SwapFacet is IISwapFacet, ReentrancyGuard, FacetBase {

    /// @notice XRP/USD feed IDs for price oracles
    bytes21 private constant XRP_USD_FEED_ID = 0x015852502f55534400000000000000000000000000;

    /// @inheritdoc ISwapFacet
    function swapWNatForStableCoin(
        string calldata _xrplAddress
    )
        external nonReentrant
    {
        Swap.State storage state = Swap.getState();
        IIPersonalAccount personalAccount = PersonalAccounts.getOrCreatePersonalAccount(_xrplAddress);
        address tokenIn = address(ContractRegistry.getWNat());
        address tokenOut = state.stableCoin;
        (uint256 amountIn, uint256 amountOut) = personalAccount.executeSwap(
            state.uniswapV3Router,
            tokenIn,
            state.wNatUsdFeedId,
            tokenOut,
            state.stableCoinUsdFeedId,
            state.wNatStableCoinPoolFeeTierPPM,
            state.maxSlippagePPM
        );
        emit SwapExecuted(
            address(personalAccount),
            tokenIn,
            tokenOut,
            _xrplAddress,
            amountIn,
            amountOut
        );
    }

    /// @inheritdoc ISwapFacet
    function swapStableCoinForFAsset(
        string calldata _xrplAddress
    )
        external nonReentrant
    {
        Swap.State storage state = Swap.getState();
        IIPersonalAccount personalAccount = PersonalAccounts.getOrCreatePersonalAccount(_xrplAddress);
        address tokenIn = state.stableCoin;
        address tokenOut = address(ContractRegistry.getAssetManagerFXRP().fAsset());
        (uint256 amountIn, uint256 amountOut) = personalAccount.executeSwap(
            state.uniswapV3Router,
            tokenIn,
            state.stableCoinUsdFeedId,
            tokenOut,
            XRP_USD_FEED_ID,
            state.stableCoinFXrpPoolFeeTierPPM,
            state.maxSlippagePPM
        );
        emit SwapExecuted(
            address(personalAccount),
            tokenIn,
            tokenOut,
            _xrplAddress,
            amountIn,
            amountOut
        );
    }

    /// @inheritdoc IISwapFacet
    function setSwapParams(
        address _uniswapV3Router,
        address _stableCoin,
        uint24 _wNatStableCoinPoolFeeTierPPM,
        uint24 _stableCoinFXrpPoolFeeTierPPM,
        uint24 _maxSlippagePPM,
        bytes21 _stableCoinUsdFeedId,
        bytes21 _wNatUsdFeedId
    )
        external
        onlyOwnerWithTimelock
    {
        require(_uniswapV3Router != address(0), InvalidUniswapV3Router());
        require(_stableCoin != address(0), InvalidStableCoin());
        require(
            _isPoolFeeTierPPMValid(_wNatStableCoinPoolFeeTierPPM) &&
            _isPoolFeeTierPPMValid(_stableCoinFXrpPoolFeeTierPPM),
            InvalidPoolFeeTierPPM()
        );
        require(_maxSlippagePPM <= 1e6, InvalidMaxSlippagePPM());
        require(_stableCoinUsdFeedId != bytes21(0) && _wNatUsdFeedId != bytes21(0), InvalidFeedId());
        Swap.State storage state = Swap.getState();
        state.uniswapV3Router = _uniswapV3Router;
        state.stableCoin = _stableCoin;
        state.wNatStableCoinPoolFeeTierPPM = _wNatStableCoinPoolFeeTierPPM;
        state.stableCoinFXrpPoolFeeTierPPM = _stableCoinFXrpPoolFeeTierPPM;
        state.maxSlippagePPM = _maxSlippagePPM;
        state.stableCoinUsdFeedId = _stableCoinUsdFeedId;
        state.wNatUsdFeedId = _wNatUsdFeedId;
        emit SwapParamsSet(
            _uniswapV3Router,
            _stableCoin,
            _wNatStableCoinPoolFeeTierPPM,
            _stableCoinFXrpPoolFeeTierPPM,
            _maxSlippagePPM,
            _stableCoinUsdFeedId,
            _wNatUsdFeedId
        );
    }

    /// @inheritdoc ISwapFacet
    function getSwapParams()
        external view
        returns (
            address _uniswapV3Router,
            address _stableCoin,
            uint24 _wNatStableCoinPoolFeeTierPPM,
            uint24 _stableCoinFXrpPoolFeeTierPPM,
            uint24 _maxSlippagePPM,
            bytes21 _stableCoinUsdFeedId,
            bytes21 _wNatUsdFeedId
        )
    {
        Swap.State storage state = Swap.getState();
        _uniswapV3Router = state.uniswapV3Router;
        _stableCoin = state.stableCoin;
        _wNatStableCoinPoolFeeTierPPM = state.wNatStableCoinPoolFeeTierPPM;
        _stableCoinFXrpPoolFeeTierPPM = state.stableCoinFXrpPoolFeeTierPPM;
        _maxSlippagePPM = state.maxSlippagePPM;
        _stableCoinUsdFeedId = state.stableCoinUsdFeedId;
        _wNatUsdFeedId = state.wNatUsdFeedId;
    }

    function _isPoolFeeTierPPMValid(uint24 _poolFeeTierPPM) internal pure returns (bool) {
        return _poolFeeTierPPM == 100 || _poolFeeTierPPM == 500 || _poolFeeTierPPM == 3000 || _poolFeeTierPPM == 10000;
    }
}
