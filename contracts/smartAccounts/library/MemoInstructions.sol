// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";

library MemoInstructions {

    /// @custom:storage-location erc7201:smartAccounts.MemoInstructions.State
    struct State {
        mapping(address account => uint256 nonce) nonces;
        mapping(address account => mapping(bytes32 txId => bool)) ignoreMemo;
        mapping(address account => address) executor;
        mapping(address account => mapping(bytes32 txId => uint32)) replacementFee;
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
        // decode PackedUserOperation from memoData (skip 6-byte header: instructionId + walletId + uint32 fee)
        PackedUserOperation memory userOp = abi.decode(_memoData[6:], (PackedUserOperation));

        // validate sender
        require(userOp.sender == _personalAccount, IInstructionsFacet.InvalidSender(userOp.sender, _personalAccount));

        State storage state = getState();

        // validate nonce
        require(
            userOp.nonce == state.nonces[_personalAccount],
            IInstructionsFacet.InvalidNonce(state.nonces[_personalAccount], userOp.nonce)
        );
        ++state.nonces[_personalAccount];

        // execute callData on PA (Diamond is controller, so onlyController is satisfied)
        (bool success, bytes memory returnData) = _personalAccount.call{value: msg.value}(userOp.callData);
        require(success, IInstructionsFacet.CallFailed(returnData));

        emit IInstructionsFacet.UserOperationExecuted(
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
        // memo format: [0xE0][walletId:uint8][fee:uint32][targetTxId:bytes32] = 38 bytes
        require(_memoData.length == 38, IInstructionsFacet.InvalidMemoData());
        bytes32 targetTxId = bytes32(_memoData[6:38]);
        State storage state = getState();
        state.ignoreMemo[_personalAccount][targetTxId] = true;
        emit IInstructionsFacet.IgnoreMemoSet(_personalAccount, targetTxId);
    }

    function setNonce(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        // memo format: [0xE1][walletId:uint8][fee:uint32][newNonce:uint256] = 38 bytes
        require(_memoData.length == 38, IInstructionsFacet.InvalidMemoData());
        uint256 newNonce = uint256(bytes32(_memoData[6:38]));
        State storage state = getState();
        uint256 currentNonce = state.nonces[_personalAccount];
        require(
            newNonce > currentNonce && newNonce - currentNonce <= type(uint32).max,
            IInstructionsFacet.InvalidNonceIncrease(currentNonce, newNonce)
        );
        state.nonces[_personalAccount] = newNonce;
        emit IInstructionsFacet.NonceIncreased(_personalAccount, newNonce);
    }

    function setExecutor(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        // memo format: [0xD0][walletId:uint8][fee:uint32][executor:address] = 26 bytes
        require(_memoData.length == 26, IInstructionsFacet.InvalidMemoData());
        address newExecutor = address(bytes20(_memoData[6:26]));
        require(newExecutor != address(0), IInstructionsFacet.AddressZero());
        State storage state = getState();
        state.executor[_personalAccount] = newExecutor;
        emit IInstructionsFacet.ExecutorSet(_personalAccount, newExecutor);
    }

    function removeExecutor(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        // memo format: [0xD1][walletId:uint8][fee:uint32] = 6 bytes
        require(_memoData.length == 6, IInstructionsFacet.InvalidMemoData());
        State storage state = getState();
        state.executor[_personalAccount] = address(0);
        emit IInstructionsFacet.ExecutorRemoved(_personalAccount);
    }

    function setReplacementFee(
        bytes calldata _memoData,
        address _personalAccount
    )
        internal
    {
        // memo format: [0xE2][walletId:uint8][fee:uint32][targetTxId:bytes32][newFee:uint32] = 42 bytes
        require(_memoData.length == 42, IInstructionsFacet.InvalidMemoData());
        bytes32 targetTxId = bytes32(_memoData[6:38]);
        uint32 newFee = uint32(bytes4(_memoData[38:42]));
        State storage state = getState();
        state.replacementFee[_personalAccount][targetTxId] = newFee + 1; // +1 so 0 means "not set"
        emit IInstructionsFacet.ReplacementFeeSet(_personalAccount, targetTxId, newFee);
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
        returns (uint32)
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
