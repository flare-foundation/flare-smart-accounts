// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;


import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title MockUniswapV3Router
/// @notice This is the mock router that is used by MasterAccountController contract only for test purposes.
contract MockUniswapV3Router {

    error TooLittleReceived();

    mapping(address => uint256) public prices; // token address => price in wei

    function setPriceInWei(address _token, uint256 _priceInWei) external {
        prices[_token] = _priceInWei;
    }

    /**
     * swaps amountIn of tokenIn for tokenOut based on set prices in wei - expects prices to be set beforehand
     * swap router has to be approved for amountIn of tokenIn beforehand and
     * has to have enough balance of tokenOut to transfer to recipient
     * uses provided fee to calculate amountOut
     * reverts if amountOut is less than amountOutMinimum
     */
    function exactInputSingle(
        ISwapRouter.ExactInputSingleParams calldata _params
    )
        external
        returns (uint256 _amountOut)
    {
        uint256 tokenInDecimals = IERC20Metadata(_params.tokenIn).decimals();
        uint256 tokenOutDecimals = IERC20Metadata(_params.tokenOut).decimals();
        // calculate amountOut based on set prices and fee
        _amountOut = prices[_params.tokenIn] * _params.amountIn * (1e6 - _params.fee) * (10 ** tokenOutDecimals) /
            1e6 / prices[_params.tokenOut] / (10 ** tokenInDecimals);

        require(_amountOut >= _params.amountOutMinimum, TooLittleReceived());

        IERC20(_params.tokenIn).transferFrom(
            msg.sender,
            address(this),
            _params.amountIn
        );

        IERC20(_params.tokenOut).transfer(
            _params.recipient,
            _amountOut
        );
    }
}
