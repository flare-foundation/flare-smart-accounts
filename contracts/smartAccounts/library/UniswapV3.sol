// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";

/**
 * @title UniswapV3
 * @dev Library for interacting with Uniswap V3 protocol.
 */
library UniswapV3 {
    using SafeERC20 for IERC20Metadata;

    /**
     * @notice Reverts if the swap is disabled - no Uniswap V3 router provided.
     */
    error SwapDisabled();

    /**
     * @notice Reverts if the amount of input tokens is zero.
     */
    error AmountInZero();

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
        bytes21 _tokenInFeedId,
        address _tokenOut,
        bytes21 _tokenOutFeedId,
        uint24 _poolFeeTierPPM,
        uint24 _maxSlippagePPM
    )
        internal
        returns (uint256 _amountIn, uint256 _amountOut)
    {
        // Ensure swap router is provided
        require(_uniswapV3Router != address(0), SwapDisabled());
        // Check input token balance
        IERC20Metadata tokenIn = IERC20Metadata(_tokenIn);
        _amountIn = tokenIn.balanceOf(address(this));
        require(_amountIn > 0, AmountInZero());

        uint256 minAmountOut;
        {
            // Fetch price feeds
            bytes21[] memory feedIds = new bytes21[](2);
            feedIds[0] = _tokenInFeedId;
            feedIds[1] = _tokenOutFeedId;
            (uint256[] memory valuesInWei, ) = ContractRegistry.getFtsoV2().getFeedsByIdInWei(feedIds);

            uint256 tokenInDecimals = tokenIn.decimals();
            uint256 tokenOutDecimals = IERC20Metadata(_tokenOut).decimals();

            // Calculate minimum amount out based on max slippage
            uint256 expectedAmountOut = Math.mulDiv(
                _amountIn,
                valuesInWei[0] * (10 ** tokenOutDecimals),
                valuesInWei[1] * (10 ** tokenInDecimals)
            );
            minAmountOut = Math.mulDiv(expectedAmountOut, 1e6 - _maxSlippagePPM, 1e6);
        }

        // Approve router to spend tokens using SafeERC20
        tokenIn.safeIncreaseAllowance(_uniswapV3Router, _amountIn);

        // Prepare swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: _poolFeeTierPPM,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        // Execute swap
        _amountOut = ISwapRouter(_uniswapV3Router).exactInputSingle(params);
    }
}