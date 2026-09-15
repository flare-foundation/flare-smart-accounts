// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMorpho} from "../../contracts/smartAccounts/interface/IMorpho.sol";
import {IOracle} from "../../contracts/smartAccounts/interface/IOracle.sol";
import {MorphoMath} from "../../contracts/smartAccounts/library/MorphoMath.sol";
import {TestnetLoanToken} from "../../contracts/mock/TestnetLoanToken.sol";
import {TestnetPriceFeed} from "../../contracts/mock/TestnetPriceFeed.sol";
import {DeployNetworks} from "../lib/DeployNetworks.sol";
import {
    IMorphoChainlinkOracleV2,
    IMorphoChainlinkOracleV2Factory,
    IMorphoIrm,
    IMorphoMarketSetup
} from "./SepoliaMarketInterfaces.sol";

/**
 * @title DeploySepoliaMarket
 * @notice The loan market the Coston2 <-> Sepolia rehearsal borrows against: our own loan token and
 * price feeds, an oracle built by Morpho's own factory over those feeds, the market on the public
 * Morpho instance, and its liquidity. Everything else the rehearsal needs - the pinned controller,
 * the remote implementations, the market's registration and fee terms, the routes - is the
 * runbook's, and governance's; this script only makes the market exist.
 *
 * Sepolia only. A market over feeds we control has no place on a production chain, so the guard
 * is the chain id, not the family. Four phases, each re-runnable: `assets` deploys the token and
 * the two feeds that the deployment record does not already hold; `market` builds the oracle and
 * creates the market, reusing either when it exists; `fund` supplies what the supplier's own
 * position is short of the configured liquidity - the position, not the pool's totals, which other
 * users and interest move - and mints only what the supplier does not already hold; `reset-feeds`
 * puts both feeds back to their configured prices and lifts any failure - the only phase that
 * touches feed state, so a rerun of the others never undoes a scenario in progress. A recorded
 * asset is trusted only with code at its address, the deployer as its owner and the configured
 * decimals: the phases mint and move feeds as the owner, and an oracle over feeds someone else
 * controls would be no rehearsal.
 * The market and fund phases hold the recorded oracle to the same checks: a market is its
 * parameters, so funding one built on an oracle the market phase refuses funds another market.
 *
 * The oracle's price is asserted at creation, over the feeds' initial answers: 36 + 18 - 6 decimal
 * places of scale give `2e48` for a $2 collateral and a $1 loan token. Fresh or recorded, the
 * oracle is held to the factory's registry and to its wiring - our two feeds and nothing else, the
 * scale the decimals give - so a record pointing at some other factory oracle is refused; only the
 * price is not re-asserted on reuse, since the feeds may deliberately be elsewhere by then.
 */
// solhint-disable no-console
contract DeploySepoliaMarket is Script {
    struct MarketConfig {
        address morpho;
        address irm;
        address oracleFactory;
        address collateralToken;
        uint8 collateralDecimals;
        uint8 loanTokenDecimals;
        uint8 feedDecimals;
        uint256 lltv;
        uint256 expectedOraclePrice;
        uint256 liquidity;
        int256 collateralInitialPrice;
        int256 loanInitialPrice;
        bytes32 oracleSalt;
        string loanTokenName;
        string loanTokenSymbol;
        string collateralFeedDescription;
        string loanFeedDescription;
    }

    struct Assets {
        TestnetLoanToken loanToken;
        TestnetPriceFeed collateralFeed;
        TestnetPriceFeed loanFeed;
    }

    /// @dev The deployment record's shape, in the field order `parseJson` produces (keys sorted).
    struct DeployedContract {
        address addr;
        string contractName;
        string name;
    }

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    string internal constant CONFIG_FILE = "deployment/market-config/sepolia.json";
    string internal constant RECORD_FILE = "deployment/deploys/sepolia.json";
    string internal constant OUTPUT_DIR = "deployment/output-internal/sepolia";
    string internal constant OUTPUT_FILE = "deployment/output-internal/sepolia/market.json";

    string internal constant LOAN_TOKEN_NAME = "TestnetLoanToken";
    string internal constant COLLATERAL_FEED_NAME = "TestnetFeedCollateralUsd";
    string internal constant LOAN_FEED_NAME = "TestnetFeedLoanUsd";
    string internal constant ORACLE_NAME = "RehearsalMarketOracle";

    function run(
        string calldata _expectedNetwork,
        string calldata _phase
    )
        external
    {
        require(block.chainid == SEPOLIA_CHAIN_ID, "the rehearsal market is a Sepolia-only deployment");
        string memory network = DeployNetworks.networkName(block.chainid);
        DeployNetworks.requireExpectedNetwork(network, _expectedNetwork);
        console2.log(string.concat("NETWORK: ", network));

        MarketConfig memory config = _loadConfig();
        // The signer is forge's, resolved from whatever the wrapper passed - a raw key, a keystore
        // or a Ledger - and `msg.sender` is that account. Reading DEPLOYER_PRIVATE_KEY here would
        // check one account and sign as another the moment the two differ, which is exactly what a
        // hardware run is. Note this validates the sender forge was GIVEN; a device whose address
        // is not that one fails later, at signing, rather than here.

        vm.startBroadcast(_signer());
        _runPhase(config, _phase, _signer(), RECORD_FILE, OUTPUT_FILE);
        vm.stopBroadcast();
    }

    /// @dev One phase, over the record at `_recordFile` and writing the market's manifest to
    /// `_outputFile`. The paths are the caller's so a suite can drive the phases over a record and
    /// a manifest of its own, and never over the deployment's.
    function _runPhase(
        MarketConfig memory _config,
        string memory _phase,
        address _deployer,
        string memory _recordFile,
        string memory _outputFile
    )
        internal
    {
        bytes32 phase = keccak256(bytes(_phase));
        if (phase == keccak256("assets")) {
            _deployAssets(_config, _deployer, _recordedAssets(_recordFile));
        } else if (phase == keccak256("market")) {
            Assets memory assets = _requireRecordedAssets(_config, _deployer, _recordFile);
            IOracle oracle = _createOracle(_config, assets, _recorded(ORACLE_NAME, _recordFile));
            _ensureMarket(_config, address(assets.loanToken), address(oracle), _outputFile);
        } else if (phase == keccak256("fund")) {
            Assets memory assets = _requireRecordedAssets(_config, _deployer, _recordFile);
            address recorded = _recorded(ORACLE_NAME, _recordFile);
            require(recorded != address(0), "no oracle recorded: run the market phase first");
            IOracle oracle = _createOracle(_config, assets, recorded);
            (IMorpho.MarketParams memory params, bytes32 id) =
                _marketOf(_config, address(assets.loanToken), address(oracle));
            _fund(_config, assets.loanToken, params, id, _deployer);
        } else if (phase == keccak256("reset-feeds")) {
            _resetFeeds(_config, _requireRecordedAssets(_config, _deployer, _recordFile));
        } else {
            revert("unknown phase: assets | market | fund | reset-feeds");
        }
    }

    /// @dev Deploys whatever `_existing` lacks, with `_owner` as the owner of each, after holding
    /// what it does hold to the phases' needs; prints a record line for each new contract only,
    /// so the record follows what this run did.
    function _deployAssets(
        MarketConfig memory _config,
        address _owner,
        Assets memory _existing
    )
        internal
        returns (Assets memory assets)
    {
        _requireOurAssets(_config, _owner, _existing);
        assets = _existing;
        if (address(assets.loanToken) == address(0)) {
            assets.loanToken = new TestnetLoanToken(
                _config.loanTokenName, _config.loanTokenSymbol, _config.loanTokenDecimals, _owner
            );
            _recordLine(LOAN_TOKEN_NAME, "TestnetLoanToken.sol", address(assets.loanToken));
        }
        if (address(assets.collateralFeed) == address(0)) {
            assets.collateralFeed = new TestnetPriceFeed(
                _config.feedDecimals, _config.collateralFeedDescription, _config.collateralInitialPrice, _owner
            );
            _recordLine(COLLATERAL_FEED_NAME, "TestnetPriceFeed.sol", address(assets.collateralFeed));
        }
        if (address(assets.loanFeed) == address(0)) {
            assets.loanFeed = new TestnetPriceFeed(
                _config.feedDecimals, _config.loanFeedDescription, _config.loanInitialPrice, _owner
            );
            _recordLine(LOAN_FEED_NAME, "TestnetPriceFeed.sol", address(assets.loanFeed));
        }
    }

    /// @dev Checks the lending infrastructure's identity before anything is built on it, then
    /// builds the oracle through Morpho's factory - or takes `_existing` - and holds either to the
    /// factory's own registry and to the configured wiring over `_assets`' feeds. The exact price
    /// is asserted only for a fresh oracle, whose feeds still carry their initial answers.
    function _createOracle(
        MarketConfig memory _config,
        Assets memory _assets,
        address _existing
    )
        internal
        returns (IOracle oracle)
    {
        require(
            IERC20Metadata(_config.collateralToken).decimals() == _config.collateralDecimals,
            "the collateral token's decimals are not the configured ones"
        );
        IMorphoMarketSetup morpho = IMorphoMarketSetup(_config.morpho);
        require(morpho.isLltvEnabled(_config.lltv), "the configured LLTV is not enabled on this Morpho");
        require(morpho.isIrmEnabled(_config.irm), "the configured IRM is not enabled on this Morpho");
        require(IMorphoIrm(_config.irm).MORPHO() == _config.morpho, "the IRM serves another Morpho instance");

        if (_existing == address(0)) {
            oracle = IOracle(_buildOracle(_config, _assets));
            require(
                oracle.price() == _config.expectedOraclePrice,
                "the fresh oracle does not price the initial feeds at the expected scale"
            );
            _recordLine(ORACLE_NAME, "MorphoChainlinkOracleV2.sol", address(oracle));
        } else {
            oracle = IOracle(_existing);
        }
        require(
            IMorphoChainlinkOracleV2Factory(_config.oracleFactory).isMorphoChainlinkOracleV2(address(oracle)),
            "the oracle is not one the factory made"
        );
        _requireConfiguredWiring(_config, _assets, IMorphoChainlinkOracleV2(address(oracle)));
    }

    /// @dev Creates the market unless it exists - the id is the hash of its parameters, so an
    /// existing market with this id is exactly the configured one - and writes the parameters,
    /// the id and the oracle's code hash to `_outputFile` for the rehearsal's record.
    function _ensureMarket(
        MarketConfig memory _config,
        address _loanToken,
        address _oracle,
        string memory _outputFile
    )
        internal
        returns (IMorpho.MarketParams memory params, bytes32 id)
    {
        (params, id) = _marketOf(_config, _loanToken, _oracle);
        (,,,, uint128 lastUpdate,) = IMorpho(_config.morpho).market(id);
        if (lastUpdate == 0) {
            IMorphoMarketSetup(_config.morpho).createMarket(params);
            console2.log("Created market", vm.toString(id));
        } else {
            console2.log("Market exists, reused", vm.toString(id));
        }
        _writeMarketOutput(params, id, _oracle, _outputFile);
    }

    /// @dev Brings the supplier's own position up to the configured liquidity - the position, not
    /// the market's totals, which anyone's supply and the interest move. It is measured in assets
    /// rather than in shares held, so a token of someone else's supply on the deployer's behalf
    /// cannot pass for the seed, and the interest is accrued before it is measured, so a position
    /// the borrowing has already grown past the seed is not topped up over and over. Each call is
    /// its own transaction, so an attempt may have minted and stopped: both the mint and the
    /// supply are of the shortfall alone.
    function _fund(
        MarketConfig memory _config,
        TestnetLoanToken _loanToken,
        IMorpho.MarketParams memory _params,
        bytes32 _id,
        address _supplier
    )
        internal
    {
        IMorpho(_config.morpho).accrueInterest(_params);
        uint256 supplied = _suppliedAssets(_config.morpho, _id, _supplier);
        if (supplied >= _config.liquidity) {
            console2.log("Liquidity already supplied by", _supplier);
            return;
        }
        uint256 missing = _config.liquidity - supplied;
        uint256 held = _loanToken.balanceOf(_supplier);
        if (held < missing) {
            _loanToken.mint(_supplier, missing - held);
        }
        _loanToken.approve(_config.morpho, missing);
        IMorphoMarketSetup(_config.morpho).supply(_params, missing, 0, _supplier, "");
        // the slack is one share's worth and no more: Morpho rounds the shares it mints down,
        // so a landed supply can read short by less than a share - a hair of a token at first,
        // more once interest has lifted the share price - while a supply that landed elsewhere
        // or not at all is short by the whole seed
        require(
            _suppliedAssets(_config.morpho, _id, _supplier) + _oneShareInAssets(_config.morpho, _id)
                >= _config.liquidity,
            "the supply did not bring the supplier's position to the configured liquidity"
        );
        console2.log("Supplied", missing);
    }

    /// @dev The one phase that touches feed state: both feeds back to their configured answers,
    /// any failure lifted. Explicit, so no other rerun quietly ends a scenario in progress. Each
    /// call is its own transaction, so the collateral feed is made to fail first and restored
    /// last: a failing feed reverts the oracle, and no block prices a position against one answer
    /// restored and the other still in a scenario.
    function _resetFeeds(
        MarketConfig memory _config,
        Assets memory _assets
    )
        internal
    {
        _assets.collateralFeed.setFailing(true);
        _assets.collateralFeed.setAnswer(_config.collateralInitialPrice);
        _assets.loanFeed.setAnswer(_config.loanInitialPrice);
        _assets.loanFeed.setFailing(false);
        _assets.collateralFeed.setFailing(false);
    }

    function _writeMarketOutput(
        IMorpho.MarketParams memory _params,
        bytes32 _id,
        address _oracle,
        string memory _outputFile
    )
        internal
    {
        vm.createDir(OUTPUT_DIR, true);
        string memory out = "market";
        vm.serializeAddress(out, "loanToken", _params.loanToken);
        vm.serializeAddress(out, "collateralToken", _params.collateralToken);
        vm.serializeAddress(out, "oracle", _params.oracle);
        vm.serializeBytes32(out, "oracleCodeHash", _oracle.codehash);
        vm.serializeAddress(out, "irm", _params.irm);
        vm.serializeUint(out, "lltv", _params.lltv);
        string memory json = vm.serializeBytes32(out, "id", _id);
        vm.writeJson(json, _outputFile);
        console2.log("Market parameters written to", _outputFile);
    }

    function _loadConfig()
        internal view
        returns (MarketConfig memory config)
    {
        string memory json = vm.readFile(CONFIG_FILE);
        config.morpho = vm.parseJsonAddress(json, ".morpho");
        config.irm = vm.parseJsonAddress(json, ".irm");
        config.lltv = vm.parseJsonUint(json, ".lltv");
        config.oracleFactory = vm.parseJsonAddress(json, ".oracleFactory");
        config.collateralToken = vm.parseJsonAddress(json, ".collateralToken");
        config.collateralDecimals = uint8(vm.parseJsonUint(json, ".collateralDecimals"));
        config.loanTokenName = vm.parseJsonString(json, ".loanTokenName");
        config.loanTokenSymbol = vm.parseJsonString(json, ".loanTokenSymbol");
        config.loanTokenDecimals = uint8(vm.parseJsonUint(json, ".loanTokenDecimals"));
        config.feedDecimals = uint8(vm.parseJsonUint(json, ".feedDecimals"));
        config.collateralFeedDescription = vm.parseJsonString(json, ".collateralFeedDescription");
        config.collateralInitialPrice = vm.parseJsonInt(json, ".collateralInitialPrice");
        config.loanFeedDescription = vm.parseJsonString(json, ".loanFeedDescription");
        config.loanInitialPrice = vm.parseJsonInt(json, ".loanInitialPrice");
        config.expectedOraclePrice = vm.parseJsonUint(json, ".expectedOraclePrice");
        config.oracleSalt = vm.parseJsonBytes32(json, ".oracleSalt");
        config.liquidity = vm.parseJsonUint(json, ".liquidity");
    }

    function _recordedAssets(
        string memory _recordFile
    )
        internal view
        returns (Assets memory assets)
    {
        assets.loanToken = TestnetLoanToken(_recorded(LOAN_TOKEN_NAME, _recordFile));
        assets.collateralFeed = TestnetPriceFeed(_recorded(COLLATERAL_FEED_NAME, _recordFile));
        assets.loanFeed = TestnetPriceFeed(_recorded(LOAN_FEED_NAME, _recordFile));
    }

    function _requireRecordedAssets(
        MarketConfig memory _config,
        address _owner,
        string memory _recordFile
    )
        internal view
        returns (Assets memory assets)
    {
        assets = _recordedAssets(_recordFile);
        require(
            address(assets.loanToken) != address(0) && address(assets.collateralFeed) != address(0)
                && address(assets.loanFeed) != address(0),
            "the assets are not all recorded: run the assets phase first"
        );
        _requireOurAssets(_config, _owner, assets);
    }

    /// @dev Holds every asset `_assets` names to what the phases need of it: code at the address,
    /// `_owner` as its owner - the mint and every feed write are the owner's alone - and the
    /// configured decimals, which the oracle's scale is built from. A zero member is one not yet
    /// deployed and is passed over.
    function _requireOurAssets(
        MarketConfig memory _config,
        address _owner,
        Assets memory _assets
    )
        internal view
    {
        if (address(_assets.loanToken) != address(0)) {
            _requireOwnedContract(address(_assets.loanToken), _owner, "loan token");
            require(
                _assets.loanToken.decimals() == _config.loanTokenDecimals,
                "the recorded loan token has other decimals than configured"
            );
        }
        if (address(_assets.collateralFeed) != address(0)) {
            _requireOwnedContract(address(_assets.collateralFeed), _owner, "collateral feed");
            require(
                _assets.collateralFeed.decimals() == _config.feedDecimals,
                "the recorded collateral feed has other decimals than configured"
            );
        }
        if (address(_assets.loanFeed) != address(0)) {
            _requireOwnedContract(address(_assets.loanFeed), _owner, "loan feed");
            require(
                _assets.loanFeed.decimals() == _config.feedDecimals,
                "the recorded loan feed has other decimals than configured"
            );
        }
    }

    function _requireOwnedContract(
        address _contract,
        address _owner,
        string memory _what
    )
        internal view
    {
        require(_contract.code.length > 0, string.concat("the recorded ", _what, " has no code"));
        require(Ownable(_contract).owner() == _owner, string.concat("the recorded ", _what, " is not the deployer's"));
    }

    /// @dev The oracle's immutable wiring against the configuration: our collateral feed alone on
    /// the base side, our loan feed alone on the quote side, no vault on either (with no vault the
    /// factory's constructor fixes the conversion samples at one, which the fork suite pins), and
    /// the scale the decimals give: 36 plus the quote side's token and feed decimals, less the
    /// base side's.
    function _requireConfiguredWiring(
        MarketConfig memory _config,
        Assets memory _assets,
        IMorphoChainlinkOracleV2 _oracle
    )
        internal view
    {
        require(
            _oracle.BASE_FEED_1() == address(_assets.collateralFeed) && _oracle.BASE_FEED_2() == address(0),
            "the oracle's base side is not the recorded collateral feed alone"
        );
        require(
            _oracle.QUOTE_FEED_1() == address(_assets.loanFeed) && _oracle.QUOTE_FEED_2() == address(0),
            "the oracle's quote side is not the recorded loan feed alone"
        );
        require(
            _oracle.BASE_VAULT() == address(0) && _oracle.QUOTE_VAULT() == address(0),
            "the oracle prices a vault's share, not the token"
        );
        uint256 places = 36 + uint256(_config.loanTokenDecimals) + _assets.loanFeed.decimals()
            - _config.collateralDecimals - _assets.collateralFeed.decimals();
        require(_oracle.SCALE_FACTOR() == 10 ** places, "the oracle's scale is not the configured decimals'");
    }

    /// @dev What a single share of this market's supply is worth, rounded up: the whole of what
    /// Morpho's rounding can cost a supply that did land.
    function _oneShareInAssets(
        address _morpho,
        bytes32 _id
    )
        internal view
        returns (uint256)
    {
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = IMorpho(_morpho).market(_id);
        return MorphoMath.toAssetsUp(1, totalSupplyAssets, totalSupplyShares);
    }

    /// @dev What `_supplier`'s supply shares are worth in this market, rounded up: the seed is a
    /// quantity of the loan token, and a share count alone says nothing about how much.
    function _suppliedAssets(
        address _morpho,
        bytes32 _id,
        address _supplier
    )
        internal view
        returns (uint256)
    {
        (uint256 supplyShares,,) = IMorpho(_morpho).position(_id, _supplier);
        if (supplyShares == 0) {
            return 0;
        }
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = IMorpho(_morpho).market(_id);
        return MorphoMath.toAssetsUp(supplyShares, totalSupplyAssets, totalSupplyShares);
    }

    /// @dev The address the deployment record holds under `_name`, or zero when the record or
    /// the entry does not exist yet.
    function _recorded(
        string memory _name,
        string memory _recordFile
    )
        internal view
        returns (address)
    {
        if (!vm.exists(_recordFile)) {
            return address(0);
        }
        DeployedContract[] memory contracts =
            abi.decode(vm.parseJson(vm.readFile(_recordFile)), (DeployedContract[]));
        bytes32 nameHash = keccak256(bytes(_name));
        for (uint256 i = 0; i < contracts.length; i++) {
            if (keccak256(bytes(contracts[i].name)) == nameHash) {
                return contracts[i].addr;
            }
        }
        return address(0);
    }

    function _marketOf(
        MarketConfig memory _config,
        address _loanToken,
        address _oracle
    )
        internal pure
        returns (IMorpho.MarketParams memory params, bytes32 id)
    {
        params = IMorpho.MarketParams({
            loanToken: _loanToken,
            collateralToken: _config.collateralToken,
            oracle: _oracle,
            irm: _config.irm,
            lltv: _config.lltv
        });
        id = MorphoMath.marketId(params);
    }

    /// @dev The factory call on its own: eleven arguments, kept apart from `_createOracle`'s locals
    /// so the legacy pipeline `forge coverage` builds with can lay them out. One feed per side and
    /// no vaults (a zero vault with conversion sample 1 is the factory's "none").
    function _buildOracle(
        MarketConfig memory _config,
        Assets memory _assets
    )
        private
        returns (address)
    {
        return IMorphoChainlinkOracleV2Factory(_config.oracleFactory).createMorphoChainlinkOracleV2(
            address(0),
            1,
            address(_assets.collateralFeed),
            address(0),
            _config.collateralDecimals,
            address(0),
            1,
            address(_assets.loanFeed),
            address(0),
            _config.loanTokenDecimals,
            _config.oracleSalt
        );
    }

    /// @dev One line per new contract, in the shape `save-deployed-addresses.ts` parses out of the
    /// run's output. Printing goes through `_print`, which a suite overrides to read back what a
    /// phase would have handed the recorder.
    function _recordLine(
        string memory _name,
        string memory _contractFile,
        address _deployed
    )
        internal
    {
        _print(string.concat("DEPLOYED: ", _name, ", ", _contractFile, ": ", vm.toString(_deployed)));
    }


    /**
     * @notice The account this run signs as.
     * @dev In a run this is the signer forge resolved from the command line - a raw key, a keystore
     * or a Ledger - so the account the script checks and the account that signs are the same one.
     * It is a seam because a test cannot name that account any other way: `vm.prank` and a
     * broadcast are mutually exclusive, so a harness overrides this instead.
     */
    function _signer()
        internal view virtual
        returns (address)
    {
        return msg.sender;
    }

    function _print(
        string memory _line
    )
        internal virtual
    {
        console2.log(_line);
    }
}
