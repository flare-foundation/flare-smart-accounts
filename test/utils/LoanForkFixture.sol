// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LoanRemoteFixture} from "./LoanRemoteFixture.sol";
import {MintableERC20} from "../../contracts/mock/MintableERC20.sol";
import {MockMorpho} from "../../contracts/mock/MockMorpho.sol";
import {MockOracle} from "../../contracts/mock/MockOracle.sol";
import {MockIrm} from "../../contracts/mock/MockIrm.sol";
import {MockOft} from "../../contracts/mock/MockOft.sol";
import {MockLzEndpoint} from "../../contracts/mock/MockLzEndpoint.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LoanForkFixture
 * @notice The remote fixture with the loan market's real Ethereum contracts behind it: canonical
 * Morpho Blue, the live FXRP/RLUSD market with its own oracle and adaptive rate model, and the
 * real tokens - at a pinned block, so the numbers a test asserts are reproducible.
 *
 * Everything the account itself touches is the production code path; only the delivery rail
 * stays mocked (the endpoint and the OFT), because the canonical wire hop is the other harness's
 * subject. What this fixture buys is the half a mock cannot: `MockIrm` returns a rate a test
 * chose, so nothing in the unit suites says the debt projection, the previews or the cover
 * boundaries agree with Morpho's adaptive model under real utilization.
 *
 * The suite skips itself unless `ETHEREUM_RPC_URL` names an endpoint that serves state at the
 * pinned block (an archive read; several public endpoints do).
 */
abstract contract LoanForkFixture is LoanRemoteFixture {
    /// @notice Canonical Morpho Blue, immutable, on Ethereum.
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    /// @notice The market's loan token, 18 decimals.
    address internal constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    /// @notice The market's collateral token, 6 decimals; it is its own LayerZero OFT.
    address internal constant FXRP = 0xCE6170EA245dC8D1f275A710a062b70f125F0110;
    /// @notice MorphoChainlinkOracleV2 over RedStone XRP/USD and Chainlink RLUSD/USD.
    address internal constant MARKET_ORACLE = 0x5AC03061500E0C97862a466a38a7e87FAC4Ac39D;
    /// @notice The market's adaptive curve rate model.
    address internal constant MARKET_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    /// @notice The market's liquidation loan-to-value, 77%.
    uint256 internal constant MARKET_LLTV = 0.77e18;

    /**
     * @notice The block every read and every assertion in the suite is made against.
     * @dev Chosen for what it holds: about 90.6% utilization, 16,320 seconds of interest not yet
     * accrued into the market's stored totals, and roughly 528,000 RLUSD of free liquidity - so
     * the projection, the cover boundaries and the liquidity bound all have something to bite on.
     */
    uint256 internal constant FORK_BLOCK = 25_900_000;

    /// @notice True once the fork exists and the stack is deployed on it.
    bool internal forked;

    /// @notice Skips the calling test when no endpoint served the pinned block.
    modifier onlyForked() {
        vm.skip(!forked, "set ETHEREUM_RPC_URL to an endpoint serving the pinned block");
        _;
    }

    /**
     * @notice Forks Ethereum at the pinned block and deploys the stack over the live market.
     * @dev Without a configured endpoint nothing is deployed and every test skips, so the suite
     * is inert in a run that cannot reach mainnet rather than failing it.
     */
    function _setUpForkFixture() internal {
        string memory rpcUrl = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            return;
        }
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        forked = true;
        _setUpRemoteFixture();
    }

    /// @dev The same stack as the mocked fixture, over the real market contracts.
    function _setUpRemoteDependencies() internal override {
        owner = makeAddr("remote owner");
        parent = makeAddr("remote parent");
        collector = makeAddr("fee collector");
        originPeer = bytes32(uint256(uint160(makeAddr("origin adapter"))));
        vm.deal(address(this), 100 ether);
        // the fork's own timestamp is what the market's `lastUpdate` is relative to, so it is
        // left alone - warping to a fixture epoch would put the accrual clock behind the market
        fxrp = MintableERC20(FXRP);
        loanToken = MintableERC20(RLUSD);
        morpho = MockMorpho(MORPHO);
        oracle = MockOracle(MARKET_ORACLE);
        irm = MockIrm(MARKET_IRM);
        endpoint = new MockLzEndpoint(DESTINATION_EID);
        oft = new MockOft(IERC20(FXRP), RETURN_VALUE);
        oft.setEndpoint(address(endpoint));
        oft.setPeer(ORIGIN_EID, originPeer);
    }

    /// @dev The live market needs no creating.
    function _ensureMarket() internal override {}

    /// @notice Puts real collateral on the account and opens a position through a borrow compose.
    function _openOnTheRealMarket(
        uint256 _collateral,
        uint256 _borrowAmount
    )
        internal
    {
        deal(FXRP, address(account), _collateral);
        _deliver(1, _collateral, _borrow(bytes32("fork-open"), _borrowAmount), 0);
    }

    /// @notice The market's free liquidity, from its stored totals.
    function _marketLiquidity() internal view returns (uint256) {
        (uint128 totalSupplyAssets, , uint128 totalBorrowAssets, , , ) = morpho.market(_marketId());
        return totalSupplyAssets - totalBorrowAssets;
    }

    /// @notice Seconds of interest the market has not yet folded into its stored totals.
    function _elapsedSinceAccrual() internal view returns (uint256) {
        (, , , , uint128 lastUpdate, ) = morpho.market(_marketId());
        return block.timestamp - lastUpdate;
    }

    function _marketId() internal view returns (bytes32) {
        return keccak256(abi.encode(params));
    }
}
