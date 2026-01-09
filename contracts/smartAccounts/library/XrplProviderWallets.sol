// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library XrplProviderWallets {


   /// @custom:storage-location erc8042:smartAccounts.XrplProviderWallets.State
    struct State {
        /// @notice XRPL provider wallet addresses
        string[] xrplProviderWallets;
        /// @notice XRPL provider wallet hashes
        mapping(bytes32 => uint256 index) xrplProviderWalletHashes; // 1-based index
    }

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.XrplProviderWallets.State");

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
