// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DeploySepoliaMarket} from "../../deployment/scripts/DeploySepoliaMarket.s.sol";
import {IMorpho} from "../../contracts/smartAccounts/interface/IMorpho.sol";
import {IOracle} from "../../contracts/smartAccounts/interface/IOracle.sol";
import {TestnetLoanToken} from "../../contracts/mock/TestnetLoanToken.sol";

/**
 * @title DeploySepoliaMarketHarness
 * @notice Exposes the market script's phases to the suites, which drive them against the real
 * Sepolia factory and Morpho - or, for what needs no chain, locally - without the deployment record
 * `run()` reads addresses from. The harness is the owner of what it deploys, so it can mint and
 * reset like the deployer does, and a test names both the file the market phase writes and the
 * record the phases read, so a suite never touches the deployment's own manifest or record.
 */
contract DeploySepoliaMarketHarness is DeploySepoliaMarket {
    /// @notice What the phases printed, in order: the record lines the recorder would consume.
    string[] public printed;

    function deployAssets(
        MarketConfig calldata _config,
        address _owner,
        Assets calldata _existing
    ) external returns (Assets memory) {
        return _deployAssets(_config, _owner, _existing);
    }

    function createOracle(
        MarketConfig calldata _config,
        Assets calldata _assets,
        address _existing
    ) external returns (IOracle) {
        return _createOracle(_config, _assets, _existing);
    }

    function ensureMarket(
        MarketConfig calldata _config,
        address _loanToken,
        address _oracle,
        string calldata _outputFile
    ) external returns (IMorpho.MarketParams memory, bytes32) {
        return _ensureMarket(_config, _loanToken, _oracle, _outputFile);
    }

    function fund(
        MarketConfig calldata _config,
        TestnetLoanToken _loanToken,
        IMorpho.MarketParams calldata _params,
        bytes32 _id
    ) external {
        _fund(_config, _loanToken, _params, _id, address(this));
    }

    function resetFeeds(MarketConfig calldata _config, Assets calldata _assets) external {
        _resetFeeds(_config, _assets);
    }

    function runPhase(
        MarketConfig calldata _config,
        string calldata _phase,
        address _deployer,
        string calldata _recordFile,
        string calldata _outputFile
    ) external {
        _runPhase(_config, _phase, _deployer, _recordFile, _outputFile);
    }

    function printedCount() external view returns (uint256) {
        return printed.length;
    }

    function loadConfig() external view returns (MarketConfig memory) {
        return _loadConfig();
    }

    function requireRecordedAssets(
        MarketConfig calldata _config,
        address _owner,
        string calldata _recordFile
    ) external view returns (Assets memory) {
        return _requireRecordedAssets(_config, _owner, _recordFile);
    }

    /// @dev Keeps the line the script composed, and prints it as the script would.
    function _print(string memory _line) internal override {
        printed.push(_line);
        super._print(_line);
    }
}
