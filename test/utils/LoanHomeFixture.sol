// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FacetsDeploy} from "./FacetsDeploy.t.sol";
import {MockLzEndpoint} from "../../contracts/mock/MockLzEndpoint.sol";
import {DiamondArgs} from "../../contracts/diamond/implementation/Diamond.sol";
import {MasterAccountController} from "../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IIMasterAccountController} from "../../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {MasterAccountControllerInit} from "../../contracts/smartAccounts/facets/MasterAccountControllerInit.sol";
import {PersonalAccount} from "../../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {LoanSubaccount} from "../../contracts/smartAccounts/implementation/LoanSubaccount.sol";
import {
    ILoanSubaccount,
    DESTINATION_KIND_EVM
} from "../../contracts/userInterfaces/ILoanSubaccount.sol";
import {IIBridgeRoutesFacet} from "../../contracts/smartAccounts/interface/IIBridgeRoutesFacet.sol";
import {MintableERC20} from "../../contracts/mock/MintableERC20.sol";
import {MockAssetManager} from "../../contracts/mock/MockAssetManager.sol";
import {MockOft} from "../../contracts/mock/MockOft.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {IRedeemExtended} from "flare-periphery/src/flare/IRedeemExtended.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {
    ACTION_REDEEM_HOME,
    REDEEM_HOME_TTL
} from "../../contracts/userInterfaces/IBridgingSubaccount.sol";
import {PAYLOAD_VERSION_1} from "../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";

/**
 * @title LoanHomeFixture
 * @notice The Flare side of the loan flow for the adversarial suites: the diamond with its bridge
 * routes, a Personal Account and its loan subaccount created through the controller, the FXRP
 * OFT and the endpoint's compose queue. OFT credit and the FAssets redemption backend are mocks.
 */
// solhint-disable-next-line max-states-count
abstract contract LoanHomeFixture is FacetsDeploy {
    uint32 internal constant FLARE_EID = 30295;
    uint32 internal constant REMOTE_EID = 30101;
    uint256 internal constant EXECUTOR_FEE = 0.003 ether;
    uint256 internal constant BRIDGE_FEE = 0.01 ether;
    string internal constant XRPL_OWNER = "rHomeOrderingOwner";

    IIMasterAccountController internal controller;
    ILoanSubaccount internal account;
    MintableERC20 internal fxrp;
    MockAssetManager internal assetManager;
    MockOft internal oft;
    MockLzEndpoint internal endpoint;
    address internal owner;
    address internal parent;
    address payable internal executor;
    bytes32 internal remotePeer;

    function _setUpHomeFixture() internal {
        _setUpHomeDependencies();
        _deployHomeController();
        _mockHomeRegistry();
        _configureHomeController();
        parent = controller.createPersonalAccount(XRPL_OWNER);
        account = ILoanSubaccount(controller.createSubaccount(XRPL_OWNER, 1));
    }

    function _setUpHomeDependencies() private {
        vm.warp(1_000_000);
        vm.deal(address(this), 100 ether);
        owner = makeAddr("home governance");
        executor = payable(makeAddr("home executor"));
        remotePeer = bytes32(uint256(uint160(makeAddr("remote home adapter"))));
        fxrp = new MintableERC20("FXRP", "FXRP", 6);
        assetManager = new MockAssetManager(fxrp);
        assetManager.setMinimumRedeemAmountUBA(10e6);
        endpoint = new MockLzEndpoint(FLARE_EID);
        oft = new MockOft(fxrp, BRIDGE_FEE);
        oft.setEndpoint(address(endpoint));
        oft.setPeer(REMOTE_EID, remotePeer);
    }

    function _deployHomeController() private {
        controller = IIMasterAccountController(
            address(
                new MasterAccountController(
                    deployBaseFacets(),
                    DiamondArgs(owner, address(0), "")
                )
            )
        );
        MasterAccountControllerInit init = new MasterAccountControllerInit();
        address personalImplementation = address(new PersonalAccount());
        vm.prank(owner);
        controller.diamondCut(
            deploySmartAccountsFacets(),
            address(init),
            abi.encodeWithSelector(
                MasterAccountControllerInit.init.selector,
                executor,
                EXECUTOR_FEE,
                bytes32("testXRP"),
                1 days,
                1_000_000,
                personalImplementation
            )
        );
    }

    function _mockHomeRegistry() private {
        vm.mockCall(
            0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019,
            abi.encodeWithSelector(
                IFlareContractRegistry.getContractAddressByHash.selector,
                keccak256(abi.encode("AssetManagerFXRP"))
            ),
            abi.encode(address(assetManager))
        );
    }

    function _configureHomeController() private {
        address implementation = address(new LoanSubaccount());
        address[] memory roles = new address[](1);
        roles[0] = owner;
        vm.startPrank(owner);
        controller.setSubaccountImplementation(1, implementation);
        controller.setFxrpOft(address(oft));
        controller.setBridgeRoute(REMOTE_EID, remotePeer);
        controller.setSubaccountTypeRoute(1, REMOTE_EID);
        controller.addPausers(roles);
        controller.addUnpausers(roles);
        vm.stopPrank();
    }

    // setup helpers are private; the scenario helpers below serve the inheriting suites
    // solhint-disable-next-line ordering
    function _queueHome(
        uint64 _nonce,
        uint256 _amount
    )
        internal
        returns (bytes memory _message, bytes32 _guid)
    {
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_REDEEM_HOME,
            abi.encode(uint64(block.timestamp) + REDEEM_HOME_TTL)
        );
        _message = OFTComposeMsgCodec.encode(
            _nonce,
            REMOTE_EID,
            _amount,
            abi.encodePacked(
                bytes32(uint256(uint160(address(account)))),
                payload
            )
        );
        _guid = GUID.generate(
            _nonce,
            REMOTE_EID,
            address(uint160(uint256(remotePeer))),
            FLARE_EID,
            bytes32(uint256(uint160(address(oft))))
        );
        vm.prank(address(oft));
        endpoint.sendCompose(address(account), _guid, 0, _message);
    }

    function _deliverHome(
        bytes memory _message,
        bytes32 _guid,
        uint256 _value
    )
        internal
    {
        endpoint.deliver{value: _value}(
            address(oft),
            address(account),
            _guid,
            _message
        );
    }

    function _expectHomeRedemption(
        uint256 _amount,
        uint256 _value
    )
        internal
    {
        vm.expectCall(
            address(assetManager),
            _value,
            abi.encodeWithSelector(
                IRedeemExtended.redeemAmount.selector,
                _amount,
                XRPL_OWNER,
                executor
            )
        );
    }

    function _setHomeTimelock() internal {
        vm.prank(owner);
        controller.setTimelockDuration(1 days);
    }

    function _queueHomeSuspension(
        bool _suspended
    )
        internal
        returns (bytes memory _callData)
    {
        _callData = abi.encodeCall(
            IIBridgeRoutesFacet.setSubaccountTypeRouteSuspended,
            (1, _suspended)
        );
        vm.prank(owner);
        controller.setSubaccountTypeRouteSuspended(1, _suspended);
        assertEq(
            controller.getExecuteTimelockedCallTimestamp(_callData),
            block.timestamp + 1 days
        );
    }

    function _borrowHome(
        bytes32 _operationId,
        uint64 _deadline
    )
        internal
    {
        account.borrow{value: BRIDGE_FEE}(
            0,
            100e18,
            DESTINATION_KIND_EVM,
            bytes32(uint256(uint160(parent))),
            0,
            _operationId,
            _deadline,
            ""
        );
    }

    function _assertHomeRequest(
        uint256 _id,
        uint256 _amount
    )
        internal view
    {
        (address redeemer, bool active, uint256 requested) = assetManager.requests(_id);
        assertEq(redeemer, parent);
        assertTrue(active);
        assertEq(requested, _amount);
        assertEq(fxrp.allowance(address(account), parent), 0);
    }

    function _homeWithdrawOptions(
    )
        internal pure
        returns (ILoanSubaccount.WithdrawOptions memory)
    {
        return ILoanSubaccount.WithdrawOptions("", "", BRIDGE_FEE);
    }
}
