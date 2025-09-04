// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../implementation/MasterAccountController.sol";
import {IGovernanceSettings} from "flare-periphery/src/flare/IGovernanceSettings.sol";

contract MasterAccountControllerProxy is ERC1967Proxy {
    constructor(
        address _implementationAddress,
        IGovernanceSettings _governanceSettings,
        address _initialGovernance,
        address _depositVault,
        address _fxrp,
        address payable _executor,
        uint256 _executorFee,
        string memory _xrplProviderWallet,
        address _operatorAddress,
        uint256 _operatorExecutionWindowSeconds,
        address _personalAccountImplementation
    )
        ERC1967Proxy(_implementationAddress,
            abi.encodeCall(
                MasterAccountController.initialize,
                (
                    _governanceSettings,
                    _initialGovernance,
                    _depositVault,
                    _fxrp,
                    _executor,
                    _executorFee,
                    _xrplProviderWallet,
                    _operatorAddress,
                    _operatorExecutionWindowSeconds,
                    _personalAccountImplementation
                )
            )
        )
    { }
}
