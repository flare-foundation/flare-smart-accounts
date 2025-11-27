// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {IIPersonalAccountsFacet} from "../interface/IIPersonalAccountsFacet.sol";
import {IPersonalAccountsFacet} from "../../userInterfaces/facets/IPersonalAccountsFacet.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/**
 * @title PersonalAccountsFacet
 * @notice Facet for handling personal accounts.
 */
contract PersonalAccountsFacet is IIPersonalAccountsFacet {

    /// @inheritdoc IIPersonalAccountsFacet
    function setPersonalAccountImplementation(
        address _newImplementation
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        PersonalAccounts.setPersonalAccountImplementation(_newImplementation);
    }

    /// @inheritdoc IPersonalAccountsFacet
    function getPersonalAccount(
        string calldata _xrplOwner
    )
        external view
        returns (address _personalAccount)
    {
        PersonalAccounts.State storage state = PersonalAccounts.getState();
        _personalAccount = address(state.personalAccounts[_xrplOwner]);
        if (_personalAccount == address(0)) {
            _personalAccount = PersonalAccounts.computePersonalAccountAddress(_xrplOwner);
        }
    }

    /// @inheritdoc IBeacon
    function implementation() external view returns (address) {
        PersonalAccounts.State storage state = PersonalAccounts.getState();
        return state.personalAccountImplementation;
    }
}
