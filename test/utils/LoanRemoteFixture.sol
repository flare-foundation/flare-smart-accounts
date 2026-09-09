// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FacetsDeploy} from "./FacetsDeploy.t.sol";
import {MockLzEndpoint} from "../../contracts/mock/MockLzEndpoint.sol";
import {MockCallbackToken} from "../../contracts/mock/MockCallbackToken.sol";
import {IDiamond} from "../../contracts/diamond/interfaces/IDiamond.sol";
import {DiamondArgs} from "../../contracts/diamond/implementation/Diamond.sol";
import {MasterAccountController} from "../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IIMasterAccountController} from "../../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {MasterAccountControllerInit} from "../../contracts/smartAccounts/facets/MasterAccountControllerInit.sol";
import {PersonalAccount} from "../../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {LoanSubaccountRemote} from "../../contracts/smartAccounts/implementation/LoanSubaccountRemote.sol";
import {SubaccountProxy} from "../../contracts/smartAccounts/proxy/SubaccountProxy.sol";
import {ComposeTransportFacet} from "../../contracts/smartAccounts/facets/ComposeTransportFacet.sol";
import {LoanMarketsFacet} from "../../contracts/smartAccounts/facets/LoanMarketsFacet.sol";
import {IIComposeTransportFacet} from "../../contracts/smartAccounts/interface/IIComposeTransportFacet.sol";
import {IILoanMarketsFacet} from "../../contracts/smartAccounts/interface/IILoanMarketsFacet.sol";
import {IComposeTransportFacet} from "../../contracts/userInterfaces/facets/IComposeTransportFacet.sol";
import {ILoanMarketsFacet} from "../../contracts/userInterfaces/facets/ILoanMarketsFacet.sol";
import {IMorpho} from "../../contracts/smartAccounts/interface/IMorpho.sol";
import {MorphoMath} from "../../contracts/smartAccounts/library/MorphoMath.sol";
import {MintableERC20} from "../../contracts/mock/MintableERC20.sol";
import {MockFreezableToken} from "../../contracts/mock/MockFreezableToken.sol";
import {MockOft} from "../../contracts/mock/MockOft.sol";
import {MockMorpho} from "../../contracts/mock/MockMorpho.sol";
import {MockOracle} from "../../contracts/mock/MockOracle.sol";
import {MockIrm} from "../../contracts/mock/MockIrm.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {
    ACTION_BORROW,
    ACTION_WITHDRAW,
    ACTION_DEPOSIT_COLLATERAL,
    DESTINATION_KIND_EVM
} from "../../contracts/userInterfaces/ILoanSubaccountRemote.sol";
import {PAYLOAD_VERSION_1} from "../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";

/**
 * @title LoanRemoteFixture
 * @notice The loan-chain side of the loan flow for the adversarial, fuzz and invariant suites: the
 * diamond with its loan facets, one registered market (RLUSD/FXRP, health check ON - the unit
 * suite in `LoanSubaccountRemote.t.sol` turns it off for its over-leveraged fee fixtures), one
 * `LoanSubaccountRemote` proxy under a parent address, and the endpoint's compose queue. FXRP is
 * a `MockCallbackToken`, so a scenario can fire a callback from inside a collateral move; the
 * market's IRM is a `MockIrm` at rate zero, so interest arrives only where a scenario sets a rate
 * or queues it.
 */
abstract contract LoanRemoteFixture is FacetsDeploy {
    uint32 internal constant ORIGIN_EID = 30295;
    uint32 internal constant DESTINATION_EID = 30101;
    uint256 internal constant RETURN_VALUE = 0.01 ether;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    IIMasterAccountController internal controller;
    LoanSubaccountRemote internal account;
    MintableERC20 internal fxrp;
    MintableERC20 internal loanToken;
    MockMorpho internal morpho;
    MockOracle internal oracle;
    MockIrm internal irm;
    MockOft internal oft;
    MockLzEndpoint internal endpoint;
    address internal owner;
    address internal parent;
    address internal collector;
    bytes32 internal originPeer;
    IMorpho.MarketParams internal params;

    function _setUpRemoteFixture() internal {
        _setUpRemoteDependencies();
        _deployRemoteController();
        _installRemoteSettings();
        _installRemoteAccount();
        _grantRemoteRoles();
    }

    function _setUpRemoteDependencies() internal virtual {
        owner = makeAddr("remote owner");
        parent = makeAddr("remote parent");
        collector = makeAddr("fee collector");
        originPeer = bytes32(uint256(uint160(makeAddr("origin adapter"))));
        vm.warp(1_000_000);
        vm.deal(address(this), 100 ether);
        fxrp = new MockCallbackToken(6);
        loanToken = new MockFreezableToken("RLUSD", "RLUSD", 18);
        morpho = new MockMorpho();
        oracle = new MockOracle(2e48);
        irm = new MockIrm();
        endpoint = new MockLzEndpoint(DESTINATION_EID);
        oft = new MockOft(fxrp, RETURN_VALUE);
        oft.setEndpoint(address(endpoint));
        oft.setPeer(ORIGIN_EID, originPeer);
    }

    function _deployRemoteController() private {
        controller = IIMasterAccountController(
            address(
                new MasterAccountController(
                    deployBaseFacets(),
                    DiamondArgs(owner, address(0), "")
                )
            )
        );
        MasterAccountControllerInit init = new MasterAccountControllerInit();
        address personalImpl = address(new PersonalAccount());
        vm.prank(owner);
        controller.diamondCut(
            deploySmartAccountsFacets(),
            address(init),
            abi.encodeWithSelector(
                MasterAccountControllerInit.init.selector,
                payable(parent),
                100,
                bytes32("testXRP"),
                1 days,
                1_000_000,
                personalImpl
            )
        );
    }

    function _installRemoteSettings() private {
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](2);
        cuts[0] = _buildFacetCut(
            address(new ComposeTransportFacet()),
            "ComposeTransportFacet",
            IDiamond.FacetCutAction.Add
        );
        cuts[1] = _buildFacetCut(
            address(new LoanMarketsFacet()),
            "LoanMarketsFacet",
            IDiamond.FacetCutAction.Add
        );
        vm.prank(owner);
        controller.diamondCut(cuts, address(0), "");
        vm.prank(owner);
        IIComposeTransportFacet(address(controller)).setComposeTransport(
            _transport()
        );
    }

    function _installRemoteAccount() private {
        LoanSubaccountRemote implementation = new LoanSubaccountRemote();
        vm.prank(owner);
        controller.setSubaccountImplementation(1, address(implementation));
        account = LoanSubaccountRemote(
            address(new SubaccountProxy(address(controller), parent, 1))
        );
        _configureMarket(1, loanToken);
    }

    function _grantRemoteRoles() private {
        address[] memory roles = new address[](1);
        roles[0] = owner;
        vm.startPrank(owner);
        controller.addPausers(roles);
        controller.addUnpausers(roles);
        vm.stopPrank();
    }

    // setup helpers are private; the scenario helpers below serve the suites and the handler
    // solhint-disable-next-line ordering
    function _configureMarket(
        uint256 _type,
        MintableERC20 _token
    )
        internal
    {
        params = IMorpho.MarketParams(
            address(_token),
            address(fxrp),
            address(oracle),
            address(irm),
            0.77e18
        );
        _ensureMarket();
        vm.prank(owner);
        IILoanMarketsFacet(address(controller)).registerLoanMarket(
            _type,
            ILoanMarketsFacet.Market(address(morpho), params)
        );
        _setTerms(_type, 0.07e18, 0.01e18);
    }

    /// @dev Creates the market the fixture is about; a fork suite inherits a live one instead.
    function _ensureMarket() internal virtual {
        morpho.createMarket(params);
    }

    function _setTerms(
        uint256 _type,
        uint64 _floor,
        uint64 _spread
    )
        internal
    {
        vm.prank(owner);
        IILoanMarketsFacet(address(controller)).setLoanFeeTerms(
            _type,
            ILoanMarketsFacet.FeeTerms(_floor, _spread, collector)
        );
    }

    function _transport(
    )
        internal view
        returns (IComposeTransportFacet.Transport memory)
    {
        return IComposeTransportFacet.Transport(address(endpoint), address(oft), ORIGIN_EID, originPeer);
    }

    function _borrow(
        bytes32 _id,
        uint256 _amount
    )
        internal view
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                _id,
                uint64(block.timestamp + 1 hours),
                DESTINATION_KIND_EVM,
                bytes32(uint256(uint160(parent))),
                _amount,
                uint256(0)
            )
        );
    }

    function _withdraw(
        bytes32 _id,
        uint256 _amount,
        uint256 _floor
    )
        internal view
        returns (bytes memory)
    {
        return abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_WITHDRAW,
            abi.encode(_id, uint64(block.timestamp + 1 hours), _amount, _floor, bytes(hex"0003"))
        );
    }

    function _deposit(
    )
        internal pure
        returns (bytes memory)
    {
        return abi.encode(PAYLOAD_VERSION_1, ACTION_DEPOSIT_COLLATERAL, bytes(""));
    }

    // the payload builders sit next to the packet encoder they feed
    // solhint-disable-next-line ordering
    function _packet(
        address _account,
        uint64 _nonce,
        uint256 _credit,
        bytes memory _payload
    )
        internal view
        returns (bytes memory _message, bytes32 _guid)
    {
        _message = OFTComposeMsgCodec.encode(
            _nonce,
            ORIGIN_EID,
            _credit,
            abi.encodePacked(bytes32(uint256(uint160(_account))), _payload)
        );
        _guid = GUID.generate(
            _nonce,
            ORIGIN_EID,
            address(uint160(uint256(originPeer))),
            DESTINATION_EID,
            bytes32(uint256(uint160(address(oft))))
        );
    }

    function _queue(
        address _account,
        uint64 _nonce,
        uint256 _credit,
        bytes memory _payload
    )
        internal
        returns (bytes memory _message, bytes32 _guid)
    {
        (_message, _guid) = _packet(_account, _nonce, _credit, _payload);
        // OFT credit and its authenticated queue insertion precede permissionless execution.
        vm.prank(address(oft));
        endpoint.sendCompose(_account, _guid, 0, _message);
    }

    function _deliver(
        uint64 _nonce,
        uint256 _credit,
        bytes memory _payload,
        uint256 _value
    )
        internal
    {
        (bytes memory message, bytes32 guid) = _queue(
            address(account),
            _nonce,
            _credit,
            _payload
        );
        endpoint.deliver{value: _value}(
            address(oft),
            address(account),
            guid,
            message
        );
    }

    function _open(
        uint256 _borrowAmount
    )
        internal
    {
        fxrp.mint(address(account), 10_000e6);
        _deliver(1, 10_000e6, _borrow(bytes32("initial"), _borrowAmount), 0);
    }

    function _debt(
    )
        internal view
        returns (uint256)
    {
        bytes32 id = MorphoMath.marketId(params);
        (, uint128 shares, ) = morpho.position(id, address(account));
        (, , uint128 assets, uint128 totalShares, , ) = morpho.market(id);
        return MorphoMath.toAssetsUp(shares, assets, totalShares);
    }

    function _shares(
    )
        internal view
        returns (uint128)
    {
        (, uint128 shares, ) = morpho.position(
            MorphoMath.marketId(params),
            address(account)
        );
        return shares;
    }

    function _collateral(
    )
        internal view
        returns (uint256)
    {
        (, , uint128 collateral) = morpho.position(
            MorphoMath.marketId(params),
            address(account)
        );
        return collateral;
    }
}
