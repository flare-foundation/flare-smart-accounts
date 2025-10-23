// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IPeripheryImmutableState } from "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";


/**
 * @title UniswapV3
 * @dev Library for interacting with Uniswap V3 protocol.
 */
library UniswapV3 {
    using SafeERC20 for IERC20;

    error SwapDisabled();
    error PoolDoesNotExist();
    error InsufficientLiquidity();

    /**
     * @notice Executes a swap on Uniswap V3.
     * @param _uniswapV3Router The address of the Uniswap V3 router.
     * @param _tokenIn The address of the input token.
     * @param _tokenOut The address of the output token.
     * @param _poolFeeTierPPM The fee tier of the pool to use for the swap (in PPM).
     * @return _amountIn The amount of input tokens used for the swap.
     * @return _amountOut The amount of output tokens received from the swap.
     */
    function executeSwap(
        address _uniswapV3Router,
        address _tokenIn,
        address _tokenOut,
        uint24 _poolFeeTierPPM
    )
        internal
        returns (uint256 _amountIn, uint256 _amountOut)
    {
        // Get Uniswap V3 Factory
        require(_uniswapV3Router != address(0), SwapDisabled());
        IUniswapV3Factory factory = IUniswapV3Factory(IPeripheryImmutableState(_uniswapV3Router).factory());

        // Check if pool exists
        address poolAddress = factory.getPool(_tokenIn, _tokenOut, _poolFeeTierPPM);
        require(poolAddress != address(0), PoolDoesNotExist());

        // Check if pool has liquidity
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        require(pool.liquidity() > 0, InsufficientLiquidity());

        // Swap everything we have
        _amountIn = IERC20(_tokenIn).balanceOf(address(this));

        // Approve router to spend tokens using SafeERC20
        IERC20(_tokenIn).safeIncreaseAllowance(_uniswapV3Router, _amountIn);

        // Prepare swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: _poolFeeTierPPM,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _amountIn,
            amountOutMinimum: 0, // TODO : Add slippage protection using price oracles
            sqrtPriceLimitX96: 0
        });

        // Execute swap
        _amountOut = ISwapRouter(_uniswapV3Router).exactInputSingle(params);
    }
}