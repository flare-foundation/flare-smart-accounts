// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {AgentInfo} from "flare-periphery/src/flare/data/AgentInfo.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IIXrplProviderWalletsFacet} from "../interface/IIXrplProviderWalletsFacet.sol";
import {IXrplProviderWalletsFacet} from "../../userInterfaces/facets/IXrplProviderWalletsFacet.sol";
import {XrplProviderWallets} from "../library/XrplProviderWallets.sol";

/**
 * @title XrplProviderWalletsFacet
 * @notice Facet for handling XRPL provider wallet-related functions.
 */
contract XrplProviderWalletsFacet is IIXrplProviderWalletsFacet {

    /// @inheritdoc IIXrplProviderWalletsFacet
    function addXrplProviderWallets(
        string[] calldata _xrplProviderWallets
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        XrplProviderWallets.State storage state = XrplProviderWallets.getState();
        for (uint256 i = 0; i < _xrplProviderWallets.length; i++) {
            string memory xrplProviderWallet = _xrplProviderWallets[i];
            require(
                bytes(xrplProviderWallet).length > 0,
                InvalidXrplProviderWallet(xrplProviderWallet)
            );
            bytes32 hash = keccak256(bytes(xrplProviderWallet));
            require(
                state.xrplProviderWalletHashes[hash] == 0,
                XrplProviderWalletAlreadyExists(xrplProviderWallet)
            );
            state.xrplProviderWallets.push(xrplProviderWallet);
            state.xrplProviderWalletHashes[hash] = state.xrplProviderWallets.length; // store 1-based index
            emit XrplProviderWalletAdded(xrplProviderWallet);
        }
    }

    /// @inheritdoc IIXrplProviderWalletsFacet
    function removeXrplProviderWallets(
        string[] calldata _xrplProviderWallets
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        XrplProviderWallets.State storage state = XrplProviderWallets.getState();
        for (uint256 i = 0; i < _xrplProviderWallets.length; i++) {
            string calldata xrplProviderWallet = _xrplProviderWallets[i];
            bytes32 walletHash = keccak256(bytes(xrplProviderWallet));
            uint256 index = state.xrplProviderWalletHashes[walletHash]; // 1-based index
            require(index != 0, InvalidXrplProviderWallet(xrplProviderWallet));
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
            emit XrplProviderWalletRemoved(xrplProviderWallet);
        }
    }

    /// @inheritdoc IXrplProviderWalletsFacet
    function getXrplProviderWallets()
        external view
        returns (string[] memory)
    {
        XrplProviderWallets.State storage state = XrplProviderWallets.getState();
        return state.xrplProviderWallets;
    }
}
