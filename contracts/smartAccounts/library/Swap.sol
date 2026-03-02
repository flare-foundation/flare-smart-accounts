// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Swap {

    /// @custom:storage-location erc7201:smartAccounts.Swap.State
    struct State {
        /// @notice Uniswap V3 router address
        address uniswapV3Router;
        /// @notice StableCoin (USDT0, USDX,...) token address
        address stableCoin;
        /// @notice Uniswap V3 pool fee tier (WNAT/StableCoin) in PPM (supported values: 100, 500, 3000, 10000)
        uint24 wNatStableCoinPoolFeeTierPPM;
        /// @notice Uniswap V3 pool fee tier (StableCoin/FXRP) in PPM (supported values: 100, 500, 3000, 10000)
        uint24 stableCoinFXrpPoolFeeTierPPM;
        /// @notice Maximum slippage allowed for swaps (in PPM)
        uint24 maxSlippagePPM;
        /// @notice StableCoin/USD feed ID as in FTSO
        bytes21 stableCoinUsdFeedId;
        /// @notice WNAT/USD feed ID as in FTSO
        bytes21 wNatUsdFeedId;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.Swap.State")) - 1)) & ~bytes32(uint256(0xff)
    );

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