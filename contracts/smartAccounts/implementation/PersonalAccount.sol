// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AvailableAgentInfo.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC1363Receiver} from "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {IBridgeRoutesFacet} from "../../userInterfaces/facets/IBridgeRoutesFacet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IExecutorsFacet} from "../../userInterfaces/facets/IExecutorsFacet.sol";
import {
    ISubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ISubaccountsFacet.sol";
import {ISubaccount} from "../../userInterfaces/ISubaccount.sol";
import {PAYLOAD_VERSION_1} from "../../userInterfaces/IComposeReceiverAccountBase.sol";
import {PA_ACTION_EXECUTE} from "../../userInterfaces/IPersonalAccountRemote.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";
import {IIVault} from "../interface/IIVault.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";
import {PersonalAccountBase} from "./PersonalAccountBase.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PersonalAccount contract
 * @notice Account controlled by MasterAccountController contract. It corresponds to an XRPL address.
 * Supports account abstraction for XRPL-integrated user operations.
 */
contract PersonalAccount is
    IIPersonalAccount, PersonalAccountBase, ReentrancyGuardTransient,
    ERC721Holder, ERC1155Holder, IERC1363Receiver
{
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /// @dev Transient guard slot of {redeemFromSubaccount}, separate from the shared guard. Keep
    /// the identifier stable across implementations: a proxy's guards must agree across upgrades.
    bytes32 private constant SUBACCOUNT_REDEMPTION_GUARD_SLOT =
        keccak256("flare.smartAccounts.PersonalAccount.subaccountRedemptionGuard");

    modifier onlyController() {
        require(msg.sender == controllerAddress, OnlyController());
        _;
    }

    /// @dev The caller must equal the controller's prediction for this account's owner and
    /// the caller's reported non-zero type. The proxy creation code and the derivation are
    /// frozen, so no other contract can sit at that address; the self-reported type is only
    /// the index into that check.
    modifier onlySubaccount() {
        require(_isOwnSubaccount(msg.sender), OnlySubaccount());
        _;
    }

    /// @dev A separate guard domain, because the legitimate path re-enters this account:
    /// {executeUserOp} (shared guard held) -> subaccount.sweepRedeem ->
    /// {redeemFromSubaccount}. What it permits is bounded: the method writes no account state,
    /// creates no allowance of this account's and pulls before it redeems, so a redemption
    /// reached from beneath another guarded method cannot touch this account's pre-existing
    /// FXRP; a nested redemption is refused by this guard.
    modifier nonReentrantSubaccountRedemption() {
        require(
            !SUBACCOUNT_REDEMPTION_GUARD_SLOT.asBoolean().tload(),
            ReentrancyGuardReentrantCall()
        );
        SUBACCOUNT_REDEMPTION_GUARD_SLOT.asBoolean().tstore(true);
        _;
        SUBACCOUNT_REDEMPTION_GUARD_SLOT.asBoolean().tstore(false);
    }

    receive() external payable {}

    /// @inheritdoc IIPersonalAccount
    function reserveCollateral(
        address _agentVault,
        uint256 _lots,
        address payable _executor,
        uint256 _executorFee
    )
        external payable
        onlyController nonReentrant
        returns (uint256 _collateralReservationId)
    {
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();

        // Check agent vault status
        AgentInfo.Info memory agentInfo = assetManager.getAgentInfo(_agentVault);
        require(agentInfo.status == AgentInfo.Status.NORMAL, AgentNotAvailable());

        // Check fees
        uint256 collateralReservationFee = assetManager.collateralReservationFee(_lots);
        require(
            msg.value >= collateralReservationFee + _executorFee,
            InsufficientFundsForCollateralReservation(collateralReservationFee, _executorFee)
        );

        // Reserve collateral
        _collateralReservationId = assetManager.reserveCollateral{value: msg.value}(
            _agentVault,
            _lots,
            agentInfo.feeBIPS,
            _executor
        );
        assert(_collateralReservationId > 0);
        emit CollateralReserved(
            _agentVault,
            _lots,
            _executor,
            _executorFee,
            _collateralReservationId
        );
    }

    /// @inheritdoc IIPersonalAccount
    function transferFXrp(
        address _to,
        uint256 _amount
    )
        external
        onlyController nonReentrant
    {
        IERC20 fxrp = ContractRegistry.getAssetManagerFXRP().fAsset();
        fxrp.safeTransfer(_to, _amount);
        emit FXrpTransferred(_to, _amount);
    }

    /// @inheritdoc IIPersonalAccount
    function redeemFXrp(
        uint256 _lots,
        address payable _executor,
        uint256 _executorFee
    )
        external payable
        onlyController nonReentrant
        returns (uint256 _amount)
    {
        require(msg.value >= _executorFee, InsufficientFundsForRedeem(_executorFee));
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        _amount = assetManager.redeem{value: msg.value}(
            _lots,
            xrplOwner,
            _executor
        );
        emit FXrpRedeemed(_lots, _amount, _executor, _executorFee);
    }

    /// @inheritdoc IIPersonalAccount
    function deposit(
        IVaultsFacet.VaultType _vaultType,
        address _vault,
        uint256 _assets
    )
        external
        onlyController nonReentrant
        returns (uint256 _shares)
    {
        assert(
            _vaultType == IVaultsFacet.VaultType.Firelight ||
            _vaultType == IVaultsFacet.VaultType.Upshift
        );
        IERC20 fxrp = ContractRegistry.getAssetManagerFXRP().fAsset();
        require(fxrp.approve(_vault, _assets), ApprovalFailed());
        emit Approved(address(fxrp), _vault, _assets);

        if (_vaultType == IVaultsFacet.VaultType.Firelight) {
            _shares = IIVault(_vault).deposit(_assets, address(this));
        } else {
            _shares = IIVault(_vault).deposit(address(fxrp), _assets, address(this));
        }
        emit Deposited(_vault, _assets, _shares);
    }

    /// @inheritdoc IIPersonalAccount
    function redeem(
        address _vault,
        uint256 _shares
    )
        external
        onlyController nonReentrant
        returns (uint256 _assets)
    {
        _assets = IIVault(_vault).redeem(
            _shares,
            address(this),
            address(this)
        );
        emit Redeemed(_vault, _assets, _shares);
    }

    /// @inheritdoc IIPersonalAccount
    function claimWithdraw(
        address _vault,
        uint256 _period
    )
        external
        onlyController nonReentrant
        returns (uint256 _assets)
    {
        _assets = IIVault(_vault).claimWithdraw(_period);
        emit WithdrawalClaimed(_vault, _period, _assets);
    }

    /// @inheritdoc IIPersonalAccount
    function requestRedeem(
        address _vault,
        uint256 _shares
    )
        external
        onlyController nonReentrant
        returns (uint256 _claimableEpoch, uint256 _year, uint256 _month, uint256 _day)
    {
        address lpToken = IIVault(_vault).lpTokenAddress();
        IERC20(lpToken).forceApprove(_vault, _shares);
        emit Approved(lpToken, _vault, _shares);
        (_claimableEpoch, _year, _month, _day) = IIVault(_vault).requestRedeem(
            _shares,
            address(this)
        );
        emit RedeemRequested(_vault, _shares, _claimableEpoch, _year, _month, _day);
    }

    /// @inheritdoc IIPersonalAccount
    function claim(
        address _vault,
        uint256 _year,
        uint256 _month,
        uint256 _day
    )
        external
        onlyController nonReentrant
        returns (uint256 _shares, uint256 _assets)
    {
        (_shares, _assets) = IIVault(_vault).claim(
            _year,
            _month,
            _day,
            address(this)
        );
        emit Claimed(_vault, _year, _month, _day, _shares, _assets);
    }

    /// @inheritdoc IPersonalAccount
    function sendCrossChainUserOp(
        uint32 _destinationEid,
        IPersonalAccount.Call[] calldata _calls,
        bytes32 _operationId,
        uint64 _deadline,
        bytes calldata _extraOptions
    )
        external payable
    {
        // only a self-call from executeUserOp can reach this method, so the batch is
        // user-signed end-to-end and is not interpreted here; it reuses that call's active
        // guard rather than entering a second one, which a nested guard would trip
        require(msg.sender == address(this), OnlySelf());
        require(
            _operationId != bytes32(0) && _deadline >= block.timestamp && _calls.length > 0,
            InvalidCrossChainUserOp()
        );
        bytes32 guid =
            _sendCrossChainUserOp(_destinationEid, _calls, _operationId, _deadline, _extraOptions);
        emit CrossChainUserOpSent(_operationId, _calls.length, _destinationEid, guid);
    }

    /// @inheritdoc IPersonalAccount
    function redeemFromSubaccount(
        uint256 _amount
    )
        external payable
        onlySubaccount
        nonReentrantSubaccountRedemption
        returns (uint256 _redeemedAmount)
    {
        // value is optional here: sweepRedeem enforces the fee at the public entry, while an
        // authenticated compose redemption may appoint the executor unpaid. Whatever arrives
        // travels whole as the fee
        // slither-disable-next-line unused-return
        (address payable executor, ) = IExecutorsFacet(controllerAddress).getExecutorInfo();

        // pull and redeem exactly the caller's amount; this account's pre-existing FXRP is
        // never included, and what FAssets does not fill stays here, under the user's control
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        assetManager.fAsset().safeTransferFrom(msg.sender, address(this), _amount);
        _redeemedAmount = assetManager.redeemAmount{value: msg.value}(
            _amount,
            xrplOwner,
            executor
        );
        emit FXrpRedeemedFromSubaccount(
            msg.sender,
            _amount,
            _redeemedAmount,
            executor,
            msg.value
        );
    }

    /// @inheritdoc IPersonalAccount
    function executeUserOp(
        IPersonalAccount.Call[] calldata _calls
    )
        external payable
        onlyController nonReentrant
    {
        for (uint256 i = 0; i < _calls.length; i++) {
            (bool success, bytes memory result) = _calls[i].target.call{
                value: _calls[i].value
            }(_calls[i].data);
            if (!success) {
                revert CallFailed(i, result);
            }
        }
    }

    /// @inheritdoc IERC1363Receiver
    function onTransferReceived(
        address,
        address,
        uint256,
        bytes calldata
    )
        external pure
        returns (bytes4)
    {
        return IERC1363Receiver.onTransferReceived.selector;
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 _interfaceId
    )
        public view
        override(ERC1155Holder)
        returns (bool)
    {
        return
            _interfaceId == type(IERC721Receiver).interfaceId ||
            _interfaceId == type(IERC1363Receiver).interfaceId ||
            super.supportsInterface(_interfaceId); // ERC1155Holder covers IERC1155Receiver and IERC165
    }

    /// @dev Sends the signed batch as a message-only compose to this account's fixed remote
    /// address, where the twin authenticates `composeFrom` back to here and executes it.
    /// Requires an unpaused, configured route with the live peer still pinned; exactly the
    /// quoted fee is spent.
    function _sendCrossChainUserOp(
        uint32 _destinationEid,
        IPersonalAccount.Call[] memory _calls,
        bytes32 _operationId,
        uint64 _deadline,
        bytes calldata _extraOptions
    )
        private
        returns (bytes32 _guid)
    {
        // a forward move: pausing the controller stops cross-chain instructions immediately
        require(!IPauseFacet(controllerAddress).isPaused(), IPauseFacet.IsPaused());

        // the route registry is the allowlist of destinations: the adapter must be configured
        // and governance must have pinned a peer for exactly this endpoint
        address fxrpOft = IBridgeRoutesFacet(controllerAddress).getFxrpOft();
        bytes32 destinationPeer = IBridgeRoutesFacet(controllerAddress).getBridgeRoute(_destinationEid);
        require(
            fxrpOft != address(0) && destinationPeer != bytes32(0),
            UnknownBridgeRoute(_destinationEid)
        );
        // a peer mutation on the OFT after configuration must fail closed, not deliver the
        // instruction to an unknown remote OApp
        require(
            IOAppCore(fxrpOft).peers(_destinationEid) == destinationPeer,
            WrongDestinationPeer()
        );

        // the envelope is built here, so what the user signed is structured and a malformed
        // envelope cannot reach the bridge; the batch encodes as the remote account's Call[]
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            PA_ACTION_EXECUTE,
            abi.encode(_operationId, _deadline, _calls)
        );
        SendParam memory sendParam = SendParam({
            dstEid: _destinationEid,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: 0,
            minAmountLD: 0,
            extraOptions: _extraOptions,
            composeMsg: payload,
            oftCmd: ""
        });

        MessagingFee memory fee = IOFT(fxrpOft).quoteSend(sendParam, false);
        require(msg.value >= fee.nativeFee, InsufficientFundsForInstruction(fee.nativeFee));

        // exactly the quoted fee is spent; msg.value rides from this account's own balance
        // (a self-call), so the excess simply remains here - no refund transfer needed
        // slither-disable-start arbitrary-send-eth
        // solhint-disable-next-line check-send-result
        (MessagingReceipt memory receipt, ) = IOFT(fxrpOft).send{value: fee.nativeFee}(
            sendParam,
            fee,
            address(this)
        );
        // slither-disable-end arbitrary-send-eth

        _guid = receipt.guid;
    }

    /// @dev Whether `_caller` is one of this account's subaccounts (see {onlySubaccount}). A
    /// caller that is not a contract, or does not answer the type query, is not one.
    function _isOwnSubaccount(
        address _caller
    )
        private view
        returns (bool)
    {
        if (_caller.code.length == 0) {
            return false;
        }
        try ISubaccount(_caller).subaccountType() returns (uint256 subaccountType) {
            if (subaccountType == SUBACCOUNT_TYPE_NONE) {
                return false;
            }
            return ISubaccountsFacet(controllerAddress).getSubaccount(xrplOwner, subaccountType)
                == _caller;
        } catch {
            return false;
        }
    }
}
