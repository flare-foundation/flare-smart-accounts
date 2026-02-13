// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/**
 * @title FAssetRedeemerAccountProxy
 * @notice Beacon proxy for per-redeemer account instances initialized at deployment.
 */
contract FAssetRedeemerAccountProxy is BeaconProxy {
    bytes4 private constant INITIALIZE_SELECTOR = bytes4(
        keccak256("initialize(address,address)")
    );

    /**
     * @notice Deploys proxy and initializes redeemer account state.
     * @param _composer Composer address used as beacon and authorized account controller.
     * @param _owner Redeemer account owner address.
     */
    constructor(address _composer, address _owner)
        BeaconProxy(
            _composer,
            abi.encodeWithSelector(
                INITIALIZE_SELECTOR,
                _composer,
                _owner
            )
        )
    {}
}
