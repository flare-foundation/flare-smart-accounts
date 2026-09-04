// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IControlledAccount} from "../contracts/userInterfaces/IControlledAccount.sol";
import {IBridgingSubaccount} from "../contracts/userInterfaces/IBridgingSubaccount.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IRedeemExtended} from "flare-periphery/src/flare/IRedeemExtended.sol";
import {IReferencedPaymentNonexistence} from "flare-periphery/src/flare/IReferencedPaymentNonexistence.sol";
import {IXRPPaymentNonexistence} from "flare-periphery/src/flare/IXRPPaymentNonexistence.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AvailableAgentInfo.sol";
import {FacetsDeploy} from "./utils/FacetsDeploy.t.sol";
import {IDiamond} from "../contracts/diamond/interfaces/IDiamond.sol";
import {DiamondArgs} from "../contracts/diamond/implementation/Diamond.sol";
import {NotContractOwner} from "../contracts/diamond/libraries/LibDiamond.sol";
import {IISingletonFactory} from "../contracts/smartAccounts/interface/IISingletonFactory.sol";
import {MasterAccountController} from "../contracts/smartAccounts/implementation/MasterAccountController.sol";
import {IIMasterAccountController} from "../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {MasterAccountControllerInit} from "../contracts/smartAccounts/facets/MasterAccountControllerInit.sol";
import {PersonalAccount} from "../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {LoanSubaccount} from "../contracts/smartAccounts/implementation/LoanSubaccount.sol";
import {SubaccountProxy} from "../contracts/smartAccounts/proxy/SubaccountProxy.sol";
import {MockSingletonFactoryNoDeploy} from "../contracts/mock/MockSingletonFactoryNoDeploy.sol";
import {MockLoanSubaccount} from "../contracts/mock/MockLoanSubaccount.sol";
import {MockGenericSubaccount} from "../contracts/mock/MockGenericSubaccount.sol";
import {MockNativeRejectingParent} from "../contracts/mock/MockNativeRejectingParent.sol";
import {ISubaccount} from "../contracts/userInterfaces/ISubaccount.sol";
import {MockOft} from "../contracts/mock/MockOft.sol";
import {MockAssetManager} from "../contracts/mock/MockAssetManager.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {ILoanSubaccount} from "../contracts/userInterfaces/ILoanSubaccount.sol";
import {ACTION_REDEEM_HOME, REDEEM_HOME_TTL} from "../contracts/userInterfaces/IBridgingSubaccount.sol";
import {
    ISubaccountsFacet,
    SUBACCOUNT_TYPE_LOAN,
    SUBACCOUNT_TYPE_NONE
} from "../contracts/userInterfaces/facets/ISubaccountsFacet.sol";
import {IBridgeRoutesFacet} from "../contracts/userInterfaces/facets/IBridgeRoutesFacet.sol";
import {IMasterAccountController} from "../contracts/userInterfaces/IMasterAccountController.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";
import {
    IComposeReceiverAccountBase,
    PAYLOAD_VERSION_1
} from "../contracts/userInterfaces/IComposeReceiverAccountBase.sol";
import {MockLzEndpoint} from "../contracts/mock/MockLzEndpoint.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {
    ACTION_BORROW,
    ACTION_WITHDRAW,
    ACTION_DEPOSIT_COLLATERAL,
    DESTINATION_KIND_EVM
} from "../contracts/userInterfaces/ILoanSubaccountRemote.sol";
import {PA_ACTION_EXECUTE} from "../contracts/userInterfaces/IPersonalAccountRemote.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMemoInstructionsFacet} from "../contracts/userInterfaces/facets/IMemoInstructionsFacet.sol";
import {IPauseFacet} from "../contracts/userInterfaces/facets/IPauseFacet.sol";

/**
 * @title LoanSubaccountTest
 * @notice Deterministic loan subaccount deployment, initialization, implementation self-lock,
 * per-type resolution through the controller (beacon), upgrade routing, controller-side
 * creation/prediction, account abstraction dispatch from an XRPL instruction through the parent
 * Personal Account into the subaccount, and the backward cleanup move (`sweepRedeem`).
 */
// solhint-disable-next-line max-states-count
contract LoanSubaccountTest is Test, FacetsDeploy {
    address private constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    IIMasterAccountController private controller;
    LoanSubaccount private loanImpl;

    address private initialOwner;
    address private governance;
    address private parentPersonalAccount;
    address private personalAccountImplementation;

    address payable private executor;
    uint256 private executorFee;
    bytes32 private sourceId;
    uint256 private paymentProofValidityDurationSeconds;
    uint256 private defaultInstructionFee;

    address private contractRegistryMock;
    address private assetManagerFxrpMock;
    address private agent;
    AgentInfo.Info private agentInfo;
    uint256 private collateralReservationFee;
    string private xrplOwner;
    MintableERC20 private fxrp;
    MockAssetManager private mockAssetManager;
    MockOft private fxrpOft;
    address private lzEndpoint;
    uint32 private flareEid;
    uint32 private destinationEid;
    uint256 private messagingFee;
    bytes32 private destinationPeer;

    // base facets are CREATE2-deployed with a fixed salt, so they are deployed once and shared
    IDiamond.FacetCut[] private baseCuts;

    function setUp() public {
        initialOwner = makeAddr("initialOwner");
        governance = makeAddr("governance");
        parentPersonalAccount = makeAddr("parentPersonalAccount");
        executor = payable(makeAddr("executor"));
        executorFee = 100;
        sourceId = bytes32("testXRP");
        paymentProofValidityDurationSeconds = 1 days;
        defaultInstructionFee = 1_000_000;

        contractRegistryMock = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
        agent = makeAddr("agent");
        agentInfo.status = AgentInfo.Status.NORMAL;
        collateralReservationFee = 123;
        xrplOwner = "rExampleXrplAddress";
        fxrp = new MintableERC20("F-XRPL", "fXRP", 6);
        mockAssetManager = new MockAssetManager(fxrp);
        assetManagerFxrpMock = address(mockAssetManager);
        destinationEid = 30101; // Ethereum
        messagingFee = 0.01 ether;
        fxrpOft = new MockOft(fxrp, messagingFee);
        destinationPeer = bytes32(uint256(uint160(address(fxrpOft))));
        // the adapter's endpoint: what the bridge-back compose must be delivered by
        flareEid = 30295; // Flare
        lzEndpoint = address(new MockLzEndpoint(flareEid));
        fxrpOft.setEndpoint(lzEndpoint);

        // deploy the personal account implementation (required by the controller init)
        personalAccountImplementation = address(new PersonalAccount());

        // deploy the diamond controller
        controller = _deployDiamond();

        // deploy and register the loan subaccount implementation (timelock duration is 0 in tests)
        loanImpl = new LoanSubaccount();
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(loanImpl)
        );

        // mocks and agent vault registration for the Personal Account creation flow
        _mockGetContractAddressByHash("AssetManagerFXRP", assetManagerFxrpMock);
        _mockGetAgentInfo(agent, agentInfo);
        _mockCollateralReservationFee(collateralReservationFee);
        _mockReserveCollateral(22);
        _mockGetDirectMintingExecutorFeeUBA(0);
        _addAgentVault(controller);
    }

    //
    // step 1: proxy + implementation resolution
    //

    function testDeployAndInitialize() public {
        vm.expectEmit();
        emit ISubaccount.SubaccountInitialized(
            address(controller), parentPersonalAccount, SUBACCOUNT_TYPE_LOAN
        );
        LoanSubaccount subaccount = _deploySubaccount();

        assertEq(subaccount.controllerAddress(), address(controller));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);
        assertEq(subaccount.subaccountType(), SUBACCOUNT_TYPE_LOAN);
        assertEq(subaccount.implementation(), address(loanImpl));
    }

    function testInitializeRevertAlreadyInitialized() public {
        LoanSubaccount subaccount = _deploySubaccount();

        vm.expectRevert(IControlledAccount.AlreadyInitialized.selector);
        subaccount.initialize(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testImplementationInitializeRevertAlreadyInitialized() public {
        vm.expectRevert(IControlledAccount.AlreadyInitialized.selector);
        loanImpl.initialize(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testDeployRevertWhenImplementationNotConfigured() public {
        // the reserved type 0 is never configured, so resolution returns address(0)
        vm.expectRevert();
        new SubaccountProxy(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_NONE
        );
    }

    function testUpgradeRoutesToNewImplementation() public {
        LoanSubaccount subaccount = _deploySubaccount();
        assertEq(subaccount.implementation(), address(loanImpl));

        LoanSubaccount newImpl = new LoanSubaccount();
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(newImpl)
        );

        // proxy resolves the new implementation, and existing state is preserved
        assertEq(subaccount.implementation(), address(newImpl));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);
    }

    function testSetSubaccountImplementationRevertNotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(loanImpl)
        );
    }

    function testSetSubaccountImplementationRevertInvalidImplementation() public {
        address notAContract = makeAddr("notAContract");
        vm.prank(governance);
        vm.expectRevert(ISubaccountsFacet.InvalidSubaccountImplementation.selector);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            notAContract
        );
    }

    function testSetSubaccountImplementationRevertInvalidType() public {
        vm.prank(governance);
        vm.expectRevert(ISubaccountsFacet.InvalidSubaccountType.selector);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_NONE,
            address(loanImpl)
        );
    }

    //
    // step 2: controller-side creation and prediction
    //

    function testCreateSubaccount() public {
        address personalAccount = _createPersonalAccount(xrplOwner);
        address predicted = controller.getSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
        assertEq(predicted.code.length, 0);

        vm.expectEmit();
        emit ISubaccountsFacet.SubaccountCreated(
            predicted,
            personalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
        address created = controller.createSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        // created at the predicted address, registered, and functional
        assertEq(created, predicted);
        assertNotEq(created.code.length, 0);
        assertEq(
            controller.getSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN),
            created
        );

        LoanSubaccount subaccount = LoanSubaccount(payable(created));
        assertEq(subaccount.controllerAddress(), address(controller));
        assertEq(subaccount.parentPersonalAccount(), personalAccount);
        assertEq(subaccount.subaccountType(), SUBACCOUNT_TYPE_LOAN);
        assertEq(subaccount.implementation(), address(loanImpl));
    }

    function testCreateSubaccountIdempotent() public {
        _createPersonalAccount(xrplOwner);
        address first = controller.createSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
        address second = controller.createSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        assertEq(first, second);
    }

    function testCreateSubaccountCanBeCalledByAnyone() public {
        address personalAccount = _createPersonalAccount(xrplOwner);
        address caller = makeAddr("caller");

        vm.prank(caller);
        address created = controller.createSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        assertEq(LoanSubaccount(payable(created)).parentPersonalAccount(), personalAccount);
    }

    function testCreateSubaccountBeforePersonalAccount() public {
        // the parent falls back to its computed address, so the subaccount can materialize
        // first (assets on the predicted address can be swept without waiting for the PA);
        // the Personal Account later deploys at exactly the parent the subaccount recorded
        address created = controller.createSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
        assertNotEq(created.code.length, 0);

        address parent = LoanSubaccount(payable(created)).parentPersonalAccount();
        assertEq(parent.code.length, 0);

        address personalAccount = _createPersonalAccount(xrplOwner);
        assertEq(personalAccount, parent);
    }

    function testPrePersonalAccountRailMatrix() public {
        // the pre-PA state is only PARTLY inert - this pins exactly which rails work:
        // onlyParent and the parent-reading sweep revert; the below-minimum dust push
        // works, parking at the future PA address
        address subaccount = controller.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        address parent = LoanSubaccount(payable(subaccount)).parentPersonalAccount();

        // onlyParent methods have no possible caller: the parent address has no code
        vm.expectRevert(ISubaccount.OnlyParent.selector);
        ILoanSubaccount(subaccount).withdraw(
            1, bytes32("op"), uint64(block.timestamp + 1), _withdrawOptions()
        );

        // at or above the minimum, sweepRedeem reverts calling the codeless parent (no
        // ABI-encoded return from an address without code)
        fxrp.mint(subaccount, 250e6);
        mockAssetManager.setMinimumRedeemAmountUBA(10e6);
        vm.deal(address(this), 2 * executorFee);
        vm.expectRevert();
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();

        // below the minimum it never calls parent code: the FXRP and the fee park at the
        // future PA address, which the owner's Personal Account later deploys at and owns
        mockAssetManager.setMinimumRedeemAmountUBA(1_000e6);
        (uint256 parked, uint256 redeemed) =
            ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        assertEq(parked, 250e6);
        assertEq(redeemed, 0);
        assertEq(fxrp.balanceOf(parent), 250e6);
        assertEq(parent.balance, executorFee);
        mockAssetManager.setMinimumRedeemAmountUBA(10e6);

        // a plain native send reverts (no receive, no native exit)
        vm.deal(address(this), 1 ether);
        (bool ok, ) = subaccount.call{value: 1 ether}("");
        assertFalse(ok);
        // the fee the dust push parked at the parent earlier
        assertEq(parent.balance, executorFee);

        // parked assets do not block the CREATE2 deployment: the PA still materializes
        // at exactly the recorded parent, owning everything parked there - the dust push's
        // FXRP and fee
        vm.deal(address(this), collateralReservationFee + executorFee);
        address personalAccount = _createPersonalAccount(xrplOwner);
        assertEq(personalAccount, parent);
        assertEq(fxrp.balanceOf(personalAccount), 250e6);
        assertEq(personalAccount.balance, executorFee);
    }

    function testCreateSubaccountEmptyOwnerIsPermanentOrphan() public {
        // the generic route accepts any string, but PersonalAccount.initialize rejects an
        // empty owner - an empty-owner subaccount is caller-funded junk whose parent can
        // never materialize; no custody or address-collision impact
        address subaccount = controller.createSubaccount("", SUBACCOUNT_TYPE_LOAN);
        assertNotEq(subaccount.code.length, 0);

        vm.deal(address(this), collateralReservationFee + executorFee);
        vm.expectRevert();
        controller.reserveCollateral{value: collateralReservationFee + executorFee}(
            "",
            (bytes32(uint256(1)) << 160) | (bytes32(uint256(1)) << 144),
            bytes32("txEmptyOwner")
        );
    }

    function testCreateSubaccountOfFutureType() public {
        // the type is a raw uint256, not an enum, so a type unknown at compile time of the proxy
        // and facet works as soon as governance registers an implementation for it — no new proxy
        // creation code, facet redeploy, or diamond cut
        uint256 futureType = 2;
        address futureImpl = address(new LoanSubaccount());
        vm.prank(governance);
        controller.setSubaccountImplementation(futureType, futureImpl);

        address personalAccount = _createPersonalAccount(xrplOwner);
        address loanTypeSubaccount = controller.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        address futureTypeSubaccount = controller.createSubaccount(xrplOwner, futureType);

        // distinct account per type, both functional, each resolving its own implementation
        assertNotEq(futureTypeSubaccount, loanTypeSubaccount);
        assertEq(LoanSubaccount(payable(futureTypeSubaccount)).parentPersonalAccount(), personalAccount);
        assertEq(LoanSubaccount(payable(futureTypeSubaccount)).subaccountType(), futureType);
        assertEq(LoanSubaccount(payable(futureTypeSubaccount)).implementation(), futureImpl);
        assertEq(LoanSubaccount(payable(loanTypeSubaccount)).implementation(), address(loanImpl));
    }

    function testCreateSubaccountOfNonLoanType() public {
        // the generic boundary holds without the loan contracts: an implementation carrying
        // only the ISubaccount surface (of which the frozen proxy dictates just
        // `initialize(address,address,uint256)`) registers, deploys
        // through the frozen proxy, and initializes - a future type needs nothing more
        uint256 genericType = 2;
        address genericImpl = address(new MockGenericSubaccount());
        vm.prank(governance);
        controller.setSubaccountImplementation(genericType, genericImpl);

        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.createSubaccount(xrplOwner, genericType);

        assertEq(subaccount, controller.getSubaccount(xrplOwner, genericType));
        assertEq(ISubaccount(subaccount).controllerAddress(), address(controller));
        assertEq(ISubaccount(subaccount).parentPersonalAccount(), personalAccount);
        assertEq(ISubaccount(subaccount).subaccountType(), genericType);
        assertEq(ISubaccount(subaccount).implementation(), genericImpl);
    }

    function testCreateSubaccountRevertInvalidSubaccountType() public {
        _createPersonalAccount(xrplOwner);

        vm.expectRevert(ISubaccountsFacet.InvalidSubaccountType.selector);
        controller.createSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_NONE
        );
    }

    function testCreateSubaccountRevertImplementationNotSet() public {
        // fresh diamond without the loan subaccount implementation configured
        IIMasterAccountController freshController = _deployDiamond();
        _addAgentVault(freshController);
        _createPersonalAccountOn(freshController, xrplOwner);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISubaccountsFacet.SubaccountImplementationNotSet.selector,
                SUBACCOUNT_TYPE_LOAN
            )
        );
        freshController.createSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testCreateSubaccountRevertNotSuccessfullyDeployed() public {
        _createPersonalAccount(xrplOwner);
        address predicted = controller.getSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        // replace the singleton factory with one that does not deploy
        MockSingletonFactoryNoDeploy mockFactoryNoDeploy = new MockSingletonFactoryNoDeploy();
        vm.etch(SINGLETON_FACTORY, address(mockFactoryNoDeploy).code);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISubaccountsFacet.SubaccountNotSuccessfullyDeployed.selector,
                predicted
            )
        );
        controller.createSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testCreateSubaccountRevertWhenPaused() public {
        _createPersonalAccount(xrplOwner);

        address pauser = makeAddr("pauser");
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        vm.prank(governance);
        controller.addPausers(pausers);
        vm.prank(pauser);
        controller.pause();

        vm.expectRevert(IPauseFacet.IsPaused.selector);
        controller.createSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testGetSubaccountPredictionStableAcrossPersonalAccountCreation() public {
        // prediction works before the Personal Account exists and does not shift when it is created
        address predictedBefore = controller.getSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
        _createPersonalAccount(xrplOwner);
        address predictedAfter = controller.getSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        assertEq(predictedBefore, predictedAfter);
    }

    function testGetSubaccountRevertInvalidSubaccountType() public {
        vm.expectRevert(ISubaccountsFacet.InvalidSubaccountType.selector);
        controller.getSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_NONE
        );
    }

    //
    // step 3: account abstraction dispatch into the subaccount
    //

    function testDispatchFromXrplInstructionReachesSubaccount() public {
        // the loan subaccount implementation for this type exposes a parent-restricted method
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(new MockLoanSubaccount())
        );

        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.getSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
        assertEq(subaccount.code.length, 0);

        // one user operation: create the subaccount, then call it
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](2);
        calls[0] = IPersonalAccount.Call({
            target: address(controller),
            value: 0,
            data: abi.encodeCall(
                ISubaccountsFacet.createSubaccount,
                (xrplOwner, SUBACCOUNT_TYPE_LOAN)
            )
        });
        calls[1] = IPersonalAccount.Call({
            target: subaccount,
            value: 0,
            data: abi.encodeWithSignature("ping()")
        });

        _executeUserOp(personalAccount, calls, bytes32("dmLoanDispatch"));

        // the subaccount was created by the instruction and is owned by the caller's PA
        assertNotEq(subaccount.code.length, 0);
        assertEq(LoanSubaccount(payable(subaccount)).parentPersonalAccount(), personalAccount);

        // the restricted method ran, called by the parent Personal Account
        assertEq(MockLoanSubaccount(payable(subaccount)).pingCount(), 1);
        assertEq(MockLoanSubaccount(payable(subaccount)).lastPingCaller(), personalAccount);
    }

    function testDispatchForwardsValueToSubaccount() public {
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(new MockLoanSubaccount())
        );
        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.getSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
        uint256 value = 3 ether;

        // the restricted methods added next need native value (executor and messaging fees),
        // so it must survive the whole chain: instruction -> Personal Account -> subaccount
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](2);
        calls[0] = IPersonalAccount.Call({
            target: address(controller),
            value: 0,
            data: abi.encodeCall(
                ISubaccountsFacet.createSubaccount,
                (xrplOwner, SUBACCOUNT_TYPE_LOAN)
            )
        });
        calls[1] = IPersonalAccount.Call({
            target: subaccount,
            value: value,
            data: abi.encodeWithSignature("ping()")
        });

        _executeUserOpWithValue(personalAccount, calls, bytes32("dmLoanValue"), value);

        assertEq(MockLoanSubaccount(payable(subaccount)).lastPingValue(), value);
        assertEq(subaccount.balance, value);
    }

    function testDispatchToUncreatedSubaccountSilentlyDoesNothing() public {
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(new MockLoanSubaccount())
        );
        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.getSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        // calling the subaccount without creating it first: a call to an address with no code
        // returns success, so the instruction does not revert and simply has no effect.
        // this is why user operations must create the subaccount as their first call.
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: subaccount,
            value: 0,
            data: abi.encodeWithSignature("ping()")
        });

        _executeUserOp(personalAccount, calls, bytes32("dmLoanNoCode"));

        assertEq(subaccount.code.length, 0);
    }

    function testDispatchRevertWhenCallingAnotherAccountsSubaccount() public {
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(new MockLoanSubaccount())
        );
        address personalAccount = _createPersonalAccount(xrplOwner);

        // another XRPL owner's subaccount, created and owned by their Personal Account
        string memory otherOwner = "rOtherXrplAddress";
        _createPersonalAccount(otherOwner);
        address otherSubaccount = controller.createSubaccount(
            otherOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: otherSubaccount,
            value: 0,
            data: abi.encodeWithSignature("ping()")
        });

        // the subaccount rejects the foreign parent, and the failure propagates out through the
        // Personal Account and the memo handler, reverting the whole instruction
        _executeUserOpExpectRevert(
            personalAccount,
            calls,
            bytes32("dmLoanForeign"),
            abi.encodeWithSelector(
                IMemoInstructionsFacet.CallFailed.selector,
                abi.encodeWithSelector(
                    IPersonalAccount.CallFailed.selector,
                    0,
                    abi.encodeWithSelector(ISubaccount.OnlyParent.selector)
                )
            )
        );
    }

    function testSubaccountMethodRevertOnlyParent() public {
        vm.prank(governance);
        controller.setSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(new MockLoanSubaccount())
        );
        _createPersonalAccount(xrplOwner);
        address subaccount = controller.createSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        // neither a random caller nor the controller may drive the subaccount directly
        vm.expectRevert(ISubaccount.OnlyParent.selector);
        MockLoanSubaccount(payable(subaccount)).ping();

        vm.prank(address(controller));
        vm.expectRevert(ISubaccount.OnlyParent.selector);
        MockLoanSubaccount(payable(subaccount)).ping();
    }

    //
    // step 4: sweepRedeem (backward cleanup move: push to the parent, which redeems)
    //

    function testSweepRedeemRedeemsWholeBalanceToParentXrplOwner() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        // deliberately not a whole number of lots (FXRP lot size is 10e6), so this exercises a
        // UBA redemption that the lot-based `redeem` could not fully perform
        uint256 balance = 250e6 + 1;
        fxrp.mint(subaccount, balance);
        mockAssetManager.setMinimumRedeemAmountUBA(10e6);

        // the parent redeems, to its own XRPL owner, with the controller's executor
        vm.expectCall(
            assetManagerFxrpMock,
            executorFee,
            abi.encodeWithSelector(
                IRedeemExtended.redeemAmount.selector, balance, xrplOwner, executor
            )
        );
        vm.deal(address(this), executorFee);
        vm.expectEmit();
        emit IPersonalAccount.FXrpRedeemedFromSubaccount(
            subaccount, balance, balance, executor, executorFee
        );
        vm.expectEmit();
        emit IBridgingSubaccount.FXrpRedeemed(personalAccount, balance, balance);
        (uint256 amount, uint256 redeemed) =
            ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();

        assertEq(amount, balance);
        assertEq(redeemed, balance);
        // the whole balance left this account and was burned by the redemption
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(fxrp.balanceOf(personalAccount), 0);
        assertEq(fxrp.allowance(subaccount, personalAccount), 0);
        // the parent is the recorded redeemer: defaults and payouts are its business
        (address redeemer, bool active, uint256 requested) =
            mockAssetManager.requests(mockAssetManager.lastRequestId());
        assertEq(redeemer, personalAccount);
        assertTrue(active);
        assertEq(requested, balance);
    }

    function testSweepRedeemPartialFillLeavesTheRemainderOnTheParent() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 250e6);
        // FAssets can redeem less than requested when tickets run out; the pushed remainder
        // stays with the redeemer - the parent - where the user controls it
        mockAssetManager.setMaxRedeemPerCall(100e6);

        vm.deal(address(this), executorFee);
        (uint256 amount, uint256 redeemed) =
            ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();

        assertEq(amount, 250e6);
        assertEq(redeemed, 100e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(fxrp.balanceOf(personalAccount), 150e6);
    }

    function testSweepRedeemCanBeCalledByAnyone() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);

        address caller = makeAddr("randomCaller");
        vm.deal(caller, executorFee);
        vm.prank(caller);
        (uint256 amount,) = ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();

        assertEq(amount, 100e6);
    }

    function testSweepRedeemRevertNothingToRedeem() public {
        address subaccount = _createSubaccountFor(xrplOwner);

        vm.deal(address(this), executorFee);
        vm.expectRevert(IBridgingSubaccount.NothingToRedeem.selector);
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
    }

    function testSweepRedeemBelowMinimumPushesUnredeemedAndPaysTheFeeToTheParent() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address parent = _personalAccountOf(xrplOwner);
        mockAssetManager.setMinimumRedeemAmountUBA(100e6);
        fxrp.mint(subaccount, 100e6 - 1);

        // FAssets would reject the redemption, so the balance goes home unredeemed and the
        // caller's fee goes to the parent's float: the rail never fails on amount and never
        // costs less than the configured fee - a griefer pushing dust pays the user
        address caller = makeAddr("executorBot");
        vm.deal(caller, 2 * executorFee);
        vm.expectEmit();
        emit IBridgingSubaccount.NativeSweptToParent(parent, executorFee);
        vm.expectEmit();
        emit IBridgingSubaccount.TokenSweptToParent(parent, address(fxrp), 100e6 - 1);
        vm.prank(caller);
        (uint256 amount, uint256 redeemed) =
            ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();

        assertEq(amount, 100e6 - 1);
        assertEq(redeemed, 0);
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(fxrp.balanceOf(parent), 100e6 - 1);
        assertEq(parent.balance, executorFee);
        assertEq(caller.balance, executorFee);
        assertEq(mockAssetManager.lastRequestId(), 0);
        // at the minimum the redemption path takes it - no gap between the two branches
        fxrp.mint(subaccount, 100e6);
        vm.prank(caller);
        (amount, redeemed) = ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        assertEq(amount, 100e6);
        assertEq(redeemed, 100e6);
        assertEq(mockAssetManager.lastRedeemValue(), executorFee);
        assertEq(caller.balance, 0);
    }

    function testSweepRedeemBelowMinimumRevertNativeSweepFailed() public {
        // a parent that cannot take native (impossible for a real Personal Account, which has a
        // receive function) fails the whole call rather than stranding the fee here
        SubaccountProxy proxy =
            new SubaccountProxy(address(controller), address(fxrp), SUBACCOUNT_TYPE_LOAN);
        address subaccount = address(proxy);
        mockAssetManager.setMinimumRedeemAmountUBA(100e6);
        fxrp.mint(subaccount, 1e6);

        vm.deal(address(this), executorFee);
        vm.expectRevert(IBridgingSubaccount.NativeSweepFailed.selector);
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
    }

    function testSweepRedeemForwardsWholeValueToAssetManager() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);

        // overpayment is deliberate: the whole msg.value travels through the parent to the
        // asset manager as the executor fee (real FAssets records it in whole gwei; the mock
        // records the exact value)
        uint256 sent = executorFee + 1 ether;
        vm.deal(address(this), sent);
        ILoanSubaccount(subaccount).sweepRedeem{value: sent}();

        assertEq(mockAssetManager.lastRedeemValue(), sent);
        assertEq(_personalAccountOf(xrplOwner).balance, 0);
    }

    function testSweepRedeemNeverTouchesTheParentsOwnBalance() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        // the parent holds FXRP of its own; a subaccount-initiated redemption pulls and redeems
        // exactly the pushed amount and nothing else
        fxrp.mint(personalAccount, 1_000e6);
        fxrp.mint(subaccount, 100e6);

        vm.deal(address(this), executorFee);
        (, uint256 redeemed) = ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();

        assertEq(redeemed, 100e6);
        assertEq(fxrp.balanceOf(personalAccount), 1_000e6);
        (,, uint256 requested) = mockAssetManager.requests(mockAssetManager.lastRequestId());
        assertEq(requested, 100e6);
    }

    function testSweepRedeemViaXrplInstructionReentersTheParent() public {
        // the user may trigger the backward move by signature, paying the executor fee from the
        // parent's own native: XRPL memo -> controller -> parent.executeUserOp (shared guard
        // held) -> subaccount.sweepRedeem -> parent.redeemFromSubaccount. The redemption runs
        // in its own guard domain, so this legitimate re-entry is not rejected
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        vm.deal(personalAccount, executorFee);

        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: subaccount,
            value: executorFee,
            data: abi.encodeCall(IBridgingSubaccount.sweepRedeem, ())
        });
        _executeUserOp(personalAccount, calls, bytes32("dmSweepRedeem"));

        assertEq(fxrp.balanceOf(subaccount), 0);
        (address redeemer,,) = mockAssetManager.requests(mockAssetManager.lastRequestId());
        assertEq(redeemer, personalAccount);
        assertEq(mockAssetManager.lastRedeemValue(), executorFee);
        assertEq(personalAccount.balance, 0);
    }

    function testRedeemFromSubaccountRejectsNestedRedemptionAndRollsBack() public {
        // the redemption guard's rejection branch: a dependency callback (modeled on the asset
        // manager) reaches the permissionless rail of a SECOND valid subaccount of the same
        // parent while the first redemption is in flight; the nested redeemFromSubaccount is
        // refused and everything - tokens, approval, value, request - rolls back
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        vm.prank(governance);
        controller.setSubaccountImplementation(2, address(loanImpl));
        address second = controller.createSubaccount(xrplOwner, 2);
        fxrp.mint(subaccount, 100e6);
        fxrp.mint(second, 50e6);
        // the callback pays the rail's fee out of the value the asset manager just received, so
        // the nested attempt gets past the fee check and is stopped by the guard itself
        mockAssetManager.setRedeemCallback(
            second, abi.encodeCall(IBridgingSubaccount.sweepRedeem, ()), executorFee
        );

        vm.deal(address(this), executorFee);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();

        assertEq(fxrp.balanceOf(subaccount), 100e6);
        assertEq(fxrp.balanceOf(second), 50e6);
        assertEq(fxrp.balanceOf(personalAccount), 0);
        assertEq(fxrp.allowance(subaccount, personalAccount), 0);
        assertEq(mockAssetManager.lastRequestId(), 0);
        assertEq(address(this).balance, executorFee);
    }

    function testRedeemFromSubaccountRevertOnlySubaccount() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        // another user's subaccount: a real one, but not one of this parent's
        address foreignSubaccount = _createSubaccountFor("rOtherOwner");

        // a contract that is no subaccount (this test), an EOA, the controller (a contract
        // without the type query), a contract reporting the reserved type, a foreign subaccount
        vm.expectRevert(IPersonalAccount.OnlySubaccount.selector);
        IPersonalAccount(personalAccount).redeemFromSubaccount(1e6);

        vm.prank(makeAddr("eoa"));
        vm.expectRevert(IPersonalAccount.OnlySubaccount.selector);
        IPersonalAccount(personalAccount).redeemFromSubaccount(1e6);

        vm.prank(address(controller));
        vm.expectRevert(IPersonalAccount.OnlySubaccount.selector);
        IPersonalAccount(personalAccount).redeemFromSubaccount(1e6);

        vm.mockCall(
            address(fxrp),
            abi.encodeWithSelector(ISubaccount.subaccountType.selector),
            abi.encode(SUBACCOUNT_TYPE_NONE)
        );
        vm.prank(address(fxrp));
        vm.expectRevert(IPersonalAccount.OnlySubaccount.selector);
        IPersonalAccount(personalAccount).redeemFromSubaccount(1e6);

        vm.prank(foreignSubaccount);
        vm.expectRevert(IPersonalAccount.OnlySubaccount.selector);
        IPersonalAccount(personalAccount).redeemFromSubaccount(1e6);

        // this parent's own subaccount passes (its approval feeds the pull)
        fxrp.mint(subaccount, 1e6);
        vm.deal(subaccount, executorFee);
        vm.startPrank(subaccount);
        fxrp.approve(personalAccount, 1e6);
        uint256 redeemed =
            IPersonalAccount(personalAccount).redeemFromSubaccount{value: executorFee}(1e6);
        vm.stopPrank();
        assertEq(redeemed, 1e6);
        assertEq(fxrp.balanceOf(subaccount), 0);
    }

    function testRedemptionDefaultByTheParentDirectlyOnTheAssetManager() public {
        // the parent is the recorded redeemer, so FAssets lets it default directly and pays
        // the payout to it - no relay on the subaccount. Production path: XRPL memo ->
        // controller -> parent.executeUserOp -> assetManager.redemptionPaymentDefault
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        MintableERC20 stableCoin = new MintableERC20("Stable", "STB", 18);
        mockAssetManager.setDefaultPayout(stableCoin, 500e18);

        fxrp.mint(subaccount, 100e6);
        vm.deal(address(this), executorFee);
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        uint256 requestId = mockAssetManager.lastRequestId();

        // the subaccount the FXRP came from is not the redeemer
        IReferencedPaymentNonexistence.Proof memory proof;
        vm.prank(subaccount);
        vm.expectRevert(bytes("only redeemer, executor or agent"));
        mockAssetManager.redemptionPaymentDefault(proof, requestId);

        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: assetManagerFxrpMock,
            value: 0,
            data: abi.encodeCall(MockAssetManager.redemptionPaymentDefault, (proof, requestId))
        });
        _executeUserOp(personalAccount, calls, bytes32("dmDefault"));

        assertEq(mockAssetManager.lastDefaultCaller(), personalAccount);
        assertEq(mockAssetManager.lastDefaultRequestId(), requestId);
        assertEq(stableCoin.balanceOf(personalAccount), 500e18);

        // a defaulted request cannot be defaulted again
        vm.prank(personalAccount);
        vm.expectRevert(bytes("invalid request id"));
        mockAssetManager.redemptionPaymentDefault(proof, requestId);
    }

    function testXrpRedemptionDefaultProofOwnerIsTheParent() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        vm.deal(address(this), executorFee);
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        uint256 requestId = mockAssetManager.lastRequestId();

        // the asset manager sees the parent as the caller, so the proof must name the parent
        // (or nobody), not the subaccount the FXRP came from - an easy integration mistake
        IXRPPaymentNonexistence.Proof memory proof;
        proof.data.requestBody.proofOwner = subaccount;
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: assetManagerFxrpMock,
            value: 0,
            data: abi.encodeCall(MockAssetManager.xrpRedemptionPaymentDefault, (proof, requestId))
        });
        vm.prank(address(controller));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPersonalAccount.CallFailed.selector,
                0,
                abi.encodeWithSignature("Error(string)", "only proof owner")
            )
        );
        IPersonalAccount(personalAccount).executeUserOp(calls);

        proof.data.requestBody.proofOwner = personalAccount;
        calls[0].data =
            abi.encodeCall(MockAssetManager.xrpRedemptionPaymentDefault, (proof, requestId));
        vm.prank(address(controller));
        IPersonalAccount(personalAccount).executeUserOp(calls);

        assertEq(mockAssetManager.lastDefaultCaller(), personalAccount);
        assertEq(mockAssetManager.lastDefaultRequestId(), requestId);
    }

    function testRedemptionDefaultViaInstructionIsUnreachableWhilePaused() public {
        // characterizes the documented liveness limitation: the user acts only through the
        // instruction pipeline, which is notPaused, so a paused controller blocks the user's
        // default; the appointed executor's direct asset manager path is unaffected
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);

        fxrp.mint(subaccount, 100e6);
        vm.deal(address(this), executorFee);
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        uint256 requestId = mockAssetManager.lastRequestId();

        address pauser = makeAddr("pauser");
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        vm.prank(governance);
        controller.addPausers(pausers);
        vm.prank(pauser);
        controller.pause();

        IReferencedPaymentNonexistence.Proof memory proof;
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: assetManagerFxrpMock,
            value: 0,
            data: abi.encodeCall(MockAssetManager.redemptionPaymentDefault, (proof, requestId))
        });
        _executeUserOpExpectRevert(
            personalAccount,
            calls,
            bytes32("dmDefaultPaused"),
            abi.encodeWithSelector(IPauseFacet.IsPaused.selector)
        );
    }

    function testImplementationContractRejectsNative() public {
        // the implementation contract is never initialized: it must not accept native
        vm.deal(address(this), 1 ether);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = address(loanImpl).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function testPublicAggregateExposesLoanFacet() public {
        // typed through the public aggregate, so an omission there fails compilation here
        IMasterAccountController publicController = IMasterAccountController(address(controller));
        _createPersonalAccount(xrplOwner);
        address subaccount =
            publicController.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertEq(
            publicController.getSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN),
            subaccount
        );
        assertEq(
            publicController.implementationForType(SUBACCOUNT_TYPE_LOAN),
            address(loanImpl)
        );
    }

    function testSweepRedeemRevertInsufficientFundsForRedeem() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);

        // the configured fee is the price of the permissionless rail, above and below the
        // minimum alike: forcing the backward direction is never gas-only
        vm.deal(address(this), executorFee);
        vm.expectRevert(
            abi.encodeWithSelector(IBridgingSubaccount.InsufficientFundsForRedeem.selector, executorFee)
        );
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee - 1}();
        mockAssetManager.setMinimumRedeemAmountUBA(1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(IBridgingSubaccount.InsufficientFundsForRedeem.selector, executorFee)
        );
        ILoanSubaccount(subaccount).sweepRedeem();
    }

    function testRedeemFromSubaccountAcceptsZeroValue() public {
        // the fee policy lives at the entry: the parent itself forwards whatever value came, so
        // an authenticated route (the compose-driven bridge-back redemption) can send none - the
        // controller's executor is appointed regardless, just unpaid
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);

        vm.expectCall(
            assetManagerFxrpMock,
            0,
            abi.encodeWithSelector(IRedeemExtended.redeemAmount.selector, 100e6, xrplOwner, executor)
        );
        vm.startPrank(subaccount);
        fxrp.approve(personalAccount, 100e6);
        vm.expectEmit();
        emit IPersonalAccount.FXrpRedeemedFromSubaccount(subaccount, 100e6, 100e6, executor, 0);
        uint256 redeemed = IPersonalAccount(personalAccount).redeemFromSubaccount(100e6);
        vm.stopPrank();

        assertEq(redeemed, 100e6);
        assertEq(mockAssetManager.lastRedeemValue(), 0);
        (address redeemer,,) = mockAssetManager.requests(mockAssetManager.lastRequestId());
        assertEq(redeemer, personalAccount);
    }

    //
    // step 4: no recovery rail - strays strand
    //

    function testStrayTokenHasNoExit() public {
        // no recovery method: a token sent here by mistake strands until a beacon upgrade
        // adds a rail - accepted, since no protocol flow delivers non-FXRP tokens here
        address subaccount = _createSubaccountFor(xrplOwner);
        MintableERC20 stableCoin = new MintableERC20("Stable", "STB", 18);
        stableCoin.mint(subaccount, 500e18);
        assertEq(stableCoin.balanceOf(subaccount), 500e18);
    }

    function testRejectsPlainNativeAndHasNoNativeExit() public {
        // no receive(): a plain send reverts at the sender - the only protocol-delivered
        // native is the redeem-home compose value, spent or forwarded within the same call
        // (the bridge refunds its caller, redemption outcomes go to the parent). Native that
        // lands without a call (funding of the predicted address before deployment, a
        // force-send) has no exit and strands - accepted; the implementation is upgradeable
        address subaccount = _createSubaccountFor(xrplOwner);
        vm.deal(address(this), 1 ether);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = subaccount.call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(subaccount.balance, 0);
    }

    function testValueSentToUncreatedSubaccountStrands() public {
        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.getSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);

        // an instruction that carries value to a not-yet-created subaccount does not revert:
        // the call to the codeless address succeeds and the value lands there
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: subaccount,
            value: 1 ether,
            data: abi.encodeWithSignature("ping()")
        });
        _executeUserOpWithValue(personalAccount, calls, bytes32("dmLoanValueLost"), 1 ether);
        assertEq(subaccount.code.length, 0);
        assertEq(subaccount.balance, 1 ether);

        // creation does not change that: the subaccount has no native exit, so the value strands
        // - accepted (nobody in the protocol causes it; a beacon upgrade can add an exit).
        // User operations must create the subaccount first
        controller.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertNotEq(subaccount.code.length, 0);
        assertEq(subaccount.balance, 1 ether);
        assertEq(personalAccount.balance, 0);
    }

    //
    // the redeem-home compose: FXRP coming back from the loan chain is redeemed on arrival
    //

    function testRedeemHomeComposeRedeemsThroughTheParent() public {
        // the loan-chain twin's withdraw action bridges FXRP here with the redeem-home compose (a
        // deadline and nothing else); this account authenticates it against its bridge route
        // (the adapter, its endpoint,
        // the loan chain, the pinned peer) and runs the sweep-redeem logic with the compose
        // value as the executor fee - no public-entry fee check, the packet already cost its
        // sender the LayerZero fee
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        _configureLoanBridge();
        fxrp.mint(subaccount, 100e6); // the OFT's credit on arrival

        vm.expectEmit();
        emit IPersonalAccount.FXrpRedeemedFromSubaccount(subaccount, 100e6, 100e6, executor, executorFee);
        vm.expectEmit();
        emit IBridgingSubaccount.FXrpRedeemed(personalAccount, 100e6, 100e6);
        _deliverRedeemHome(subaccount, 1, 100e6, executorFee);

        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(mockAssetManager.lastRedeemValue(), executorFee);
        (address redeemer,,) = mockAssetManager.requests(mockAssetManager.lastRequestId());
        assertEq(redeemer, personalAccount);
    }

    function testRedeemHomeComposeWithZeroValueAndWhilePaused() public {
        // zero compose value appoints the executor unpaid; and the backward move is an exit
        // toward the user, so the pause does not gate it
        address subaccount = _createSubaccountFor(xrplOwner);
        _configureLoanBridge();
        fxrp.mint(subaccount, 100e6);
        address pauser = makeAddr("pauser");
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        vm.prank(governance);
        controller.addPausers(pausers);
        vm.prank(pauser);
        controller.pause();

        _deliverRedeemHome(subaccount, 1, 100e6, 0);

        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(mockAssetManager.lastRedeemValue(), 0);
    }

    function testRedeemHomeComposeBelowMinimumPushesToParent() public {
        // dust comes home unredeemed, and the compose value joins the parent's float - never a
        // refund to msg.sender, which here would be the endpoint
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        _configureLoanBridge();
        mockAssetManager.setMinimumRedeemAmountUBA(1_000e6);
        fxrp.mint(subaccount, 100e6);

        _deliverRedeemHome(subaccount, 1, 100e6, executorFee);

        assertEq(fxrp.balanceOf(personalAccount), 100e6);
        assertEq(personalAccount.balance, executorFee);
        assertEq(mockAssetManager.lastRequestId(), 0);
    }

    function testRedeemHomeComposeIsCappedAtItsPacketAmount() public {
        // two bridge-back packets can credit the account before either compose runs; each
        // compose redeems at most its own packet's amount (the codec amount), so the first
        // cannot consume more than one packet's worth, and the rest of the balance stays for
        // the public rail
        address subaccount = _createSubaccountFor(xrplOwner);
        _configureLoanBridge();
        fxrp.mint(subaccount, 100e6); // 60 + 40 credited, no compose yet

        _deliverRedeemHome(subaccount, 1, 60e6, 0);
        assertEq(fxrp.balanceOf(subaccount), 40e6);
        (,, uint256 requested) = mockAssetManager.requests(mockAssetManager.lastRequestId());
        assertEq(requested, 60e6);

        _deliverRedeemHome(subaccount, 2, 40e6, 0);
        assertEq(fxrp.balanceOf(subaccount), 0);

        // a packet finding more than its amount leaves the rest alone
        fxrp.mint(subaccount, 30e6);
        _deliverRedeemHome(subaccount, 3, 10e6, 0);
        assertEq(fxrp.balanceOf(subaccount), 20e6);
    }

    function testRedeemHomeComposeSkipsPastItsDeadline() public {
        // a packet delivered after the sender-stamped deadline does nothing to the balance:
        // whatever is on the account stays for the public rail and its value joins the
        // parent's float - a packet cannot outlive its window as an instruction over later funds
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        _configureLoanBridge();
        fxrp.mint(subaccount, 100e6);
        bytes memory stale = _redeemHomePayloadAt(uint64(block.timestamp - 1));
        (bytes memory message, bytes32 guid) = _composeFromLoanChain(subaccount, 1, 100e6, stale);

        vm.deal(lzEndpoint, executorFee);
        vm.expectEmit();
        emit IBridgingSubaccount.NativeSweptToParent(personalAccount, executorFee);
        vm.expectEmit();
        emit IBridgingSubaccount.RedeemHomeSkipped(personalAccount, guid);
        vm.prank(lzEndpoint);
        ILoanSubaccount(subaccount).lzCompose{value: executorFee}(address(fxrpOft), guid, message, executor, "");

        assertEq(fxrp.balanceOf(subaccount), 100e6);
        assertEq(personalAccount.balance, executorFee);
        assertEq(mockAssetManager.lastRequestId(), 0);
    }

    function testRedeemHomeComposeExpiredRevertNativeSweepFailed() public {
        // an expired packet forwards its value to the parent; a parent that cannot take native
        // (impossible for a real Personal Account) fails the delivery rather than stranding it
        SubaccountProxy proxy =
            new SubaccountProxy(address(controller), address(fxrp), SUBACCOUNT_TYPE_LOAN);
        address subaccount = address(proxy);
        _configureLoanBridge();
        fxrp.mint(subaccount, 100e6);
        bytes memory stale = _redeemHomePayloadAt(uint64(block.timestamp - 1));
        (bytes memory message, bytes32 guid) = _composeFromLoanChain(subaccount, 1, 100e6, stale);

        vm.deal(lzEndpoint, executorFee);
        vm.prank(lzEndpoint);
        vm.expectRevert(IBridgingSubaccount.NativeSweepFailed.selector);
        ILoanSubaccount(subaccount).lzCompose{value: executorFee}(address(fxrpOft), guid, message, executor, "");
    }

    function testStaleRedeemHomeComposeIsBoundedInAmountAndTime() public {
        // the residual accepted risk, pinned: a packet whose credit a public rail already moved
        // stays retriable, but can redeem at most its own amount out of later funds, and only
        // until its deadline - never the whole balance, never forever
        address subaccount = _createSubaccountFor(xrplOwner);
        _configureLoanBridge();
        fxrp.mint(subaccount, 100e6);
        (bytes memory message, bytes32 guid) = _composeFromLoanChain(subaccount, 1, 100e6, _redeemHomePayload());

        // an executor's public sweep takes the credit before the compose runs
        vm.deal(address(this), executorFee);
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        vm.prank(lzEndpoint);
        vm.expectRevert(IBridgingSubaccount.NothingToRedeem.selector);
        ILoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");

        // later funds arrive for a new attempt: within the TTL the old packet redeems at most
        // its own 100 of them
        fxrp.mint(subaccount, 500e6);
        vm.prank(lzEndpoint);
        ILoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
        assertEq(fxrp.balanceOf(subaccount), 400e6);

        // past the TTL a stale packet skips - the balance is untouched
        (message, guid) = _composeFromLoanChain(subaccount, 2, 100e6, _redeemHomePayload());
        vm.warp(block.timestamp + REDEEM_HOME_TTL + 1);
        vm.prank(lzEndpoint);
        ILoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
        assertEq(fxrp.balanceOf(subaccount), 400e6);
    }

    function testRedeemHomeComposeAuthentication() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);

        // no bridge route, no transport to authenticate against
        (bytes memory message, bytes32 guid) = _composeFromLoanChain(subaccount, 1, 100e6, _redeemHomePayload());
        vm.prank(lzEndpoint);
        vm.expectRevert(IBridgingSubaccount.BridgeRouteNotConfigured.selector);
        ILoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
        _configureLoanBridge();

        // only the adapter's endpoint may deliver
        vm.expectRevert(IComposeReceiverAccountBase.OnlyEndpoint.selector);
        ILoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");

        // the compose sender must be the configured adapter
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongComposeSender.selector, makeAddr("otherOft"))
        );
        ILoanSubaccount(subaccount).lzCompose(makeAddr("otherOft"), guid, message, executor, "");

        // the message must come from the loan chain
        bytes memory wrongChain = OFTComposeMsgCodec.encode(
            1, 30110, 100e6, abi.encodePacked(bytes32(uint256(uint160(subaccount))), _redeemHomePayload())
        );
        vm.prank(lzEndpoint);
        vm.expectRevert(abi.encodeWithSelector(IComposeReceiverAccountBase.WrongSourceEid.selector, uint32(30110)));
        ILoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, wrongChain, executor, "");

        // the source-chain sender must be this account itself - its own loan-chain twin
        bytes memory forged = OFTComposeMsgCodec.encode(
            1, destinationEid, 100e6,
            abi.encodePacked(bytes32(uint256(uint160(makeAddr("intruder")))), _redeemHomePayload())
        );
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(
                IComposeReceiverAccountBase.WrongComposeFrom.selector, bytes32(uint256(uint160(makeAddr("intruder"))))
            )
        );
        ILoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, forged, executor, "");

        // the GUID must recompute from the pinned peer
        bytes32 wrongGuid = GUID.generate(
            1, destinationEid, makeAddr("maliciousPeer"), flareEid, bytes32(uint256(uint160(address(fxrpOft))))
        );
        vm.prank(lzEndpoint);
        vm.expectRevert(abi.encodeWithSelector(IComposeReceiverAccountBase.WrongGuid.selector, wrongGuid));
        ILoanSubaccount(subaccount).lzCompose(address(fxrpOft), wrongGuid, message, executor, "");

        // unsupported version and action
        bytes memory wrongVersion = abi.encode(uint8(2), ACTION_REDEEM_HOME, bytes(""));
        (message, guid) = _composeFromLoanChain(subaccount, 1, 100e6, wrongVersion);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.UnsupportedPayloadVersion.selector, uint8(2))
        );
        ILoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
        bytes memory wrongAction = abi.encode(PAYLOAD_VERSION_1, uint8(9), bytes(""));
        (message, guid) = _composeFromLoanChain(subaccount, 1, 100e6, wrongAction);
        vm.prank(lzEndpoint);
        vm.expectRevert(abi.encodeWithSelector(IComposeReceiverAccountBase.UnsupportedAction.selector, uint8(9)));
        ILoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");

        // value is admitted for the redeem-home action only: any other action with value fails
        // the value check (before it would fail as unsupported), so no branch can keep native
        vm.deal(lzEndpoint, 1);
        vm.prank(lzEndpoint);
        vm.expectRevert(IComposeReceiverAccountBase.NonZeroComposeValue.selector);
        ILoanSubaccount(subaccount).lzCompose{value: 1}(address(fxrpOft), guid, message, executor, "");

        // nothing idle to redeem: reverts, retriable (the credit always precedes the compose)
        fxrp.burn(subaccount, 100e6);
        (message, guid) = _composeFromLoanChain(subaccount, 1, 100e6, _redeemHomePayload());
        vm.prank(lzEndpoint);
        vm.expectRevert(IBridgingSubaccount.NothingToRedeem.selector);
        ILoanSubaccount(subaccount).lzCompose(address(fxrpOft), guid, message, executor, "");
    }

    //
    // the forward-move guards (shared bridging core) and the pause-time exit
    //

    function testSendCrossChainUserOp() public {
        // the user-signed instruction to the loan-chain twin: reached only through an
        // executeUserOp multicall (a self-call), the envelope is built here and sent as a
        // message-only compose to this same address, where the remote account authenticates it and
        // executes the batch - any calls the user signs
        address personalAccount = _createPersonalAccount(xrplOwner);
        _configureLoanBridge();
        vm.deal(personalAccount, messagingFee);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        IPersonalAccount.Call[] memory batch = new IPersonalAccount.Call[](2);
        batch[0] = IPersonalAccount.Call({
            target: makeAddr("rlusd"), value: 0,
            data: abi.encodeCall(IERC20.approve, (makeAddr("bridge"), 500e18))
        });
        batch[1] = IPersonalAccount.Call({
            target: makeAddr("bridge"), value: 0.01 ether, data: hex"deadbeef"
        });

        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: personalAccount,
            value: messagingFee,
            data: abi.encodeCall(
                IPersonalAccount.sendCrossChainUserOp, (destinationEid, batch, bytes32("op-x"), deadline, "")
            )
        });
        vm.expectEmit();
        emit IPersonalAccount.CrossChainUserOpSent(bytes32("op-x"), 2, destinationEid, fxrpOft.GUID());
        vm.prank(address(controller));
        IPersonalAccount(personalAccount).executeUserOp(calls);

        (uint32 sentDstEid, bytes32 to, uint256 amountLD,,, bytes memory composeMsg,) =
            fxrpOft.lastSendParam();
        assertEq(sentDstEid, destinationEid);
        assertEq(to, bytes32(uint256(uint160(personalAccount))));
        assertEq(amountLD, 0);
        assertEq(
            composeMsg,
            abi.encode(PAYLOAD_VERSION_1, PA_ACTION_EXECUTE, abi.encode(bytes32("op-x"), deadline, batch))
        );
        assertEq(fxrpOft.lastValue(), messagingFee);
    }

    function testSendCrossChainUserOpReverts() public {
        address personalAccount = _createPersonalAccount(xrplOwner);
        vm.deal(personalAccount, 1 ether);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        IPersonalAccount.Call[] memory batch = _transferBatch(makeAddr("token"), makeAddr("dest"), 1e18);

        // self-call only
        vm.expectRevert(IPersonalAccount.OnlySelf.selector);
        IPersonalAccount(personalAccount).sendCrossChainUserOp(destinationEid, batch, bytes32("op-x"), deadline, "");

        // envelope checks, before any fee is paid: zero id, passed deadline, empty batch
        vm.startPrank(personalAccount);
        vm.expectRevert(IPersonalAccount.InvalidCrossChainUserOp.selector);
        IPersonalAccount(personalAccount).sendCrossChainUserOp(destinationEid, batch, bytes32(0), deadline, "");
        vm.expectRevert(IPersonalAccount.InvalidCrossChainUserOp.selector);
        IPersonalAccount(personalAccount).sendCrossChainUserOp(
            destinationEid,
            batch, bytes32("op-x"), uint64(block.timestamp - 1), ""
        );
        vm.expectRevert(IPersonalAccount.InvalidCrossChainUserOp.selector);
        IPersonalAccount(personalAccount).sendCrossChainUserOp(
            destinationEid,
            new IPersonalAccount.Call[](0), bytes32("op-x"), deadline, ""
        );

        // bridge not configured yet
        vm.expectRevert(abi.encodeWithSelector(IPersonalAccount.UnknownBridgeRoute.selector, destinationEid));
        IPersonalAccount(personalAccount).sendCrossChainUserOp(destinationEid, batch, bytes32("op-x"), deadline, "");
        vm.stopPrank();

        _configureLoanBridge();

        // insufficient fee
        vm.prank(personalAccount);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPersonalAccount.InsufficientFundsForInstruction.selector, messagingFee
            )
        );
        IPersonalAccount(personalAccount).sendCrossChainUserOp{value: messagingFee - 1}(
            destinationEid,
            batch, bytes32("op-x"), deadline, ""
        );

        // a peer mutation fails closed
        fxrpOft.setPeer(destinationEid, bytes32(uint256(0xbad)));
        vm.prank(personalAccount);
        vm.expectRevert(IPersonalAccount.WrongDestinationPeer.selector);
        IPersonalAccount(personalAccount).sendCrossChainUserOp{value: messagingFee}(
            destinationEid,
            batch, bytes32("op-x"), deadline, ""
        );
        fxrpOft.setPeer(destinationEid, destinationPeer);

        // a forward move: the pause stops it
        address pauser = makeAddr("pauser");
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        vm.prank(governance);
        controller.addPausers(pausers);
        vm.prank(pauser);
        controller.pause();
        vm.prank(personalAccount);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        IPersonalAccount(personalAccount).sendCrossChainUserOp{value: messagingFee}(
            destinationEid,
            batch, bytes32("op-x"), deadline, ""
        );
    }

    function testSendCrossChainUserOpExcessStaysAndOptionsPassThrough() public {
        // the fee value rides from the account's own balance, so the excess never leaves it;
        // the caller-supplied type-3 options reach the OFT verbatim
        address personalAccount = _createPersonalAccount(xrplOwner);
        _configureLoanBridge();
        vm.deal(personalAccount, 1 ether);
        bytes memory options = hex"0003010011010000000000000000000000000000c350";

        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: personalAccount,
            value: messagingFee + 0.5 ether,
            data: abi.encodeCall(
                IPersonalAccount.sendCrossChainUserOp,
                (
                    destinationEid,
                    _transferBatch(makeAddr("token"), makeAddr("dest"), 1e18), bytes32("op-x"),
                    uint64(block.timestamp + 1 hours), options
                )
            )
        });
        vm.prank(address(controller));
        IPersonalAccount(personalAccount).executeUserOp(calls);

        assertEq(fxrpOft.lastValue(), messagingFee);
        assertEq(personalAccount.balance, 1 ether - messagingFee);
        (,,,, bytes memory sentOptions,,) = fxrpOft.lastSendParam();
        assertEq(sentOptions, options);
    }

    function testSendCrossChainUserOpViaMemo() public {
        // end to end through the production path: XRPL memo -> handleMintedFAssets ->
        // executeUserOp -> the account's own sendCrossChainUserOp
        address personalAccount = _createPersonalAccount(xrplOwner);
        _configureLoanBridge();

        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: personalAccount,
            value: messagingFee,
            data: abi.encodeCall(
                IPersonalAccount.sendCrossChainUserOp,
                (
                    destinationEid,
                    _transferBatch(makeAddr("token"), makeAddr("dest"), 1e18), bytes32("op-x"),
                    uint64(block.timestamp + 1 hours), ""
                )
            )
        });
        _executeUserOpWithValue(personalAccount, calls, bytes32("tx-cross-chain"), messagingFee);
        assertEq(fxrpOft.lastValue(), messagingFee);

        (uint32 sentDstEid, bytes32 to, uint256 amountLD,,,,) = fxrpOft.lastSendParam();
        assertEq(sentDstEid, destinationEid);
        assertEq(to, bytes32(uint256(uint160(personalAccount))));
        assertEq(amountLD, 0);
    }

    function testSendCrossChainUserOpAcceptsDeadlineEqualToNow() public {
        // inclusive boundary, matching the remote account's skip rule (past the deadline, not at it)
        address personalAccount = _createPersonalAccount(xrplOwner);
        _configureLoanBridge();
        vm.deal(personalAccount, messagingFee);
        uint64 deadline = uint64(block.timestamp);
        IPersonalAccount.Call[] memory batch = _transferBatch(makeAddr("token"), makeAddr("dest"), 1e18);

        vm.prank(personalAccount);
        IPersonalAccount(personalAccount).sendCrossChainUserOp{value: messagingFee}(
            destinationEid,
            batch, bytes32("op-x"), deadline, ""
        );
        (,,,,, bytes memory composeMsg,) = fxrpOft.lastSendParam();
        assertEq(
            composeMsg,
            abi.encode(PAYLOAD_VERSION_1, PA_ACTION_EXECUTE, abi.encode(bytes32("op-x"), deadline, batch))
        );
    }

    //
    // bridge routes
    //

    function testBridgeRoutesRevertNotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.startPrank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance));
        controller.setFxrpOft(address(fxrpOft));
        vm.expectRevert(abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance));
        controller.setBridgeRoute(destinationEid, destinationPeer);
        vm.expectRevert(abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance));
        controller.setSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN, destinationEid);
        vm.stopPrank();
    }

    function testSetFxrpOftRevertInvalidValues() public {
        vm.prank(governance);
        vm.expectRevert(IBridgeRoutesFacet.InvalidFxrpOft.selector);
        controller.setFxrpOft(makeAddr("notAContract"));
    }

    function testSetFxrpOftRevertWrongToken() public {
        // an OFT wrapping some other token must be rejected
        MintableERC20 otherToken = new MintableERC20("Other", "OTH", 6);
        MockOft otherOft = new MockOft(otherToken, messagingFee);

        vm.prank(governance);
        vm.expectRevert(IBridgeRoutesFacet.InvalidFxrpOft.selector);
        controller.setFxrpOft(address(otherOft));
    }

    function testSetFxrpOftRevertWrongSharedDecimals() public {
        // shared decimals below the token's would truncate to dust; the token-bearing signed
        // instructions send with minAmountLD == amountLD, so such an OFT must be rejected up front
        fxrpOft.setSharedDecimals(4);

        vm.prank(governance);
        vm.expectRevert(IBridgeRoutesFacet.InvalidFxrpOft.selector);
        controller.setFxrpOft(address(fxrpOft));
    }

    function testSetFxrpOftRevertWrongOftVersion() public {
        // wrong message-codec version: the destination-side compose authentication depends on
        // the canonical codec, so only version 1 is accepted
        fxrpOft.setOftVersion(0x02e49c2c, 2);
        vm.prank(governance);
        vm.expectRevert(IBridgeRoutesFacet.InvalidFxrpOft.selector);
        controller.setFxrpOft(address(fxrpOft));

        // wrong interface id
        fxrpOft.setOftVersion(0xdeadbeef, 1);
        vm.prank(governance);
        vm.expectRevert(IBridgeRoutesFacet.InvalidFxrpOft.selector);
        controller.setFxrpOft(address(fxrpOft));

        // the canonical pair is accepted
        fxrpOft.setOftVersion(0x02e49c2c, 1);
        vm.prank(governance);
        vm.expectEmit();
        emit IBridgeRoutesFacet.FxrpOftSet(address(fxrpOft));
        controller.setFxrpOft(address(fxrpOft));
        assertEq(controller.getFxrpOft(), address(fxrpOft));
    }

    function testSetBridgeRouteRevertWithoutFxrpOft() public {
        // a route is pinned against the adapter's live peer, so the adapter comes first
        fxrpOft.setPeer(destinationEid, destinationPeer);
        vm.prank(governance);
        vm.expectRevert(IBridgeRoutesFacet.FxrpOftNotConfigured.selector);
        controller.setBridgeRoute(destinationEid, destinationPeer);
    }

    function testSetBridgeRouteRevertInvalidEid() public {
        vm.startPrank(governance);
        controller.setFxrpOft(address(fxrpOft));
        vm.expectRevert(IBridgeRoutesFacet.InvalidDestinationEid.selector);
        controller.setBridgeRoute(0, destinationPeer);
        vm.stopPrank();
    }

    function testSetBridgeRouteRevertNoPeerForDestination() public {
        // no peer wired for the destination endpoint: the route does not exist on the adapter
        vm.startPrank(governance);
        controller.setFxrpOft(address(fxrpOft));
        vm.expectRevert(IBridgeRoutesFacet.InvalidDestinationPeer.selector);
        controller.setBridgeRoute(destinationEid, destinationPeer);
        vm.stopPrank();
    }

    function testSetBridgeRouteRevertPeerMismatch() public {
        vm.prank(governance);
        controller.setFxrpOft(address(fxrpOft));

        // the live peer must equal the intended remote OApp exactly; existence is not identity
        fxrpOft.setPeer(destinationEid, bytes32(uint256(0xbad)));
        vm.prank(governance);
        vm.expectRevert(IBridgeRoutesFacet.InvalidDestinationPeer.selector);
        controller.setBridgeRoute(destinationEid, destinationPeer);

        // a peer with dirty upper bits would route to the same EVM address but change the
        // source-computed GUID, failing the destination-side compose authentication
        bytes32 dirtyPeer = bytes32(uint256(destinationPeer) | (uint256(1) << 200));
        fxrpOft.setPeer(destinationEid, dirtyPeer);
        vm.prank(governance);
        vm.expectRevert(IBridgeRoutesFacet.InvalidDestinationPeer.selector);
        controller.setBridgeRoute(destinationEid, dirtyPeer);
    }

    function testSetSubaccountTypeRouteReverts() public {
        vm.startPrank(governance);
        controller.setFxrpOft(address(fxrpOft));
        // the route must exist before a type can point at it
        vm.expectRevert(
            abi.encodeWithSelector(IBridgeRoutesFacet.UnknownBridgeRoute.selector, destinationEid)
        );
        controller.setSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN, destinationEid);
        // the reserved type is never routable, and a zero endpoint id is not a way to clear
        vm.expectRevert(ISubaccountsFacet.InvalidSubaccountType.selector);
        controller.setSubaccountTypeRoute(0, destinationEid);
        vm.expectRevert(IBridgeRoutesFacet.InvalidDestinationEid.selector);
        controller.setSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN, 0);
        vm.stopPrank();
    }

    function testBridgeRoutesViews() public {
        _configureLoanBridge();
        (address oft, uint32 eid, bytes32 peer) = controller.getSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN);
        assertEq(oft, address(fxrpOft));
        assertEq(eid, destinationEid);
        assertEq(peer, destinationPeer);
        assertEq(controller.getBridgeRoute(destinationEid), destinationPeer);
        assertEq(controller.getBridgeRoute(30184), bytes32(0));
        (uint32[] memory eids, bytes32[] memory peers) = controller.getBridgeRoutes();
        assertEq(eids.length, 1);
        assertEq(eids[0], destinationEid);
        assertEq(peers[0], destinationPeer);
        // a type pointed nowhere resolves to no route at all
        (oft, eid, peer) = controller.getSubaccountTypeRoute(2);
        assertEq(oft, address(fxrpOft));
        assertEq(eid, 0);
        assertEq(peer, bytes32(0));
    }

    function testClearBridgeRouteDisablesForwardMovesOnIt() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        // a zero peer clears the route: the type pointed at it and the cross-chain user
        // operations naming it fail closed until it is set again; the type stays pointed
        vm.prank(governance);
        vm.expectEmit();
        emit IBridgeRoutesFacet.BridgeRouteSet(destinationEid, bytes32(0));
        controller.setBridgeRoute(destinationEid, bytes32(0));
        assertEq(controller.getBridgeRoute(destinationEid), bytes32(0));
        (uint32[] memory eids, ) = controller.getBridgeRoutes();
        assertEq(eids.length, 0);
        (, uint32 eid, bytes32 peer) = controller.getSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN);
        assertEq(eid, destinationEid);
        assertEq(peer, bytes32(0));

        vm.deal(personalAccount, 2 * messagingFee);
        vm.prank(personalAccount);
        vm.expectRevert(IBridgingSubaccount.BridgeRouteNotConfigured.selector);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
        vm.prank(personalAccount);
        vm.expectRevert(
            abi.encodeWithSelector(IPersonalAccount.UnknownBridgeRoute.selector, destinationEid)
        );
        IPersonalAccount(personalAccount).sendCrossChainUserOp{value: messagingFee}(
            destinationEid, _transferBatch(makeAddr("token"), makeAddr("dest"), 1e18),
            bytes32("op-x"), uint64(block.timestamp + 1 hours), ""
        );

        // re-pinning the same route restores both without touching the type
        vm.prank(governance);
        controller.setBridgeRoute(destinationEid, destinationPeer);
        vm.prank(personalAccount);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
    }

    function testClearFxrpOftDisablesEveryForwardMove() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        // clearing the adapter blocks every send while routes and type assignments stay recorded
        vm.prank(governance);
        controller.setFxrpOft(address(0));
        assertEq(controller.getFxrpOft(), address(0));
        assertEq(controller.getBridgeRoute(destinationEid), destinationPeer);

        vm.deal(personalAccount, messagingFee);
        vm.prank(personalAccount);
        vm.expectRevert(IBridgingSubaccount.BridgeRouteNotConfigured.selector);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
        vm.prank(personalAccount);
        vm.expectRevert(
            abi.encodeWithSelector(IPersonalAccount.UnknownBridgeRoute.selector, destinationEid)
        );
        IPersonalAccount(personalAccount).sendCrossChainUserOp{value: messagingFee}(
            destinationEid, _transferBatch(makeAddr("token"), makeAddr("dest"), 1e18),
            bytes32("op-x"), uint64(block.timestamp + 1 hours), ""
        );
    }

    function testSuspendingSubaccountTypeRouteBlocksOnlyThatType() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        vm.prank(governance);
        vm.expectEmit();
        emit IBridgeRoutesFacet.SubaccountTypeRouteSuspended(SUBACCOUNT_TYPE_LOAN, true);
        controller.setSubaccountTypeRouteSuspended(SUBACCOUNT_TYPE_LOAN, true);

        // the type's forward moves stop; the chain pin, the route itself, and the Personal
        // Account's cross-chain user operations over it, are untouched
        vm.deal(personalAccount, 2 * messagingFee);
        vm.prank(personalAccount);
        vm.expectRevert(IBridgingSubaccount.BridgeRouteNotConfigured.selector);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
        vm.prank(personalAccount);
        IPersonalAccount(personalAccount).sendCrossChainUserOp{value: messagingFee}(
            destinationEid, _transferBatch(makeAddr("token"), makeAddr("dest"), 1e18),
            bytes32("op-x"), uint64(block.timestamp + 1 hours), ""
        );

        // the pin survives the suspension, and resuming needs no re-pinning
        (uint32 pinnedEid, bool suspended) =
            controller.getSubaccountTypeRoutePin(SUBACCOUNT_TYPE_LOAN);
        assertEq(pinnedEid, destinationEid);
        assertTrue(suspended);
        vm.prank(governance);
        controller.setSubaccountTypeRouteSuspended(SUBACCOUNT_TYPE_LOAN, false);
        vm.prank(personalAccount);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
    }

    function testSubaccountTypeRouteIsWriteOnce() public {
        // a type's signed instructions carry no destination, so its chain must never move
        // under them: a second chain is a second type
        _configureLoanBridge();
        uint32 baseEid = 30184;
        bytes32 basePeer = bytes32(uint256(uint160(makeAddr("baseAdapter"))));
        fxrpOft.setPeer(baseEid, basePeer);
        vm.startPrank(governance);
        controller.setBridgeRoute(baseEid, basePeer);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBridgeRoutesFacet.SubaccountTypeRoutePinned.selector,
                SUBACCOUNT_TYPE_LOAN,
                destinationEid
            )
        );
        controller.setSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN, baseEid);

        // re-pinning the same route is a no-op, so a retried timelocked call is harmless - even
        // while that route is cleared, since the pin is checked before the route
        controller.setSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN, destinationEid);
        controller.setBridgeRoute(destinationEid, bytes32(0));
        controller.setSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN, destinationEid);
        controller.setBridgeRoute(destinationEid, destinationPeer);
        // and an unregistered endpoint id is refused as a re-point, not as an unknown route
        vm.expectRevert(
            abi.encodeWithSelector(
                IBridgeRoutesFacet.SubaccountTypeRoutePinned.selector,
                SUBACCOUNT_TYPE_LOAN,
                destinationEid
            )
        );
        controller.setSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN, 40999);
        // a suspension is not a way around it either
        controller.setSubaccountTypeRouteSuspended(SUBACCOUNT_TYPE_LOAN, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBridgeRoutesFacet.SubaccountTypeRoutePinned.selector,
                SUBACCOUNT_TYPE_LOAN,
                destinationEid
            )
        );
        controller.setSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN, baseEid);
        // and an unpinned type cannot be suspended at all
        vm.expectRevert(
            abi.encodeWithSelector(IBridgeRoutesFacet.UnknownBridgeRoute.selector, uint32(0))
        );
        controller.setSubaccountTypeRouteSuspended(9, true);
        vm.stopPrank();
        (uint32 pinnedEid, ) = controller.getSubaccountTypeRoutePin(SUBACCOUNT_TYPE_LOAN);
        assertEq(pinnedEid, destinationEid);
    }

    function testSetFxrpOftRotationRevalidatesRoutes() public {
        _configureLoanBridge();

        // a replacement adapter must carry every registered route, or the rotation fails at the
        // timelocked call instead of stranding the route in the field
        MockOft rotated = new MockOft(fxrp, messagingFee);
        rotated.setEndpoint(lzEndpoint);
        vm.prank(governance);
        vm.expectRevert(IBridgeRoutesFacet.InvalidDestinationPeer.selector);
        controller.setFxrpOft(address(rotated));

        rotated.setPeer(destinationEid, destinationPeer);
        vm.prank(governance);
        controller.setFxrpOft(address(rotated));
        assertEq(controller.getFxrpOft(), address(rotated));
        (address oft, , ) = controller.getSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN);
        assertEq(oft, address(rotated));
    }

    function testInboundComposeIsBoundToTheTypesOwnRoute() public {
        // the bridge-back of a type is authenticated against that type's route: a redeem-home
        // packet from the other type's chain is rejected, one from its own chain redeems
        uint32 baseEid = 30184;
        bytes32 basePeer = bytes32(uint256(uint160(makeAddr("baseFxrpOft"))));
        uint256 baseType = 2;
        _configureLoanBridge();
        fxrpOft.setPeer(baseEid, basePeer);
        vm.startPrank(governance);
        controller.setBridgeRoute(baseEid, basePeer);
        controller.setSubaccountImplementation(baseType, address(new LoanSubaccount()));
        controller.setSubaccountTypeRoute(baseType, baseEid);
        vm.stopPrank();
        _createSubaccountFor(xrplOwner);
        address baseSubaccount = controller.createSubaccount(xrplOwner, baseType);
        fxrp.mint(baseSubaccount, 100e6);
        bytes memory payload = _redeemHomePayloadAt(uint64(block.timestamp + 1 hours));
        bytes memory composeFrom = abi.encodePacked(bytes32(uint256(uint160(baseSubaccount))), payload);

        // from Ethereum (the loan type's chain): wrong source for a Base-typed account
        (bytes memory fromEthereum, bytes32 ethereumGuid) = _composeFromLoanChain(baseSubaccount, 1, 100e6, payload);
        vm.deal(lzEndpoint, 2 * executorFee);
        vm.prank(lzEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IComposeReceiverAccountBase.WrongSourceEid.selector, destinationEid)
        );
        ILoanSubaccount(baseSubaccount).lzCompose{value: executorFee}(
            address(fxrpOft), ethereumGuid, fromEthereum, executor, ""
        );

        // from Base, sent by the pinned Base peer: authenticated and redeemed
        bytes memory fromBase = OFTComposeMsgCodec.encode(1, baseEid, 100e6, composeFrom);
        bytes32 baseGuid = GUID.generate(
            1, baseEid, address(uint160(uint256(basePeer))), flareEid,
            bytes32(uint256(uint160(address(fxrpOft))))
        );
        vm.prank(lzEndpoint);
        ILoanSubaccount(baseSubaccount).lzCompose{value: executorFee}(
            address(fxrpOft), baseGuid, fromBase, executor, ""
        );
        assertEq(fxrp.balanceOf(baseSubaccount), 0);
    }

    function testSubaccountTypesBridgeToTheirOwnChains() public {
        // two types on two remote chains behind one adapter: each type sends to its own route,
        // and the Personal Account may name either
        uint32 baseEid = 30184;
        bytes32 basePeer = bytes32(uint256(uint160(makeAddr("baseFxrpOft"))));
        uint256 baseType = 2;
        _configureLoanBridge();
        fxrpOft.setPeer(baseEid, basePeer);
        vm.startPrank(governance);
        controller.setBridgeRoute(baseEid, basePeer);
        controller.setSubaccountImplementation(baseType, address(new LoanSubaccount()));
        controller.setSubaccountTypeRoute(baseType, baseEid);
        vm.stopPrank();
        (uint32[] memory eids, ) = controller.getBridgeRoutes();
        assertEq(eids.length, 2);

        address loanSubaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        address baseSubaccount = controller.createSubaccount(xrplOwner, baseType);
        assertTrue(baseSubaccount != loanSubaccount);
        fxrp.mint(loanSubaccount, 100e6);
        fxrp.mint(baseSubaccount, 40e6);
        vm.deal(personalAccount, 4 * messagingFee);

        vm.prank(personalAccount);
        ILoanSubaccount(loanSubaccount).depositCollateral{value: messagingFee}(100e6, "");
        (uint32 sentDstEid, bytes32 to, uint256 amountLD,,,,) = fxrpOft.lastSendParam();
        assertEq(sentDstEid, destinationEid);
        assertEq(to, bytes32(uint256(uint160(loanSubaccount))));
        assertEq(amountLD, 100e6);

        vm.prank(personalAccount);
        ILoanSubaccount(baseSubaccount).depositCollateral{value: messagingFee}(40e6, "");
        (sentDstEid, to, amountLD,,,,) = fxrpOft.lastSendParam();
        assertEq(sentDstEid, baseEid);
        assertEq(to, bytes32(uint256(uint160(baseSubaccount))));
        assertEq(amountLD, 40e6);

        // the Personal Account picks the chain per instruction
        IPersonalAccount.Call[] memory batch = _transferBatch(makeAddr("token"), makeAddr("dest"), 1e18);
        vm.prank(personalAccount);
        IPersonalAccount(personalAccount).sendCrossChainUserOp{value: messagingFee}(
            baseEid, batch, bytes32("op-x"), uint64(block.timestamp + 1 hours), ""
        );
        (sentDstEid, to,,,,,) = fxrpOft.lastSendParam();
        assertEq(sentDstEid, baseEid);
        assertEq(to, bytes32(uint256(uint160(personalAccount))));

        // an unregistered chain is refused before any fee is paid
        vm.prank(personalAccount);
        vm.expectRevert(abi.encodeWithSelector(IPersonalAccount.UnknownBridgeRoute.selector, uint32(30110)));
        IPersonalAccount(personalAccount).sendCrossChainUserOp{value: messagingFee}(
            30110, batch, bytes32("op-y"), uint64(block.timestamp + 1 hours), ""
        );
    }

    function testSweepRedeemWorksWhilePaused() public {
        // the redemption exit stays open during incidents: assets can always exit toward the
        // user on this chain, while the forward moves wait out the pause
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);

        address pauser = makeAddr("pauser");
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        vm.prank(governance);
        controller.addPausers(pausers);
        vm.prank(pauser);
        controller.pause();

        vm.deal(address(this), executorFee);
        (uint256 amount,) = ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        assertEq(amount, 100e6);
    }

    function testPermissionlessPaCreationUnblocksPreParentRecovery() public {
        // the pre-PA recovery path: sweepRedeem at or above the FAssets minimum needs parent
        // code, and anyone can materialize the parent with the permissionless creation route -
        // no instruction machinery, no user involvement
        address subaccount = controller.createSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        fxrp.mint(subaccount, 250e6);
        mockAssetManager.setMinimumRedeemAmountUBA(10e6);

        vm.deal(address(this), 2 * executorFee);
        vm.expectRevert();
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();

        vm.prank(makeAddr("anyone"));
        address parent = controller.createPersonalAccount(xrplOwner);
        (uint256 amount, uint256 redeemed) =
            ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        assertEq(amount, 250e6);
        assertEq(redeemed, 250e6);
        assertEq(fxrp.balanceOf(parent), 0);
    }

    //
    // the loan instructions: borrow, depositCollateral and withdraw (forward moves with typed payloads)
    //

    function testBorrowBridgesExactAmountWithTypedPayload() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        // more on the balance than the signed amount: the residue stays for the cleanup rails
        fxrp.mint(subaccount, 250e6);
        uint256 amount = 100e6;
        _configureLoanBridge();

        bytes32 destination = bytes32(uint256(uint160(makeAddr("exchangeDeposit"))));
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory extraOptions = _canonicalLoanOptions();
        vm.deal(personalAccount, messagingFee);
        vm.expectEmit();
        emit ILoanSubaccount.BorrowInstructionSent(
            personalAccount, bytes32("op-1"), amount, 500e18, DESTINATION_KIND_EVM, destination,
            destinationEid, fxrpOft.GUID()
        );
        vm.prank(personalAccount);
        ILoanSubaccount(subaccount).borrow{value: messagingFee}(
            amount, 500e18, DESTINATION_KIND_EVM, destination, bytes32("op-1"), deadline, extraOptions
        );

        // exactly the signed amount left; the adapter locked it; no standing approval remains
        assertEq(fxrp.balanceOf(subaccount), 150e6);
        assertEq(fxrp.balanceOf(address(fxrpOft)), amount);
        assertEq(fxrp.allowance(subaccount, address(fxrpOft)), 0);

        // destination is this account's own address; the payload is the typed borrow schema
        // the loan-chain twin decodes, built here rather than passed in
        (uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD,,,) = fxrpOft.lastSendParam();
        assertEq(dstEid, destinationEid);
        assertEq(to, bytes32(uint256(uint160(subaccount))));
        assertEq(amountLD, amount);
        assertEq(minAmountLD, amount);
        (,,,, bytes memory extraOptionsSent, bytes memory composeMsgSent,) = fxrpOft.lastSendParam();
        assertEq(extraOptionsSent, extraOptions);
        assertEq(
            composeMsgSent,
            abi.encode(
                PAYLOAD_VERSION_1,
                ACTION_BORROW,
                abi.encode(
                    bytes32("op-1"), deadline, DESTINATION_KIND_EVM, destination,
                    uint256(500e18)
                )
            )
        );
        assertEq(fxrpOft.lastValue(), messagingFee);
    }

    function testBorrowAgainstExistingCollateralIsMessageOnly() public {
        // a zero collateral amount carries only the instruction: the account's balance is
        // untouched and the loan chain borrows against the existing position
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        vm.deal(personalAccount, messagingFee);
        vm.prank(personalAccount);
        ILoanSubaccount(subaccount).borrow{value: messagingFee}(
            0, 300e18, DESTINATION_KIND_EVM, bytes32(uint256(uint160(makeAddr("dest")))),
            bytes32("op-1"), uint64(block.timestamp + 1 hours), ""
        );

        assertEq(fxrp.balanceOf(subaccount), 100e6);
        assertEq(fxrp.balanceOf(address(fxrpOft)), 0);
        (,, uint256 amountLD,,,,) = fxrpOft.lastSendParam();
        assertEq(amountLD, 0);
    }

    function testBorrowAllowsParentAsDestination() public {
        // the parent Personal Account is a functional account on the loan chain (the
        // compose-driven remote account), so disbursing into it is a legitimate user choice
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        _configureLoanBridge();

        vm.deal(personalAccount, messagingFee);
        vm.prank(personalAccount);
        ILoanSubaccount(subaccount).borrow{value: messagingFee}(
            0, 300e18, DESTINATION_KIND_EVM, bytes32(uint256(uint160(personalAccount))),
            bytes32("op-1"), uint64(block.timestamp + 1 hours), ""
        );
        (,,,,, bytes memory composeMsgSent,) = fxrpOft.lastSendParam();
        (, , bytes memory actionData) = abi.decode(composeMsgSent, (uint8, uint8, bytes));
        (, , , bytes32 destination, ) = abi.decode(actionData, (bytes32, uint64, uint8, bytes32, uint256));
        assertEq(destination, bytes32(uint256(uint160(personalAccount))));
    }

    function testDepositCollateralBridgesExactAmountWithTypedPayload() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 250e6);
        _configureLoanBridge();

        // the pure collateral deposit is its own instruction and action: exactly the signed
        // amount travels, with the deposit schema the loan-chain twin decodes
        vm.deal(personalAccount, messagingFee);
        vm.expectEmit();
        emit ILoanSubaccount.CollateralDepositInstructionSent(
            personalAccount, 100e6, destinationEid, fxrpOft.GUID()
        );
        vm.prank(personalAccount);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");

        assertEq(fxrp.balanceOf(subaccount), 150e6);
        assertEq(fxrp.balanceOf(address(fxrpOft)), 100e6);
        (,, uint256 amountLD,,, bytes memory composeMsgSent,) = fxrpOft.lastSendParam();
        assertEq(amountLD, 100e6);
        assertEq(
            composeMsgSent,
            abi.encode(PAYLOAD_VERSION_1, ACTION_DEPOSIT_COLLATERAL, bytes(""))
        );
    }

    function testWithdrawIsMessageOnlyWithTypedPayload() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();
        uint64 deadline = uint64(block.timestamp + 1 hours);

        vm.deal(personalAccount, messagingFee);
        vm.expectEmit();
        emit ILoanSubaccount.WithdrawInstructionSent(
            personalAccount, bytes32("op-w"), 30e6, destinationEid, fxrpOft.GUID()
        );
        vm.prank(personalAccount);
        ILoanSubaccount(subaccount).withdraw{value: messagingFee}(
            30e6, bytes32("op-w"), deadline, _withdrawOptions()
        );

        // nothing travels but the instruction; the signed return options ride in the payload
        assertEq(fxrp.balanceOf(subaccount), 100e6);
        (,, uint256 amountLD,,, bytes memory composeMsgSent,) = fxrpOft.lastSendParam();
        assertEq(amountLD, 0);
        assertEq(
            composeMsgSent,
            abi.encode(
                PAYLOAD_VERSION_1,
                ACTION_WITHDRAW,
                abi.encode(
                    bytes32("op-w"), deadline, uint256(30e6), _withdrawOptions().minComposeValue,
                    _withdrawOptions().returnOptions
                )
            )
        );
    }

    function testLoanInstructionsAcceptDeadlineEqualToNow() public {
        // the boundary is inclusive on both chains: the loan chain executes an instruction
        // whose deadline equals its block time and skips only once past it, so the source
        // must not reject the same deadline before the fee is paid
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();
        uint64 deadline = uint64(block.timestamp);
        vm.deal(personalAccount, 2 * messagingFee);

        vm.startPrank(personalAccount);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
        ILoanSubaccount(subaccount).withdraw{value: messagingFee}(
            30e6, bytes32("op-w"), deadline, _withdrawOptions()
        );
        vm.stopPrank();
        (,,,,, bytes memory composeMsgSent,) = fxrpOft.lastSendParam();
        assertEq(
            composeMsgSent,
            abi.encode(
                PAYLOAD_VERSION_1,
                ACTION_WITHDRAW,
                abi.encode(
                    bytes32("op-w"), deadline, uint256(30e6), _withdrawOptions().minComposeValue,
                    _withdrawOptions().returnOptions
                )
            )
        );
    }

    function testForwardMoveRevertAmountExceedsBalance() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 40e6);
        _configureLoanBridge();

        vm.deal(personalAccount, messagingFee);
        vm.prank(personalAccount);
        vm.expectRevert(
            abi.encodeWithSelector(IBridgingSubaccount.AmountExceedsBalance.selector, 100e6, 40e6)
        );
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
    }

    function testInstructionRefundFailureRevertsTheInstruction() public {
        // the excess refund goes to the caller - the parent Personal Account - and a parent that
        // cannot receive native must not leave the excess stranded here (this account has no
        // native exit), so the whole instruction reverts and stays retriable with the exact fee
        MockNativeRejectingParent rejectingParent = new MockNativeRejectingParent();
        address subaccount = address(new SubaccountProxy(
            address(controller), address(rejectingParent), SUBACCOUNT_TYPE_LOAN
        ));
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();
        vm.deal(address(rejectingParent), 2 * messagingFee);

        bytes memory withdrawCall = abi.encodeCall(
            ILoanSubaccount.withdraw,
            (30e6, bytes32("op-w"), uint64(block.timestamp + 1 hours), _withdrawOptions())
        );
        vm.expectRevert(IBridgingSubaccount.RefundFailed.selector);
        rejectingParent.callWithValue(subaccount, 2 * messagingFee, withdrawCall);

        // exactly the quoted fee still goes through: nothing is stranded and nothing is lost
        rejectingParent.callWithValue(subaccount, messagingFee, withdrawCall);
        assertEq(address(subaccount).balance, 0);
        assertEq(address(rejectingParent).balance, messagingFee);
    }

    function testInitializeValidatesItsArgumentsOnAClearedAccount() public {
        // defense in depth: the proxy always passes its own constructor arguments, and it
        // resolves the implementation through the controller first, so these guards cannot be
        // reached in production. Clearing the controller slot re-opens `initialize` on a live
        // account, which is the only way to exercise them.
        address subaccount = address(_deploySubaccount());
        vm.store(subaccount, bytes32(0), bytes32(0));

        vm.expectRevert(IControlledAccount.InvalidControllerAddress.selector);
        ISubaccount(subaccount).initialize(address(0), parentPersonalAccount, SUBACCOUNT_TYPE_LOAN);

        vm.expectRevert(ISubaccount.InvalidParentPersonalAccount.selector);
        ISubaccount(subaccount).initialize(address(controller), address(0), SUBACCOUNT_TYPE_LOAN);

        vm.expectRevert(ISubaccountsFacet.InvalidSubaccountType.selector);
        ISubaccount(subaccount).initialize(
            address(controller), parentPersonalAccount, SUBACCOUNT_TYPE_NONE
        );
    }

    function testLoanInstructionsRevertOnlyParent() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        // the instruction names a loan action and, for a borrow, its destination, so only the
        // user - through the parent Personal Account - may send it
        vm.deal(address(this), 2 * messagingFee);
        vm.expectRevert(ISubaccount.OnlyParent.selector);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
        vm.expectRevert(ISubaccount.OnlyParent.selector);
        ILoanSubaccount(subaccount).withdraw{value: messagingFee}(
            1e6, bytes32("op-1"), uint64(block.timestamp + 1 hours), _withdrawOptions()
        );
    }

    function testLoanInstructionsRevertInvalidArguments() public {
        // arguments that could never execute on the loan chain fail here, before any bridge
        // fee is paid
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 destination = bytes32(uint256(uint160(makeAddr("dest"))));
        vm.deal(personalAccount, 10 * messagingFee);
        vm.startPrank(personalAccount);

        // nothing to collateralize or borrow
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        ILoanSubaccount(subaccount).borrow{value: messagingFee}(
            100e6, 0, DESTINATION_KIND_EVM, destination, bytes32("op-1"), deadline, ""
        );
        // deposit: zero amount (it carries no operation id and no deadline to check)
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(0, "");
        // a disbursement needs the EVM kind and a clean, non-zero destination other than
        // the subaccount itself
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        ILoanSubaccount(subaccount).borrow{value: messagingFee}(
            0, 300e18, 2, destination, bytes32("op-1"), deadline, ""
        );
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        ILoanSubaccount(subaccount).borrow{value: messagingFee}(
            0, 300e18, DESTINATION_KIND_EVM, bytes32(0), bytes32("op-1"), deadline, ""
        );
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        ILoanSubaccount(subaccount).borrow{value: messagingFee}(
            0, 300e18, DESTINATION_KIND_EVM, bytes32(uint256(uint160(subaccount))),
            bytes32("op-1"), deadline, ""
        );
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        ILoanSubaccount(subaccount).borrow{value: messagingFee}(
            0, 300e18, DESTINATION_KIND_EVM, destination | bytes32(uint256(1) << 200),
            bytes32("op-1"), deadline, ""
        );
        // a zero withdrawal
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        ILoanSubaccount(subaccount).withdraw{value: messagingFee}(
            0, bytes32("op-1"), deadline, _withdrawOptions()
        );
        // a zero delivery-value floor would let anyone consume the packet with the prepaid
        // return fee undelivered
        vm.expectRevert(ILoanSubaccount.InvalidLoanInstruction.selector);
        ILoanSubaccount(subaccount).withdraw{value: messagingFee}(
            30e6, bytes32("op-1"), deadline,
            ILoanSubaccount.WithdrawOptions({
                destinationOptions: "",
                returnOptions: hex"0003",
                minComposeValue: 0
            })
        );
        vm.stopPrank();
    }

    function testForwardMoveRefundsExcessToParent() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        uint256 sent = messagingFee + 1 ether;
        vm.deal(personalAccount, sent);
        vm.prank(personalAccount);
        ILoanSubaccount(subaccount).depositCollateral{value: sent}(100e6, "");

        // only the fee was forwarded; the excess came back to the parent, not stranded here
        assertEq(fxrpOft.lastValue(), messagingFee);
        assertEq(fxrpOft.lastRefundAddress(), personalAccount);
        assertEq(personalAccount.balance, sent - messagingFee);
        assertEq(subaccount.balance, 0);
    }

    function testBorrowViaXrplInstruction() public {
        // the full production path: XRPL memo -> controller -> parent PA -> loan instruction
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 destination = bytes32(uint256(uint160(makeAddr("exchangeDeposit"))));

        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({
            target: subaccount,
            value: messagingFee,
            data: abi.encodeCall(
                ILoanSubaccount.borrow,
                (
                    100e6, 500e18, DESTINATION_KIND_EVM, destination, bytes32("op-1"),
                    deadline, _canonicalLoanOptions()
                )
            )
        });
        _executeUserOpWithValue(personalAccount, calls, bytes32("dmLoanCall"), messagingFee);

        assertEq(fxrp.balanceOf(address(fxrpOft)), 100e6);
        (,,,,, bytes memory composeMsgSent,) = fxrpOft.lastSendParam();
        assertEq(
            composeMsgSent,
            abi.encode(
                PAYLOAD_VERSION_1,
                ACTION_BORROW,
                abi.encode(
                    bytes32("op-1"), deadline, DESTINATION_KIND_EVM, destination,
                    uint256(500e18)
                )
            )
        );
    }

    function testLoanInstructionAtomicMintFundExecuteInOneTransaction() public {
        // the primary loan flow, all in ONE handleMintedFAssets transaction: FAssets mints and
        // funds the Personal Account, and the user operation creates the subaccount, funds it
        // and sends the borrow instruction. The subaccount balance never exists outside this
        // transaction, so the permissionless `sweepRedeem` has nothing to front-run.
        address personalAccount = _createPersonalAccount(xrplOwner);
        _configureLoanBridge();
        address subaccount = controller.getSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertEq(subaccount.code.length, 0);

        uint256 loanAmount = 100e6;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 destination = bytes32(uint256(uint160(makeAddr("exchangeDeposit"))));
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](3);
        calls[0] = IPersonalAccount.Call({
            target: address(controller),
            value: 0,
            data: abi.encodeCall(
                ISubaccountsFacet.createSubaccount, (xrplOwner, SUBACCOUNT_TYPE_LOAN)
            )
        });
        calls[1] = IPersonalAccount.Call({
            target: address(fxrp),
            value: 0,
            data: abi.encodeCall(fxrp.transfer, (subaccount, loanAmount))
        });
        calls[2] = IPersonalAccount.Call({
            target: subaccount,
            value: messagingFee,
            data: abi.encodeCall(
                ILoanSubaccount.borrow,
                (
                    loanAmount, 500e18, DESTINATION_KIND_EVM, destination, bytes32("op-1"),
                    deadline, _canonicalLoanOptions()
                )
            )
        });

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: personalAccount,
            nonce: controller.getNonce(personalAccount),
            initCode: "",
            callData: abi.encodeCall(IPersonalAccount.executeUserOp, (calls)),
            accountGasLimits: 0,
            preVerificationGas: 0,
            gasFees: 0,
            paymasterAndData: "",
            signature: ""
        });
        bytes memory memoData = abi.encodePacked(
            uint8(0xFF), uint8(1), uint64(0), abi.encode(userOp)
        );
        // the minted FXRP arrives at the controller with the memo, exactly as in production
        fxrp.mint(address(controller), loanAmount);
        vm.deal(assetManagerFxrpMock, messagingFee);
        vm.prank(assetManagerFxrpMock);
        controller.handleMintedFAssets{value: messagingFee}(
            bytes32("dmAtomicLoan"), xrplOwner, loanAmount, 0, memoData, executor, ""
        );

        // created, funded, drained into the bridge - nothing remains at any intermediate stop
        assertNotEq(subaccount.code.length, 0);
        assertEq(fxrp.balanceOf(personalAccount), 0);
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(fxrp.balanceOf(address(fxrpOft)), loanAmount);
        (,, uint256 amountLD,,,,) = fxrpOft.lastSendParam();
        assertEq(amountLD, loanAmount);
    }

    function testForwardMoveRevertWhenPaused() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        address pauser = makeAddr("pauser");
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        vm.prank(governance);
        controller.addPausers(pausers);
        vm.prank(pauser);
        controller.pause();

        // even on a direct parent call, outside the paused instruction pipeline, the forward
        // move is blocked: it is the incident-containment surface
        vm.deal(personalAccount, messagingFee);
        vm.prank(personalAccount);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
    }

    function testForwardMoveRevertBridgeRouteNotConfigured() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);

        vm.deal(personalAccount, messagingFee);
        vm.prank(personalAccount);
        vm.expectRevert(IBridgingSubaccount.BridgeRouteNotConfigured.selector);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
    }

    function testForwardMoveRevertWhenPeerMutatedAfterConfiguration() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        // fail-closed like every forward move: the guards are shared by construction
        fxrpOft.setPeer(destinationEid, bytes32(uint256(0xbad)));

        vm.deal(personalAccount, messagingFee);
        vm.prank(personalAccount);
        vm.expectRevert(IBridgingSubaccount.WrongDestinationPeer.selector);
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
    }

    function testForwardMoveRevertInsufficientFundsForSweep() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        vm.deal(personalAccount, messagingFee);
        vm.prank(personalAccount);
        vm.expectRevert(
            abi.encodeWithSelector(IBridgingSubaccount.InsufficientFundsForSweep.selector, messagingFee)
        );
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee - 1}(100e6, "");
    }

    function testForwardMoveRevertOnEmptyBalance() public {
        // an empty account can still send message-only instructions, but any positive
        // collateral amount exceeds the balance
        address subaccount = _createSubaccountFor(xrplOwner);
        address personalAccount = _personalAccountOf(xrplOwner);
        _configureLoanBridge();

        vm.deal(personalAccount, messagingFee);
        vm.prank(personalAccount);
        vm.expectRevert(
            abi.encodeWithSelector(IBridgingSubaccount.AmountExceedsBalance.selector, 100e6, 0)
        );
        ILoanSubaccount(subaccount).depositCollateral{value: messagingFee}(100e6, "");
    }

    function testGetSubaccountDifferentOwnersGetDifferentAddresses() public view {
        address subaccount1 = controller.getSubaccount(
            "rOwner1",
            SUBACCOUNT_TYPE_LOAN
        );
        address subaccount2 = controller.getSubaccount(
            "rOwner2",
            SUBACCOUNT_TYPE_LOAN
        );

        assertNotEq(subaccount1, subaccount2);
    }

    function testLoanImplementationForTypeReturnsConfiguredImplementation() public view {
        assertEq(
            controller.implementationForType(SUBACCOUNT_TYPE_LOAN),
            address(loanImpl)
        );
    }

    function testLoanImplementationForTypeReturnsZeroForUnconfiguredType() public view {
        assertEq(
            controller.implementationForType(SUBACCOUNT_TYPE_NONE),
            address(0)
        );
    }

    //
    // helpers
    //

    function _deployDiamond() private returns (IIMasterAccountController _controller) {
        if (baseCuts.length == 0) {
            IDiamond.FacetCut[] memory deployedBaseCuts = deployBaseFacets();
            for (uint256 i = 0; i < deployedBaseCuts.length; i++) {
                baseCuts.push(deployedBaseCuts[i]);
            }
        }
        DiamondArgs memory args = DiamondArgs({
            owner: initialOwner,
            initAddress: address(0),
            initCalldata: ""
        });
        bytes memory bytecode = abi.encodePacked(
            type(MasterAccountController).creationCode,
            abi.encode(baseCuts, args)
        );
        // salt from the nonce so repeated deployments (fresh diamonds) get unique addresses
        address deployed = IISingletonFactory(SINGLETON_FACTORY).deploy(
            bytecode,
            keccak256(abi.encode("diamond", vm.getNonce(address(this))))
        );
        _controller = IIMasterAccountController(deployed);

        IDiamond.FacetCut[] memory smartAccountsCuts = deploySmartAccountsFacets();
        MasterAccountControllerInit init = new MasterAccountControllerInit();
        vm.prank(initialOwner);
        _controller.diamondCut(
            smartAccountsCuts,
            address(init),
            abi.encodeWithSelector(
                MasterAccountControllerInit.init.selector,
                executor,
                executorFee,
                sourceId,
                paymentProofValidityDurationSeconds,
                defaultInstructionFee,
                personalAccountImplementation
            )
        );

        vm.prank(initialOwner);
        _controller.transferOwnership(governance);
    }

    function _addAgentVault(IIMasterAccountController _controller) private {
        uint256[] memory agentVaultIds = new uint256[](1);
        address[] memory agentVaultAddresses = new address[](1);
        agentVaultIds[0] = 1;
        agentVaultAddresses[0] = agent;
        vm.prank(governance);
        _controller.addAgentVaults(agentVaultIds, agentVaultAddresses);
    }

    function _createPersonalAccount(string memory _xrplOwner) private returns (address) {
        return _createPersonalAccountOn(controller, _xrplOwner);
    }

    function _createPersonalAccountOn(
        IIMasterAccountController _controller,
        string memory _xrplOwner
    )
        private
        returns (address _personalAccount)
    {
        // FXRP collateral reservation instruction (type 0, command 0), wallet id 0, 1 lot, agent vault id 1
        bytes32 paymentReference =
            (bytes32(uint256(1)) << 160) | // value (lots)
            (bytes32(uint256(1)) << 144); // agent vault id
        _controller.reserveCollateral{value: collateralReservationFee + executorFee}(
            _xrplOwner,
            paymentReference,
            bytes32("tx1")
        );
        _personalAccount = _controller.getPersonalAccount(_xrplOwner);
        assertNotEq(_personalAccount.code.length, 0);
    }

    /// Drives an XRPL-signed instruction through the direct-minting memo path (opcode 0xFF),
    /// which executes the user operation on the Personal Account.
    function _executeUserOp(
        address _personalAccount,
        IPersonalAccount.Call[] memory _calls,
        bytes32 _transactionId
    )
        private
    {
        _executeUserOpWithValue(_personalAccount, _calls, _transactionId, 0);
    }

    function _executeUserOpExpectRevert(
        address _personalAccount,
        IPersonalAccount.Call[] memory _calls,
        bytes32 _transactionId,
        bytes memory _expectedRevert
    )
        private
    {
        _executeUserOpWithValue(_personalAccount, _calls, _transactionId, 0, _expectedRevert);
    }

    function _executeUserOpWithValue(
        address _personalAccount,
        IPersonalAccount.Call[] memory _calls,
        bytes32 _transactionId,
        uint256 _value
    )
        private
    {
        _executeUserOpWithValue(_personalAccount, _calls, _transactionId, _value, "");
    }

    function _executeUserOpWithValue(
        address _personalAccount,
        IPersonalAccount.Call[] memory _calls,
        bytes32 _transactionId,
        uint256 _value,
        bytes memory _expectedRevert
    )
        private
    {
        uint64 memoFee = 0;
        uint256 amount = 5_000;
        fxrp.mint(address(controller), amount);

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: _personalAccount,
            nonce: controller.getNonce(_personalAccount),
            initCode: "",
            callData: abi.encodeCall(IPersonalAccount.executeUserOp, (_calls)),
            accountGasLimits: 0,
            preVerificationGas: 0,
            gasFees: 0,
            paymasterAndData: "",
            signature: ""
        });
        bytes memory memoData = abi.encodePacked(
            uint8(0xFF), uint8(1), memoFee, abi.encode(userOp)
        );

        vm.deal(assetManagerFxrpMock, _value);
        if (_expectedRevert.length > 0) {
            vm.expectRevert(_expectedRevert);
        }
        vm.prank(assetManagerFxrpMock);
        controller.handleMintedFAssets{value: _value}(
            _transactionId, xrplOwner, amount, 0, memoData, executor, ""
        );
    }

    function _createSubaccountFor(string memory _xrplOwner) private returns (address) {
        _createPersonalAccount(_xrplOwner);
        return controller.createSubaccount(
            _xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function _configureLoanBridge() private {
        fxrpOft.setPeer(destinationEid, destinationPeer);
        vm.startPrank(governance);
        controller.setFxrpOft(address(fxrpOft));
        controller.setBridgeRoute(destinationEid, destinationPeer);
        controller.setSubaccountTypeRoute(SUBACCOUNT_TYPE_LOAN, destinationEid);
        vm.stopPrank();
    }

    function _deploySubaccount() private returns (LoanSubaccount) {
        SubaccountProxy proxy = new SubaccountProxy(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
        return LoanSubaccount(payable(address(proxy)));
    }

    function _mockGetContractAddressByHash(string memory _name, address _addr) private {
        vm.mockCall(
            contractRegistryMock,
            abi.encodeWithSelector(
                IFlareContractRegistry.getContractAddressByHash.selector,
                keccak256(abi.encode(_name))
            ),
            abi.encode(_addr)
        );
    }

    function _mockGetAgentInfo(address _agent, AgentInfo.Info memory _info) private {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(IAssetManager.getAgentInfo.selector, _agent),
            abi.encode(_info)
        );
    }

    function _mockCollateralReservationFee(uint256 _fee) private {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(IAssetManager.collateralReservationFee.selector),
            abi.encode(_fee)
        );
    }

    function _mockReserveCollateral(uint256 _reservationId) private {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(IAssetManager.reserveCollateral.selector),
            abi.encode(_reservationId)
        );
    }

    function _mockGetDirectMintingExecutorFeeUBA(uint256 _fee) private {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSignature("getDirectMintingExecutorFeeUBA()"),
            abi.encode(_fee)
        );
    }

    function _deliverRedeemHome(
        address _subaccount,
        uint64 _nonce,
        uint256 _amountLD,
        uint256 _value
    )
        private
    {
        (bytes memory message, bytes32 guid) =
            _composeFromLoanChain(_subaccount, _nonce, _amountLD, _redeemHomePayload());
        vm.deal(lzEndpoint, _value);
        vm.prank(lzEndpoint);
        ILoanSubaccount(_subaccount).lzCompose{value: _value}(address(fxrpOft), guid, message, executor, "");
    }

    function _personalAccountOf(string memory _xrplOwner) private view returns (address) {
        return controller.getPersonalAccount(_xrplOwner);
    }

    /// The redeem-home payload as the loan-chain twin stamps it: its block time plus the TTL.
    function _redeemHomePayload() private view returns (bytes memory) {
        return _redeemHomePayloadAt(uint64(block.timestamp) + REDEEM_HOME_TTL);
    }

    /// The compose the loan-chain twin's bridge-back arrives as: canonical wrapper, source = the
    /// loan chain, composeFrom = the account itself, guid as Flare's endpoint computes it for a
    /// packet from the pinned peer.
    function _composeFromLoanChain(
        address _subaccount,
        uint64 _nonce,
        uint256 _amountLD,
        bytes memory _payload
    )
        private view
        returns (bytes memory _message, bytes32 _guid)
    {
        _message = OFTComposeMsgCodec.encode(
            _nonce, destinationEid, _amountLD,
            abi.encodePacked(bytes32(uint256(uint160(_subaccount))), _payload)
        );
        _guid = GUID.generate(
            _nonce, destinationEid, address(uint160(uint256(destinationPeer))), flareEid,
            bytes32(uint256(uint160(address(fxrpOft))))
        );
    }

    /// Canonical type-3 options - destination lzReceive gas plus index-0 lzCompose gas -
    /// validated against the live FXRP adapter's `quoteSend`. Byte-identical to LayerZero's
    /// `OptionsBuilder.newOptions().addExecutorLzReceiveOption(150_000, 0)
    /// .addExecutorLzComposeOption(0, 700_000, 0)`, kept inline to avoid two test-only
    /// dependencies. The gas VALUES are mock-only; deployment must profile them per action
    /// against the real Morpho, oracle and token contracts (release checklist).
    function _canonicalLoanOptions() private pure returns (bytes memory) {
        // worker id 1 = executor; option type 1 = lzReceive (gas), type 3 = lzCompose
        // (index ++ gas); each option is [workerId ++ size ++ optionType ++ payload]
        bytes memory lzReceivePayload = abi.encodePacked(uint128(150_000));
        bytes memory lzComposePayload = abi.encodePacked(uint16(0), uint128(700_000));
        return abi.encodePacked(
            uint16(3),
            uint8(1), uint16(1 + lzReceivePayload.length), uint8(1), lzReceivePayload,
            uint8(1), uint16(1 + lzComposePayload.length), uint8(3), lzComposePayload
        );
    }

    /// The one-call transfer batch a wallet builds for the common instruction.
    function _transferBatch(
        address _token,
        address _destination,
        uint256 _amount
    )
        private
        pure
        returns (IPersonalAccount.Call[] memory _calls)
    {
        _calls = new IPersonalAccount.Call[](1);
        _calls[0] = IPersonalAccount.Call({
            target: _token,
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (_destination, _amount))
        });
    }

    function _redeemHomePayloadAt(uint64 _deadline) private pure returns (bytes memory) {
        return abi.encode(PAYLOAD_VERSION_1, ACTION_REDEEM_HOME, abi.encode(_deadline));
    }

    /// Two-leg options for a withdraw. Both blobs may be empty (enforced options can make an
    /// empty blob valid, and the mock ignores them); only the delivery-value floor is
    /// validated, and it is what the sender requires to be non-zero.
    function _withdrawOptions() private pure returns (ILoanSubaccount.WithdrawOptions memory) {
        return ILoanSubaccount.WithdrawOptions({
            destinationOptions: "",
            returnOptions: "",
            minComposeValue: 0.01 ether
        });
    }
}
