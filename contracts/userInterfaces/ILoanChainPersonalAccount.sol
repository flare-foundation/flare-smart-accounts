// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {ILoanChainAccountBase} from "./ILoanChainAccountBase.sol";

/// @dev Execute action: `actionData` is `abi.encode(bytes32 operationId, uint64 deadline,
/// Call[] calls)`. Runs the signed batch of calls from this account, in order, all or nothing
/// for calls that revert: the loan-chain form of the Flare `executeUserOp`, carried by the
/// authenticated compose instead of the controller. The user's XRPL signature covers every
/// target, value and calldata, exactly as it does on Flare - and, as there, return data is
/// not interpreted: a callee that reports failure by returning `false` (some ERC-20s) or a
/// codeless target counts as a successful call, so the wallet must know the callee's success
/// convention.
uint8 constant PA_ACTION_EXECUTE = 1;

/**
 * @title ILoanChainPersonalAccount
 * @notice User interface for the loan-chain-side Personal Account: the implementation
 * registered behind the frozen PA proxy on the loan-chain diamond (Ethereum, at launch),
 * living at the same CREATE2 address as the user's Flare Personal Account. It has no local
 * owner and no controller-driven methods — instructions exist only on Flare — so every
 * authorized action arrives as an authenticated LayerZero compose message sent by this same
 * account on Flare (`executeLoanChainUserOp`). The action set is exactly one action: execute
 * a signed batch of calls, the way the Flare account executes `executeUserOp`. The blast
 * radius is therefore the same as a controller compromise on Flare: a compromised compose
 * root has the full on-chain authority of this address - balances, approvals, external
 * positions and any role granted to it - but no authority over the loan subaccount beyond
 * its permissionless fixed rails (it has no parent-driven methods on this chain, so
 * collateral and debt stay behind its own compose authentication). There is
 * no permissionless rail: what arrives here (borrow proceeds the user directed here,
 * recovered loan-token surplus, strays, native delivered with a message to fund
 * value-carrying calls) moves only by the user's signature.
 */
interface ILoanChainPersonalAccount is ILoanChainAccountBase {
    /// @notice One call of a signed batch. Field-identical to the Flare `IPersonalAccount.Call`
    /// (the sender encodes that struct, this account decodes this one - the same ABI layout).
    struct Call {
        /// @notice Target contract or recipient.
        address target;
        /// @notice Native value (in wei) to send with the call, from this account's balance.
        uint256 value;
        /// @notice Call data; empty for a plain native transfer.
        bytes data;
    }

    /**
     * @notice Emitted when a loan-chain Personal Account is initialized.
     * @param controllerAddress The controller address.
     * @param xrplOwner The XRPL owner.
     */
    event LoanChainPersonalAccountInitialized(
        address indexed controllerAddress,
        string xrplOwner
    );

    /**
     * @notice Emitted when a signed batch of calls executed.
     * @param operationId The user-chosen operation id, now consumed.
     * @param callCount The number of calls executed.
     * @param guid The LayerZero message id the action arrived with.
     */
    event UserOpExecuted(
        bytes32 operationId,
        uint256 callCount,
        bytes32 guid
    );

    /**
     * @notice Emitted when an authenticated action completes without executing.
     * @param operationId The payload's operation id. A duplicate was already consumed; an
     * expired skip leaves it unconsumed (the intent can retry under it).
     * @param reason The skip reason (see the `SKIP_REASON_*` constants).
     * @param guid The LayerZero message id the action arrived with.
     */
    event ActionSkipped(
        bytes32 operationId,
        uint8 reason,
        bytes32 guid
    );

    /**
     * @notice Reverts if the XRPL owner is invalid (empty).
     */
    error InvalidXrplOwner();

    /**
     * @notice Reverts on an empty batch, which would only consume the operation id.
     */
    error EmptyUserOp();

    /**
     * @notice Reverts if a call of the batch fails: the whole delivery reverts (all or
     * nothing) and stays retriable at the endpoint, with the id unconsumed.
     * @param index The index of the call that failed.
     * @param returnData The return data of the failed call.
     */
    error CallFailed(
        uint256 index,
        bytes returnData
    );

    /**
     * @notice Reverts on the implementation contract itself, which is never initialized: it
     * must not accept native, since nothing could ever move it out again.
     */
    error NotInitialized();

    /**
     * @notice The XRPL owner this account belongs to.
     * @return The XRPL owner.
     */
    function xrplOwner()
        external view
        returns (string memory);

    /**
     * @notice The implementation this account currently runs, resolved through the
     * controller-as-beacon.
     * @return The implementation address.
     */
    function implementation()
        external view
        returns (address);
}
