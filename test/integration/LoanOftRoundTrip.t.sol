// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {Errors} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {FacetsDeploy} from "../utils/FacetsDeploy.t.sol";
import {IDiamond} from "../../contracts/diamond/interfaces/IDiamond.sol";
import {DiamondArgs} from "../../contracts/diamond/implementation/Diamond.sol";
import {MasterAccountController} from "../../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {MasterAccountControllerInit} from "../../contracts/smartAccounts/facets/MasterAccountControllerInit.sol";
import {ComposeTransportFacet} from "../../contracts/smartAccounts/facets/ComposeTransportFacet.sol";
import {MorphoLoanMarketsFacet} from "../../contracts/smartAccounts/facets/MorphoLoanMarketsFacet.sol";
import {PersonalAccount} from "../../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {PersonalAccountRemote} from "../../contracts/smartAccounts/implementation/PersonalAccountRemote.sol";
import {LoanSubaccount} from "../../contracts/smartAccounts/implementation/LoanSubaccount.sol";
import {MorphoLoanSubaccountRemote} from "../../contracts/smartAccounts/implementation/MorphoLoanSubaccountRemote.sol";
import {IIMasterAccountController} from "../../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {IISingletonFactory} from "../../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {IMorpho} from "../../contracts/smartAccounts/interface/IMorpho.sol";
import {IPersonalAccount} from "../../contracts/userInterfaces/IPersonalAccount.sol";
import {ILoanSubaccount, DESTINATION_KIND_EVM} from "../../contracts/userInterfaces/ILoanSubaccount.sol";
import {IMorphoLoanSubaccountRemote} from "../../contracts/userInterfaces/IMorphoLoanSubaccountRemote.sol";
import {IComposeTransportFacet} from "../../contracts/userInterfaces/facets/IComposeTransportFacet.sol";
import {IMorphoLoanMarketsFacet} from "../../contracts/userInterfaces/facets/IMorphoLoanMarketsFacet.sol";
import {MintableERC20} from "../../contracts/mock/MintableERC20.sol";
import {MockAssetManager} from "../../contracts/mock/MockAssetManager.sol";
import {MockSingletonFactory} from "../../contracts/mock/MockSingletonFactory.sol";
import {MockMorpho} from "../../contracts/mock/MockMorpho.sol";
import {MockOracle} from "../../contracts/mock/MockOracle.sol";
import {MockIrm} from "../../contracts/mock/MockIrm.sol";
import {FeeOftAdapter} from "../../contracts/mock/FeeOftAdapter.sol";
import {FeeOftToken} from "../../contracts/mock/FeeOftToken.sol";
import {RelayLzEndpoint} from "../../contracts/mock/RelayLzEndpoint.sol";

/**
 * @title LoanOftRoundTripTest
 * @notice The production account pair and frozen proxies, on independent chain states, through
 * fee-capable lock/unlock and mint/burn OFTs and canonical compose queues. No destination token
 * credit or compose payload is manufactured by the fixture. The market and the FAssets redemption
 * remain behavioral mocks here, and they are not covered alike: the market's live semantics are
 * `MorphoLoanSubaccountRemoteFork.t.sol`'s subject, while FAssets redemption has no fork suite at
 * all and is mocked everywhere in this repository.
 * @dev `test/tooling/loan-oft-roundtrip.test.ts` starts an empty local Anvil and requires these
 * tests to run. Both forks start there, requiring no public RPC. Independent states let the real
 * CREATE2 derivations and same-address compose authentication run without replacing account code
 * or rewriting storage. The sole source authorization seam is the controller calling the real
 * Personal Account batch, after the out-of-scope XRPL proof check.
 */
// solhint-disable-next-line max-states-count
contract LoanOftRoundTripTest is FacetsDeploy {
    struct Delivery {
        bytes32 guid;
        bytes message;
    }

    address private constant FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    address private constant REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
    uint32 private constant HOME_EID = 30295;
    uint32 private constant REMOTE_EID = 30101;
    uint256 private constant TYPE = 1;
    uint256 private constant FEE = 0.01 ether;
    /// The controller's executor fee, which every FXRP redemption this account performs must carry.
    uint256 private constant REDEEM_FEE = 100;
    uint256 private constant GROSS = 100e6;
    uint256 private constant NET = 99e6;
    uint256 private constant BORROW = 50e18;
    string private constant XRPL_OWNER = "rOftRoundTripOwner";

    uint256 private homeFork;
    uint256 private remoteFork;
    IIMasterAccountController private controller;
    address private parent;
    address private account;
    MintableERC20 private homeToken;
    MintableERC20 private loanToken;
    MockAssetManager private assetManager;
    MockMorpho private morpho;
    IMorpho.MarketParams private params;
    RelayLzEndpoint private homeEndpoint;
    RelayLzEndpoint private remoteEndpoint;
    FeeOftAdapter private homeOft;
    FeeOftToken private remoteOft;

    function setUp() public {
        string memory rpc = vm.envOr("F28_LOCAL_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            require(
                !vm.envExists("REQUIRE_LOAN_OFT_ROUNDTRIP"),
                "required local OFT round trip has no local RPC"
            );
            vm.skip(true);
            return;
        }
        vm.deal(address(this), 100 ether);
        homeFork = vm.createSelectFork(rpc);
        vm.chainId(14);
        vm.warp(1_000_000);
        _deployHome();

        remoteFork = vm.createSelectFork(rpc);
        vm.chainId(1);
        vm.warp(1_000_000);
        _deployRemote();
        remoteOft.setPeer(HOME_EID, bytes32(uint256(uint160(address(homeOft)))));
        controller.setComposeTransport(
            IComposeTransportFacet.Transport(
                address(remoteEndpoint), address(remoteOft), HOME_EID,
                bytes32(uint256(uint160(address(homeOft))))
            )
        );
        _configureMarket();

        vm.selectFork(homeFork);
        homeOft.setPeer(REMOTE_EID, bytes32(uint256(uint160(address(remoteOft)))));
        controller.setFxrpOft(address(homeOft));
        controller.setBridgeRoute(REMOTE_EID, bytes32(uint256(uint160(address(remoteOft)))));
        controller.setSubaccountTypeRoute(TYPE, REMOTE_EID);
    }

    function testDepositSuppliesTheActualFeeReducedCredit() public {
        _sendDeposit(GROSS, NET);
        assertEq(homeToken.balanceOf(parent), 900e6, "source parent paid the gross");
        assertEq(homeToken.balanceOf(address(homeOft)), GROSS, "source adapter locked the gross");
        assertEq(homeOft.feeBalance(), 1e6, "source fee is separately accounted");

        Delivery memory delivery = _receiveRemote(0);
        assertEq(remoteOft.balanceOf(account), NET, "the actual OFT minted the net to the proxy");
        assertEq(_collateral(), 0, "receive alone does not execute compose");
        _composeRemote(delivery, 0);
        assertEq(_collateral(), NET, "the real loan action supplied exactly its credit");
        assertEq(remoteOft.balanceOf(account), 0);
        assertEq(remoteOft.balanceOf(address(morpho)), NET);
        assertEq(remoteOft.totalSupply(), NET, "no fixture minting exists remotely");

        vm.expectRevert(abi.encodeWithSelector(
            Errors.LZ_ComposeNotFound.selector, bytes32(uint256(1)), keccak256(delivery.message)
        ));
        _composeRemote(delivery, 0);
        assertEq(_collateral(), NET, "a second compose cannot supply again");
    }

    function testBorrowUsesNetCollateralAndPaysTheRemotePersonalAccount() public {
        _openBorrow();
        assertEq(_collateral(), NET);
        assertEq(loanToken.balanceOf(parent), BORROW, "proceeds reach the real remote PA proxy");
        assertEq(MorphoLoanSubaccountRemote(payable(account)).getLoanPosition().debt, BORROW);
        assertTrue(MorphoLoanSubaccountRemote(payable(account)).usedOperations(bytes32("borrow")));
    }

    function testWithdrawalBurnsNetUnlocksBackingAndRedeemsTheWholeBalance() public {
        _openBorrow();
        _sendWithdraw(bytes32("withdraw"), 20e6, 19_800_000);
        Delivery memory withdrawal = _receiveRemote(1);
        _composeRemote(withdrawal, FEE);
        assertEq(_collateral(), 79e6);
        assertEq(remoteOft.balanceOf(account), 0);
        assertEq(remoteOft.feeBalance(), 200_000);
        assertEq(remoteOft.balanceOf(address(remoteOft)), 200_000);
        assertEq(remoteOft.totalSupply(), 79_200_000, "only the net return was burned");

        vm.selectFork(homeFork);
        homeToken.mint(account, 3e6);
        Delivery memory returned = _receiveHome(0);
        assertEq(homeToken.balanceOf(account), 22_800_000, "idle plus actual unlocked credit");
        assertEq(homeToken.balanceOf(address(homeOft)), 80_200_000);
        _composeHome(returned, 123);
        (address redeemer, bool active, uint256 amount) = assetManager.requests(1);
        assertEq(redeemer, parent);
        assertTrue(active);
        assertEq(amount, 22_800_000, "the arrival and the idle balance are redeemed together");
        assertEq(assetManager.lastRedeemValue(), 123, "compose value reaches the FAssets executor fee");
        assertEq(homeToken.balanceOf(account), 0, "the redemption leaves nothing behind");
        assertEq(homeToken.balanceOf(parent), 900e6, "the parent's old FXRP was not redeemed");
        assertEq(account.balance, 0, "no native remains in the home subaccount");
    }

    function testNoFeeRoundTripReturnsAndRedeemsTheWholeDeposit() public {
        homeOft.setDefaultFeeBps(0);
        vm.selectFork(remoteFork);
        remoteOft.setDefaultFeeBps(0);
        _sendDeposit(GROSS, GROSS);
        Delivery memory deposit = _receiveRemote(0);
        _composeRemote(deposit, 0);
        assertEq(_collateral(), GROSS);
        _sendWithdraw(bytes32("all"), GROSS, GROSS);
        Delivery memory withdrawal = _receiveRemote(1);
        _composeRemote(withdrawal, FEE);
        assertEq(_collateral(), 0);
        assertEq(remoteOft.totalSupply(), 0);
        assertEq(remoteOft.feeBalance(), 0);
        Delivery memory returned = _receiveHome(0);
        _composeHome(returned, REDEEM_FEE);
        (, , uint256 amount) = assetManager.requests(1);
        assertEq(amount, GROSS);
        assertEq(homeToken.balanceOf(address(homeOft)), 0);
        assertEq(homeOft.feeBalance(), 0);
    }

    function testFeeIncreaseWhileWithdrawalIsPendingRollsBackAndCanRetry() public {
        _openBorrow();
        _sendWithdraw(bytes32("fee-change"), 20e6, 19_800_000);
        Delivery memory withdrawal = _receiveRemote(1);
        remoteOft.setDefaultFeeBps(200);
        bytes32 feeStateBefore = _feeStateHash();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        // Keep the signed instruction live while making its fee checkpoint do real work.
        // The helper's deadline is seven days; the bridge-back's TTL starts only on success.
        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 19_600_000, 19_800_000));
        _composeRemote(withdrawal, FEE);
        assertEq(_collateral(), NET);
        assertEq(remoteOft.totalSupply(), NET);
        assertEq(remoteOft.feeBalance(), 0);
        assertEq(remoteEndpoint.packetCount(), 0);
        assertEq(_feeStateHash(), feeStateBefore, "the failed withdrawal also rolls back its checkpoint");
        assertFalse(MorphoLoanSubaccountRemote(payable(account)).usedOperations(bytes32("fee-change")));
        _assertRemoteQueued(withdrawal);

        remoteOft.setDefaultFeeBps(100);
        _composeRemote(withdrawal, FEE);
        assertEq(_collateral(), 79e6);
        assertTrue(MorphoLoanSubaccountRemote(payable(account)).usedOperations(bytes32("fee-change")));
        Delivery memory returned = _receiveHome(0);
        _composeHome(returned, REDEEM_FEE);
        (, , uint256 amount) = assetManager.requests(1);
        assertEq(amount, 19_800_000);
    }

    function testUnderfundedWithdrawalCannotConsumeItsPacketOrItsCollateral() public {
        _openBorrow();
        _sendWithdraw(bytes32("funding"), 20e6, 19_800_000);
        Delivery memory withdrawal = _receiveRemote(1);
        vm.expectRevert(abi.encodeWithSelector(
            IMorphoLoanSubaccountRemote.InsufficientDeliveryValue.selector, FEE, FEE - 1
        ));
        _composeRemote(withdrawal, FEE - 1);
        assertEq(_collateral(), NET);
        assertEq(remoteEndpoint.packetCount(), 0);
        assertFalse(MorphoLoanSubaccountRemote(payable(account)).usedOperations(bytes32("funding")));
        _assertRemoteQueued(withdrawal);
        _composeRemote(withdrawal, FEE);
        assertEq(_collateral(), 79e6);
        assertEq(remoteEndpoint.packetCount(), 1);
    }

    function testARefusedBorrowKeepsItsRealCreditAndRetriesAfterASecondDeposit() public {
        _sendBorrow(150e18);
        Delivery memory borrow = _receiveRemote(0);
        vm.expectRevert(abi.encodeWithSelector(
            IMorphoLoanSubaccountRemote.InsufficientRemainingCollateral.selector, 225e18, 198e18
        ));
        _composeRemote(borrow, 0);
        assertEq(remoteOft.balanceOf(account), NET, "credited tokens survive a failed compose");
        assertEq(_collateral(), 0, "supply during the failed borrow rolled back");
        assertEq(loanToken.balanceOf(parent), 0);
        assertFalse(MorphoLoanSubaccountRemote(payable(account)).usedOperations(bytes32("borrow")));
        _assertRemoteQueued(borrow);

        // The permissionless recovery rail supplies the original credit, then a second real
        // cross-chain deposit provides enough cover for the ORIGINAL queued borrow.
        MorphoLoanSubaccountRemote(payable(account)).depositIdleFxrp();
        assertEq(_collateral(), NET);
        _sendDeposit(GROSS, NET);
        Delivery memory rescue = _receiveRemote(1);
        _composeRemote(rescue, 0);
        _composeRemote(borrow, 0);
        assertEq(_collateral(), 2 * NET);
        assertEq(loanToken.balanceOf(parent), 150e18);
        assertEq(remoteOft.totalSupply(), 2 * NET, "retry never re-credits the OFT transfer");
    }

    function testSourceMinimumRefusalRollsBackTheWholePersonalAccountBatch() public {
        vm.expectRevert(abi.encodeWithSelector(
            IPersonalAccount.CallFailed.selector,
            uint256(1),
            abi.encodeWithSelector(IOFT.SlippageExceeded.selector, NET, GROSS)
        ));
        _sendDeposit(GROSS, GROSS);
        assertEq(homeToken.balanceOf(parent), 1_000e6);
        assertEq(homeToken.balanceOf(account), 0);
        assertEq(homeToken.balanceOf(address(homeOft)), 0);
        assertEq(homeOft.feeBalance(), 0);
        assertEq(homeEndpoint.packetCount(), 0);
    }

    function _deployHome()
        private
    {
        controller = _deployController(false);
        homeToken = new MintableERC20("FXRP", "FXRP", 6);
        assetManager = new MockAssetManager(homeToken);
        assetManager.setMinimumRedeemAmountUBA(1e6);
        vm.mockCall(REGISTRY, abi.encodeWithSelector(
            IFlareContractRegistry.getContractAddressByHash.selector, keccak256(abi.encode("AssetManagerFXRP"))
        ), abi.encode(address(assetManager)));
        homeEndpoint = new RelayLzEndpoint(HOME_EID, FEE);
        homeOft = new FeeOftAdapter(address(homeToken), address(homeEndpoint), address(this));
        homeOft.setDefaultFeeBps(100);
        controller.setSubaccountImplementation(TYPE, address(new LoanSubaccount()));
        parent = controller.createPersonalAccount(XRPL_OWNER);
        account = controller.createSubaccount(XRPL_OWNER, TYPE);
        homeToken.mint(parent, 1_000e6);
    }

    function _deployRemote()
        private
    {
        IIMasterAccountController remoteController = _deployController(true);
        assertEq(address(remoteController), address(controller), "same CREATE2 controller on both chains");
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](2);
        cuts[0] = _buildFacetCut(
            address(new ComposeTransportFacet()), "ComposeTransportFacet", IDiamond.FacetCutAction.Add
        );
        cuts[1] = _buildFacetCut(
            address(new MorphoLoanMarketsFacet()), "MorphoLoanMarketsFacet", IDiamond.FacetCutAction.Add
        );
        controller.diamondCut(cuts, address(0), "");
        remoteEndpoint = new RelayLzEndpoint(REMOTE_EID, FEE);
        remoteOft = new FeeOftToken("Remote FXRP", "FXRP", address(remoteEndpoint), address(this));
        remoteOft.setDefaultFeeBps(100);
        controller.setSubaccountImplementation(TYPE, address(new MorphoLoanSubaccountRemote()));
        assertEq(controller.createPersonalAccount(XRPL_OWNER), parent, "same frozen Personal Account proxy");
        assertEq(controller.createSubaccount(XRPL_OWNER, TYPE), account, "same frozen subaccount proxy");
        assertEq(homeToken.balanceOf.selector, IERC20.balanceOf.selector);
    }

    function _deployController(
        bool _remote
    )
        private
        returns (IIMasterAccountController _controller)
    {
        vm.etch(FACTORY, address(new MockSingletonFactory()).code);
        bytes memory initCode = abi.encodePacked(
            type(MasterAccountController).creationCode,
            abi.encode(deployBaseFacets(), DiamondArgs(address(this), address(0), ""))
        );
        _controller = IIMasterAccountController(IISingletonFactory(FACTORY).deploy(initCode, bytes32(0)));
        assertNotEq(address(_controller), address(0));
        address personalImplementation =
            _remote ? address(new PersonalAccountRemote()) : address(new PersonalAccount());
        _controller.diamondCut(
            deploySmartAccountsFacets(), address(new MasterAccountControllerInit()),
            abi.encodeCall(MasterAccountControllerInit.init, (
                payable(address(this)), REDEEM_FEE, bytes32("XRP"), uint256(1 days), uint256(0),
                personalImplementation
            ))
        );
    }

    function _configureMarket()
        private
    {
        loanToken = new MintableERC20("RLUSD", "RLUSD", 18);
        morpho = new MockMorpho();
        params = IMorpho.MarketParams(
            address(loanToken), address(remoteOft), address(new MockOracle(2e48)), address(new MockIrm()), 0.77e18
        );
        morpho.createMarket(params);
        controller.registerLoanMarket(TYPE, IMorphoLoanMarketsFacet.Market(address(morpho), params));
        controller.setLoanFeeTerms(TYPE, IMorphoLoanMarketsFacet.FeeTerms(0.07e18, 0.01e18, address(this)));
    }

    function _sendDeposit(
        uint256 _amount,
        uint256 _minimum
    )
        private
    {
        _sendHome(abi.encodeCall(ILoanSubaccount.depositCollateral, (_amount, _minimum, bytes(hex"0003"))), _amount);
    }

    function _sendBorrow(
        uint256 _amount
    )
        private
    {
        _sendHome(abi.encodeCall(ILoanSubaccount.borrow, (
            GROSS, NET, _amount, DESTINATION_KIND_EVM, bytes32(uint256(uint160(parent))), uint256(0),
            bytes32("borrow"), uint64(1_000_000 + 7 days), bytes(hex"0003")
        )), GROSS);
    }

    function _sendWithdraw(
        bytes32 _id,
        uint256 _amount,
        uint256 _minimum
    )
        private
    {
        ILoanSubaccount.WithdrawOptions memory options = ILoanSubaccount.WithdrawOptions({
            destinationOptions: hex"0003", returnOptions: hex"0003",
            minComposeValue: FEE
        });
        _sendHome(abi.encodeCall(ILoanSubaccount.withdraw, (
            _amount, _minimum, _id, uint64(1_000_000 + 7 days), options
        )), 0);
    }

    function _sendHome(
        bytes memory _data,
        uint256 _collateral
    )
        private
    {
        vm.selectFork(homeFork);
        uint256 offset = _collateral > 0 ? 1 : 0;
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](offset + 1);
        if (_collateral > 0) {
            calls[0] = IPersonalAccount.Call(
                address(homeToken), 0, abi.encodeCall(IERC20.transfer, (account, _collateral))
            );
        }
        calls[offset] = IPersonalAccount.Call(account, FEE, _data);
        // the batch's value rides from the controller, as it does in production: the instruction
        // facet forwards what its caller sent, so the pranked sender is the one that must hold it
        vm.deal(address(controller), FEE);
        vm.prank(address(controller));
        IPersonalAccount(parent).executeUserOp{value: FEE}(calls);
    }

    function _openBorrow()
        private
    {
        _sendBorrow(BORROW);
        Delivery memory delivery = _receiveRemote(0);
        _composeRemote(delivery, 0);
    }

    function _receiveRemote(
        uint256 _index
    )
        private
        returns (Delivery memory)
    {
        vm.selectFork(homeFork);
        RelayLzEndpoint.Packet memory packet = homeEndpoint.packetAt(_index);
        vm.selectFork(remoteFork);
        return _receivePacket(remoteEndpoint, HOME_EID, address(homeOft), address(remoteOft), packet);
    }

    function _receiveHome(
        uint256 _index
    )
        private
        returns (Delivery memory)
    {
        vm.selectFork(remoteFork);
        RelayLzEndpoint.Packet memory packet = remoteEndpoint.packetAt(_index);
        vm.selectFork(homeFork);
        return _receivePacket(homeEndpoint, REMOTE_EID, address(remoteOft), address(homeOft), packet);
    }

    function _receivePacket(
        RelayLzEndpoint _endpoint,
        uint32 _srcEid,
        address _source,
        address _receiver,
        RelayLzEndpoint.Packet memory _packet
    )
        private
        returns (Delivery memory _delivery)
    {
        vm.recordLogs();
        _endpoint.deliver(_srcEid, _source, _receiver, _packet);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(_endpoint) && logs[i].topics.length > 0 &&
                logs[i].topics[0] == keccak256("ComposeSent(address,address,bytes32,uint16,bytes)")) {
                (address from, address to, bytes32 guid, uint16 index, bytes memory message) =
                    abi.decode(logs[i].data, (address, address, bytes32, uint16, bytes));
                assertEq(from, _receiver);
                assertEq(to, account);
                assertEq(guid, _packet.guid);
                assertEq(index, 0);
                assertEq(_endpoint.composeQueue(from, to, guid, index), keccak256(message));
                return Delivery(guid, message);
            }
        }
        revert("OFT did not queue compose");
    }

    function _composeRemote(
        Delivery memory _delivery,
        uint256 _value
    )
        private
    {
        remoteEndpoint.lzCompose{value: _value}(address(remoteOft), account, _delivery.guid, 0, _delivery.message, "");
    }

    function _composeHome(
        Delivery memory _delivery,
        uint256 _value
    )
        private
    {
        homeEndpoint.lzCompose{value: _value}(address(homeOft), account, _delivery.guid, 0, _delivery.message, "");
    }

    function _assertRemoteQueued(
        Delivery memory _delivery
    )
        private view
    {
        assertEq(
            remoteEndpoint.composeQueue(address(remoteOft), account, _delivery.guid, 0),
            keccak256(_delivery.message)
        );
    }

    function _collateral()
        private view
        returns (uint256)
    {
        (, , uint128 collateral) = morpho.position(keccak256(abi.encode(params)), account);
        return collateral;
    }

    function _feeStateHash()
        private view
        returns (bytes32)
    {
        (bool success, bytes memory result) = account.staticcall(
            abi.encodeCall(IMorphoLoanSubaccountRemote.getLoanFeeState, ())
        );
        require(success, "fee state read failed");
        return keccak256(result);
    }
}
