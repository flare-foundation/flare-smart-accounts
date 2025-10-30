// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PersonalAccount} from "../contracts/smartAccounts/implementation/PersonalAccount.sol";
import {IPersonalAccount} from "../contracts/userInterfaces/IPersonalAccount.sol";
import {PersonalAccountProxy} from "../contracts/smartAccounts/proxy/PersonalAccountProxy.sol";
import {IIVault} from "../contracts/smartAccounts/interface/IIVault.sol";
import {IFlareContractRegistry} from "flare-periphery/src/flare/IFlareContractRegistry.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AgentInfo.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {FtsoV2Interface} from "flare-periphery/src/flare/FtsoV2Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {MockBeacon} from "./mock/MockBeacon.sol";

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
        personalAccount = PersonalAccount(address(personalAccountProxy));

        depositVault = makeAddr("depositVault");
        fxrp = makeAddr("fxrp");

        _mockGetContractAddressByHash(
            "AssetManagerFXRP",
            assetManagerMock
        );

        // fund controller
        vm.deal(controller, 1 ether);
    }

    function testInitializeImplementationRevert() public {
        vm.expectRevert(IPersonalAccount.AlreadyInitialized.selector);
        personalAccountImpl.initialize(makeAddr("controller"), xrplOwner);
    }

    function testInitializeRevertAlreadyInitialized() public {
        vm.expectRevert(IPersonalAccount.AlreadyInitialized.selector);
        personalAccount.initialize(makeAddr("controller"), xrplOwner);
    }

    // function testInitializeRevertInvalidControllerAddress() public {
    //     vm.expectRevert(IPersonalAccount.InvalidControllerAddress.selector);
    //     new PersonalAccountProxy(
    //         address(0),
    //         xrplOwner
    //     );
    // }

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

    function testRedeemRevertOnlyController() public {
        vm.expectRevert(IPersonalAccount.OnlyController.selector);
        personalAccount.redeem(
            1,
            payable(executor),
            1
        );
    }

    function testRedeemRevertInsufficientFunds() public {
        uint256 lots = 2;
        uint256 executorFee = 10;
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPersonalAccount.InsufficientFundsForRedeem.selector,
                executorFee
            )
        );
        personalAccount.redeem{value: executorFee - 1}(
            lots,
            payable(executor),
            executorFee
        );
    }

    function testRedeem() public {
        uint256 lots = 2;
        uint256 executorFee = 10;
        uint256 amount = 1000;
        _mockRedeem(amount);
        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.Redeemed(
            lots,
            amount,
            executor,
            executorFee
        );
        uint256 returnedAmount = personalAccount.redeem{value: executorFee}(
            lots,
            payable(executor),
            executorFee
        );
        assertEq(returnedAmount, amount);
    }

    function testDepositRevertOnlyController() public {
        vm.expectRevert(IPersonalAccount.OnlyController.selector);
        personalAccount.deposit(
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
            depositVault,
            0
        );
    }

    function testDeposit() public {
        uint256 assets = 500;
        uint256 shares = 501;
        _mockApprove(true);
        _mockAsset();

        vm.mockCall(
            depositVault,
            abi.encodeWithSelector(
                IIVault.deposit.selector
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
            depositVault,
            assets
        );
        assertEq(returnedShares, shares);
    }

    function testWithdrawRevertOnlyController() public {
        vm.expectRevert(IPersonalAccount.OnlyController.selector);
        personalAccount.withdraw(
            depositVault,
            100
        );
    }

    function testWithdraw() public {
        uint256 assets = 500;
        uint256 shares = 501;

        vm.mockCall(
            depositVault,
            abi.encodeWithSelector(
                IIVault.withdraw.selector
            ),
            abi.encode(shares)
        );

        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.Withdrawn(
            depositVault,
            assets,
            shares
        );
        uint256 returnedShares = personalAccount.withdraw(
            depositVault,
            assets
        );
        assertEq(returnedShares, shares);
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
        uint256 assets = 600;
        uint256 claimableEpoch = 42;

        vm.mockCall(
            depositVault,
            abi.encodeWithSelector(
                IIVault.requestRedeem.selector
            ),
            abi.encode(assets, claimableEpoch)
        );

        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.RedeemRequested(
            depositVault,
            shares,
            assets,
            claimableEpoch
        );
        (uint256 returnedAssets, uint256 returnedClaimableEpoch) = personalAccount.requestRedeem(
            depositVault,
            shares
        );
        assertEq(returnedAssets, assets);
        assertEq(returnedClaimableEpoch, claimableEpoch);
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

    function testExecuteSwapRevertOnlyController() public {
        vm.expectRevert(IPersonalAccount.OnlyController.selector);
        personalAccount.executeSwap(
            address(0),
            address(0),
            bytes21(0),
            address(0),
            bytes21(0),
            0,
            0
        );
    }

    function testExecuteSwap() public {
        address uniswapV3Router = makeAddr("uniswapV3Router");
        address tokenIn = makeAddr("tokenIn");
        bytes21 tokenInFeedId = bytes21(keccak256("tokenInFeedId"));
        address tokenOut = makeAddr("tokenOut");
        bytes21 tokenOutFeedId = bytes21(keccak256("tokenOutFeedId"));
        uint256 amountIn = 1000;
        uint256 amountOut = 950;

        // mock personal account balance of tokenIn
        vm.mockCall(
            tokenIn,
            abi.encodeWithSelector(
                IERC20.balanceOf.selector,
                address(personalAccount)
            ),
            abi.encode(amountIn)
        );

        address ftsoV2 = makeAddr("ftsoV2");
        // mock get FtsoV2
        _mockGetContractAddressByHash(
            "FtsoV2",
            ftsoV2
        );

        // mock getFeedsByIdInWei
        bytes21[] memory feedIds = new bytes21[](2);
        feedIds[0] = tokenInFeedId;
        feedIds[1] = tokenOutFeedId;
        uint256[] memory valuesInWei = new uint256[](2);
        valuesInWei[0] = 1234; // mock price for tokenIn
        valuesInWei[1] = 12345; // mock price for tokenOut
        vm.mockCall(
            ftsoV2,
            abi.encodeWithSelector(
                FtsoV2Interface.getFeedsByIdInWei.selector,
                feedIds
            ),
            abi.encode(valuesInWei)
        );

        // mock safeIncreaseAllowance
        vm.mockCall(
            tokenIn,
            abi.encodeWithSelector(
                IERC20.allowance.selector,
                address(personalAccount),
                uniswapV3Router
            ),
            abi.encode(0)
        );

        // mock exactInputSingle
        vm.mockCall(
            uniswapV3Router,
            abi.encodeWithSelector(
                ISwapRouter.exactInputSingle.selector
            ),
            abi.encode(amountOut)
        );

        vm.prank(controller);
        vm.expectEmit();
        emit IPersonalAccount.SwapExecuted(
            tokenIn,
            tokenOut,
            amountIn,
            amountOut
        );
        personalAccount.executeSwap(
            uniswapV3Router,
            tokenIn,
            tokenInFeedId,
            tokenOut,
            tokenOutFeedId,
            3000,
            5000
        );
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
            depositVault,
            abi.encodeWithSelector(
                IIVault.asset.selector
            ),
            abi.encode(fxrp)
        );
    }
}
