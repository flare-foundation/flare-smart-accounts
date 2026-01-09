// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Swap {

    /// @custom:storage-location erc8042:smartAccounts.Swap.State
    struct State {
        /// @notice Uniswap V3 router address
        address uniswapV3Router;
        /// @notice USDT0 token address
        address usdt0;
        /// @notice Uniswap V3 pool fee tier (WNAT/USDT0) in PPM (supported values: 100, 500, 3000, 10000)
        uint24 wNatUsdt0PoolFeeTierPPM;
        /// @notice Uniswap V3 pool fee tier (USDT0/FXRP) in PPM (supported values: 100, 500, 3000, 10000)
        uint24 usdt0FXrpPoolFeeTierPPM;
        /// @notice Maximum slippage allowed for swaps (in PPM)
        uint24 maxSlippagePPM;
    }

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.Swap.State");

    function getState()
        internal pure
        returns (State storage _state)
    {
        bytes32 position = STATE_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }
}