// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PersonalAccount} from "../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";
import {PersonalAccountProxy} from "../contracts/smartAccounts/proxy/PersonalAccountProxy.sol";
import {IIVault} from "../contracts/smartAccounts/interface/IIVault.sol";
import {IVaultsFacet} from "../contracts/userInterfaces/facets/IVaultsFacet.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AgentInfo.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {MockBeacon} from "../contracts/mock/MockBeacon.sol";
import {MockERC721} from "../contracts/mock/MockERC721.sol";
import {MockERC1155} from "../contracts/mock/MockERC1155.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

contract PersonalAccountTest is Test {
    PersonalAccount private personalAccountImpl;
    PersonalAccountProxy private personalAccountProxy;
    PersonalAccount private personalAccount;

    address private controller;
    string private xrplOwner;
    address private contractRegistryMock;
    address private agentVault;
    address private executor;
    address private assetManagerMock;
    address private depositVault;
    address private fxrp = makeAddr("fxrp");

    function setUp() public {
        xrplOwner = "rExampleXrplAddress";
        contractRegistryMock = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
        agentVault = makeAddr("agentVault");
        executor = makeAddr("executor");
        assetManagerMock = makeAddr("assetManager");

        personalAccountImpl = new PersonalAccount();
        controller = address(new MockBeacon(address(personalAccountImpl)));
        personalAccountProxy = new PersonalAccountProxy(
            controller, // needs to implement the IBeacon interface
            xrplOwner
        );
        personalAccount = PersonalAccount(payable(address(personalAccountProxy)));

        depositVault = makeAddr("depositVault");
        fxrp = makeAddr("fxrp");

        _mockGetContractAddressByHash(
            "AssetManagerFXRP",
            assetManagerMock
        );

        // fund controller
        vm.deal(controller, 1 ether);
    }

    function testInitializeRevertAlreadyInitialized() public {
        vm.expectRevert(IPersonalAccount.AlreadyInitialized.selector);
        personalAccount.initialize(
            makeAddr("controller"),
            xrplOwner
        );
    }

    function testInitializeRevertInvalidCBeacon() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC1967Utils.ERC1967InvalidBeacon.selector,
                address(0)
            )
        );
        // vm.expectRevert(IPersonalAccount.InvalidControllerAddress.selector);
        // it will not reach the InvalidControllerAddress check because of invalid beacon
        new PersonalAccountProxy(
            address(0),
            xrplOwner
        );

    }

    function testInitializeRevertInvalidXrplOwner() public {
        vm.expectRevert(IPersonalAccount.InvalidXrplOwner.selector);
        new PersonalAccountProxy(
            controller,
            ""
        );
    }

    function testInitializeCheckValues() public {
        assertEq(personalAccount.controllerAddress(), controller);
        assertEq(personalAccount.xrplOwner(), xrplOwner);
    }

    function testReserveCollateralRevertOnlyController() public {
        vm.expectRevert(IPersonalAccount.OnlyController.selector);
        personalAccount.reserveCollateral(
            agentVault,
            1,
            payable(executor),
            1
        );
    }

    function testReserveCollateralRevertAgentNotAvailable() public {
        _mockGetAgentInfo(AgentInfo.Status.LIQUIDATION);
        vm.prank(controller);
        vm.expectRevert(IPersonalAccount.AgentNotAvailable.selector);
        personalAccount.reserveCollateral(
            agentVault,
            1,
            payable(executor),
            1
        );
    }

    function testReserveCollateralRevertInsufficientFunds() public {
        _mockGetAgentInfo(AgentInfo.Status.NORMAL);
        uint256 lots = 2;
        uint256 reservationFee = 100;
        uint256 executorFee = 10;
        _mockCollateralReservationFee(lots, reservationFee);
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPersonalAccount.InsufficientFundsForCollateralReservation.selector,
                reservationFee,
                executorFee
            )
        );
        personalAccount.reserveCollateral{value: reservationFee + executorFee - 1}(
            agentVault,
            lots,
            payable(executor),
            executorFee
        );
    }

    function testReserveCollateral() public {
        _mockGetAgentInfo(AgentInfo.Status.NORMAL);
        uint256 lots = 2;
        uint256 reservationFee = 100;
        uint256 executorFee = 10;
        _mockCollateralReservationFee(lots, reservationFee);
        uint256 reservationId = 42;
        _mockReserveCollateral(reservationId);
        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.CollateralReserved(
            agentVault,
            lots,
            executor,
            executorFee,
            reservationId
        );
        uint256 returnedReservationId = personalAccount.reserveCollateral{value: reservationFee + executorFee}(
            agentVault,
            lots,
            payable(executor),
            executorFee
        );
        assertEq(returnedReservationId, reservationId);
    }

    function testRedeemFXrpRevertOnlyController() public {
        vm.expectRevert(IPersonalAccount.OnlyController.selector);
        personalAccount.redeemFXrp(
            1,
            payable(executor),
            1
        );
    }

    function testRedeemFXrpRevertInsufficientFunds() public {
        uint256 lots = 2;
        uint256 executorFee = 10;
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPersonalAccount.InsufficientFundsForRedeem.selector,
                executorFee
            )
        );
        personalAccount.redeemFXrp{value: executorFee - 1}(
            lots,
            payable(executor),
            executorFee
        );
    }

    function testRedeemFXrp() public {
        uint256 lots = 2;
        uint256 executorFee = 10;
        uint256 amount = 1000;
        _mockRedeem(amount);
        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.FXrpRedeemed(
            lots,
            amount,
            executor,
            executorFee
        );
        uint256 returnedAmount = personalAccount.redeemFXrp{value: executorFee}(
            lots,
            payable(executor),
            executorFee
        );
        assertEq(returnedAmount, amount);
    }

    function testDepositRevertOnlyController() public {
        vm.expectRevert(IPersonalAccount.OnlyController.selector);
        personalAccount.deposit(
            IVaultsFacet.VaultType.Firelight,
            depositVault,
            100
        );
    }

    function testDepositRevertApprovalFailed() public {
        _mockApprove(false); // simulate approval failure
        _mockAsset();
        vm.prank(controller);
        vm.expectRevert(IPersonalAccount.ApprovalFailed.selector);
        personalAccount.deposit(
            IVaultsFacet.VaultType.Firelight,
            depositVault,
            0
        );
    }

    function testDeposit1() public {
        uint256 assets = 500;
        uint256 shares = 501;
        _mockApprove(true);
        _mockAsset();

        vm.mockCall(
            depositVault,
            abi.encodeWithSelector(
                bytes4(keccak256("deposit(uint256,address)"))
            ),
            abi.encode(shares)
        );

        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.Approved(
            fxrp,
            depositVault,
            assets
        );
        vm.expectEmit();
        emit IPersonalAccount.Deposited(
            depositVault,
            assets,
            shares
        );
        uint256 returnedShares = personalAccount.deposit(
            IVaultsFacet.VaultType.Firelight,
            depositVault,
            assets
        );
        assertEq(returnedShares, shares);
    }

    function testDeposit2() public {
        uint256 assets = 500;
        uint256 shares = 501;
        _mockApprove(true);
        _mockAsset();

        vm.mockCall(
            depositVault,
            abi.encodeWithSelector(
                bytes4(keccak256("deposit(address,uint256,address)"))
            ),
            abi.encode(shares)
        );

        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.Approved(
            fxrp,
            depositVault,
            assets
        );
        vm.expectEmit();
        emit IPersonalAccount.Deposited(
            depositVault,
            assets,
            shares
        );
        uint256 returnedShares = personalAccount.deposit(
            IVaultsFacet.VaultType.Upshift,
            depositVault,
            assets
        );
        assertEq(returnedShares, shares);
    }

    function testRedeemRevertOnlyController() public {
        vm.expectRevert(IPersonalAccount.OnlyController.selector);
        personalAccount.redeem(
            depositVault,
            100
        );
    }

    function testRedeem() public {
        uint256 assets = 500;
        uint256 shares = 501;

        vm.mockCall(
            depositVault,
            abi.encodeWithSelector(
                IIVault.redeem.selector
            ),
            abi.encode(assets)
        );

        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.Redeemed(
            depositVault,
            assets,
            shares
        );
        uint256 returnedAssets = personalAccount.redeem(
            depositVault,
            shares
        );
        assertEq(returnedAssets, assets);
    }

    function testClaimWithdrawRevertOnlyController() public {
        vm.expectRevert(IPersonalAccount.OnlyController.selector);
        personalAccount.claimWithdraw(
            depositVault,
            1
        );
    }

    function testClaimWithdraw() public {
        uint256 period = 1;
        uint256 assets = 500;

        vm.mockCall(
            depositVault,
            abi.encodeWithSelector(
                IIVault.claimWithdraw.selector,
                period
            ),
            abi.encode(assets)
        );

        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.WithdrawalClaimed(
            depositVault,
            period,
            assets
        );
        uint256 returnedAssets = personalAccount.claimWithdraw(
            depositVault,
            period
        );
        assertEq(returnedAssets, assets);
    }

    function testRequestRedeemRevertOnlyController() public {
        vm.expectRevert(IPersonalAccount.OnlyController.selector);
        personalAccount.requestRedeem(
            depositVault,
            100
        );
    }

    function testRequestRedeem() public {
        uint256 shares = 500;
        uint256 claimableEpoch = 42;
        uint256 year = 2024;
        uint256 month = 1;
        uint256 day = 1;

        vm.mockCall(
            depositVault,
            abi.encodeWithSelector(
                IIVault.requestRedeem.selector
            ),
            abi.encode(claimableEpoch, year, month, day)
        );

        vm.mockCall(
            depositVault,
            abi.encodeWithSelector(
                IIVault.lpTokenAddress.selector
            ),
            abi.encode(depositVault)
        );

        vm.mockCall(
            depositVault,
            abi.encodeWithSelector(
                IERC20.approve.selector,
                depositVault,
                shares
            ),
            abi.encode(true)
        );

        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.RedeemRequested(
            depositVault,
            shares,
            claimableEpoch,
            year,
            month,
            day
        );
        (uint256 returnedClaimableEpoch, uint256 returnedYear, uint256 returnedMonth, uint256 returnedDay) =
            personalAccount.requestRedeem(
                depositVault,
                shares
            );
        assertEq(returnedClaimableEpoch, claimableEpoch);
        assertEq(returnedYear, year);
        assertEq(returnedMonth, month);
        assertEq(returnedDay, day);
    }

    function testClaimRevertOnlyController() public {
        vm.expectRevert(IPersonalAccount.OnlyController.selector);
        personalAccount.claim(
            depositVault,
            2024,
            1,
            1
        );
    }

    function testClaim() public {
        uint256 year = 2024;
        uint256 month = 1;
        uint256 day = 1;
        uint256 shares = 500;
        uint256 assets = 600;

        vm.mockCall(
            depositVault,
            abi.encodeWithSelector(
                IIVault.claim.selector,
                year,
                month,
                day
            ),
            abi.encode(shares, assets)
        );

        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.Claimed(
            depositVault,
            year,
            month,
            day,
            shares,
            assets
        );
        (uint256 returnedShares, uint256 returnedAssets) = personalAccount.claim(
            depositVault,
            year,
            month,
            day
        );
        assertEq(returnedShares, shares);
        assertEq(returnedAssets, assets);
    }

    function testReceiveERC721() public {
        MockERC721 nft = new MockERC721();
        address minter = makeAddr("minter");
        nft.mint(minter, 1);
        vm.prank(minter);
        nft.safeTransferFrom(minter, address(personalAccount), 1);
        assertEq(nft.ownerOf(1), address(personalAccount));
    }

    function testReceiveERC1155() public {
        MockERC1155 token = new MockERC1155();
        address minter = makeAddr("minter");
        token.mint(minter, 1, 10);
        vm.prank(minter);
        token.safeTransferFrom(minter, address(personalAccount), 1, 5, "");
        assertEq(token.balanceOf(address(personalAccount), 1), 5);
    }

    function testReceiveERC1155Batch() public {
        MockERC1155 token = new MockERC1155();
        address minter = makeAddr("minter");
        token.mint(minter, 1, 10);
        token.mint(minter, 2, 20);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5;
        amounts[1] = 15;
        vm.prank(minter);
        token.safeBatchTransferFrom(minter, address(personalAccount), ids, amounts, "");
        assertEq(token.balanceOf(address(personalAccount), 1), 5);
        assertEq(token.balanceOf(address(personalAccount), 2), 15);
    }

    function testSupportsInterface() public view {
        assertTrue(personalAccount.supportsInterface(type(IERC721Receiver).interfaceId));
        assertTrue(personalAccount.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertTrue(personalAccount.supportsInterface(type(IERC165).interfaceId));
        assertFalse(personalAccount.supportsInterface(bytes4(0xdeadbeef)));
    }

    //// helper functions
    function _mockGetContractAddressByHash(
        string memory _name,
        address _addr
    )
        private
    {
        vm.mockCall(
            contractRegistryMock,
            abi.encodeWithSelector(
                IFlareContractRegistry.getContractAddressByHash.selector,
                keccak256(abi.encode(_name))
            ),
            abi.encode(_addr)
        );
    }

    function _mockGetAgentInfo(AgentInfo.Status _status) private {
        AgentInfo.Info memory info;
        info.status = _status;
        vm.mockCall(
            assetManagerMock,
            abi.encodeWithSelector(
                IAssetManager.getAgentInfo.selector,
                agentVault
            ),
            abi.encode(info)
        );
    }

    function _mockCollateralReservationFee(uint256 _lots, uint256 _fee) private {
        vm.mockCall(
            assetManagerMock,
            abi.encodeWithSelector(
                IAssetManager.collateralReservationFee.selector,
                _lots
            ),
            abi.encode(_fee)
        );
    }

    function _mockReserveCollateral(uint256 _reservationId) private {
        vm.mockCall(
            assetManagerMock,
            abi.encodeWithSelector(
                IAssetManager.reserveCollateral.selector
            ),
            abi.encode(_reservationId)
        );
    }

    function _mockRedeem(uint256 _amount) private {
        vm.mockCall(
            assetManagerMock,
            abi.encodeWithSelector(
                IAssetManager.redeem.selector
            ),
            abi.encode(_amount)
        );
    }

    function _mockApprove(bool _success) private {
        vm.mockCall(
            fxrp,
            abi.encodeWithSelector(
                IERC20.approve.selector
            ),
            abi.encode(_success)
        );
    }

    function _mockAsset() private {
        vm.mockCall(
            assetManagerMock,
            abi.encodeWithSelector(
                IAssetManager.fAsset.selector
            ),
            abi.encode(fxrp)
        );
    }
}
