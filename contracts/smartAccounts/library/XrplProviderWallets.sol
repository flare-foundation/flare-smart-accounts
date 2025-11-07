// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";


library XrplProviderWallets {

    struct State {
        /// @notice XRPL provider wallet addresses
        string[] xrplProviderWallets;
        /// @notice XRPL provider wallet hashes
        mapping(bytes32 => uint256 index) xrplProviderWalletHashes; // 1-based index
    }

    /**
     * @notice Adds new XRPL provider wallet addresses.
     * @param _xrplProviderWallets The XRPL provider wallet addresses to add.
     * Can only be called by the owner.
     */
    function addXrplProviderWallets(
        string[] calldata _xrplProviderWallets
    )
        internal
    {
        LibDiamond.enforceIsContractOwner();
        State storage state = getState();
        for (uint256 i = 0; i < _xrplProviderWallets.length; i++) {
            string memory xrplProviderWallet = _xrplProviderWallets[i];
            require(
                bytes(xrplProviderWallet).length > 0,
                IMasterAccountController.InvalidXrplProviderWallet(xrplProviderWallet)
            );
            bytes32 hash = keccak256(bytes(xrplProviderWallet));
            require(
                state.xrplProviderWalletHashes[hash] == 0,
                IMasterAccountController.XrplProviderWalletAlreadyExists(xrplProviderWallet)
            );
            state.xrplProviderWallets.push(xrplProviderWallet);
            state.xrplProviderWalletHashes[hash] = state.xrplProviderWallets.length; // store 1-based index
            emit IMasterAccountController.XrplProviderWalletAdded(xrplProviderWallet);
        }
    }

    /**
     * @notice Removes existing XRPL provider wallet addresses.
     * @param _xrplProviderWallets The XRPL provider wallet addresses to remove.
     * Can only be called by the owner.
     */
    function removeXrplProviderWallets(
        string[] calldata _xrplProviderWallets
    )
        internal
    {
        LibDiamond.enforceIsContractOwner();
        State storage state = getState();
        for (uint256 i = 0; i < _xrplProviderWallets.length; i++) {
            string calldata xrplProviderWallet = _xrplProviderWallets[i];
            bytes32 walletHash = keccak256(bytes(xrplProviderWallet));
            uint256 index = state.xrplProviderWalletHashes[walletHash]; // 1-based index
            require(index != 0, IMasterAccountController.InvalidXrplProviderWallet(xrplProviderWallet));
            // remove from mapping
            delete state.xrplProviderWalletHashes[walletHash];
            uint256 length = state.xrplProviderWallets.length;
            if (index == length) {
                // removing the last element
                state.xrplProviderWallets.pop();
            } else {
                string memory lastWallet = state.xrplProviderWallets[length - 1];
                // move the last element to the removed position
                state.xrplProviderWallets[index - 1] = lastWallet;
                state.xrplProviderWallets.pop();
                // update moved wallet's index in mapping
                bytes32 movedWalletHash = keccak256(bytes(lastWallet));
                state.xrplProviderWalletHashes[movedWalletHash] = index; // update to new 1-based index
            }
            emit IMasterAccountController.XrplProviderWalletRemoved(xrplProviderWallet);
        }
    }

    /**
     * @inheritdoc IMasterAccountController
     */
    function getXrplProviderWallets()
        external view
        returns (string[] memory)
    {
        State storage state = getState();
        return state.xrplProviderWallets;
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
