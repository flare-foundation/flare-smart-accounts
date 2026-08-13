// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title PinnedControllerInitCode
 * @notice The historical CREATE2 inputs of the production MasterAccountController deployment,
 * pinned so the diamond can be reproduced byte-exactly at the same address on new chains
 * (Ethereum). Recovered from the Flare creation transactions (block 55446816; deployed via the
 * EIP-2470 singleton factory with salt 0) and verified: hashing the pinned init code and
 * applying the CREATE2 derivation reproduces the live addresses exactly.
 *
 * Rebuilding today's sources does NOT reproduce them — source drift changes the base facets'
 * bytecode, their CREATE2 addresses, the diamond's constructor arguments, and with them the
 * diamond address. That is why the init code is pinned as raw bytes under
 * `deployment/pinned-init-code/` instead of being rebuilt from source.
 *
 * The decoded controller constructor arguments are the three base facet cuts below and
 * `DiamondArgs{owner: INITIAL_OWNER, initAddress: 0, initCalldata: ""}`. INITIAL_OWNER is an
 * EOA: a freshly reproduced diamond is owned by it, so the post-deployment cut on a new chain
 * requires that key. Confirm it is still controlled before deploying to a new chain.
 *
 * `test/PinnedInitCode.t.sol` asserts all of this in CI.
 */
library PinnedControllerInitCode {
    address internal constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    bytes32 internal constant SALT = bytes32(0);

    /// @notice `DiamondArgs.owner` of the production deployment (an EOA).
    address internal constant INITIAL_OWNER = 0x7801A7e1FD6a99d1a74DC0a59622b3b7dc4049bA;

    address internal constant MASTER_ACCOUNT_CONTROLLER = 0x434936d47503353f06750Db1A444DBDC5F0AD37c;
    bytes32 internal constant MASTER_ACCOUNT_CONTROLLER_INIT_CODE_HASH =
        0x3efed6a50c99e0747b20fb67400ad08fb1ac42884b5764b59bbbabae69481dd5;
    bytes32 internal constant MASTER_ACCOUNT_CONTROLLER_RUNTIME_CODE_HASH =
        0x0b54490d44d6e65d6bb7df4ea599653733fa916b03109737a576cb868fe45a94;

    address internal constant DIAMOND_CUT_FACET = 0xbBfDC00D4a230eB2cBf2623f8ca67C23D31E094D;
    bytes32 internal constant DIAMOND_CUT_FACET_INIT_CODE_HASH =
        0x896043a78dbba03b305bf6286faa2a4f360f3fbb8cd288a5a8188f44264213d8;
    bytes32 internal constant DIAMOND_CUT_FACET_RUNTIME_CODE_HASH =
        0xd5373fb6476a85185d3deb26df77ade094ace8e316aa17a1ec9311f9e556c64a;

    address internal constant DIAMOND_LOUPE_FACET = 0x39Da5ec984c0E5797E0BD24706Ab35F21EB065d1;
    bytes32 internal constant DIAMOND_LOUPE_FACET_INIT_CODE_HASH =
        0x2d5d2ee6694f7267bb8744c523b8f91e19f04be038a45350eb914e8648917f0c;
    bytes32 internal constant DIAMOND_LOUPE_FACET_RUNTIME_CODE_HASH =
        0x71a4fbf2d44b48cbc3f1b4a099f16a08686f732c80b2e7a682a0f9685fd7f5d4;

    address internal constant OWNERSHIP_FACET = 0x615eAdb82F2c3b84Ee4cd7ac5DefdF381d585978;
    bytes32 internal constant OWNERSHIP_FACET_INIT_CODE_HASH =
        0x1b9c9f7a795e294ea00d739f77fb0ca40f595fbdf74ce6bf2c47cd89400d1944;
    bytes32 internal constant OWNERSHIP_FACET_RUNTIME_CODE_HASH =
        0xd55ffb61d489bf9e14ddeef839e0204c1c5e54df914a8a9171864d93bd2379cc;

    /// @dev The `*_RUNTIME_CODE_HASH` fixtures are the keccak256 of each contract's deployed
    /// runtime code on Flare (`EXTCODEHASH`), so a reproduction can be verified after - and a
    /// skipped already-deployed address verified instead of trusted.

    /// @notice Directory holding the raw pinned init code, one `<Name>.hex` file per contract.
    string internal constant INIT_CODE_DIR = "deployment/pinned-init-code/";
}
