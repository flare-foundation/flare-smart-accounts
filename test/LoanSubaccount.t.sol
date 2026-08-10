// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
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
import {MintableERC20} from "../contracts/mock/MintableERC20.sol";
import {ILoanSubaccount} from "../contracts/userInterfaces/ILoanSubaccount.sol";
import {ILoanSubaccountsFacet} from "../contracts/userInterfaces/facets/ILoanSubaccountsFacet.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";
import {IMemoInstructionsFacet} from "../contracts/userInterfaces/facets/IMemoInstructionsFacet.sol";
import {IPauseFacet} from "../contracts/userInterfaces/facets/IPauseFacet.sol";

/**
 * @title LoanSubaccountTest
 * @notice Steps 1 to 3 coverage: deterministic loan subaccount deployment, initialization,
 * implementation self-lock, per-type resolution through the controller (beacon), upgrade routing,
 * controller-side creation/prediction, and account abstraction dispatch from an XRPL instruction
 * through the parent Personal Account into the subaccount. Asset-moving methods are intentionally
 * out of scope in these steps.
 */
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
        assetManagerFxrpMock = makeAddr("AssetManagerFXRP");
        agent = makeAddr("agent");
        agentInfo.status = AgentInfo.Status.NORMAL;
        collateralReservationFee = 123;
        xrplOwner = "rExampleXrplAddress";
        fxrp = new MintableERC20("F-XRPL", "fXRP", 6);

        // deploy the personal account implementation (required by the controller init)
        personalAccountImplementation = address(new PersonalAccount());

        // deploy the diamond controller
        controller = _deployDiamond();

        // deploy and register the loan subaccount implementation (timelock duration is 0 in tests)
        loanImpl = new LoanSubaccount();
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(
            ILoanSubaccountsFacet.SubaccountType.Loan,
            address(loanImpl)
        );

        // mocks and agent vault registration for the Personal Account creation flow
        _mockGetContractAddressByHash("AssetManagerFXRP", assetManagerFxrpMock);
        _mockGetAgentInfo(agent, agentInfo);
        _mockCollateralReservationFee(collateralReservationFee);
        _mockReserveCollateral(22);
        _mockGetFAsset();
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
        assertEq(
            uint256(subaccount.subaccountType()),
            uint256(ILoanSubaccountsFacet.SubaccountType.Loan)
        );
        assertEq(subaccount.implementation(), address(loanImpl));
    }

    function testInitializeRevertAlreadyInitialized() public {
        LoanSubaccount subaccount = _deploySubaccount();

        vm.expectRevert(ILoanSubaccount.AlreadyInitialized.selector);
        subaccount.initialize(
            address(controller),
            parentPersonalAccount,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
    }

    function testImplementationInitializeRevertAlreadyInitialized() public {
        vm.expectRevert(ILoanSubaccount.AlreadyInitialized.selector);
        loanImpl.initialize(
            address(controller),
            parentPersonalAccount,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
    }

    function testDeployRevertWhenImplementationNotConfigured() public {
        // SubaccountType.None is never configured, so resolution returns address(0)
        vm.expectRevert();
        new LoanSubaccountProxy(
            address(controller),
            parentPersonalAccount,
            ILoanSubaccountsFacet.SubaccountType.None
        );
    }

    function testUpgradeRoutesToNewImplementation() public {
        LoanSubaccount subaccount = _deploySubaccount();
        assertEq(subaccount.implementation(), address(loanImpl));

        LoanSubaccount newImpl = new LoanSubaccount();
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(
            ILoanSubaccountsFacet.SubaccountType.Loan,
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
            ILoanSubaccountsFacet.SubaccountType.Loan,
            address(loanImpl)
        );
    }

    function testSetLoanSubaccountImplementationRevertInvalidImplementation() public {
        address notAContract = makeAddr("notAContract");
        vm.prank(governance);
        vm.expectRevert(ILoanSubaccountsFacet.InvalidLoanSubaccountImplementation.selector);
        controller.setLoanSubaccountImplementation(
            ILoanSubaccountsFacet.SubaccountType.Loan,
            notAContract
        );
    }

    function testSetLoanSubaccountImplementationRevertInvalidType() public {
        vm.prank(governance);
        vm.expectRevert(ILoanSubaccountsFacet.InvalidSubaccountType.selector);
        controller.setLoanSubaccountImplementation(
            ILoanSubaccountsFacet.SubaccountType.None,
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
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
        assertEq(predicted.code.length, 0);

        vm.expectEmit();
        emit ILoanSubaccountsFacet.LoanSubaccountCreated(
            predicted,
            personalAccount,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
        address created = controller.createLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );

        // created at the predicted address, registered, and functional
        assertEq(created, predicted);
        assertNotEq(created.code.length, 0);
        assertEq(
            controller.getLoanSubaccount(xrplOwner, ILoanSubaccountsFacet.SubaccountType.Loan),
            created
        );

        LoanSubaccount subaccount = LoanSubaccount(created);
        assertEq(subaccount.controllerAddress(), address(controller));
        assertEq(subaccount.parentPersonalAccount(), personalAccount);
        assertEq(
            uint256(subaccount.subaccountType()),
            uint256(ILoanSubaccountsFacet.SubaccountType.Loan)
        );
        assertEq(subaccount.implementation(), address(loanImpl));
    }

    function testCreateLoanSubaccountIdempotent() public {
        _createPersonalAccount(xrplOwner);
        address first = controller.createLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
        address second = controller.createLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );

        assertEq(first, second);
    }

    function testCreateLoanSubaccountCanBeCalledByAnyone() public {
        address personalAccount = _createPersonalAccount(xrplOwner);
        address caller = makeAddr("caller");

        vm.prank(caller);
        address created = controller.createLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );

        assertEq(LoanSubaccount(created).parentPersonalAccount(), personalAccount);
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
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
    }

    function testCreateLoanSubaccountRevertInvalidSubaccountType() public {
        _createPersonalAccount(xrplOwner);

        vm.expectRevert(ILoanSubaccountsFacet.InvalidSubaccountType.selector);
        controller.createLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.None
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
                ILoanSubaccountsFacet.SubaccountType.Loan
            )
        );
        freshController.createLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
    }

    function testCreateLoanSubaccountRevertNotSuccessfullyDeployed() public {
        _createPersonalAccount(xrplOwner);
        address predicted = controller.getLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
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
            ILoanSubaccountsFacet.SubaccountType.Loan
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
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
    }

    function testGetLoanSubaccountPredictionStableAcrossPersonalAccountCreation() public {
        // prediction works before the Personal Account exists and does not shift when it is created
        address predictedBefore = controller.getLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
        _createPersonalAccount(xrplOwner);
        address predictedAfter = controller.getLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );

        assertEq(predictedBefore, predictedAfter);
    }

    function testGetLoanSubaccountRevertInvalidSubaccountType() public {
        vm.expectRevert(ILoanSubaccountsFacet.InvalidSubaccountType.selector);
        controller.getLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.None
        );
    }

    //
    // step 3: account abstraction dispatch into the subaccount
    //

    function testDispatchFromXrplInstructionReachesSubaccount() public {
        // the loan subaccount implementation for this type exposes a parent-restricted method
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(
            ILoanSubaccountsFacet.SubaccountType.Loan,
            address(new MockLoanSubaccount())
        );

        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.getLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
        assertEq(subaccount.code.length, 0);

        // one user operation: create the subaccount, then call it
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](2);
        calls[0] = IPersonalAccount.Call({
            target: address(controller),
            value: 0,
            data: abi.encodeCall(
                ILoanSubaccountsFacet.createLoanSubaccount,
                (xrplOwner, ILoanSubaccountsFacet.SubaccountType.Loan)
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
        assertEq(LoanSubaccount(subaccount).parentPersonalAccount(), personalAccount);

        // the restricted method ran, called by the parent Personal Account
        assertEq(MockLoanSubaccount(subaccount).pingCount(), 1);
        assertEq(MockLoanSubaccount(subaccount).lastPingCaller(), personalAccount);
    }

    function testDispatchForwardsValueToSubaccount() public {
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(
            ILoanSubaccountsFacet.SubaccountType.Loan,
            address(new MockLoanSubaccount())
        );
        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.getLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
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
                (xrplOwner, ILoanSubaccountsFacet.SubaccountType.Loan)
            )
        });
        calls[1] = IPersonalAccount.Call({
            target: subaccount,
            value: value,
            data: abi.encodeWithSignature("ping()")
        });

        _executeUserOpWithValue(personalAccount, calls, bytes32("dmLoanValue"), value);

        assertEq(MockLoanSubaccount(subaccount).lastPingValue(), value);
        assertEq(subaccount.balance, value);
    }

    function testDispatchToUncreatedSubaccountSilentlyDoesNothing() public {
        vm.prank(governance);
        controller.setLoanSubaccountImplementation(
            ILoanSubaccountsFacet.SubaccountType.Loan,
            address(new MockLoanSubaccount())
        );
        address personalAccount = _createPersonalAccount(xrplOwner);
        address subaccount = controller.getLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
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
            ILoanSubaccountsFacet.SubaccountType.Loan,
            address(new MockLoanSubaccount())
        );
        address personalAccount = _createPersonalAccount(xrplOwner);

        // another XRPL owner's subaccount, created and owned by their Personal Account
        string memory otherOwner = "rOtherXrplAddress";
        _createPersonalAccount(otherOwner);
        address otherSubaccount = controller.createLoanSubaccount(
            otherOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
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
            ILoanSubaccountsFacet.SubaccountType.Loan,
            address(new MockLoanSubaccount())
        );
        _createPersonalAccount(xrplOwner);
        address subaccount = controller.createLoanSubaccount(
            xrplOwner,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );

        // neither a random caller nor the controller may drive the subaccount directly
        vm.expectRevert(ILoanSubaccount.OnlyParent.selector);
        MockLoanSubaccount(subaccount).ping();

        vm.prank(address(controller));
        vm.expectRevert(ILoanSubaccount.OnlyParent.selector);
        MockLoanSubaccount(subaccount).ping();
    }

    function testGetLoanSubaccountDifferentOwnersGetDifferentAddresses() public view {
        address subaccount1 = controller.getLoanSubaccount(
            "rOwner1",
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
        address subaccount2 = controller.getLoanSubaccount(
            "rOwner2",
            ILoanSubaccountsFacet.SubaccountType.Loan
        );

        assertNotEq(subaccount1, subaccount2);
    }

    function testLoanImplementationForTypeReturnsConfiguredImplementation() public view {
        assertEq(
            controller.loanImplementationForType(ILoanSubaccountsFacet.SubaccountType.Loan),
            address(loanImpl)
        );
    }

    function testLoanImplementationForTypeReturnsZeroForUnconfiguredType() public view {
        assertEq(
            controller.loanImplementationForType(ILoanSubaccountsFacet.SubaccountType.None),
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

    function _deploySubaccount() private returns (LoanSubaccount) {
        LoanSubaccountProxy proxy = new LoanSubaccountProxy(
            address(controller),
            parentPersonalAccount,
            ILoanSubaccountsFacet.SubaccountType.Loan
        );
        return LoanSubaccount(address(proxy));
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

    function _mockGetFAsset() private {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSelector(IAssetManager.fAsset.selector),
            abi.encode(address(fxrp))
        );
    }

    function _mockGetDirectMintingExecutorFeeUBA(uint256 _fee) private {
        vm.mockCall(
            assetManagerFxrpMock,
            abi.encodeWithSignature("getDirectMintingExecutorFeeUBA()"),
            abi.encode(_fee)
        );
    }
}
