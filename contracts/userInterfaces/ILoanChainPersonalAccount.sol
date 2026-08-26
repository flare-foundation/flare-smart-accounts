// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {ILoanChainAccountBase} from "./ILoanChainAccountBase.sol";

/// @dev Transfer-token action: `actionData` is `abi.encode(bytes32 operationId,
/// uint64 deadline, address token, address destination, uint256 amount)`. Sends an exact
/// ERC-20 amount to a destination of the user's choice (shape-checked only: non-zero, not
/// this account). The user-signed command replaces any set-then-recover indirection: the
/// signature covers the actual move.
uint8 constant PA_ACTION_TRANSFER_TOKEN = 1;

/**
 * @title ILoanChainPersonalAccount
 * @notice User interface for the loan-chain-side Personal Account: the implementation
 * registered behind the frozen PA proxy on the loan-chain diamond (Ethereum, at launch),
 * living at the same CREATE2 address as the user's Flare Personal Account. It has no local
 * owner and no controller-driven methods — instructions exist only on Flare — so every
 * authorized action arrives as an authenticated LayerZero compose message sent by this same
 * account on Flare (`sendCrossChainInstruction`). The action set is deliberately minimal
 * and typed - one signed transfer action - so a compromised compose root can at worst drain
 * token balances and invoke an ERC-20-`transfer`-shaped call on a target of its choosing;
 * it gets no arbitrary calldata, delegatecall, approval, or general execution. There is no
 * permissionless rail at all: no protocol flow ever routes FXRP or native here (collateral
 * lands on the loan subaccount; the planned redirection of subaccount recovery to the parent
 * brings only non-collateral tokens), so anything that arrives is external or recovered, and
 * the signed transfer is its one exit. The implementation is
 * beacon-upgradeable, so a rail can be added if a real inflow ever appears.
 */
interface ILoanChainPersonalAccount is ILoanChainAccountBase {

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
     * @notice Emitted when a signed token transfer executes.
     * @param token The transferred token.
     * @param destination The destination paid.
     * @param amount The amount transferred.
     * @param operationId The user-chosen operation id, now consumed.
     * @param guid The LayerZero message id the action arrived with.
     */
    event TokenTransferred(
        address indexed token,
        address indexed destination,
        uint256 amount,
        bytes32 operationId,
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
     * @notice Reverts on a transfer destination that is not a clean non-zero address, or is
     * this account itself.
     */
    error InvalidDestination();

    /**
     * @notice Reverts on a transfer of zero amount.
     */
    error ZeroAmount();

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
