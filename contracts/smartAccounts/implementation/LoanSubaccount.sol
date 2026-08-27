// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {ILoanSubaccount} from "../../userInterfaces/ILoanSubaccount.sol";
import {PAYLOAD_VERSION_1} from "../../userInterfaces/ILoanChainAccountBase.sol";
import {
    ACTION_BORROW,
    ACTION_WITHDRAW,
    DESTINATION_KIND_EVM
} from "../../userInterfaces/ILoanChainSubaccount.sol";
import {ISubaccount} from "../../userInterfaces/ISubaccount.sol";
import {
    ISubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ISubaccountsFacet.sol";
import {ILoanBridgeSettingsFacet} from "../../userInterfaces/facets/ILoanBridgeSettingsFacet.sol";
import {IExecutorsFacet} from "../../userInterfaces/facets/IExecutorsFacet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";

/**
 * @title LoanSubaccount contract
 * @notice Deterministic staging account for loan-related assets owned by a Personal Account.
 * @dev The controller (MasterAccountController Diamond) is the beacon: the proxy and this
 * contract resolve the implementation per subaccount type through {implementationForType}.
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

    /// @dev Native can arrive as an external refund or with an instruction sent before the
    /// account existed; {sweepNativeToParent} is its exit. The implementation contract itself
    /// (never initialized, no parent) rejects it.
    receive() external payable {
        require(parentPersonalAccount != address(0), NotInitialized());
    }

    /// @inheritdoc ISubaccount
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
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ISubaccountsFacet.InvalidSubaccountType());

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
        IERC20 fxrp = assetManager.fAsset();
        _amount = fxrp.balanceOf(address(this));
        require(_amount > 0, NothingToRedeem());
        // the permissionless rail costs the configured executor fee - paid to the FAssets
        // executor when a redemption happens, to the parent when it does not - so forcing the
        // backward direction is never gas-only (the accepted sweep-direction griefing bound)
        // slither-disable-next-line unused-return
        (, uint256 executorFee) = IExecutorsFacet(controllerAddress).getExecutorInfo();
        require(msg.value >= executorFee, InsufficientFundsForRedeem(executorFee));

        if (_amount < assetManager.minimumRedeemAmountUBA()) {
            // FAssets would reject the redemption: the balance still goes home, unredeemed, and
            // the value joins the user's float on the parent - the rail never fails on amount.
            // Whatever FAssets does not redeem stays on the parent; here that is all of it
            fxrp.safeTransfer(parentPersonalAccount, _amount);
            if (msg.value > 0) {
                // false positive (arbitrary-send-eth): the recipient is the parent, fixed at
                // initialization and part of this account's address - not caller-chosen
                // slither-disable-next-line arbitrary-send-eth
                // solhint-disable-next-line avoid-low-level-calls
                (bool success, ) = parentPersonalAccount.call{value: msg.value}("");
                require(success, NativeSweepFailed());
                emit NativeSweptToParent(parentPersonalAccount, msg.value);
            }
            emit TokenSweptToParent(parentPersonalAccount, address(fxrp), _amount);
            return (_amount, 0);
        }

        // the parent redeems: it pulls exactly this amount and redeems exactly that, so it is
        // the recorded redeemer and every redemption outcome lands on it, under the user's
        // control; the whole msg.value rides along for the executor fee
        fxrp.forceApprove(parentPersonalAccount, _amount);
        _redeemedAmount = IPersonalAccount(parentPersonalAccount).redeemFromSubaccount{
            value: msg.value
        }(_amount);

        emit FXrpRedeemed(
            parentPersonalAccount,
            _amount,
            _redeemedAmount
        );
    }

    /// @inheritdoc ILoanSubaccount
    function sweepToLoan()
        external payable
        nonReentrant
        returns (uint256 _amount)
    {
        // cleanup sweeps the whole balance; no compose message and no options - acting on the
        // assets on the destination side is the loan instruction's job
        _amount = ContractRegistry.getAssetManagerFXRP().fAsset().balanceOf(address(this));
        require(_amount > 0, NothingToSweep());
        (uint32 destinationEid, bytes32 guid) = _bridgeToSelf(_amount, "", "");
        emit FXrpSweptToLoan(parentPersonalAccount, _amount, destinationEid, guid);
    }

    /// @inheritdoc ILoanSubaccount
    function borrow(
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        uint8 _destinationKind,
        bytes32 _destination,
        bytes32 _operationId,
        uint64 _deadline,
        bytes calldata _extraOptions
    )
        external payable
        onlyParent
        nonReentrant
    {
        // fail fast on Flare, before any bridge fee is paid; the loan chain re-validates
        require(
            _operationId != bytes32(0) &&
                _deadline >= block.timestamp &&
                (_collateralAmount > 0 || _borrowAmount > 0),
            InvalidLoanInstruction()
        );
        if (_borrowAmount > 0) {
            // only the EVM form exists today; a clean non-zero address other than this account
            // (the parent - the user's own loan-chain account - is a valid target)
            address destinationAddress = address(uint160(uint256(_destination)));
            require(
                _destinationKind == DESTINATION_KIND_EVM &&
                    uint256(_destination) >> 160 == 0 &&
                    destinationAddress != address(0) &&
                    destinationAddress != address(this),
                InvalidLoanInstruction()
            );
        }
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(_operationId, _deadline, _destinationKind, _destination, _borrowAmount)
        );
        (uint32 destinationEid, bytes32 guid) =
            _bridgeToSelf(_collateralAmount, _extraOptions, payload);
        emit BorrowInstructionSent(
            parentPersonalAccount,
            _operationId,
            _collateralAmount,
            _borrowAmount,
            _destinationKind,
            _destination,
            destinationEid,
            guid
        );
    }

    /// @inheritdoc ILoanSubaccount
    function withdraw(
        uint256 _amount,
        bytes32 _operationId,
        uint64 _deadline,
        bytes calldata _extraOptions
    )
        external payable
        onlyParent
        nonReentrant
    {
        require(
            _operationId != bytes32(0) && _deadline >= block.timestamp && _amount > 0,
            InvalidLoanInstruction()
        );
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_WITHDRAW,
            abi.encode(_operationId, _deadline, _amount)
        );
        (uint32 destinationEid, bytes32 guid) = _bridgeToSelf(0, _extraOptions, payload);
        emit WithdrawInstructionSent(
            parentPersonalAccount, _operationId, _amount, destinationEid, guid
        );
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

        // FXRP moves only on its own rails - sweepRedeem (which pushes a balance below the
        // FAssets minimum to the parent unredeemed) and the forward moves - so a permissionless
        // push cannot front-run the redemption executors run
        require(
            _token != address(ContractRegistry.getAssetManagerFXRP().fAsset()),
            ProtectedToken(_token)
        );
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

    /// @inheritdoc ISubaccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon; it resolves the implementation for this subaccount type
        return ISubaccountsFacet(controllerAddress).implementationForType(subaccountType);
    }

    /// @dev Shared forward-move core of {sweepToLoan}, {borrow} and {withdraw}: bridges
    /// exactly `_amount` FXRP over LayerZero to this account's own address on the loan chain,
    /// so both entry points share the same guards by construction. A zero amount is a
    /// message-only send (the loan instruction's withdraw and configuration actions carry no
    /// tokens); the destination is never caller-chosen.
    function _bridgeToSelf(
        uint256 _amount,
        bytes memory _extraOptions,
        bytes memory _composeMsg
    )
        private
        returns (uint32 _destinationEid, bytes32 _guid)
    {
        IERC20 fxrp = ContractRegistry.getAssetManagerFXRP().fAsset();
        uint256 balance = fxrp.balanceOf(address(this));
        require(_amount <= balance, AmountExceedsBalance(_amount, balance));

        // the forward move is the incident-containment surface: pausing the controller stops
        // bridging out immediately, while the backward sweep stays available so assets can
        // always exit toward the user's own XRPL address
        require(!IPauseFacet(controllerAddress).isPaused(), IPauseFacet.IsPaused());

        (address fxrpOft, uint32 destinationEid, bytes32 destinationPeer) =
            ILoanBridgeSettingsFacet(controllerAddress).getLoanBridgeSettings();
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
        if (_amount > 0) {
            fxrp.forceApprove(fxrpOft, _amount);
        }
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
        if (_amount > 0) {
            fxrp.forceApprove(fxrpOft, 0);
        }

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
