// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IReferencedPaymentNonexistence} from "flare-periphery/src/flare/IReferencedPaymentNonexistence.sol";
import {IXRPPaymentNonexistence} from "flare-periphery/src/flare/IXRPPaymentNonexistence.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {ILoanSubaccount} from "../../userInterfaces/ILoanSubaccount.sol";
import {
    ILoanSubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ILoanSubaccountsFacet.sol";
import {IExecutorsFacet} from "../../userInterfaces/facets/IExecutorsFacet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
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
    uint256 public subaccountType;

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

    /// @dev Native can arrive as a bridge or redemption refund; {sweepNativeToParent} is its exit.
    /// The implementation contract itself (never initialized, no parent) rejects it.
    receive() external payable {
        require(parentPersonalAccount != address(0), NotInitialized());
    }

    /// @inheritdoc ILoanSubaccount
    function initialize(
        address _controllerAddress,
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        external
    {
        require(controllerAddress == address(0), AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        require(_parentPersonalAccount != address(0), InvalidParentPersonalAccount());
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ILoanSubaccountsFacet.InvalidSubaccountType());

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
        // a residual below the FAssets minimum cannot be redeemed; it leaves via sweepToParent
        uint256 minimumRedeemAmount = assetManager.minimumRedeemAmountUBA();
        require(_amount >= minimumRedeemAmount, BelowMinimumRedemption(minimumRedeemAmount));

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
            msg.value
        );
    }

    /// @inheritdoc ILoanSubaccount
    function sweepToLoan()
        external payable
        nonReentrant
        returns (uint256 _amount)
    {
        // no compose message and no options: this is cleanup, just moving the assets across;
        // acting on them on the destination side is the loan instruction's job
        (uint256 amount, uint32 destinationEid, bytes32 guid) = _bridgeToSelf("", "");
        emit FXrpSweptToLoan(parentPersonalAccount, amount, destinationEid, guid);
        _amount = amount;
    }

    /// @inheritdoc ILoanSubaccount
    function executeLayerZeroCall(
        bytes calldata _composeMsg,
        bytes calldata _extraOptions
    )
        external payable
        onlyParent
        nonReentrant
        returns (uint256 _amount)
    {
        // an empty payload would degrade to a plain transfer, which is sweepToLoan's job
        require(_composeMsg.length > 0, EmptyComposeMessage());
        (uint256 amount, uint32 destinationEid, bytes32 guid) = _bridgeToSelf(_extraOptions, _composeMsg);
        emit LayerZeroCallExecuted(
            parentPersonalAccount,
            amount,
            destinationEid,
            guid,
            keccak256(_composeMsg)
        );
        _amount = amount;
    }

    /// @inheritdoc ILoanSubaccount
    function redemptionPaymentDefault(
        IReferencedPaymentNonexistence.Proof calldata _proof,
        uint256 _redemptionRequestId
    )
        external
        onlyParent
    {
        // parent-driven relay: whether and when to default is the user's decision, and a public
        // relay would let anyone front-run the appointed executor's own call, which burns the
        // funded executor fee; the payout lands here, where sweepToParent recovers it
        ContractRegistry.getAssetManagerFXRP().redemptionPaymentDefault(_proof, _redemptionRequestId);
        emit RedemptionPaymentDefaulted(_redemptionRequestId);
    }

    /// @inheritdoc ILoanSubaccount
    function xrpRedemptionPaymentDefault(
        IXRPPaymentNonexistence.Proof calldata _proof,
        uint256 _redemptionRequestId
    )
        external
        onlyParent
    {
        ContractRegistry.getAssetManagerFXRP().xrpRedemptionPaymentDefault(_proof, _redemptionRequestId);
        emit XrpRedemptionPaymentDefaulted(_redemptionRequestId);
    }

    /// @inheritdoc ILoanSubaccount
    function sweepToParent(
        address _token
    )
        external
        nonReentrant
        returns (uint256 _amount)
    {
        // never on the implementation contract itself, where the parent is unset
        require(parentPersonalAccount != address(0), NotInitialized());
        IERC20 token = IERC20(_token);
        _amount = token.balanceOf(address(this));
        require(_amount > 0, NothingToSweep());

        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        if (_token == address(assetManager.fAsset())) {
            // the loan asset has its own two directions (sweepRedeem, sweepToLoan); recovery to
            // the parent only takes residuals that FAssets cannot redeem, so this method cannot
            // become a third direction for it
            uint256 minimumRedeemAmount = assetManager.minimumRedeemAmountUBA();
            require(
                _amount < minimumRedeemAmount,
                FXrpAboveMinimumRedemption(_amount, minimumRedeemAmount)
            );
        }

        token.safeTransfer(parentPersonalAccount, _amount);
        emit TokenSweptToParent(parentPersonalAccount, _token, _amount);
    }

    /// @inheritdoc ILoanSubaccount
    function sweepNativeToParent()
        external
        nonReentrant
        returns (uint256 _amount)
    {
        // never on the implementation contract itself: native can be force-sent even past the
        // guarded receive, and recovery there would burn it to the zero address
        require(parentPersonalAccount != address(0), NotInitialized());
        _amount = address(this).balance;
        require(_amount > 0, NothingToSweep());

        // false positive (arbitrary-send-eth): the recipient is the parent Personal Account,
        // fixed at initialization and part of this account's CREATE2 address — not caller-chosen;
        // the parent accepts native (it has a receive function)
        // slither-disable-start arbitrary-send-eth
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = parentPersonalAccount.call{value: _amount}("");
        // slither-disable-end arbitrary-send-eth
        require(success, NativeSweepFailed());
        emit NativeSweptToParent(parentPersonalAccount, _amount);
    }

    /// @inheritdoc ILoanSubaccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon; it resolves the implementation for this subaccount type
        return ILoanSubaccountsFacet(controllerAddress).loanImplementationForType(subaccountType);
    }

    /// @dev Shared forward-move core of {sweepToLoan} and {executeLayerZeroCall}: bridges the
    /// whole idle FXRP balance over LayerZero to this account's own address on the loan chain,
    /// so both entry points share the same guards by construction. Only the composed payload
    /// and the execution options vary; the destination is never caller-chosen.
    function _bridgeToSelf(
        bytes memory _extraOptions,
        bytes memory _composeMsg
    )
        private
        returns (uint256 _amount, uint32 _destinationEid, bytes32 _guid)
    {
        IERC20 fxrp = ContractRegistry.getAssetManagerFXRP().fAsset();
        _amount = fxrp.balanceOf(address(this));
        require(_amount > 0, NothingToSweep());

        // the forward move is the incident-containment surface: pausing the controller stops
        // bridging out immediately, while the backward sweep stays available so assets can
        // always exit toward the user's own XRPL address
        require(!IPauseFacet(controllerAddress).isPaused(), IPauseFacet.IsPaused());

        (address fxrpOft, uint32 destinationEid, bytes32 destinationPeer) =
            ILoanSubaccountsFacet(controllerAddress).getLoanBridgeSettings();
        require(
            fxrpOft != address(0) && destinationEid != 0 && destinationPeer != bytes32(0),
            LoanBridgeNotConfigured()
        );
        // a peer mutation on the OFT after configuration must fail closed, not deliver the
        // locked FXRP to an unknown remote OApp
        require(
            IOAppCore(fxrpOft).peers(destinationEid) == destinationPeer,
            WrongDestinationPeer()
        );

        // this account has the same address on every chain, so it is its own destination;
        // FXRP and the OFT share 6 decimals, so the full amount arrives and `minAmountLD`
        // can equal `amountLD`
        SendParam memory sendParam = SendParam({
            dstEid: destinationEid,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: _extraOptions,
            composeMsg: _composeMsg,
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

        _destinationEid = destinationEid;
        _guid = receipt.guid;
    }
}
