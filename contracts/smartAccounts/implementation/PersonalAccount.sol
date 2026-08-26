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
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {ILoanBridgeSettingsFacet} from "../../userInterfaces/facets/ILoanBridgeSettingsFacet.sol";
import {IPauseFacet} from "../../userInterfaces/facets/IPauseFacet.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IVaultsFacet} from "../../userInterfaces/facets/IVaultsFacet.sol";
import {IIVault} from "../interface/IIVault.sol";
import {IPersonalAccount} from "../../userInterfaces/IPersonalAccount.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PersonalAccount contract
 * @notice Account controlled by MasterAccountController contract. It corresponds to an XRPL address.
 * Supports account abstraction for XRPL-integrated user operations.
 */
contract PersonalAccount is
    IIPersonalAccount, ReentrancyGuardTransient,
    ERC721Holder, ERC1155Holder, IERC1363Receiver
{
    using SafeERC20 for IERC20;

    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;

    /// @notice MasterAccountController contract address
    address public controllerAddress;
    /// @notice XRPL address
    string public xrplOwner;

    modifier onlyController() {
        require(msg.sender == controllerAddress, OnlyController());
        _;
    }

    constructor() {
        // ensure the implementation contract itself cannot be initialized/used
        controllerAddress = EMPTY_ADDRESS;
    }

    receive() external payable {}

    /**
     * Proxyable initialization method. Can be called only once, from the proxy constructor
     * @param _controllerAddress MasterAccountController contract address
     * @param _xrplOwner XRPL address owner
     * @dev initialize is callable once by anyone (proxy constructor in practice)
     */
    function initialize(
        address _controllerAddress,
        string calldata _xrplOwner
    ) external {
        require(controllerAddress == address(0), AlreadyInitialized());
        require(_controllerAddress != address(0), InvalidControllerAddress());
        require(bytes(_xrplOwner).length > 0, InvalidXrplOwner());

        controllerAddress = _controllerAddress;
        xrplOwner = _xrplOwner;
    }

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
    function sendCrossChainInstruction(
        bytes calldata _payload,
        bytes calldata _extraOptions
    )
        external payable
    {
        // reachable only through executeUserOp (a self-call), so every instruction is
        // user-signed end-to-end; deliberately not nonReentrant - it runs inside
        // executeUserOp's transient guard, which a nested guard would trip
        require(msg.sender == address(this), OnlySelf());
        require(_payload.length > 0, EmptyCrossChainPayload());
        // a forward move: pausing the controller stops cross-chain instructions immediately
        require(!IPauseFacet(controllerAddress).isPaused(), IPauseFacet.IsPaused());

        (address fxrpOft, uint32 destinationEid, bytes32 destinationPeer) =
            ILoanBridgeSettingsFacet(controllerAddress).getLoanBridgeSettings();
        require(
            fxrpOft != address(0) && destinationEid != 0 && destinationPeer != bytes32(0),
            LoanBridgeNotConfigured()
        );
        // a peer mutation on the OFT after configuration must fail closed, not deliver the
        // instruction to an unknown remote OApp
        require(
            IOAppCore(fxrpOft).peers(destinationEid) == destinationPeer,
            WrongDestinationPeer()
        );

        // message-only send to this account's own address on the loan chain: the loan-chain
        // Personal Account authenticates `composeFrom` back to exactly this address
        SendParam memory sendParam = SendParam({
            dstEid: destinationEid,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: 0,
            minAmountLD: 0,
            extraOptions: _extraOptions,
            composeMsg: _payload,
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

        emit CrossChainInstructionSent(destinationEid, receipt.guid, keccak256(_payload));
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

    /// @inheritdoc IPersonalAccount
    function implementation() external view returns (address) {
        // controller is the beacon
        return IBeacon(controllerAddress).implementation();
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
}
