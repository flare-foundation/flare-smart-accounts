// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {GUID} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import {IMessagingChannel} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessagingChannel.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {
    IEthereumLoanSubaccount,
    PAYLOAD_VERSION_1,
    ACTION_BORROW,
    ACTION_WITHDRAW,
    DESTINATION_KIND_EVM,
    SKIP_REASON_DUPLICATE,
    SKIP_REASON_EXPIRED
} from "../../userInterfaces/IEthereumLoanSubaccount.sol";
import {IEthereumLoanSettingsFacet} from "../../userInterfaces/facets/IEthereumLoanSettingsFacet.sol";
import {
    ILoanSubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ILoanSubaccountsFacet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IMorpho} from "../interface/IMorpho.sol";

/**
 * @title EthereumLoanSubaccount contract
 * @notice The Ethereum-side loan subaccount implementation: same frozen proxy, same CREATE2
 * address as the Flare-side account, different implementation behind the controller-as-beacon.
 * It has no parent-driven methods — the parent Personal Account exists only on Flare — so
 * every authorized action arrives through {lzCompose}, authenticated down to the LayerZero
 * packet GUID, and everything else is permissionless movement along fixed rails (added in the
 * next step).
 */
contract EthereumLoanSubaccount is IEthereumLoanSubaccount, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using OFTComposeMsgCodec for bytes;

    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;

    /// @notice MasterAccountController address.
    address public controllerAddress;
    /// @notice Parent Personal Account address (a Flare-side address; no code on this chain).
    address public parentPersonalAccount;
    /// @notice Subaccount type.
    uint256 public subaccountType;
    /// @inheritdoc IEthereumLoanSubaccount
    mapping(bytes32 operationId => bool used) public usedOperations;

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controllerAddress = EMPTY_ADDRESS;
    }

    // note: no `receive()` yet - it is added together with the native exit in the
    // asset-moving steps, so the account can never hold native it cannot release

    /// @inheritdoc IEthereumLoanSubaccount
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

    /// @inheritdoc ILayerZeroComposer
    /// @dev The authenticated entry point for loan actions. The executor and extra data are
    /// untrusted and ignored; authorization comes from the message itself: only the LayerZero
    /// endpoint may deliver it, only the configured FXRP OFT may have sent it, only from the
    /// configured origin chain, only this account itself (same address on the origin chain)
    /// may be the source-chain sender, and the delivered GUID must equal the one recomputed
    /// from the pinned origin peer — the compose wrapper alone does not commit to the source
    /// OApp, so this last check is what defeats a temporarily swapped OFT peer. A message
    /// failing any check reverts; the composed transfer's tokens are already on this account
    /// and stay recoverable, and the delivery can be retried through the endpoint.
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    )
        external payable
        nonReentrant
    {
        // the loan flow never sends compose value, and the account has no native exit
        require(msg.value == 0, NonZeroComposeValue());

        IEthereumLoanSettingsFacet.Settings memory settings = _getSettings();
        _authenticate(settings, _from, _guid, _message);

        // a composed loan action moves value onward: pausing the controller stops it; the
        // compose stays queued at the endpoint and can be re-delivered after unpausing
        require(!IPauseFacet(controllerAddress).isPaused(), IPauseFacet.IsPaused());

        (uint8 version, uint8 action, bytes memory actionData) =
            abi.decode(_message.composeMsg(), (uint8, uint8, bytes));
        require(version == PAYLOAD_VERSION_1, UnsupportedPayloadVersion(version));
        if (action == ACTION_BORROW) {
            _executeBorrow(settings, actionData, _guid, _message.amountLD());
        } else if (action == ACTION_WITHDRAW) {
            _executeWithdraw(settings, actionData, _guid);
        } else {
            revert UnsupportedAction(action);
        }
    }

    /// @inheritdoc IEthereumLoanSubaccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon; it resolves the implementation for this subaccount type
        return ILoanSubaccountsFacet(controllerAddress).loanImplementationForType(subaccountType);
    }

    /// @dev Supplies exactly the authenticated bridged amount as collateral — never the idle
    /// balance, which can commingle unrelated transfers — and, for a non-zero `borrowAmount`,
    /// borrows the loan token against the account's own position and disburses it to the
    /// payload's destination. The destination is the user's choice, authorized by the XRPL
    /// signature that produced the composed payload on the origin chain.
    function _executeBorrow(
        IEthereumLoanSettingsFacet.Settings memory _settings,
        bytes memory _actionData,
        bytes32 _guid,
        uint256 _bridgedAmount
    )
        private
    {
        (
            bytes32 operationId,
            uint64 deadline,
            bytes32 expectedMarketId,
            uint8 destinationKind,
            bytes32 destination,
            uint256 borrowAmount
        ) = abi.decode(_actionData, (bytes32, uint64, bytes32, uint8, bytes32, uint256));
        require(_bridgedAmount > 0 || borrowAmount > 0, NothingToDo());
        _validateAction(operationId, expectedMarketId, _settings);
        if (_skipped(operationId, deadline, _guid)) return;
        usedOperations[operationId] = true;

        if (_bridgedAmount > 0) {
            IERC20 fxrp = IERC20(_settings.marketParams.collateralToken);
            uint256 balance = fxrp.balanceOf(address(this));
            // the credited tokens can have been moved before this delivery (documented,
            // accepted race); this is a cap, not provenance - every balance here is the same
            // account's own - but it stops a signed action from absorbing more than its credit
            require(balance >= _bridgedAmount, InsufficientComposeBalance(_bridgedAmount, balance));
            fxrp.forceApprove(_settings.morpho, _bridgedAmount);
            IMorpho(_settings.morpho).supplyCollateral(
                _settings.marketParams, _bridgedAmount, address(this), ""
            );
        }
        if (borrowAmount > 0) {
            // only the EVM/ERC-20 form is implemented; the Wormhole-to-XRPL kind is reserved
            require(
                destinationKind == DESTINATION_KIND_EVM,
                UnsupportedDestinationKind(destinationKind)
            );
            // the destination must be a clean zero-padded, non-zero EVM address
            require(
                destination != bytes32(0) && uint256(destination) >> 160 == 0,
                InvalidDestination()
            );
            (uint256 assetsBorrowed, ) = IMorpho(_settings.morpho).borrow(
                _settings.marketParams, borrowAmount, 0, address(this), address(this)
            );
            IERC20(_settings.marketParams.loanToken).safeTransfer(
                address(uint160(uint256(destination))), assetsBorrowed
            );
        }

        emit LoanOpened(
            parentPersonalAccount,
            operationId,
            _bridgedAmount,
            borrowAmount,
            destinationKind,
            destination,
            _guid
        );
    }

    /// @dev Withdraws collateral from the account's own position to the account itself, where
    /// it leaves only along the fixed rails. Morpho enforces the resulting position health.
    function _executeWithdraw(
        IEthereumLoanSettingsFacet.Settings memory _settings,
        bytes memory _actionData,
        bytes32 _guid
    )
        private
    {
        (bytes32 operationId, uint64 deadline, bytes32 expectedMarketId, uint256 amount) =
            abi.decode(_actionData, (bytes32, uint64, bytes32, uint256));
        require(amount > 0, NothingToDo());
        _validateAction(operationId, expectedMarketId, _settings);
        if (_skipped(operationId, deadline, _guid)) return;
        usedOperations[operationId] = true;

        IMorpho(_settings.morpho).withdrawCollateral(
            _settings.marketParams, amount, address(this), address(this)
        );
        emit CollateralWithdrawn(parentPersonalAccount, operationId, amount, _guid);
    }

    /// @dev The soft gates shared by all actions: an already-executed operation id or a stale
    /// deadline completes the delivery without executing, leaving the bridged FXRP on the
    /// fixed rails. Skipping never consumes the operation id, so a stale intent can be retried
    /// under the same id with a fresh deadline.
    function _skipped(
        bytes32 _operationId,
        uint64 _deadline,
        bytes32 _guid
    )
        private
        returns (bool)
    {
        uint8 reason;
        if (usedOperations[_operationId]) {
            reason = SKIP_REASON_DUPLICATE;
        } else if (block.timestamp > _deadline) {
            reason = SKIP_REASON_EXPIRED;
        } else {
            return false;
        }
        emit LoanActionSkipped(parentPersonalAccount, _operationId, reason, _guid);
        return true;
    }

    /// @dev The full authentication checklist for a composed message; see {lzCompose}.
    function _authenticate(
        IEthereumLoanSettingsFacet.Settings memory _settings,
        address _from,
        bytes32 _guid,
        bytes calldata _message
    )
        private view
    {
        require(msg.sender == _settings.lzEndpoint, OnlyEndpoint());
        require(_from == _settings.fxrpOft, WrongComposeSender(_from));
        uint32 srcEid = _message.srcEid();
        require(srcEid == _settings.originEid, WrongSourceEid(srcEid));
        // the canonical OFT codec records the source-chain caller of `send`; only this account
        // itself bridges composed FXRP here, so any other sender's payload must not execute
        bytes32 composeFrom = _message.composeFrom();
        require(
            composeFrom == bytes32(uint256(uint160(address(this)))),
            WrongComposeFrom(composeFrom)
        );
        // bind the message to the pinned origin peer: the endpoint computed the GUID from the
        // true packet header, so it cannot match unless the sender was exactly the pinned peer
        bytes32 expectedGuid = GUID.generate(
            _message.nonce(),
            srcEid,
            address(uint160(uint256(_settings.originPeer))),
            IMessagingChannel(_settings.lzEndpoint).eid(),
            bytes32(uint256(uint160(_settings.fxrpOft)))
        );
        require(_guid == expectedGuid, WrongGuid(_guid));
    }

    function _getSettings()
        private view
        returns (IEthereumLoanSettingsFacet.Settings memory _settings)
    {
        _settings = IEthereumLoanSettingsFacet(controllerAddress).getEthereumLoanSettings();
        require(_settings.lzEndpoint != address(0), EthereumLoanSettingsNotConfigured());
    }

    /// @dev The hard shape gates shared by all actions: the operation id must be non-zero,
    /// and the configured market must be the one the payload was signed for. The market check
    /// is deliberately a revert, not a skip: a mismatch is temporary (settings can change
    /// back), and a permissionless delivery during the window must not consume the packet.
    function _validateAction(
        bytes32 _operationId,
        bytes32 _expectedMarketId,
        IEthereumLoanSettingsFacet.Settings memory _settings
    )
        private pure
    {
        require(_operationId != bytes32(0), InvalidOperationId());
        require(
            _expectedMarketId == keccak256(abi.encode(_settings.marketParams)),
            WrongMarket(_expectedMarketId)
        );
    }
}
