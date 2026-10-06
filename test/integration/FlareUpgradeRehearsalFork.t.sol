// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, Vm} from "forge-std/Test.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IPayment} from "flare-periphery/src/flare/IPayment.sol";
import {IPaymentVerification} from "flare-periphery/src/flare/IPaymentVerification.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {IDiamond} from "../../contracts/diamond/interfaces/IDiamond.sol";
import {IDiamondCut} from "../../contracts/diamond/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../contracts/diamond/interfaces/IDiamondLoupe.sol";
import {IIMasterAccountController} from "../../contracts/smartAccounts/interface/IIMasterAccountController.sol";
import {IPersonalAccount} from "../../contracts/userInterfaces/IPersonalAccount.sol";
import {IRedeemingSubaccount} from "../../contracts/userInterfaces/IRedeemingSubaccount.sol";
import {PAYLOAD_VERSION_1} from "../../contracts/userInterfaces/IComposeReceiverAccountBase.sol";
import {PA_ACTION_EXECUTE} from "../../contracts/userInterfaces/IPersonalAccountRemote.sol";
import {PersonalAccount} from "../../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {LoanSubaccount} from "../../contracts/smartAccounts/implementation/LoanSubaccount.sol";

/// @dev The one endpoint read the suite makes that no interface in the repository declares.
interface IOutboundNonce {
    function outboundNonce(
        address _sender,
        uint32 _dstEid,
        bytes32 _receiver
    )
        external view
        returns (uint64);
}

/**
 * @title FlareUpgradeRehearsalForkTest
 * @notice Part C, item 1 of the runbook: the release applied to the live Flare controller at a
 * pinned block, against the Personal Account implementation and the accounts that are actually
 * there - never a fresh deployment. Registration verification proves the code, the registry and
 * one account's identity; this proves the upgrade preserves live state and that the new code
 * runs behind proxies that predate it.
 *
 * The release is applied the way the runbook applies it: the facet cut built by the cut tool
 * (`build-cut.ts`) from the committed cut file and the fork's own loupe, then the two
 * implementation registrations, each submitted by the owner Safe, queued by the timelock and
 * executed by a third party an hour later. The routes (Part D) are opened only by the tests that
 * need them.
 *
 * Every live Flare owner is a 33- or 34-character XRPL address (12,444 accounts on 2026-10-06), so
 * every live owner string is a long Solidity string; the short form is covered by an account the
 * live code creates on the fork before the upgrade. Only FDC proof verification is mocked: every
 * other contract the instructions reach is the deployed one.
 *
 * Skips itself unless `FLARE_RPC_URL` names an archive endpoint serving the pinned block;
 * `REQUIRE_FLARE_FORK` turns the skip into a failure.
 */
contract FlareUpgradeRehearsalForkTest is Test {
    /// @dev What an account holds and has granted, compared whole across the upgrade.
    struct Holdings {
        string xrplOwner;
        address controller;
        uint256 native;
        uint256 fxrp;
        uint256 wNat;
        uint256 stXrp;
        uint256 earnXrp;
        uint256 mxrpy;
        uint256 fxrpAllowanceToFirelight;
        uint256 earnXrpAllowanceToVault;
        uint256 mxrpyAllowanceToVault;
    }

    uint256 private constant FLARE = 14;
    /// @dev 2026-10-06, a few minutes before the accounts below were chosen from a scan of every
    /// `PersonalAccountCreated` event.
    uint256 private constant FORK_BLOCK = 71_441_000;

    IIMasterAccountController private constant CONTROLLER =
        IIMasterAccountController(0x434936d47503353f06750Db1A444DBDC5F0AD37c);
    address private constant OWNER_SAFE = 0xbe653C54DF337F13Fcb726101388F4a4803049F3;
    address private constant LIVE_PERSONAL_ACCOUNT_IMPLEMENTATION = 0x3eFab0Eb4c65163651BB1FC50d84D4AF0B782d09;
    uint256 private constant TIMELOCK_SECONDS = 3600;
    string private constant CUT_FILE = "deployment/cuts/flare/cuts-2026-10-06.json";
    // the suite's own cut-tool inputs, beside the deployment's and never them
    string private constant OUTPUT_DIR = "deployment/output-internal/flare";
    string private constant FACETS_FILE = "deployment/output-internal/flare/rehearsal-facets.txt";
    string private constant LOUPE_FILE = "deployment/output-internal/flare/rehearsal-loupe.txt";

    address private constant FIRELIGHT_STXRP = 0x4C18Ff3C89632c3Dd62E796c0aFA5c07c4c1B2b3;
    address private constant UPSHIFT_EARNXRP = 0x373D7d201C8134D4a2f7b5c63560da217e3dEA28;
    address private constant UPSHIFT_MXRPY = 0x2439D4bb753A0f3777d4C9011AFacc475ba6B951;
    address private constant EARNXRP_LP = 0xE533E447fD7720b2F8654da2B1953Efa06b60bfA;
    address private constant MXRPY_LP = 0x36f236af59CB279bab884e464Ef1Bc23c7B1a115;
    uint256 private constant FIRELIGHT_VAULT_ID = 1;
    uint256 private constant EARNXRP_VAULT_ID = 2;

    /// @dev The Flare FXRP OFT adapter: the FXRP it holds funds the suite's transfers.
    address private constant FXRP_OFT_ADAPTER = 0xd70659a6396285BF7214d7Ea9673184e7C72E07E;
    uint32 private constant ETHEREUM_EID = 30101;
    bytes32 private constant ETHEREUM_PEER = bytes32(uint256(uint160(0xCE6170EA245dC8D1f275A710a062b70f125F0110)));
    uint256 private constant LOAN_SUBACCOUNT_TYPE = 1;

    // live accounts, chosen for what they hold at the pinned block
    // cspell:disable
    /// 33 characters; native, FXRP and earnXRP shares
    string private constant OWNER_33 = "r8V3BPz4WgVo81S7CQMyG3dPFFYJkHQup";
    address private constant ACCOUNT_33 = 0x6E600eE1a1cef8050917bd3aFF082F9377edB960;
    /// FXRP, earnXRP and mXRPY shares
    string private constant OWNER_HOLDER = "rBRYc7VctLs49s16dK6j2UeceCk4oZVyeJ";
    address private constant ACCOUNT_HOLDER = 0xb152FC031B9e67033e258846a31aFAcd9a82524E;
    /// FXRP and stXRP shares
    string private constant OWNER_STXRP = "r9uiVoWtutCeRj83xToy5Z16yKpUZvVJKx";
    address private constant ACCOUNT_STXRP = 0xf32C8574e91B8D0a59cc1c6Cd1ca7bE41112238e;
    /// the one standing allowance: unlimited FXRP to Firelight, granted by a user operation
    string private constant OWNER_ALLOWANCE = "rNPxGhruFNa6zUerKEtzF9KJBvPjqqoxT7";
    address private constant ACCOUNT_ALLOWANCE = 0x4603152603460FE440B8a2C9FbdF80ab71C5e97e;
    /// the largest native balance
    string private constant OWNER_NATIVE = "rNaFfVgbqWYotrR3Jz4RorirDUZgLfxhXt";
    address private constant ACCOUNT_NATIVE = 0xe7A124A08933d246398382be0Ce246157D9750a6;
    /// 26 characters, a valid classic address; created on the fork by the live code
    string private constant SHORT_OWNER = "rrrrrrrrrrrrrrrrrrrrBZbvji";
    // cspell:enable

    bool private forked;
    IERC20 private fxrp;
    IERC20 private wNat;
    address private shortAccount;
    address private personalAccountImplementation;
    address private loanSubaccountImplementation;
    uint256 private transactionNonce;

    string[] private owners;
    mapping(string owner => bytes holdings) private holdingsBefore;
    bytes[] private configurationBefore;
    bytes4[] private selectorsBefore;
    mapping(bytes4 selector => address facet) private facetBefore;
    mapping(uint256 instructionId => uint256 fee) private instructionFeeBefore;
    IDiamond.FacetCut[] private appliedCut;

    modifier onlyForked() {
        vm.skip(!forked, "set FLARE_RPC_URL to an archive endpoint serving the pinned block");
        _;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("FLARE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            require(
                !vm.envOr("REQUIRE_FLARE_FORK", false),
                "REQUIRE_FLARE_FORK is set: FLARE_RPC_URL must name an archive endpoint serving the pinned block"
            );
            return;
        }
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        assertEq(block.chainid, FLARE, "FLARE_RPC_URL does not serve Flare");
        forked = true;
        fxrp = ContractRegistry.getAssetManagerFXRP().fAsset();
        wNat = IERC20(address(ContractRegistry.getWNat()));
        // FDC proofs are the one thing a fork cannot produce; everything they gate is live code
        vm.mockCall(
            address(ContractRegistry.getFdcVerification()),
            abi.encodeWithSelector(IPaymentVerification.verifyPayment.selector),
            abi.encode(true)
        );

        assertEq(CONTROLLER.implementation(), LIVE_PERSONAL_ACCOUNT_IMPLEMENTATION, "the predecessor is live");
        uint256[] memory instructionIds = _instructionIds();
        for (uint256 i = 0; i < instructionIds.length; i++) {
            instructionFeeBefore[instructionIds[i]] = CONTROLLER.getInstructionFee(instructionIds[i]);
        }
        _createShortOwnerAccountWithLiveCode();
        owners.push(OWNER_33);
        owners.push(OWNER_HOLDER);
        owners.push(OWNER_STXRP);
        owners.push(OWNER_ALLOWANCE);
        owners.push(OWNER_NATIVE);
        owners.push(SHORT_OWNER);
        for (uint256 i = 0; i < owners.length; i++) {
            holdingsBefore[owners[i]] = abi.encode(_holdings(CONTROLLER.getPersonalAccount(owners[i])));
        }
        _snapshotConfiguration();
        _snapshotSelectors();

        _applyCut();
        personalAccountImplementation = address(new PersonalAccount());
        _governance(abi.encodeCall(CONTROLLER.setPersonalAccountImplementation, (personalAccountImplementation)));
        loanSubaccountImplementation = address(new LoanSubaccount());
        _governance(
            abi.encodeCall(
                CONTROLLER.setSubaccountImplementation,
                (LOAN_SUBACCOUNT_TYPE, loanSubaccountImplementation)
            )
        );
    }

    function testTheChosenAccountsHoldWhatTheyWereChosenFor() public onlyForked {
        // a moved pin would leave a case unexercised while every other test still passed
        Holdings memory h = abi.decode(holdingsBefore[OWNER_33], (Holdings));
        assertEq(bytes(h.xrplOwner).length, 33);
        assertGt(h.native, 0);
        assertGt(h.fxrp, 0);
        assertGt(h.earnXrp, 0);
        h = abi.decode(holdingsBefore[OWNER_HOLDER], (Holdings));
        assertGt(h.fxrp, 100e6);
        assertGt(h.earnXrp, 0);
        assertGt(h.mxrpy, 0);
        h = abi.decode(holdingsBefore[OWNER_STXRP], (Holdings));
        assertGt(h.fxrp, 2e6);
        assertGt(h.stXrp, 1e6);
        h = abi.decode(holdingsBefore[OWNER_ALLOWANCE], (Holdings));
        assertEq(h.fxrpAllowanceToFirelight, type(uint256).max);
        h = abi.decode(holdingsBefore[OWNER_NATIVE], (Holdings));
        assertGt(h.native, 1000 ether);
        h = abi.decode(holdingsBefore[SHORT_OWNER], (Holdings));
        assertLt(bytes(h.xrplOwner).length, 32, "the short owner is stored in its slot, not out of line");
        assertGt(h.stXrp, 0);
    }

    function testTheCutAddsAndRepointsButRemovesNothing() public onlyForked {
        for (uint256 i = 0; i < appliedCut.length; i++) {
            assertTrue(appliedCut[i].action != IDiamond.FacetCutAction.Remove, "the cut removes no selector");
        }
        // every selector the cut did not name still reaches the facet it reached before
        for (uint256 i = 0; i < selectorsBefore.length; i++) {
            bytes4 selector = selectorsBefore[i];
            address expected = _cutFacetOf(selector);
            if (expected == address(0)) {
                expected = facetBefore[selector];
            }
            assertEq(CONTROLLER.facetAddress(selector), expected);
        }
        // and every selector it added is new
        for (uint256 i = 0; i < appliedCut.length; i++) {
            if (appliedCut[i].action == IDiamond.FacetCutAction.Add) {
                bytes4[] memory added = appliedCut[i].functionSelectors;
                for (uint256 j = 0; j < added.length; j++) {
                    assertEq(facetBefore[added[j]], address(0), "an added selector was not live");
                    assertEq(CONTROLLER.facetAddress(added[j]), appliedCut[i].facetAddress);
                }
            }
        }
    }

    function testTheControllerConfigurationSurvives() public onlyForked {
        // the pinned block carries per-instruction overrides, so the fees compared are not all the default
        assertNotEq(instructionFeeBefore[0x00], instructionFeeBefore[0x01]);
        bytes[] memory calls = _configurationCalls();
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(CONTROLLER).staticcall(calls[i]);
            assertTrue(success);
            assertEq(result, configurationBefore[i], vm.toString(calls[i]));
        }
        assertEq(CONTROLLER.implementation(), personalAccountImplementation);
        assertEq(CONTROLLER.implementationForType(LOAN_SUBACCOUNT_TYPE), loanSubaccountImplementation);
    }

    function testExistingAccountsKeepTheirIdentityHoldingsAndAllowances() public onlyForked {
        for (uint256 i = 0; i < owners.length; i++) {
            string memory owner = owners[i];
            address account = CONTROLLER.getPersonalAccount(owner);
            assertEq(abi.encode(_holdings(account)), holdingsBefore[owner], owner);
            assertEq(IPersonalAccount(payable(account)).implementation(), personalAccountImplementation);
            (bool isSmartAccount, string memory xrplOwner) = CONTROLLER.isSmartAccount(account);
            assertTrue(isSmartAccount);
            assertEq(xrplOwner, owner);
        }
        assertEq(CONTROLLER.getPersonalAccount(OWNER_33), ACCOUNT_33);
        assertEq(CONTROLLER.getPersonalAccount(OWNER_HOLDER), ACCOUNT_HOLDER);
        assertEq(CONTROLLER.getPersonalAccount(OWNER_STXRP), ACCOUNT_STXRP);
        assertEq(CONTROLLER.getPersonalAccount(OWNER_ALLOWANCE), ACCOUNT_ALLOWANCE);
        assertEq(CONTROLLER.getPersonalAccount(OWNER_NATIVE), ACCOUNT_NATIVE);
        assertEq(CONTROLLER.getPersonalAccount(SHORT_OWNER), shortAccount);
    }

    function testUpshiftDepositAndRedeemRequestThroughAnUpgradedAccount() public onlyForked {
        uint256 fxrpBefore = fxrp.balanceOf(ACCOUNT_HOLDER);
        uint256 sharesBefore = IERC20(EARNXRP_LP).balanceOf(ACCOUNT_HOLDER);
        _executeInstruction(OWNER_HOLDER, _vaultReference(0x21, 100e6, EARNXRP_VAULT_ID));
        assertEq(fxrp.balanceOf(ACCOUNT_HOLDER), fxrpBefore - 100e6, "the deposit pulls exactly its amount");
        uint256 shares = IERC20(EARNXRP_LP).balanceOf(ACCOUNT_HOLDER);
        assertGt(shares, sharesBefore, "and mints shares");
        assertEq(fxrp.allowance(ACCOUNT_HOLDER, UPSHIFT_EARNXRP), 0, "and leaves no allowance");

        _executeInstruction(OWNER_HOLDER, _vaultReference(0x22, 1e6, EARNXRP_VAULT_ID));
        assertEq(IERC20(EARNXRP_LP).balanceOf(ACCOUNT_HOLDER), shares - 1e6, "the request takes its shares");
    }

    function testFirelightDepositAndRedeemThroughAnUpgradedAccount() public onlyForked {
        uint256 fxrpBefore = fxrp.balanceOf(ACCOUNT_STXRP);
        uint256 sharesBefore = IERC20(FIRELIGHT_STXRP).balanceOf(ACCOUNT_STXRP);
        _executeInstruction(OWNER_STXRP, _vaultReference(0x11, 2e6, FIRELIGHT_VAULT_ID));
        assertEq(fxrp.balanceOf(ACCOUNT_STXRP), fxrpBefore - 2e6);
        uint256 shares = IERC20(FIRELIGHT_STXRP).balanceOf(ACCOUNT_STXRP);
        assertGt(shares, sharesBefore);

        _executeInstruction(OWNER_STXRP, _vaultReference(0x12, 1e6, FIRELIGHT_VAULT_ID));
        assertEq(IERC20(FIRELIGHT_STXRP).balanceOf(ACCOUNT_STXRP), shares - 1e6);
    }

    function testTheShortOwnerAccountRedeemsWhatTheLiveCodeDeposited() public onlyForked {
        uint256 shares = IERC20(FIRELIGHT_STXRP).balanceOf(shortAccount);
        _executeInstruction(SHORT_OWNER, _vaultReference(0x12, shares, FIRELIGHT_VAULT_ID));
        assertEq(IERC20(FIRELIGHT_STXRP).balanceOf(shortAccount), 0);
    }

    function testAStandingAllowanceIsUsableAfterTheUpgrade() public onlyForked {
        // the allowance a user operation granted still lets its spender pull
        uint256 balance = fxrp.balanceOf(ACCOUNT_ALLOWANCE);
        assertGt(balance, 0);
        vm.prank(FIRELIGHT_STXRP);
        assertTrue(fxrp.transferFrom(ACCOUNT_ALLOWANCE, FIRELIGHT_STXRP, balance));
        assertEq(fxrp.balanceOf(ACCOUNT_ALLOWANCE), 0);
    }

    function testNativeMovesBothWaysThroughAnUpgradedAccount() public onlyForked {
        address recipient = makeAddr("recipient");
        uint256 nativeBefore = ACCOUNT_NATIVE.balance;
        IPersonalAccount.Call[] memory calls = new IPersonalAccount.Call[](1);
        calls[0] = IPersonalAccount.Call({target: recipient, value: 1 ether, data: ""});
        vm.prank(address(CONTROLLER));
        IPersonalAccount(payable(ACCOUNT_NATIVE)).executeUserOp(calls);
        assertEq(recipient.balance, 1 ether);
        assertEq(ACCOUNT_NATIVE.balance, nativeBefore - 1 ether);

        vm.prank(recipient);
        (bool success, ) = ACCOUNT_NATIVE.call{value: 1 ether}("");
        assertTrue(success, "the account still accepts native");
        assertEq(ACCOUNT_NATIVE.balance, nativeBefore);
    }

    function testCrossChainUserOpIsClosedUntilTheRoutesOpen() public onlyForked {
        // the selector is the new implementation's, behind a proxy that predates it; with no
        // route registered (Part D has not run) it refuses rather than sending
        IPersonalAccount.Call[] memory calls = _selfCall(ACCOUNT_33, 0, _crossChainUserOp(bytes32("op"), 0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPersonalAccount.CallFailed.selector,
                0,
                abi.encodeWithSelector(IPersonalAccount.UnknownBridgeRoute.selector, ETHEREUM_EID)
            )
        );
        vm.prank(address(CONTROLLER));
        IPersonalAccount(payable(ACCOUNT_33)).executeUserOp(calls);
    }

    function testCrossChainUserOpLeavesThroughAPreexistingProxyOnceTheRoutesOpen() public onlyForked {
        _openRoutes();
        bytes32 operationId = keccak256("rehearsal operation");
        uint64 deadline = uint64(vm.getBlockTimestamp() + 1 hours);
        uint256 fee = _quoteCrossChainUserOp(ACCOUNT_33, operationId, deadline);
        // the fee is added to the account, so what it held before is what it holds after
        uint256 nativeBefore = ACCOUNT_33.balance;
        vm.deal(ACCOUNT_33, nativeBefore + fee);
        address endpoint = address(IOAppCore(FXRP_OFT_ADAPTER).endpoint());
        uint64 nonceBefore = IOutboundNonce(endpoint).outboundNonce(FXRP_OFT_ADAPTER, ETHEREUM_EID, ETHEREUM_PEER);

        IPersonalAccount.Call[] memory calls = _selfCall(ACCOUNT_33, fee, _crossChainUserOp(operationId, deadline));
        vm.recordLogs();
        vm.prank(address(CONTROLLER));
        IPersonalAccount(payable(ACCOUNT_33)).executeUserOp(calls);

        assertEq(ACCOUNT_33.balance, nativeBefore, "exactly the quoted fee is spent");
        assertEq(
            IOutboundNonce(endpoint).outboundNonce(FXRP_OFT_ADAPTER, ETHEREUM_EID, ETHEREUM_PEER),
            nonceBefore + 1,
            "one packet left for Ethereum's peer"
        );
        (bytes32 sentOperationId, uint256 callCount, uint32 destinationEid, bytes32 guid) = _crossChainUserOpSent();
        assertEq(sentOperationId, operationId);
        assertEq(callCount, 1);
        assertEq(destinationEid, ETHEREUM_EID);
        assertNotEq(guid, bytes32(0));
    }

    function testASubaccountRedeemsThroughAPreexistingProxy() public onlyForked {
        // the parent is a live account; only its subaccount is new
        address subaccount = CONTROLLER.createSubaccount(OWNER_33, LOAN_SUBACCOUNT_TYPE);
        assertEq(CONTROLLER.getSubaccount(OWNER_33, LOAN_SUBACCOUNT_TYPE), subaccount);
        uint256 parentFxrp = fxrp.balanceOf(ACCOUNT_33);
        uint256 amount = 20e6;
        vm.prank(FXRP_OFT_ADAPTER);
        assertTrue(fxrp.transfer(subaccount, amount));
        (address executor, uint256 executorFee) = CONTROLLER.getExecutorInfo();
        address sweeper = makeAddr("sweeper");
        vm.deal(sweeper, executorFee);

        vm.expectEmit(ACCOUNT_33);
        emit IPersonalAccount.FXrpRedeemedFromSubaccount(subaccount, amount, amount, executor, executorFee);
        vm.prank(sweeper);
        (uint256 swept, uint256 redeemed) = IRedeemingSubaccount(subaccount).sweepRedeem{value: executorFee}();

        assertEq(swept, amount);
        assertEq(redeemed, amount, "FAssets fills the whole amount");
        assertEq(fxrp.balanceOf(subaccount), 0);
        assertEq(fxrp.balanceOf(ACCOUNT_33), parentFxrp, "the parent's own FXRP is not part of it");
        assertEq(fxrp.allowance(subaccount, ACCOUNT_33), 0, "and the pull leaves no allowance");
    }

    /// @dev The live code creates the account, through a Firelight deposit instruction, so its
    /// owner string is written by the predecessor's `initialize`.
    function _createShortOwnerAccountWithLiveCode() private {
        shortAccount = CONTROLLER.getPersonalAccount(SHORT_OWNER);
        assertEq(shortAccount.code.length, 0);
        vm.prank(FXRP_OFT_ADAPTER);
        assertTrue(fxrp.transfer(shortAccount, 10e6));
        _executeInstruction(SHORT_OWNER, _vaultReference(0x11, 10e6, FIRELIGHT_VAULT_ID));
        assertGt(shortAccount.code.length, 0);
    }

    /// @dev The cut tool's inputs are written from the fork - the facets this run deployed and the
    /// diamond's own loupe - and the tool reads the committed cut file, exactly as
    /// `ExecuteDiamondCut` drives it.
    function _applyCut() private {
        string memory json = vm.readFile(CUT_FILE);
        assertEq(vm.parseJsonAddress(json, ".diamond"), address(CONTROLLER), "the cut file targets this diamond");
        assertFalse(vm.keyExistsJson(json, ".init"), "the cut carries no init");
        string[] memory facetNames = vm.parseJsonStringArray(json, ".facets");
        string memory facetLines = "";
        for (uint256 i = 0; i < facetNames.length; i++) {
            address facet = deployCode(string.concat(facetNames[i], ".sol:", facetNames[i]));
            facetLines = string.concat(facetLines, vm.toString(facet), "|", facetNames[i], "\n");
        }
        vm.createDir(OUTPUT_DIR, true);
        vm.writeFile(FACETS_FILE, facetLines);
        vm.writeFile(LOUPE_FILE, _loupeLines());

        string[] memory command = new string[](11);
        command[0] = "npx";
        command[1] = "tsx";
        command[2] = "deployment/utils/build-cut.ts";
        command[3] = "--diamond";
        command[4] = vm.toString(address(CONTROLLER));
        command[5] = "--facets-file";
        command[6] = FACETS_FILE;
        command[7] = "--loupe-file";
        command[8] = LOUPE_FILE;
        command[9] = "--config";
        command[10] = CUT_FILE;
        (IDiamond.FacetCut[] memory cut, address init, bytes memory initData) =
            abi.decode(vm.ffi(command), (IDiamond.FacetCut[], address, bytes));
        for (uint256 i = 0; i < cut.length; i++) {
            appliedCut.push(cut[i]);
        }
        _governance(abi.encodeCall(IDiamondCut.diamondCut, (cut, init, initData)));
    }

    /// @dev One owner-only call through the timelock, as the runbook's shared procedure makes it:
    /// the Safe's submission queues it, and anyone executes it once the hour has passed.
    function _governance(
        bytes memory _call
    )
        private
    {
        vm.prank(OWNER_SAFE);
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = address(CONTROLLER).call(_call);
        assertTrue(success, "the owner's submission is accepted");
        uint256 executableAt = CONTROLLER.getExecuteTimelockedCallTimestamp(_call);
        assertEq(executableAt, vm.getBlockTimestamp() + TIMELOCK_SECONDS, "and queued for an hour");
        vm.warp(executableAt);
        vm.prank(makeAddr("anyone"));
        CONTROLLER.executeTimelockedCall(_call);
    }

    /// @dev Part D, in its order.
    function _openRoutes() private {
        _governance(abi.encodeCall(CONTROLLER.setFxrpOft, (FXRP_OFT_ADAPTER)));
        _governance(abi.encodeCall(CONTROLLER.setBridgeRoute, (ETHEREUM_EID, ETHEREUM_PEER)));
        _governance(abi.encodeCall(CONTROLLER.setSubaccountTypeRoute, (LOAN_SUBACCOUNT_TYPE, ETHEREUM_EID)));
        assertEq(CONTROLLER.getFxrpOft(), FXRP_OFT_ADAPTER);
        assertEq(CONTROLLER.getBridgeRoute(ETHEREUM_EID), ETHEREUM_PEER);
        (address oft, uint32 destinationEid, bytes32 destinationPeer) =
            CONTROLLER.getSubaccountTypeRoute(LOAN_SUBACCOUNT_TYPE);
        assertEq(oft, FXRP_OFT_ADAPTER);
        assertEq(destinationEid, ETHEREUM_EID);
        assertEq(destinationPeer, ETHEREUM_PEER);
    }

    function _executeInstruction(
        string memory _owner,
        bytes32 _paymentReference
    )
        private
    {
        IPayment.Proof memory proof;
        proof.data.sourceId = CONTROLLER.getSourceId();
        proof.data.requestBody.transactionId = keccak256(abi.encode("rehearsal transaction", ++transactionNonce));
        proof.data.responseBody.blockTimestamp = uint64(vm.getBlockTimestamp());
        proof.data.responseBody.sourceAddressHash = keccak256(bytes(_owner));
        proof.data.responseBody.receivingAddressHash = keccak256(bytes(CONTROLLER.getXrplProviderWallets()[0]));
        // the predecessor's fee, so a changed fee fails the instruction rather than being paid
        proof.data.responseBody.receivedAmount = int256(instructionFeeBefore[uint256(_paymentReference) >> 248]);
        proof.data.responseBody.standardPaymentReference = _paymentReference;
        CONTROLLER.executeInstruction(proof, _owner);
    }

    function _snapshotConfiguration() private {
        bytes[] memory calls = _configurationCalls();
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(CONTROLLER).staticcall(calls[i]);
            assertTrue(success, vm.toString(calls[i]));
            configurationBefore.push(result);
        }
    }

    function _snapshotSelectors() private {
        IDiamondLoupe.Facet[] memory facets = CONTROLLER.facets();
        for (uint256 i = 0; i < facets.length; i++) {
            for (uint256 j = 0; j < facets[i].functionSelectors.length; j++) {
                bytes4 selector = facets[i].functionSelectors[j];
                selectorsBefore.push(selector);
                facetBefore[selector] = facets[i].facetAddress;
            }
        }
    }

    function _crossChainUserOpSent()
        private
        returns (bytes32, uint256, uint32, bytes32)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == ACCOUNT_33 && logs[i].topics[0] == IPersonalAccount.CrossChainUserOpSent.selector) {
                return abi.decode(logs[i].data, (bytes32, uint256, uint32, bytes32));
            }
        }
        revert("no CrossChainUserOpSent from the account");
    }

    function _holdings(
        address _account
    )
        private view
        returns (Holdings memory _h)
    {
        IPersonalAccount account = IPersonalAccount(payable(_account));
        _h.xrplOwner = account.xrplOwner();
        _h.controller = account.controllerAddress();
        _h.native = _account.balance;
        _h.fxrp = fxrp.balanceOf(_account);
        _h.wNat = wNat.balanceOf(_account);
        _h.stXrp = IERC20(FIRELIGHT_STXRP).balanceOf(_account);
        _h.earnXrp = IERC20(EARNXRP_LP).balanceOf(_account);
        _h.mxrpy = IERC20(MXRPY_LP).balanceOf(_account);
        _h.fxrpAllowanceToFirelight = fxrp.allowance(_account, FIRELIGHT_STXRP);
        _h.earnXrpAllowanceToVault = IERC20(EARNXRP_LP).allowance(_account, UPSHIFT_EARNXRP);
        _h.mxrpyAllowanceToVault = IERC20(MXRPY_LP).allowance(_account, UPSHIFT_MXRPY);
    }

    /// @dev The loupe in the cut tool's input format: `facetAddress|sel1,sel2,...` per line.
    function _loupeLines()
        private view
        returns (string memory _lines)
    {
        IDiamondLoupe.Facet[] memory facets = CONTROLLER.facets();
        for (uint256 i = 0; i < facets.length; i++) {
            _lines = string.concat(_lines, vm.toString(facets[i].facetAddress), "|");
            bytes4[] memory selectors = facets[i].functionSelectors;
            for (uint256 j = 0; j < selectors.length; j++) {
                _lines = string.concat(_lines, vm.toString(abi.encodePacked(selectors[j])));
                if (j + 1 < selectors.length) {
                    _lines = string.concat(_lines, ",");
                }
            }
            _lines = string.concat(_lines, "\n");
        }
    }

    /// @dev The facet the applied cut points `_selector` at, or zero when the cut leaves it alone.
    function _cutFacetOf(
        bytes4 _selector
    )
        private view
        returns (address)
    {
        for (uint256 i = 0; i < appliedCut.length; i++) {
            bytes4[] memory selectors = appliedCut[i].functionSelectors;
            for (uint256 j = 0; j < selectors.length; j++) {
                if (selectors[j] == _selector) {
                    return appliedCut[i].facetAddress;
                }
            }
        }
        return address(0);
    }

    function _crossChainUserOp(
        bytes32 _operationId,
        uint64 _deadline
    )
        private view
        returns (bytes memory)
    {
        if (_deadline == 0) {
            _deadline = uint64(vm.getBlockTimestamp() + 1 hours);
        }
        return abi.encodeCall(
            IPersonalAccount.sendCrossChainUserOp,
            (ETHEREUM_EID, _remoteBatch(), _operationId, _deadline, _extraOptions())
        );
    }

    /// @dev The adapter's quote for the send the account builds: the same envelope, to the
    /// account's own address on Ethereum.
    function _quoteCrossChainUserOp(
        address _account,
        bytes32 _operationId,
        uint64 _deadline
    )
        private view
        returns (uint256)
    {
        SendParam memory sendParam = SendParam({
            dstEid: ETHEREUM_EID,
            to: bytes32(uint256(uint160(_account))),
            amountLD: 0,
            minAmountLD: 0,
            extraOptions: _extraOptions(),
            composeMsg: abi.encode(
                PAYLOAD_VERSION_1,
                PA_ACTION_EXECUTE,
                abi.encode(_operationId, _deadline, _remoteBatch())
            ),
            oftCmd: ""
        });
        MessagingFee memory fee = IOFT(FXRP_OFT_ADAPTER).quoteSend(sendParam, false);
        return fee.nativeFee;
    }

    /// @dev A vault instruction's reference: id in byte 0, value in bytes 2-11, vault id in 14-15.
    function _vaultReference(
        uint256 _instructionId,
        uint256 _value,
        uint256 _vaultId
    )
        private pure
        returns (bytes32)
    {
        return bytes32((_instructionId << 248) | (_value << 160) | (_vaultId << 128));
    }

    /// @dev Every configuration getter the predecessor's facets answer, which the cut must not
    /// change; the implementation registry is the one value the release does change.
    function _configurationCalls()
        private pure
        returns (bytes[] memory _calls)
    {
        uint256[] memory instructionIds = _instructionIds();
        _calls = new bytes[](14 + instructionIds.length);
        _calls[0] = abi.encodeWithSignature("owner()");
        _calls[1] = abi.encodeWithSignature("getTimelockDurationSeconds()");
        _calls[2] = abi.encodeWithSignature("getPausers()");
        _calls[3] = abi.encodeWithSignature("getUnpausers()");
        _calls[4] = abi.encodeWithSignature("isPaused()");
        _calls[5] = abi.encodeWithSignature("getExecutorInfo()");
        _calls[6] = abi.encodeWithSignature("getSourceId()");
        _calls[7] = abi.encodeWithSignature("getPaymentProofValidityDurationSeconds()");
        _calls[8] = abi.encodeWithSignature("getXrplProviderWallets()");
        _calls[9] = abi.encodeWithSignature("getDefaultInstructionFee()");
        _calls[10] = abi.encodeWithSignature("vaults()");
        _calls[11] = abi.encodeWithSignature("agentVaults()");
        _calls[12] = abi.encodeWithSignature("getVaults()");
        _calls[13] = abi.encodeWithSignature("getAgentVaults()");
        for (uint256 i = 0; i < instructionIds.length; i++) {
            _calls[14 + i] = abi.encodeWithSignature("getInstructionFee(uint256)", instructionIds[i]);
        }
    }

    /// @dev Every legacy instruction id: FXRP 0x00-0x02, Firelight 0x10-0x13, Upshift 0x20-0x23.
    function _instructionIds()
        private pure
        returns (uint256[] memory _ids)
    {
        _ids = new uint256[](11);
        _ids[0] = 0x00;
        _ids[1] = 0x01;
        _ids[2] = 0x02;
        _ids[3] = 0x10;
        _ids[4] = 0x11;
        _ids[5] = 0x12;
        _ids[6] = 0x13;
        _ids[7] = 0x20;
        _ids[8] = 0x21;
        _ids[9] = 0x22;
        _ids[10] = 0x23;
    }

    function _selfCall(
        address _account,
        uint256 _value,
        bytes memory _data
    )
        private pure
        returns (IPersonalAccount.Call[] memory _calls)
    {
        _calls = new IPersonalAccount.Call[](1);
        _calls[0] = IPersonalAccount.Call({target: _account, value: _value, data: _data});
    }

    /// @dev The batch the remote twin would execute; its content is the user's, so any call does.
    function _remoteBatch()
        private pure
        returns (IPersonalAccount.Call[] memory _calls)
    {
        _calls = new IPersonalAccount.Call[](1);
        _calls[0] = IPersonalAccount.Call({target: address(0xdead), value: 0, data: ""});
    }

    /// @dev Type-3 options: destination lzReceive gas, then index-0 lzCompose gas. The values only
    /// need to be accepted here; what the wire needs is gate 3's measurement.
    function _extraOptions()
        private pure
        returns (bytes memory)
    {
        bytes memory lzReceivePayload = abi.encodePacked(uint128(150_000));
        bytes memory lzComposePayload = abi.encodePacked(uint16(0), uint128(700_000));
        return abi.encodePacked(
            uint16(3),
            uint8(1), uint16(1 + lzReceivePayload.length), uint8(1), lzReceivePayload,
            uint8(1), uint16(1 + lzComposePayload.length), uint8(3), lzComposePayload
        );
    }
}
