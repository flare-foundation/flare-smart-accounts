// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

/**
 * @title MarketRecordFixture
 * @notice Writes a deployment record in the recorder's own shape, under a name the suite chooses,
 * so the Sepolia market script's phases can be driven over a record with a piece missing or wrong
 * without ever writing the deployment's own.
 */
abstract contract MarketRecordFixture is Test {
    /// @dev Records whichever of the four addresses is not zero, under the names the script reads.
    /// Whichever are absent, what is written is a record like any other: the separators go between
    /// the entries there are, so a record missing an asset reaches the script's own guard rather
    /// than the JSON parser.
    function _writeRecord(
        string memory _file,
        address _loanToken,
        address _collateralFeed,
        address _loanFeed,
        address _oracle
    )
        internal
    {
        string memory json = "[";
        json = _append(json, "TestnetLoanToken", "TestnetLoanToken.sol", _loanToken);
        json = _append(json, "TestnetFeedCollateralUsd", "TestnetPriceFeed.sol", _collateralFeed);
        json = _append(json, "TestnetFeedLoanUsd", "TestnetPriceFeed.sol", _loanFeed);
        json = _append(json, "RehearsalMarketOracle", "MorphoChainlinkOracleV2.sol", _oracle);
        vm.createDir("deployment/output-internal/sepolia", true);
        vm.writeFile(_file, string.concat(json, "]"));
    }

    /// @dev Adds one entry to `_json`, with a comma before it if an entry is already there.
    function _append(
        string memory _json,
        string memory _name,
        string memory _contractName,
        address _addr
    )
        private pure
        returns (string memory)
    {
        if (_addr == address(0)) {
            return _json;
        }
        return string.concat(
            _json,
            keccak256(bytes(_json)) == keccak256("[") ? "" : ",",
            "{\"name\":\"",
            _name,
            "\",\"contractName\":\"",
            _contractName,
            "\",\"address\":\"",
            vm.toString(_addr),
            "\"}"
        );
    }
}
