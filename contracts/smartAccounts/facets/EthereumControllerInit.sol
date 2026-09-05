// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {IDiamondLoupe} from "../../diamond/interfaces/IDiamondLoupe.sol";
import {IDiamondCut} from "../../diamond/interfaces/IDiamondCut.sol";
import {IERC173} from "../../diamond/interfaces/IERC173.sol";
import {IERC165} from "../../diamond/interfaces/IERC165.sol";

/**
 * @title EthereumControllerInit
 * @notice The loan-chain counterpart of {MasterAccountControllerInit}: it registers the four
 * ERC-165 interface flags and writes nothing else.
 * @dev Every other setting the Flare init writes is either Flare-only or must not be written
 * here: the executor, the payment-proof source and validity, and the default instruction fee
 * belong to facets that are not part of the Ethereum cut, and the Personal Account beacon is
 * set by a timelocked governance call after the cut (as is each subaccount type's
 * implementation), so setting it from an init would bypass that timelock. The diamond
 * reproduced by the pinned Ethereum bootstrap carries no interface flags of its own - the
 * Flare init that set them was never run there - so this is what makes the loupe, cut,
 * ownership and ERC-165 answers match Flare's.
 */
contract EthereumControllerInit {

    function init()
        external
    {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;
    }
}
