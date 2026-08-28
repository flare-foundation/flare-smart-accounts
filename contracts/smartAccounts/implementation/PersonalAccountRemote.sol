// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {
    IPersonalAccountRemote,
    PA_ACTION_EXECUTE
} from "../../userInterfaces/IPersonalAccountRemote.sol";
import {ComposeReceiverAccountBase} from "./ComposeReceiverAccountBase.sol";

/**
 * @title PersonalAccountRemote contract
 * @notice The remote Personal Account implementation (the loan chain, at launch): the
 * same frozen PA proxy and CREATE2 address as the user's Flare Personal Account, resolved per
 * chain through the controller-as-beacon. Instructions exist only on Flare, so this account has no
 * controller-driven methods at all; every authorized action arrives through the authenticated
 * `lzCompose` (see {ComposeReceiverAccountBase}) sent by this same account on Flare. It does what
 * the Flare account does: execute the batch of calls the user signed — here carried by the
 * compose instead of the controller — and nothing permissionless. Borrow proceeds the user
 * directed here, recovered loan-token surplus from the loan subaccount, mistaken sends and
 * strays land here, where the user can always move or use them by signature. Native is
 * accepted (a LayerZero native drop delivered with a message funds value-carrying calls) and
 * leaves the same way, as a value-carrying call.
 */
contract PersonalAccountRemote is IPersonalAccountRemote, ComposeReceiverAccountBase {

    /// @notice XRPL owner (the same string the Flare Personal Account is derived from).
    string public xrplOwner;

    /// @dev Native funds value-carrying calls (a LayerZero native drop, a plain send) and
    /// leaves as one; the implementation contract itself (never initialized) rejects it, since
    /// nothing could ever move it out of there.
    receive() external payable {
        require(bytes(xrplOwner).length != 0, NotInitialized());
    }

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
        emit PersonalAccountRemoteInitialized(_controllerAddress, _xrplOwner);
    }

    /// @inheritdoc IPersonalAccountRemote
    function implementation()
        external view
        returns (address)
    {
        // controller is the beacon, exactly as for the Flare Personal Account
        return IBeacon(controller).implementation();
    }

    /// @dev The account's action set (see {ComposeReceiverAccountBase._dispatch}): one action, the
    /// signed batch. Pause-gated - during an incident the pause must stop even signed-looking
    /// traffic, since a transport compromise is exactly what an incident looks like.
    function _dispatch(
        uint8 _action,
        bytes memory _actionData,
        bytes32 _guid,
        uint256 /* _amountLD */
    )
        internal override
    {
        if (_action == PA_ACTION_EXECUTE) {
            _executeUserOp(_actionData, _guid);
        } else {
            revert UnsupportedAction(_action);
        }
    }

    /// @dev The loan-chain `executeUserOp`: hard argument checks revert (retriable), terminal
    /// gates skip (finalize without effect), then the pause is checked, the id consumed and the
    /// calls run in order - all or nothing for calls that revert, exactly like the Flare
    /// account's multicall.
    function _executeUserOp(
        bytes memory _actionData,
        bytes32 _guid
    )
        private
    {
        (bytes32 operationId, uint64 deadline, Call[] memory calls) =
            abi.decode(_actionData, (bytes32, uint64, Call[]));
        require(operationId != bytes32(0), InvalidOperationId());
        require(calls.length > 0, EmptyUserOp());
        uint8 reason = _terminalSkipReason(operationId, deadline);
        if (reason != 0) {
            emit ActionSkipped(operationId, reason, _guid);
            return;
        }
        // signed traffic stops while paused; the compose stays queued at the endpoint and
        // re-delivers after unpausing
        _checkNotPaused();
        usedOperations[operationId] = true;

        for (uint256 i = 0; i < calls.length; i++) {
            // targets, values and calldata are the user's signed instruction, exactly as in
            // the Flare executeUserOp (slither arbitrary-send-eth / calls-loop are that by
            // design); return data is not interpreted - a callee that signals failure by
            // returning false rather than reverting counts as success, as it does there.
            // A re-entry of this account's compose entry meets the transient guard
            // slither-disable-start arbitrary-send-eth,calls-loop
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, bytes memory result) =
                calls[i].target.call{value: calls[i].value}(calls[i].data);
            // slither-disable-end arbitrary-send-eth,calls-loop
            require(success, CallFailed(i, result));
        }
        emit UserOpExecuted(operationId, calls.length, _guid);
    }
}
