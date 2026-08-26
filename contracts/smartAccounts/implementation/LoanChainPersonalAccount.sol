// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {
    ILoanChainPersonalAccount,
    PA_ACTION_TRANSFER_TOKEN
} from "../../userInterfaces/ILoanChainPersonalAccount.sol";
import {LoanChainAccountBase} from "./LoanChainAccountBase.sol";

/**
 * @title LoanChainPersonalAccount contract
 * @notice The loan-chain-side Personal Account implementation: the
 * same frozen PA proxy and CREATE2 address as the user's Flare Personal Account, resolved
 * per chain through the controller-as-beacon. Instructions exist only on Flare, so this
 * account has no controller-driven methods at all; every authorized action arrives through
 * the authenticated `lzCompose` (see {LoanChainAccountBase}) sent by this same account on
 * Flare, and the action set is deliberately minimal and typed — one signed exact-amount
 * token transfer out, and nothing permissionless. Mistaken token sends and strays land here -
 * and, once loan subaccount recovery is redirected to the parent (planned), recovered surplus
 * will too - where the user can always move them by signature. It accepts no native and has
 * no native exit (nothing in the protocol ever sends native - or FXRP - here; the
 * implementation is beacon-upgradeable if a real inflow ever needs a rail).
 */
contract LoanChainPersonalAccount is ILoanChainPersonalAccount, LoanChainAccountBase {
    using SafeERC20 for IERC20;

    /// @notice XRPL owner (the same string the Flare Personal Account is derived from).
    string public xrplOwner;

    // deliberately no receive(): nothing in the protocol ever pushes native at this account
    // (there is no payable entry besides the value-rejecting lzCompose), so plain native
    // sends revert at the sender

    /**
     * @notice Proxyable initialization method, called once from the frozen PA proxy's
     * constructor (`initialize(address,string)` — the selector the proxy commits to).
     * @param _controllerAddress MasterAccountController contract address.
     * @param _xrplOwner The XRPL owner.
     */
    function initialize(
        address _controllerAddress,
        string calldata _xrplOwner
    )
        external
    {
        _setController(_controllerAddress);
        require(bytes(_xrplOwner).length > 0, InvalidXrplOwner());
        xrplOwner = _xrplOwner;
        emit LoanChainPersonalAccountInitialized(_controllerAddress, _xrplOwner);
    }

    /// @inheritdoc ILoanChainPersonalAccount
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon, exactly as for the Flare Personal Account
        return IBeacon(controller).implementation();
    }

    /// @dev The account's action set (see {LoanChainAccountBase._dispatch}): one typed
    /// signed transfer. Pause-gated - it is an outward move, and during an incident the pause
    /// must stop even signed-looking traffic, since a transport compromise is exactly what an
    /// incident looks like.
    function _dispatch(
        uint8 _action,
        bytes memory _actionData,
        bytes32 _guid,
        uint256 /* _amountLD */
    )
        internal override
    {
        if (_action == PA_ACTION_TRANSFER_TOKEN) {
            _executeTransferToken(_actionData, _guid);
        } else {
            revert UnsupportedAction(_action);
        }
    }

    /// @dev A signed exact-amount ERC-20 transfer to a destination of the user's choice:
    /// hard argument checks revert (retriable), terminal gates skip (finalize without
    /// effect), then the pause is checked and the id consumed.
    function _executeTransferToken(
        bytes memory _actionData,
        bytes32 _guid
    )
        private
    {
        (bytes32 operationId, uint64 deadline, address token, address destination, uint256 amount) =
            abi.decode(_actionData, (bytes32, uint64, address, address, uint256));
        require(operationId != bytes32(0), InvalidOperationId());
        require(amount > 0, ZeroAmount());
        // the user's money and the user's choice - shape rules only: non-zero, and not this
        // account (a self-transfer is a no-op that would only consume the id)
        require(
            destination != address(0) && destination != address(this),
            InvalidDestination()
        );
        uint8 reason = _terminalSkipReason(operationId, deadline);
        if (reason != 0) {
            emit ActionSkipped(operationId, reason, _guid);
            return;
        }
        // outward moves stop while paused; the compose stays queued at the endpoint and
        // re-delivers after unpausing
        _checkNotPaused();
        usedOperations[operationId] = true;

        IERC20(token).safeTransfer(destination, amount);
        emit TokenTransferred(token, destination, amount, operationId, _guid);
    }
}
