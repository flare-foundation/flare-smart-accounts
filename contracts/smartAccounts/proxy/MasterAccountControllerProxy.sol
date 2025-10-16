// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MasterAccountController} from "../implementation/MasterAccountController.sol";
import {IGovernanceSettings} from "flare-periphery/src/flare/IGovernanceSettings.sol";

contract MasterAccountControllerProxy is ERC1967Proxy {
    constructor(
        address _implementationAddress,
        IGovernanceSettings _governanceSettings,
        address _initialGovernance,
        address payable _executor,
        uint256 _executorFee,
        uint256 _paymentProofValidityDurationSeconds,
        uint256 _defaultInstructionFee,
        string memory _xrplProviderWallet,
        address _personalAccountImplementation,
        address _seedPersonalAccountImplementation
    )
        ERC1967Proxy(
            _implementationAddress,
            abi.encodeCall(
                MasterAccountController.initialize,
                (
                    _governanceSettings,
                    _initialGovernance,
                    _executor,
                    _executorFee,
                    _paymentProofValidityDurationSeconds,
                    _defaultInstructionFee,
                    _xrplProviderWallet,
                    _personalAccountImplementation,
                    _seedPersonalAccountImplementation
                )
            )
        )
    {}
}
