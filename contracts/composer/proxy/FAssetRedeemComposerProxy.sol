// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title FAssetRedeemComposerProxy
 * @notice ERC1967 proxy that initializes `FAssetRedeemComposer` on deployment.
 */
contract FAssetRedeemComposerProxy is ERC1967Proxy {
    bytes4 private constant INITIALIZE_SELECTOR = bytes4(
        keccak256("initialize(address,address,address,address,address,address,address,uint256,address,address)")
    );

    /**
     * @notice Deploys proxy and forwards initialization calldata to implementation.
     * @param _implementation FAssetRedeemComposer implementation address.
     * @param _initialOwner Initial owner for composer administrative operations.
     * @param _endpoint Trusted endpoint allowed to invoke compose callbacks.
     * @param _trustedSourceOApp Trusted source OApp address.
     * @param _assetManager Asset manager used for redemption.
     * @param _stableCoin Stable coin token - returned in case of a redemption failure.
     * @param _wNat Wrapped native token - returned in case of a redemption failure
     *              if stable coin balance is insufficient.
     * @param _composerFeeRecipient Recipient of composer fee collected in f-asset.
     * @param _defaultComposerFeePPM Default composer fee in PPM.
     * @param _defaultExecutor Default executor address used for redemption execution.
     * @param _redeemerAccountImplementation Beacon implementation for redeemer accounts.
     */
    constructor(
        address _implementation,
        address _initialOwner,
        address _endpoint,
        address _trustedSourceOApp,
        address _assetManager,
        address _stableCoin,
        address _wNat,
        address _composerFeeRecipient,
        uint256 _defaultComposerFeePPM,
        address payable _defaultExecutor,
        address _redeemerAccountImplementation
    )
        ERC1967Proxy(
            _implementation,
            abi.encodeWithSelector(
                INITIALIZE_SELECTOR,
                _initialOwner,
                _endpoint,
                _trustedSourceOApp,
                _assetManager,
                _stableCoin,
                _wNat,
                _composerFeeRecipient,
                _defaultComposerFeePPM,
                _defaultExecutor,
                _redeemerAccountImplementation
            )
        )
    {}
}
