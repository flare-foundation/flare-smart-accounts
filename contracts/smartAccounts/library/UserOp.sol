// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";

library UserOp {

    /// @custom:storage-location erc7201:smartAccounts.UserOp.State
    struct State {
        mapping(address account => uint256 nonce) nonces;
        mapping(bytes32 txId => bool) ignoreNonce;
        mapping(bytes32 txId => bool) ignoreMemo;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.UserOp.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function execute(
        bytes calldata _memoData,
        address _personalAccount,
        bytes32 _transactionId
    )
        internal
    {
        // decode PackedUserOperation from memoData (skip byte 0 = instruction ID, byte 1 = wallet ID)
        PackedUserOperation memory userOp = abi.decode(_memoData[2:], (PackedUserOperation));

        // validate sender
        require(userOp.sender == _personalAccount, IInstructionsFacet.InvalidSender(userOp.sender, _personalAccount));

        State storage state = getState();

        // validate nonce
        if (userOp.nonce != state.nonces[_personalAccount]) {
            require(state.ignoreNonce[_transactionId],
                IInstructionsFacet.InvalidNonce(state.nonces[_personalAccount], userOp.nonce)
            );
            state.ignoreNonce[_transactionId] = false;
        } else {
            ++state.nonces[_personalAccount];
        }

        // execute callData on PA (Diamond is controller, so onlyController is satisfied)
        (bool success, bytes memory returnData) = _personalAccount.call{value: msg.value}(userOp.callData);
        require(success, IInstructionsFacet.CallFailed(returnData));

        emit IInstructionsFacet.UserOperationExecuted(
            _personalAccount,
            userOp.nonce
        );
    }

    function setIgnoreNonce(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        require(_memoData.length == 34, IInstructionsFacet.NoMemoData());
        bytes32 txId = bytes32(_memoData[2:34]);
        State storage state = getState();
        state.ignoreNonce[txId] = true;
        emit IInstructionsFacet.NonceIgnoreSet(_personalAccount, txId);
    }

    function incrementNonce(
        address _personalAccount
    )
        internal
    {
        State storage state = getState();
        uint256 newNonce = ++state.nonces[_personalAccount];
        emit IInstructionsFacet.NonceIncremented(_personalAccount, newNonce);
    }

    function setIgnoreMemo(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        require(_memoData.length == 34, IInstructionsFacet.NoMemoData());
        bytes32 txId = bytes32(_memoData[2:34]);
        State storage state = getState();
        state.ignoreMemo[txId] = true;
        emit IInstructionsFacet.MemoIgnoreSet(_personalAccount, txId);
    }

    function getNonce(address _sender) internal view returns (uint256) {
        State storage state = getState();
        return state.nonces[_sender];
    }

    function getState()
        internal pure
        returns (State storage _state)
    {
        bytes32 position = STATE_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }
}
