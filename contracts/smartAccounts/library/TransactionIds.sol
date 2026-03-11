// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";

library TransactionIds {

    /// @custom:storage-location erc7201:smartAccounts.TransactionIds.State
    struct State {
        /// @notice Indicates if transaction has already been executed.
        mapping(bytes32 transactionId => bool) usedTransactionIds;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.TransactionIds.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function markUsed(
        bytes32 _transactionId
    )
        internal
    {
        State storage state = getState();
        state.usedTransactionIds[_transactionId] = true;
    }

    function requireNotUsed(
        bytes32 _transactionId
    )
        internal view
    {
        State storage state = getState();
        require(!state.usedTransactionIds[_transactionId], IInstructionsFacet.TransactionAlreadyExecuted());
    }

    function isUsed(
        bytes32 _transactionId
    )
        internal view
        returns (bool)
    {
        State storage state = getState();
        return state.usedTransactionIds[_transactionId];
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
