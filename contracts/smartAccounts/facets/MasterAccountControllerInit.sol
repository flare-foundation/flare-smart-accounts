// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../diamond/libraries/LibDiamond.sol";
import {IDiamondLoupe} from "../../diamond/interfaces/IDiamondLoupe.sol";
import {IDiamondCut} from "../../diamond/interfaces/IDiamondCut.sol";
import {IERC173} from "../../diamond/interfaces/IERC173.sol";
import {IERC165} from "../../diamond/interfaces/IERC165.sol";

import {Executors} from "../library/Executors.sol";
import {PaymentProofs} from "../library/PaymentProofs.sol";
import {InstructionFees} from "../library/InstructionFees.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";

contract MasterAccountControllerInit {

    // You can add parameters to this function in order to pass in
    // data to set your own state variables
    function init(
        address payable _executor,
        uint256 _executorFee,
        bytes32 _sourceId,
        uint256 _paymentProofValidityDurationSeconds,
        uint256 _defaultInstructionFee,
        address _personalAccountImplementation
    )
        external
    {
        // adding ERC165 data
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;

        // add your own state variables
        // EIP-2535 specifies that the `diamondCut` function takes two optional
        // arguments: address _init and bytes calldata _calldata
        // These arguments are used to execute an arbitrary function using delegatecall
        // in order to set state variables in the diamond during deployment or an upgrade
        // More info here: https://eips.ethereum.org/EIPS/eip-2535#diamond-interface


        Executors.setExecutor(_executor);
        Executors.setExecutorFee(_executorFee);
        PaymentProofs.setSourceId(_sourceId);
        PaymentProofs.setPaymentProofValidityDuration(_paymentProofValidityDurationSeconds);
        InstructionFees.setDefaultInstructionFee(_defaultInstructionFee);
        // set the PA implementation that this controller (as beacon) will return
        PersonalAccounts.setPersonalAccountImplementation(_personalAccountImplementation);
    }
}
