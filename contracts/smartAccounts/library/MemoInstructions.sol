// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IMemoInstructionsFacet} from "../../userInterfaces/facets/IMemoInstructionsFacet.sol";

library MemoInstructions {

    /// @custom:storage-location erc7201:smartAccounts.MemoInstructions.State
    struct State {
        mapping(address account => uint256 nonce) nonces;
        mapping(address account => mapping(bytes32 txId => bool)) ignoreMemo;
        mapping(address account => address) executor;
        mapping(address account => mapping(bytes32 txId => uint64)) replacementFee;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.MemoInstructions.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function execute(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        // decode PackedUserOperation from memoData (skip 10-byte header: instructionId + walletId + uint64 fee)
        PackedUserOperation memory userOp = abi.decode(_memoData[10:], (PackedUserOperation));

        // validate sender
        require(
            userOp.sender == _personalAccount,
            IMemoInstructionsFacet.InvalidSender(userOp.sender, _personalAccount)
        );

        State storage state = getState();

        // validate nonce
        require(
            userOp.nonce == state.nonces[_personalAccount],
            IMemoInstructionsFacet.InvalidNonce(state.nonces[_personalAccount], userOp.nonce)
        );
        ++state.nonces[_personalAccount];

        // execute callData on PA (Diamond is controller, so onlyController is satisfied)
        (bool success, bytes memory returnData) = _personalAccount.call{value: msg.value}(userOp.callData);
        require(success, IMemoInstructionsFacet.CallFailed(returnData));

        emit IMemoInstructionsFacet.UserOperationExecuted(
            _personalAccount,
            userOp.nonce
        );
    }

    function setIgnoreMemo(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        // memo format: [0xE0][walletId:uint8][fee:uint64][targetTxId:bytes32] = 42 bytes
        require(_memoData.length == 42, IMemoInstructionsFacet.InvalidMemoData());
        bytes32 targetTxId = bytes32(_memoData[10:42]);
        State storage state = getState();
        state.ignoreMemo[_personalAccount][targetTxId] = true;
        emit IMemoInstructionsFacet.IgnoreMemoSet(_personalAccount, targetTxId);
    }

    function setNonce(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        // memo format: [0xE1][walletId:uint8][fee:uint64][newNonce:uint256] = 42 bytes
        require(_memoData.length == 42, IMemoInstructionsFacet.InvalidMemoData());
        uint256 newNonce = uint256(bytes32(_memoData[10:42]));
        State storage state = getState();
        uint256 currentNonce = state.nonces[_personalAccount];
        require(
            newNonce > currentNonce && newNonce - currentNonce <= type(uint32).max,
            IMemoInstructionsFacet.InvalidNonceIncrease(currentNonce, newNonce)
        );
        state.nonces[_personalAccount] = newNonce;
        emit IMemoInstructionsFacet.NonceIncreased(_personalAccount, newNonce);
    }

    function setExecutor(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        // memo format: [0xD0][walletId:uint8][fee:uint64][executor:address] = 30 bytes
        require(_memoData.length == 30, IMemoInstructionsFacet.InvalidMemoData());
        address newExecutor = address(bytes20(_memoData[10:30]));
        require(newExecutor != address(0), IMemoInstructionsFacet.AddressZero());
        State storage state = getState();
        state.executor[_personalAccount] = newExecutor;
        emit IMemoInstructionsFacet.ExecutorSet(_personalAccount, newExecutor);
    }

    function removeExecutor(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        // memo format: [0xD1][walletId:uint8][fee:uint64] = 10 bytes
        require(_memoData.length == 10, IMemoInstructionsFacet.InvalidMemoData());
        State storage state = getState();
        state.executor[_personalAccount] = address(0);
        emit IMemoInstructionsFacet.ExecutorRemoved(_personalAccount);
    }

    function setReplacementFee(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        // memo format: [0xE2][walletId:uint8][fee:uint64][targetTxId:bytes32][newFee:uint64] = 50 bytes
        require(_memoData.length == 50, IMemoInstructionsFacet.InvalidMemoData());
        bytes32 targetTxId = bytes32(_memoData[10:42]);
        uint64 newFee = uint64(bytes8(_memoData[42:50]));
        State storage state = getState();
        state.replacementFee[_personalAccount][targetTxId] = newFee + 1; // +1 so 0 means "not set"
        emit IMemoInstructionsFacet.ReplacementFeeSet(_personalAccount, targetTxId, newFee);
    }

    function getExecutor(
        address _personalAccount
    )
        internal view
        returns (address)
    {
        State storage state = getState();
        return state.executor[_personalAccount];
    }

    function getReplacementFee(
        address _personalAccount,
        bytes32 _txId
    )
        internal view
        returns (uint64)
    {
        return getState().replacementFee[_personalAccount][_txId];
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
