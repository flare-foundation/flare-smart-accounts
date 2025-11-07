// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";


contract SwapFacet {
    /// @notice Feed IDs for price oracles
    bytes21 private constant FLR_USD_FEED_ID = 0x01464c522f55534400000000000000000000000000;
    bytes21 private constant USDT_USD_FEED_ID = 0x01555344542f555344000000000000000000000000;
    bytes21 private constant XRP_USD_FEED_ID = 0x015852502f55534400000000000000000000000000;

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

    function swapWNatForUsdt0(
        string calldata _xrplAddress
    )
        external
    {
        State storage state = getState();
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
        emit IMasterAccountController.SwapExecuted(
            address(personalAccount),
            tokenIn,
            state.usdt0,
            _xrplAddress,
            amountIn,
            amountOut
        );
    }

    function swapUsdt0ForFAsset(
        string calldata _xrplAddress
    )
        external
    {
        State storage state = getState();
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
        emit IMasterAccountController.SwapExecuted(
            address(personalAccount),
            state.usdt0,
            tokenOut,
            _xrplAddress,
            amountIn,
            amountOut
        );
    }

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
        external
    {
        LibDiamond.enforceIsContractOwner();
        require(_uniswapV3Router != address(0), IMasterAccountController.InvalidUniswapV3Router());
        require(_usdt0 != address(0), IMasterAccountController.InvalidUsdt0());
        require(
            isPoolFeeTierPPMValid(_wNatUsdt0PoolFeeTierPPM) && isPoolFeeTierPPMValid(_usdt0FXrpPoolFeeTierPPM),
            IMasterAccountController.InvalidPoolFeeTierPPM()
        );
        require(_maxSlippagePPM <= 1e6, IMasterAccountController.InvalidMaxSlippagePPM());
        State storage state = getState();
        state.uniswapV3Router = _uniswapV3Router;
        state.usdt0 = _usdt0;
        state.wNatUsdt0PoolFeeTierPPM = _wNatUsdt0PoolFeeTierPPM;
        state.usdt0FXrpPoolFeeTierPPM = _usdt0FXrpPoolFeeTierPPM;
        state.maxSlippagePPM = _maxSlippagePPM;
        emit IMasterAccountController.SwapParamsSet(
            _uniswapV3Router,
            _usdt0,
            _wNatUsdt0PoolFeeTierPPM,
            _usdt0FXrpPoolFeeTierPPM,
            _maxSlippagePPM
        );
    }

    /**
     * @inheritdoc IMasterAccountController
     */
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
        State storage state = getState();
        _uniswapV3Router = state.uniswapV3Router;
        _usdt0 = state.usdt0;
        _wNatUsdt0PoolFeeTierPPM = state.wNatUsdt0PoolFeeTierPPM;
        _usdt0FXrpPoolFeeTierPPM = state.usdt0FXrpPoolFeeTierPPM;
        _maxSlippagePPM = state.maxSlippagePPM;
    }

    function isPoolFeeTierPPMValid(uint24 _poolFeeTierPPM) internal pure returns (bool) {
        return _poolFeeTierPPM == 100 || _poolFeeTierPPM == 500 || _poolFeeTierPPM == 3000 || _poolFeeTierPPM == 10000;
    }

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.SwapFacet.State");

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
