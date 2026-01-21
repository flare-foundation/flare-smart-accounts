// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {PersonalAccountProxy} from "../proxy/PersonalAccountProxy.sol";
import {IISingletonFactory} from "../interface/IISingletonFactory.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IPersonalAccountsFacet} from "../../userInterfaces/facets/IPersonalAccountsFacet.sol";

library PersonalAccounts {

    /// @custom:storage-location erc7201:smartAccounts.PersonalAccounts.State
    struct State {
        /// @notice PersonalAccount implementation used by BeaconProxy PA instances via IBeacon
        address personalAccountImplementation;
        /// Mapping from XRPL address to Personal Account
        mapping(string xrplAddress => IIPersonalAccount) personalAccounts;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.PersonalAccounts.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    /// @notice EIP-2470 Singleton Factory address used as the CREATE2 deployer
    address internal constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    function setPersonalAccountImplementation(
        address _implementation
    )
        internal
    {
        require(_implementation.code.length > 0, IPersonalAccountsFacet.InvalidPersonalAccountImplementation());
        State storage state = getState();
        state.personalAccountImplementation = _implementation;
        emit IPersonalAccountsFacet.PersonalAccountImplementationSet(_implementation);
    }

    function getOrCreatePersonalAccount(
        string memory _xrplOwner
    )
        internal
        returns (IIPersonalAccount _personalAccount)
    {
        State storage state = getState();
        _personalAccount = state.personalAccounts[_xrplOwner];
        if (address(_personalAccount) == address(0)) {
            // create new Personal Account
            _personalAccount = createPersonalAccount(_xrplOwner);
        }
    }

    function createPersonalAccount(
        string memory _xrplOwner
    )
        internal
        returns (IIPersonalAccount _personalAccount)
    {
        bytes memory bytecode = generateBytecode(_xrplOwner);
        // check if already deployed
        address personalAccountProxyAddress =
            Create2.computeAddress(bytes32(0), keccak256(bytecode), SINGLETON_FACTORY);
        uint256 codeSize = personalAccountProxyAddress.code.length;
        if (codeSize == 0) {
            // deploy via EIP-2470 singleton factory using CREATE2
            IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, bytes32(0));
        }

        _personalAccount = IIPersonalAccount(payable(personalAccountProxyAddress));

        // ensure the proxy address is a contract
        codeSize = personalAccountProxyAddress.code.length;
        require(
            codeSize > 0,
            IPersonalAccountsFacet.PersonalAccountNotSuccessfullyDeployed(personalAccountProxyAddress)
        );

        State storage state = getState();
        state.personalAccounts[_xrplOwner] = _personalAccount;
        emit IPersonalAccountsFacet.PersonalAccountCreated(personalAccountProxyAddress, _xrplOwner);
    }

    /**
     * @notice Generates the bytecode for deploying a PersonalAccountProxy contract.
     * @return The bytecode to be used for CREATE2 deployment.
     */
    function generateBytecode(string memory _xrplOwner)
        internal view
        returns (bytes memory)
    {
        // Use the controller (diamond) address as the beacon so the controller acts as IBeacon for PAs.
        // address(this) resolves to the diamond address when called via delegatecall from facet.
        return abi.encodePacked(
            type(PersonalAccountProxy).creationCode,
            abi.encode(address(this), _xrplOwner)
        );
    }

    function computePersonalAccountAddress(
        string memory _xrplOwner
    )
        internal view
        returns (address _personalAccount)
    {
        bytes memory bytecode = generateBytecode(_xrplOwner);
        _personalAccount = Create2.computeAddress(bytes32(0), keccak256(bytecode), SINGLETON_FACTORY);
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
