// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {ILoanSubaccount} from "../../userInterfaces/ILoanSubaccount.sol";
import {ILoanSubaccountsFacet} from "../../userInterfaces/facets/ILoanSubaccountsFacet.sol";
import {IExecutorsFacet} from "../../userInterfaces/facets/IExecutorsFacet.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";

/**
 * @title LoanSubaccount contract
 * @notice Deterministic staging account for loan-related assets owned by a Personal Account.
 * @dev The controller (MasterAccountController Diamond) is the beacon: the proxy and this
 * contract resolve the implementation per subaccount type through {loanImplementationForType}.
 */
contract LoanSubaccount is ILoanSubaccount, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;

    /// @notice MasterAccountController address.
    address public controllerAddress;
    /// @notice Parent Personal Account address.
    address public parentPersonalAccount;
    /// @notice Subaccount type.
    ILoanSubaccountsFacet.SubaccountType public subaccountType;

    /// @dev Restricted methods are reached through FSA account abstraction: an XRPL-signed
    /// instruction drives the controller, which drives the parent Personal Account, which calls
    /// this subaccount. The parent is fixed at deployment and is part of this account's address.
    modifier onlyParent() {
        require(msg.sender == parentPersonalAccount, OnlyParent());
        _;
    }

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controllerAddress = EMPTY_ADDRESS;
    }

    /// @inheritdoc ILoanSubaccount
    function initialize(
        address _controllerAddress,
        address _parentPersonalAccount,
        ILoanSubaccountsFacet.SubaccountType _subaccountType
    )
        external
    {
        require(controllerAddress == address(0), AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        require(_parentPersonalAccount != address(0), InvalidParentPersonalAccount());
        require(
            _subaccountType != ILoanSubaccountsFacet.SubaccountType.None,
            ILoanSubaccountsFacet.InvalidSubaccountType()
        );

        controllerAddress = _controllerAddress;
        parentPersonalAccount = _parentPersonalAccount;
        subaccountType = _subaccountType;

        emit LoanSubaccountInitialized(_controllerAddress, _parentPersonalAccount, _subaccountType);
    }

    /// @inheritdoc ILoanSubaccount
    function sweepRedeem()
        external payable
        nonReentrant
        returns (uint256 _amount, uint256 _redeemedAmount)
    {
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        _amount = assetManager.fAsset().balanceOf(address(this));
        require(_amount > 0, NothingToRedeem());

        (address payable executor, uint256 executorFee) =
            IExecutorsFacet(controllerAddress).getExecutorInfo();
        require(msg.value >= executorFee, InsufficientFundsForRedeem(executorFee));

        _redeemedAmount = assetManager.redeemAmount{value: msg.value}(
            _amount,
            IPersonalAccount(parentPersonalAccount).xrplOwner(),
            executor
        );

        emit FXrpRedeemed(
            parentPersonalAccount,
            _amount,
            _redeemedAmount,
            executor,
            executorFee
        );
    }

    /// @inheritdoc ILoanSubaccount
    function sweepToLoan()
        external payable
        nonReentrant
        returns (uint256 _amount)
    {
        IERC20 fxrp = ContractRegistry.getAssetManagerFXRP().fAsset();
        _amount = fxrp.balanceOf(address(this));
        require(_amount > 0, NothingToSweep());

        (address fxrpOft, uint32 destinationEid) =
            ILoanSubaccountsFacet(controllerAddress).getLoanBridgeSettings();
        require(fxrpOft != address(0) && destinationEid != 0, LoanBridgeNotConfigured());

        // this account has the same address on every chain, so it is its own destination;
        // the OFT enforces its own execution options, and FXRP and the OFT share 6 decimals,
        // so the full amount arrives and `minAmountLD` can equal `amountLD`
        SendParam memory sendParam = SendParam({
            dstEid: destinationEid,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory fee = IOFT(fxrpOft).quoteSend(sendParam, false);
        require(msg.value >= fee.nativeFee, InsufficientFundsForSweep(fee.nativeFee));

        // the OFT is a lock/unlock adapter, so it must be approved to pull the FXRP
        fxrp.forceApprove(fxrpOft, _amount);
        // two false positives on this call: slither arbitrary-send-eth (recipient is the
        // governance-set OFT, value capped by the msg.value check above) and solhint
        // check-send-result (this is the OFT's `send`, not address.send; it reverts on failure)
        // slither-disable-start arbitrary-send-eth
        // solhint-disable-next-line check-send-result
        (MessagingReceipt memory receipt, ) = IOFT(fxrpOft).send{value: fee.nativeFee}(
            sendParam,
            fee,
            msg.sender
        );
        // slither-disable-end arbitrary-send-eth
        fxrp.forceApprove(fxrpOft, 0);

        // return the caller's excess, so it is not stranded on an account with no native exit
        uint256 excess = msg.value - fee.nativeFee;
        if (excess > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = msg.sender.call{value: excess}("");
            require(success, RefundFailed());
        }

        emit FXrpSweptToLoan(parentPersonalAccount, _amount, destinationEid, receipt.guid);
    }

    /// @inheritdoc ILoanSubaccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon; it resolves the implementation for this subaccount type
        return ILoanSubaccountsFacet(controllerAddress).loanImplementationForType(subaccountType);
    }
}
