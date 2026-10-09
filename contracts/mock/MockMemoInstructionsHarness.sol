// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MemoInstructions} from "../smartAccounts/library/MemoInstructions.sol";

/**
 * @title MockMemoInstructionsHarness
 * @notice Calls the internal {MemoInstructions.execute} directly, so its own opcode guard can be
 * exercised: `MemoInstructionsFacet` dispatches only `0xFF` and `0xFE` into it, which makes the
 * guard unreachable in production and untestable through the diamond.
 */
contract MockMemoInstructionsHarness {

    function execute(
        bytes calldata _memoData,
        address _personalAccount,
        bytes calldata _data
    )
        external
    {
        MemoInstructions.execute(_memoData, _personalAccount, _data);
    }
}
