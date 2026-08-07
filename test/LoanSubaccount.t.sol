// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
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
import {ILoanSubaccount} from "../contracts/userInterfaces/ILoanSubaccount.sol";
import {ILoanSubaccountsFacet} from "../contracts/userInterfaces/facets/ILoanSubaccountsFacet.sol";
import {IPauseFacet} from "../contracts/userInterfaces/facets/IPauseFacet.sol";

/**
 * @title LoanSubaccountTest
 * @notice Steps 1 and 2 coverage: deterministic loan subaccount deployment, initialization,
 * implementation self-lock, per-type resolution through the controller (beacon), upgrade
 * routing, and controller-side creation/prediction (`createLoanSubaccount`, `getLoanSubaccount`).
 * Asset-moving methods are intentionally out of scope in these steps.
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
}
