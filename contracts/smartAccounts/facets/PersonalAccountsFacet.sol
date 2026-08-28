// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IIPersonalAccountsFacet} from "../interface/IIPersonalAccountsFacet.sol";
import {IPersonalAccountsFacet} from "../../userInterfaces/facets/IPersonalAccountsFacet.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {Pause} from "../library/Pause.sol";
import {FacetBase} from "./FacetBase.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/**
 * @title PersonalAccountsFacet
 * @notice Facet for handling Personal Accounts: the implementation behind the frozen PA proxies
 * (controller-as-beacon), the explicit permissionless creation route, and the address lookup.
 * Cut on every chain.
 */
contract PersonalAccountsFacet is IIPersonalAccountsFacet, FacetBase {

    modifier notPaused {
        Pause.checkNotPaused();
        _;
    }

    /// @inheritdoc IIPersonalAccountsFacet
    function setPersonalAccountImplementation(
        address _newImplementation
    )
        external
        onlyOwnerWithTimelock
    {
        PersonalAccounts.setPersonalAccountImplementation(_newImplementation);
    }

    /// @inheritdoc IPersonalAccountsFacet
    function createPersonalAccount(
        string calldata _xrplOwner
    )
        external
        notPaused
        returns (address)
    {
        // permissionless and idempotent: the proxy derivation is frozen and commits to the owner
        // and this controller, so the caller gains no authority over the account it materializes
        return PersonalAccounts.getOrCreatePersonalAccount(_xrplOwner);
    }

    /// @inheritdoc IPersonalAccountsFacet
    function getPersonalAccount(
        string calldata _xrplOwner
    )
        external view
        returns (address _personalAccount)
    {
        PersonalAccounts.State storage state = PersonalAccounts.getState();
        _personalAccount = state.personalAccounts[_xrplOwner];
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
