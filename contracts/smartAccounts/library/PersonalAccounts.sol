// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {PersonalAccountProxy} from "../proxy/PersonalAccountProxy.sol";
import {IISingletonFactory} from "../interface/IISingletonFactory.sol";
import {IMasterAccountController} from "../../userInterfaces/IMasterAccountController.sol";


library PersonalAccounts {

    /// @notice EIP-2470 Singleton Factory address used as the CREATE2 deployer
    address constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    struct State {
        /// @notice PersonalAccount implementation used by BeaconProxy PA instances via IBeacon
        address personalAccountImplementation;
        /// Mapping from XRPL address to Personal Account
        mapping(string xrplAddress => IIPersonalAccount) personalAccounts;
    }

    /**
     * @notice Sets new PersonalAccount implementation address.
     * @param _newImplementation New PersonalAccount implementation address.
     * Can only be called by the owner.
     */
    function setPersonalAccountImplementation(
        address _newImplementation
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        _setPersonalAccountImplementation(_newImplementation);
    }


    /**
     * @inheritdoc IMasterAccountController
     */
    function getPersonalAccount(
        string calldata _xrplOwner
    )
        external view
        returns (address _personalAccount)
    {
        State storage state = getState();
        _personalAccount = address(state.personalAccounts[_xrplOwner]);
        if (_personalAccount == address(0)) {
            // compute the address
            bytes memory bytecode = _generateBytecode(_xrplOwner);
            _personalAccount = Create2.computeAddress(bytes32(0), keccak256(bytecode), SINGLETON_FACTORY);
        }
    }

    /**
     * @inheritdoc IBeacon
     */
    function implementation() external view returns (address) {
        State storage state = getState();
        return state.personalAccountImplementation;
    }

    function _setPersonalAccountImplementation(address _newImplementation) internal {
        require(_newImplementation != address(0), IMasterAccountController.InvalidPersonalAccountImplementation());
        State storage state = getState();
        state.personalAccountImplementation = _newImplementation;
        emit IMasterAccountController.PersonalAccountImplementationSet(_newImplementation);
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
            _personalAccount = _createPersonalAccount(_xrplOwner);
        }
    }

    function _createPersonalAccount(
        string memory _xrplOwner
    )
        internal
        returns (IIPersonalAccount _personalAccount)
    {
        bytes memory bytecode = _generateBytecode(_xrplOwner);
        // check if already deployed
        address personalAccountProxyAddress =
            Create2.computeAddress(bytes32(0), keccak256(bytecode), SINGLETON_FACTORY);
        uint256 codeSize = personalAccountProxyAddress.code.length;
        if (codeSize == 0) {
            // deploy via EIP-2470 singleton factory using CREATE2
            IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, bytes32(0));
        }

        _personalAccount = IIPersonalAccount(payable(personalAccountProxyAddress));

        // ensure the proxy address is a contract before calling initialize
        codeSize = personalAccountProxyAddress.code.length;
        require(
            codeSize > 0,
            IMasterAccountController.PersonalAccountNotSuccessfullyDeployed(personalAccountProxyAddress)
        );

        State storage state = getState();
        state.personalAccounts[_xrplOwner] = _personalAccount;
        emit IMasterAccountController.PersonalAccountCreated(personalAccountProxyAddress, _xrplOwner);
    }

    /**
     * @notice Generates the bytecode for deploying a PersonalAccountProxy contract.
     * @return The bytecode to be used for CREATE2 deployment.
     */
    function _generateBytecode(string memory _xrplOwner) internal view returns (bytes memory) {
        // Use the controller proxy address as the beacon so the controller acts as IBeacon for PAs.
        // address(this) resolves to the proxy address when called via delegatecall.
        return abi.encodePacked(
            type(PersonalAccountProxy).creationCode,
            abi.encode(address(this), _xrplOwner)
        );
    }

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.PersonalAccounts.State");

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
