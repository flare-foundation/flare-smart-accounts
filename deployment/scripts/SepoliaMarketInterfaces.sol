// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IMorpho} from "../../contracts/smartAccounts/interface/IMorpho.sol";

/**
 * @notice The external ABIs the rehearsal market is built against, declared here in the
 * repository's own words the way `IMorpho` is: the upstream sources are GPL and this repository
 * is MIT, so no Morpho file is imported. Every type is the ABI type - the upstream interfaces'
 * typed parameters (`IERC4626`, `AggregatorV3Interface`) encode as `address` - so the selectors
 * are the deployed contracts' own. Pinned to the deployed Sepolia contracts by the fork suite.
 */

/// @notice Morpho's `MorphoChainlinkOracleV2Factory`: creates and vouches for its oracles.
interface IMorphoChainlinkOracleV2Factory {
    function createMorphoChainlinkOracleV2(
        address _baseVault,
        uint256 _baseVaultConversionSample,
        address _baseFeed1,
        address _baseFeed2,
        uint256 _baseTokenDecimals,
        address _quoteVault,
        uint256 _quoteVaultConversionSample,
        address _quoteFeed1,
        address _quoteFeed2,
        uint256 _quoteTokenDecimals,
        bytes32 _salt
    )
        external
        returns (address oracle);

    function isMorphoChainlinkOracleV2(
        address _target
    )
        external view
        returns (bool);
}

/// @notice The part of Morpho Blue that sets a market up, which the accounts never call and
/// `IMorpho` therefore does not carry.
interface IMorphoMarketSetup {
    function createMarket(
        IMorpho.MarketParams memory _marketParams
    )
        external;

    function supply(
        IMorpho.MarketParams memory _marketParams,
        uint256 _assets,
        uint256 _shares,
        address _onBehalf,
        bytes memory _data
    )
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function isLltvEnabled(
        uint256 _lltv
    )
        external view
        returns (bool);

    function isIrmEnabled(
        address _irm
    )
        external view
        returns (bool);
}

/// @notice The adaptive rate model's one binding: the Morpho instance it serves.
interface IMorphoIrm {
    // solhint-disable-next-line func-name-mixedcase
    function MORPHO()
        external view
        returns (address);
}

/// @notice Morpho's `MorphoChainlinkOracleV2`, read back for its wiring: the vaults and feeds it
/// was built over and its scale, all immutable. Its `price()` is `IOracle`'s.
interface IMorphoChainlinkOracleV2 {
    // solhint-disable func-name-mixedcase
    function BASE_VAULT()
        external view
        returns (address);

    function QUOTE_VAULT()
        external view
        returns (address);

    function BASE_FEED_1()
        external view
        returns (address);

    function BASE_FEED_2()
        external view
        returns (address);

    function QUOTE_FEED_1()
        external view
        returns (address);

    function QUOTE_FEED_2()
        external view
        returns (address);

    function SCALE_FACTOR()
        external view
        returns (uint256);
    // solhint-enable func-name-mixedcase
}
