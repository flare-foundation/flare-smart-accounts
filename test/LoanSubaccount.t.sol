// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IRedeemExtended} from "flare-periphery/src/flare/IRedeemExtended.sol";
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
import {LoanSubaccountProxy} from "../contracts/smartAccounts/proxy/LoanSubaccountProxy.sol";
import {MockSingletonFactoryNoDeploy} from "../contracts/mock/MockSingletonFactoryNoDeploy.sol";
import {MockLoanSubaccount} from "../contracts/mock/MockLoanSubaccount.sol";
import {MockOft} from "../contracts/mock/MockOft.sol";
import {MockAssetManager} from "../contracts/mock/MockAssetManager.sol";
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {ILoanSubaccount} from "../contracts/userInterfaces/ILoanSubaccount.sol";
import {
    ILoanSubaccountsFacet,
    SUBACCOUNT_TYPE_LOAN,
    SUBACCOUNT_TYPE_NONE
} from "../contracts/userInterfaces/facets/ILoanSubaccountsFacet.sol";
import {IMasterAccountController} from "../contracts/userInterfaces/IMasterAccountController.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";
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
    uint32 private destinationEid;
    uint256 private messagingFee;

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

        // deploy the personal account implementation (required by the controller init)
        personalAccountImplementation = address(new PersonalAccount());

        // deploy the diamond controller
        controller = _deployDiamond();

        // deploy and register the loan subaccount implementation (timelock duration is 0 in tests)
        loanImpl = new LoanSubaccount();
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(
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
        LoanSubaccount subaccount = _deploySubaccount();

        assertEq(subaccount.controllerAddress(), address(controller));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);
        assertEq(subaccount.subaccountType(), SUBACCOUNT_TYPE_LOAN);
        assertEq(subaccount.implementation(), address(loanImpl));
    }

    function testInitializeRevertAlreadyInitialized() public {
        LoanSubaccount subaccount = _deploySubaccount();

        vm.expectRevert(ILoanSubaccount.AlreadyInitialized.selector);
        subaccount.initialize(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testImplementationInitializeRevertAlreadyInitialized() public {
        vm.expectRevert(ILoanSubaccount.AlreadyInitialized.selector);
        loanImpl.initialize(
            address(controller),
            parentPersonalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testDeployRevertWhenImplementationNotConfigured() public {
        // the reserved type 0 is never configured, so resolution returns address(0)
        vm.expectRevert();
        new LoanSubaccountProxy(
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
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(newImpl)
        );

        // proxy resolves the new implementation, and existing state is preserved
        assertEq(subaccount.implementation(), address(newImpl));
        assertEq(subaccount.parentPersonalAccount(), parentPersonalAccount);
    }

    function testSetLoanSubaccountImplementationRevertNotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(loanImpl)
        );
    }

    function testSetLoanSubaccountImplementationRevertInvalidImplementation() public {
        address notAContract = makeAddr("notAContract");
        vm.prank(governance);
        vm.expectRevert(ILoanSubaccountsFacet.InvalidLoanSubaccountImplementation.selector);
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            notAContract
        );
    }

    function testSetLoanSubaccountImplementationRevertInvalidType() public {
        vm.prank(governance);
        vm.expectRevert(ILoanSubaccountsFacet.InvalidSubaccountType.selector);
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_NONE,
            address(loanImpl)
        );
    }

    //
    // step 2: controller-side creation and prediction
    //

    function testCreateLoanSubaccount() public {
        address personalAccount = _createPersonalAccount(xrplOwner);
        address predicted = controller.getLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
        assertEq(predicted.code.length, 0);

        vm.expectEmit();
        emit ILoanSubaccountsFacet.LoanSubaccountCreated(
            predicted,
            personalAccount,
            SUBACCOUNT_TYPE_LOAN
        );
        address created = controller.createLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        // created at the predicted address, registered, and functional
        assertEq(created, predicted);
        assertNotEq(created.code.length, 0);
        assertEq(
            controller.getLoanSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN),
            created
        );

        LoanSubaccount subaccount = LoanSubaccount(payable(created));
        assertEq(subaccount.controllerAddress(), address(controller));
        assertEq(subaccount.parentPersonalAccount(), personalAccount);
        assertEq(subaccount.subaccountType(), SUBACCOUNT_TYPE_LOAN);
        assertEq(subaccount.implementation(), address(loanImpl));
    }

    function testCreateLoanSubaccountIdempotent() public {
        _createPersonalAccount(xrplOwner);
        address first = controller.createLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
        address second = controller.createLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        assertEq(first, second);
    }

    function testCreateLoanSubaccountCanBeCalledByAnyone() public {
        address personalAccount = _createPersonalAccount(xrplOwner);
        address caller = makeAddr("caller");

        vm.prank(caller);
        address created = controller.createLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        assertEq(LoanSubaccount(payable(created)).parentPersonalAccount(), personalAccount);
    }

    function testCreateLoanSubaccountRevertPersonalAccountNotDeployed() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccountsFacet.PersonalAccountNotDeployed.selector,
                xrplOwner
            )
        );
        controller.createLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testCreateLoanSubaccountOfFutureType() public {
        // the type is a raw uint256, not an enum, so a type unknown at compile time of the proxy
        // and facet works as soon as governance registers an implementation for it — no new proxy
        // creation code, facet redeploy, or diamond cut
        uint256 futureType = 2;
        address futureImpl = address(new LoanSubaccount());
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(futureType, futureImpl);

        address personalAccount = _createPersonalAccount(xrplOwner);
        address loanTypeSubaccount = controller.createLoanSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        address futureTypeSubaccount = controller.createLoanSubaccount(xrplOwner, futureType);

        // distinct account per type, both functional, each resolving its own implementation
        assertNotEq(futureTypeSubaccount, loanTypeSubaccount);
        assertEq(LoanSubaccount(payable(futureTypeSubaccount)).parentPersonalAccount(), personalAccount);
        assertEq(LoanSubaccount(payable(futureTypeSubaccount)).subaccountType(), futureType);
        assertEq(LoanSubaccount(payable(futureTypeSubaccount)).implementation(), futureImpl);
        assertEq(LoanSubaccount(payable(loanTypeSubaccount)).implementation(), address(loanImpl));
    }

    function testCreateLoanSubaccountRevertInvalidSubaccountType() public {
        _createPersonalAccount(xrplOwner);

        vm.expectRevert(ILoanSubaccountsFacet.InvalidSubaccountType.selector);
        controller.createLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_NONE
        );
    }

    function testCreateLoanSubaccountRevertImplementationNotSet() public {
        // fresh diamond without the loan subaccount implementation configured
        IIMasterAccountController freshController = _deployDiamond();
        _addAgentVault(freshController);
        _createPersonalAccountOn(freshController, xrplOwner);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccountsFacet.LoanSubaccountImplementationNotSet.selector,
                SUBACCOUNT_TYPE_LOAN
            )
        );
        freshController.createLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testCreateLoanSubaccountRevertNotSuccessfullyDeployed() public {
        _createPersonalAccount(xrplOwner);
        address predicted = controller.getLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        // replace the singleton factory with one that does not deploy
        MockSingletonFactoryNoDeploy mockFactoryNoDeploy = new MockSingletonFactoryNoDeploy();
        vm.etch(SINGLETON_FACTORY, address(mockFactoryNoDeploy).code);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccountsFacet.LoanSubaccountNotSuccessfullyDeployed.selector,
                predicted
            )
        );
        controller.createLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testCreateLoanSubaccountRevertWhenPaused() public {
        _createPersonalAccount(xrplOwner);

        address pauser = makeAddr("pauser");
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        vm.prank(governance);
        controller.addPausers(pausers);
        vm.prank(pauser);
        controller.pause();

        vm.expectRevert(IPauseFacet.IsPaused.selector);
        controller.createLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function testGetLoanSubaccountPredictionStableAcrossPersonalAccountCreation() public {
        // prediction works before the Personal Account exists and does not shift when it is created
        address predictedBefore = controller.getLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
        _createPersonalAccount(xrplOwner);
        address predictedAfter = controller.getLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        assertEq(predictedBefore, predictedAfter);
    }

    function testGetLoanSubaccountRevertInvalidSubaccountType() public {
        vm.expectRevert(ILoanSubaccountsFacet.InvalidSubaccountType.selector);
        controller.getLoanSubaccount(
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
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(new MockLoanSubaccount())
        );

        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.getLoanSubaccount(
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
                ILoanSubaccountsFacet.createLoanSubaccount,
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
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(new MockLoanSubaccount())
        );
        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.getLoanSubaccount(
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
                ILoanSubaccountsFacet.createLoanSubaccount,
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
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(new MockLoanSubaccount())
        );
        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.getLoanSubaccount(
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
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(new MockLoanSubaccount())
        );
        address personalAccount = _createPersonalAccount(xrplOwner);

        // another XRPL owner's subaccount, created and owned by their Personal Account
        string memory otherOwner = "rOtherXrplAddress";
        _createPersonalAccount(otherOwner);
        address otherSubaccount = controller.createLoanSubaccount(
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
                    abi.encodeWithSelector(ILoanSubaccount.OnlyParent.selector)
                )
            )
        );
    }

    function testSubaccountMethodRevertOnlyParent() public {
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(
            SUBACCOUNT_TYPE_LOAN,
            address(new MockLoanSubaccount())
        );
        _createPersonalAccount(xrplOwner);
        address subaccount = controller.createLoanSubaccount(
            xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );

        // neither a random caller nor the controller may drive the subaccount directly
        vm.expectRevert(ILoanSubaccount.OnlyParent.selector);
        MockLoanSubaccount(payable(subaccount)).ping();

        vm.prank(address(controller));
        vm.expectRevert(ILoanSubaccount.OnlyParent.selector);
        MockLoanSubaccount(payable(subaccount)).ping();
    }

    //
    // step 4: sweepRedeem (backward cleanup move)
    //

    function testSweepRedeemRedeemsWholeBalanceToParentXrplOwner() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        // deliberately not a whole number of lots (FXRP lot size is 10e6), so this exercises a
        // UBA redemption that the lot-based `redeem` could not fully perform
        uint256 balance = 250e6 + 1;
        fxrp.mint(subaccount, balance);
        mockAssetManager.setMinimumRedeemAmountUBA(10e6);

        // redeemed to the parent Personal Account's XRPL owner, with the controller's executor
        vm.expectCall(
            assetManagerFxrpMock,
            executorFee,
            abi.encodeWithSelector(
                IRedeemExtended.redeemAmount.selector, balance, xrplOwner, executor
            )
        );
        vm.deal(address(this), executorFee);
        vm.expectEmit();
        emit ILoanSubaccount.FXrpRedeemed(
            _personalAccountOf(xrplOwner), balance, balance, executor, executorFee
        );
        (uint256 amount, uint256 redeemed) =
            ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();

        assertEq(amount, balance);
        assertEq(redeemed, balance);
        // the whole balance was burned by the redemption: nothing left stranded here
        assertEq(fxrp.balanceOf(subaccount), 0);
    }

    function testSweepRedeemPartialRedemptionLeavesRemainderOnTheAccount() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 250e6);
        // FAssets can redeem less than requested when tickets run out; the rest stays here
        mockAssetManager.setMaxRedeemPerCall(100e6);

        vm.deal(address(this), 2 * executorFee);
        (uint256 amount, uint256 redeemed) =
            ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();

        assertEq(amount, 250e6);
        assertEq(redeemed, 100e6);
        // only the redeemed part was burned; the remainder can be swept again
        assertEq(fxrp.balanceOf(subaccount), 150e6);
        (amount, redeemed) = ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        assertEq(amount, 150e6);
        assertEq(redeemed, 100e6);
        assertEq(fxrp.balanceOf(subaccount), 50e6);
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
        vm.expectRevert(ILoanSubaccount.NothingToRedeem.selector);
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
    }

    function testSweepRedeemRevertBelowMinimumRedemption() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        mockAssetManager.setMinimumRedeemAmountUBA(100e6);
        fxrp.mint(subaccount, 100e6 - 1);

        // a residual FAssets cannot redeem is rejected with a clear error instead of reverting
        // opaquely inside the asset manager; it leaves through sweepToParent instead
        vm.deal(address(this), executorFee);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccount.BelowMinimumRedemption.selector, 100e6)
        );
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
    }

    function testSweepRedeemAtExactMinimumBoundary() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        mockAssetManager.setMinimumRedeemAmountUBA(100e6);
        fxrp.mint(subaccount, 100e6);

        // at exactly the minimum the balance is redeemable, so redemption must take it and
        // parent recovery must refuse it - the two paths meet with no gap and no overlap
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccount.FXrpAboveMinimumRedemption.selector, 100e6, 100e6
            )
        );
        ILoanSubaccount(subaccount).sweepToParent(address(fxrp));

        vm.deal(address(this), executorFee);
        (uint256 amount, uint256 redeemed) =
            ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        assertEq(amount, 100e6);
        assertEq(redeemed, 100e6);
    }

    function testSweepRedeemForwardsWholeValueToAssetManager() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);

        // overpayment is deliberate: the whole msg.value is forwarded to the asset manager,
        // which uses it for the executor fee
        uint256 sent = executorFee + 1 ether;
        vm.deal(address(this), sent);
        ILoanSubaccount(subaccount).sweepRedeem{value: sent}();

        assertEq(mockAssetManager.lastRedeemValue(), sent);
    }

    function testPartialRedemptionRemainderBelowMinimumIsRecoverable() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address parent = _personalAccountOf(xrplOwner);
        mockAssetManager.setMinimumRedeemAmountUBA(100e6);
        mockAssetManager.setMaxRedeemPerCall(100e6);
        fxrp.mint(subaccount, 150e6);

        // a real partial redemption produces the below-minimum remainder
        vm.deal(address(this), 2 * executorFee);
        (, uint256 redeemed) = ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        assertEq(redeemed, 100e6);
        assertEq(fxrp.balanceOf(subaccount), 50e6);

        // the remainder cannot be redeemed again, and leaves through parent recovery instead
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccount.BelowMinimumRedemption.selector, 100e6)
        );
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        uint256 recovered = ILoanSubaccount(subaccount).sweepToParent(address(fxrp));
        assertEq(recovered, 50e6);
        assertEq(fxrp.balanceOf(parent), 50e6);
    }

    function testImplementationContractRejectsNativeAndRecovery() public {
        // the implementation contract is never initialized and has no parent: it must not
        // accept native, and its recovery methods must not burn to the zero address
        vm.deal(address(this), 1 ether);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = address(loanImpl).call{value: 1 ether}("");
        assertFalse(ok);

        // native can still be force-sent past the guarded receive; recovery must refuse
        vm.deal(address(loanImpl), 1 ether);
        vm.expectRevert(ILoanSubaccount.NotInitialized.selector);
        loanImpl.sweepNativeToParent();

        fxrp.mint(address(loanImpl), 1e6);
        vm.expectRevert(ILoanSubaccount.NotInitialized.selector);
        loanImpl.sweepToParent(address(fxrp));
    }

    function testPublicAggregateExposesLoanFacet() public {
        // typed through the public aggregate, so an omission there fails compilation here
        IMasterAccountController publicController = IMasterAccountController(address(controller));
        _createPersonalAccount(xrplOwner);
        address subaccount =
            publicController.createLoanSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        assertEq(
            publicController.getLoanSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN),
            subaccount
        );
        assertEq(
            publicController.loanImplementationForType(SUBACCOUNT_TYPE_LOAN),
            address(loanImpl)
        );
    }

    function testSweepRedeemRevertInsufficientFundsForRedeem() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);

        vm.deal(address(this), executorFee);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccount.InsufficientFundsForRedeem.selector, executorFee)
        );
        ILoanSubaccount(subaccount).sweepRedeem{value: executorFee - 1}();
    }

    //
    // step 4: recovery to the parent Personal Account
    //

    function testSweepToParentRecoversDefaultPayoutTokens() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address parent = _personalAccountOf(xrplOwner);
        // stand-in for vault collateral or WNat paid out by a FAssets redemption default
        MintableERC20 stableCoin = new MintableERC20("Stable", "STB", 18);
        stableCoin.mint(subaccount, 500e18);

        vm.expectEmit();
        emit ILoanSubaccount.TokenSweptToParent(parent, address(stableCoin), 500e18);
        uint256 amount = ILoanSubaccount(subaccount).sweepToParent(address(stableCoin));

        assertEq(amount, 500e18);
        assertEq(stableCoin.balanceOf(subaccount), 0);
        assertEq(stableCoin.balanceOf(parent), 500e18);
    }

    function testSweepToParentRecoversFxrpResidualBelowMinimum() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address parent = _personalAccountOf(xrplOwner);
        mockAssetManager.setMinimumRedeemAmountUBA(100e6);
        fxrp.mint(subaccount, 100e6 - 1);

        uint256 amount = ILoanSubaccount(subaccount).sweepToParent(address(fxrp));

        assertEq(amount, 100e6 - 1);
        assertEq(fxrp.balanceOf(parent), 100e6 - 1);
    }

    function testSweepToParentRevertFxrpAboveMinimum() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        mockAssetManager.setMinimumRedeemAmountUBA(100e6);
        fxrp.mint(subaccount, 250e6);

        // a redeemable FXRP balance moves only through sweepRedeem or sweepToLoan, so recovery
        // to the parent cannot become a third direction for the loan asset
        vm.expectRevert(
            abi.encodeWithSelector(
                ILoanSubaccount.FXrpAboveMinimumRedemption.selector, 250e6, 100e6
            )
        );
        ILoanSubaccount(subaccount).sweepToParent(address(fxrp));
    }

    function testSweepToParentRevertNothingToSweep() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        MintableERC20 stableCoin = new MintableERC20("Stable", "STB", 18);

        vm.expectRevert(ILoanSubaccount.NothingToSweep.selector);
        ILoanSubaccount(subaccount).sweepToParent(address(stableCoin));
    }

    function testSweepNativeToParentRecoversNative() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address parent = _personalAccountOf(xrplOwner);

        // the subaccount accepts plain native transfers (bridge or redemption refunds)
        vm.deal(address(this), 1 ether);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = subaccount.call{value: 1 ether}("");
        assertTrue(ok);

        vm.expectEmit();
        emit ILoanSubaccount.NativeSweptToParent(parent, 1 ether);
        uint256 amount = ILoanSubaccount(subaccount).sweepNativeToParent();

        assertEq(amount, 1 ether);
        assertEq(subaccount.balance, 0);
        assertEq(parent.balance, 1 ether);
    }

    function testSweepNativeToParentRevertNothingToSweep() public {
        address subaccount = _createSubaccountFor(xrplOwner);

        vm.expectRevert(ILoanSubaccount.NothingToSweep.selector);
        ILoanSubaccount(subaccount).sweepNativeToParent();
    }

    function testSweepToParentWorksWhilePaused() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        address parent = _personalAccountOf(xrplOwner);
        MintableERC20 stableCoin = new MintableERC20("Stable", "STB", 18);
        stableCoin.mint(subaccount, 500e18);
        vm.deal(subaccount, 1 ether);

        address pauser = makeAddr("pauser");
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        vm.prank(governance);
        controller.addPausers(pausers);
        vm.prank(pauser);
        controller.pause();

        // recovery to the parent is the safest destination, so it stays available in an incident
        ILoanSubaccount(subaccount).sweepToParent(address(stableCoin));
        ILoanSubaccount(subaccount).sweepNativeToParent();
        assertEq(stableCoin.balanceOf(parent), 500e18);
        assertEq(parent.balance, 1 ether);
    }

    function testValueSentToUncreatedSubaccountIsRecoverableAfterCreation() public {
        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.getLoanSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);

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

        // once the subaccount is created, the native recovery path brings it to the parent
        controller.createLoanSubaccount(xrplOwner, SUBACCOUNT_TYPE_LOAN);
        ILoanSubaccount(subaccount).sweepNativeToParent();
        assertEq(personalAccount.balance, 1 ether);
    }

    //
    // step 4: sweepToLoan (forward cleanup move)
    //

    function testSweepToLoanBridgesWholeBalanceToOwnAddressOnLoanChain() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        uint256 balance = 250e6;
        fxrp.mint(subaccount, balance);
        _configureLoanBridge();

        vm.deal(address(this), messagingFee);
        uint256 amount = ILoanSubaccount(subaccount).sweepToLoan{value: messagingFee}();

        assertEq(amount, balance);
        // the FXRP left the subaccount and the adapter locked it
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(fxrp.balanceOf(address(fxrpOft)), balance);

        // destination is this account's own address on the configured chain, full amount, no compose
        (uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD,,,) = fxrpOft.lastSendParam();
        assertEq(dstEid, destinationEid);
        assertEq(to, bytes32(uint256(uint160(subaccount))));
        assertEq(amountLD, balance);
        assertEq(minAmountLD, balance);
        assertEq(fxrpOft.lastValue(), messagingFee);
    }

    function testSweepToLoanCanBeCalledByAnyoneAndRefundsExcess() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        address caller = makeAddr("randomCaller");
        uint256 sent = messagingFee + 1 ether;
        vm.deal(caller, sent);
        vm.prank(caller);
        ILoanSubaccount(subaccount).sweepToLoan{value: sent}();

        // only the fee was forwarded; the excess came back to the caller, not stranded here
        assertEq(fxrpOft.lastValue(), messagingFee);
        assertEq(fxrpOft.lastRefundAddress(), caller);
        assertEq(caller.balance, sent - messagingFee);
        assertEq(subaccount.balance, 0);
    }

    function testSweepToLoanLeavesNoStandingApproval() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        vm.deal(address(this), messagingFee);
        ILoanSubaccount(subaccount).sweepToLoan{value: messagingFee}();

        assertEq(fxrp.allowance(subaccount, address(fxrpOft)), 0);
    }

    function testSweepToLoanRevertNothingToSweep() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        _configureLoanBridge();

        vm.deal(address(this), messagingFee);
        vm.expectRevert(ILoanSubaccount.NothingToSweep.selector);
        ILoanSubaccount(subaccount).sweepToLoan{value: messagingFee}();
    }

    function testSweepToLoanRevertLoanBridgeNotConfigured() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);

        vm.deal(address(this), messagingFee);
        vm.expectRevert(ILoanSubaccount.LoanBridgeNotConfigured.selector);
        ILoanSubaccount(subaccount).sweepToLoan{value: messagingFee}();
    }

    function testSweepToLoanRevertInsufficientFundsForSweep() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        vm.deal(address(this), messagingFee);
        vm.expectRevert(
            abi.encodeWithSelector(ILoanSubaccount.InsufficientFundsForSweep.selector, messagingFee)
        );
        ILoanSubaccount(subaccount).sweepToLoan{value: messagingFee - 1}();
    }

    function testSetLoanBridgeSettingsRevertNotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(
            abi.encodeWithSelector(NotContractOwner.selector, notOwner, governance)
        );
        controller.setLoanBridgeSettings(address(fxrpOft), destinationEid);
    }

    function testSetLoanBridgeSettingsRevertInvalidValues() public {
        vm.prank(governance);
        vm.expectRevert(ILoanSubaccountsFacet.InvalidFxrpOft.selector);
        controller.setLoanBridgeSettings(makeAddr("notAContract"), destinationEid);

        vm.prank(governance);
        vm.expectRevert(ILoanSubaccountsFacet.InvalidDestinationEid.selector);
        controller.setLoanBridgeSettings(address(fxrpOft), 0);
    }

    function testSetLoanBridgeSettingsRevertWrongToken() public {
        // an OFT wrapping some other token must be rejected, even with a peer wired
        MintableERC20 otherToken = new MintableERC20("Other", "OTH", 6);
        MockOft otherOft = new MockOft(otherToken, messagingFee);
        otherOft.setPeer(destinationEid, bytes32(uint256(1)));

        vm.prank(governance);
        vm.expectRevert(ILoanSubaccountsFacet.InvalidFxrpOft.selector);
        controller.setLoanBridgeSettings(address(otherOft), destinationEid);
    }

    function testSetLoanBridgeSettingsRevertWrongSharedDecimals() public {
        // shared decimals below the token's would truncate to dust; sweeps send with
        // minAmountLD == amountLD, so such an OFT must be rejected up front
        fxrpOft.setPeer(destinationEid, bytes32(uint256(1)));
        fxrpOft.setSharedDecimals(4);

        vm.prank(governance);
        vm.expectRevert(ILoanSubaccountsFacet.InvalidFxrpOft.selector);
        controller.setLoanBridgeSettings(address(fxrpOft), destinationEid);
    }

    function testSetLoanBridgeSettingsRevertNoPeerForDestination() public {
        // no peer wired for the destination endpoint: the route does not exist
        vm.prank(governance);
        vm.expectRevert(ILoanSubaccountsFacet.InvalidDestinationEid.selector);
        controller.setLoanBridgeSettings(address(fxrpOft), destinationEid);
    }

    function testClearLoanBridgeSettingsDisablesForwardSweep() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        // clearing with explicit zeros disables the forward sweep until reconfigured
        vm.prank(governance);
        controller.setLoanBridgeSettings(address(0), 0);

        (address oft, uint32 eid) = controller.getLoanBridgeSettings();
        assertEq(oft, address(0));
        assertEq(eid, 0);

        vm.deal(address(this), messagingFee);
        vm.expectRevert(ILoanSubaccount.LoanBridgeNotConfigured.selector);
        ILoanSubaccount(subaccount).sweepToLoan{value: messagingFee}();
    }

    function testSweepToLoanRevertWhenPausedButSweepRedeemStillWorks() public {
        address subaccount = _createSubaccountFor(xrplOwner);
        fxrp.mint(subaccount, 100e6);
        _configureLoanBridge();

        address pauser = makeAddr("pauser");
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        vm.prank(governance);
        controller.addPausers(pausers);
        vm.prank(pauser);
        controller.pause();

        // the forward sweep is blocked while paused: it is the incident-containment surface
        vm.deal(address(this), messagingFee + executorFee);
        vm.expectRevert(IPauseFacet.IsPaused.selector);
        ILoanSubaccount(subaccount).sweepToLoan{value: messagingFee}();

        // the backward sweep stays available, so assets can always exit toward the user
        (uint256 amount,) = ILoanSubaccount(subaccount).sweepRedeem{value: executorFee}();
        assertEq(amount, 100e6);
    }

    function testGetLoanSubaccountDifferentOwnersGetDifferentAddresses() public view {
        address subaccount1 = controller.getLoanSubaccount(
            "rOwner1",
            SUBACCOUNT_TYPE_LOAN
        );
        address subaccount2 = controller.getLoanSubaccount(
            "rOwner2",
            SUBACCOUNT_TYPE_LOAN
        );

        assertNotEq(subaccount1, subaccount2);
    }

    function testLoanImplementationForTypeReturnsConfiguredImplementation() public view {
        assertEq(
            controller.loanImplementationForType(SUBACCOUNT_TYPE_LOAN),
            address(loanImpl)
        );
    }

    function testLoanImplementationForTypeReturnsZeroForUnconfiguredType() public view {
        assertEq(
            controller.loanImplementationForType(SUBACCOUNT_TYPE_NONE),
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
        return controller.createLoanSubaccount(
            _xrplOwner,
            SUBACCOUNT_TYPE_LOAN
        );
    }

    function _configureLoanBridge() private {
        fxrpOft.setPeer(destinationEid, bytes32(uint256(uint160(address(fxrpOft)))));
        vm.prank(governance);
        controller.setLoanBridgeSettings(address(fxrpOft), destinationEid);
    }

    function _deploySubaccount() private returns (LoanSubaccount) {
        LoanSubaccountProxy proxy = new LoanSubaccountProxy(
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

    function _personalAccountOf(string memory _xrplOwner) private view returns (address) {
        return controller.getPersonalAccount(_xrplOwner);
    }
}
