# Redeemer accounts

[`FAssetRedeemerAccount`](../../../contracts/composer/implementation/FAssetRedeemerAccount.sol) is a per-redeemer account, deployed once per EVM address that ever redeems through the composer. It holds the redeemer's in-flight fAsset, any wrapped-native refund from a failed redeem, any stable-coin output the FAssets system might route there, and pre-approved allowances back to the redeemer's own EVM address.

It is deployed as a [`FAssetRedeemerAccountProxy`](../../../contracts/composer/proxy/FAssetRedeemerAccountProxy.sol) — an OpenZeppelin `BeaconProxy`. The beacon is the composer, so every redeemer account points at `composer.implementation()`.

## Storage and access control

```solidity
contract FAssetRedeemerAccount is IIFAssetRedeemerAccount {
    address private constant EMPTY_ADDRESS = 0x0000000000000000000000000000000000001111;
    address public composer;
    address public owner;

    modifier onlyComposer() { require(msg.sender == composer, ComposerOnly()); _; }
    modifier onlyOwner()    { require(msg.sender == owner, OwnerOnly()); _; }
}
```

Two roles, two modifiers, no overlap:

- **`onlyComposer`** — the composer's contract address. Used by `redeemFAsset` and `setMaxAllowances`.
- **`onlyOwner`** — the redeemer's EVM address, set at init. Used by `redemptionPaymentDefault` and `xrpRedemptionPaymentDefault`.

The implementation's constructor pins `composer = 0x…1111` so it can never be initialized when called directly. The proxy's constructor invokes `initialize(composer, owner)` once during deployment; `initialize` requires `composer == address(0)` and so reverts on any subsequent call.

## Allowances primed at creation

When the composer creates a new account, it immediately calls `setMaxAllowances`:

```solidity
function setMaxAllowances(IERC20 _fAsset, IERC20 _stableCoin, IERC20 _wNat) external onlyComposer {
    _fAsset.forceApprove(owner, type(uint256).max);
    _stableCoin.forceApprove(owner, type(uint256).max);
    _wNat.forceApprove(owner, type(uint256).max);
    emit MaxAllowancesSet(owner, _fAsset, _stableCoin, _wNat);
}
```

The user can therefore sweep any of these three tokens from their redeemer account *without ever interacting with the composer*. After an `FAssetRedeemFailed`, the residual fAsset (and any wrapped-native deposit) is recoverable via a single `transferFrom`.

`forceApprove` is the OZ helper that handles ERC-20s like USDT that revert on a re-approve from non-zero.

`setMaxAllowances` is `onlyComposer` and is only invoked from `_getOrCreateRedeemerAccount` on the freshly-deployed branch. Existing accounts hit the early-return branch, so subsequent redemptions never re-prime allowances — there is no top-up path. In practice this never matters: each allowance starts at `type(uint256).max`, and ordinary `transferFrom` calls reduce it by amounts that are negligible compared to that ceiling.

## Redeem entry

```solidity
function redeemFAsset(
    IAssetManager _assetManager,
    uint256 _amountLD,
    string calldata _redeemerUnderlyingAddress,
    bool _redeemWithTag,
    uint256 _destinationTag,
    address payable _executor
) external payable onlyComposer returns (uint256 _redeemedAmountUBA);
```

The composer passes the asset manager explicitly (rather than the account reading it from `composer.assetManager()`) to keep this hot path one read shorter. Two paths:

- `_redeemWithTag == false`: `_assetManager.redeemAmount{value: msg.value}(_amountLD, _redeemerUnderlyingAddress, _executor)`.
- `_redeemWithTag == true`: assert `_assetManager.redeemWithTagSupported()` (XRP only), then `_assetManager.redeemWithTag{value: msg.value}(_amountLD, _redeemerUnderlyingAddress, _executor, _destinationTag)`.

`msg.value` is the executor fee — forwarded so the AssetManager pays it on to the executor.

`RedeemWithTagNotSupported` reverts when the asset manager rejects tagged redemptions; that propagates up to the composer's `catch` and becomes an `FAssetRedeemFailed`.

## Payment-default entry points

After a redemption request, the FAssets system expects the agent to make the underlying-chain payment within a window. If they don't, the redeemer can submit a non-payment proof and unwind:

```solidity
function redemptionPaymentDefault(
    IReferencedPaymentNonexistence.Proof calldata _proof,
    uint256 _redemptionRequestId
) external onlyOwner;

function xrpRedemptionPaymentDefault(
    IXRPPaymentNonexistence.Proof calldata _proof,
    uint256 _redemptionRequestId
) external onlyOwner;
```

Both are `onlyOwner` so an arbitrary actor cannot trigger a default on behalf of the user — the user has to opt in.

The asset manager address is read from `composer.assetManager()` (not from a stored field) so the account stays minimal. The asset manager's revert (e.g. proof invalid, request not actually defaulted) bubbles up unchanged.

The XRP-specific variant calls `xrpRedemptionPaymentDefault` on the asset manager; the generic variant calls `redemptionPaymentDefault`. Pick the variant matching the underlying asset.

## Address derivation

The composer deploys redeemer accounts itself via CREATE2 (no singleton factory):

```solidity
bytes memory bytecode = abi.encodePacked(
    type(FAssetRedeemerAccountProxy).creationCode,
    abi.encode(address(this) /* composer */, _redeemer)
);
_redeemerAccount = Create2.deploy(0, bytes32(0), bytecode);
```

`salt = bytes32(0)`. The CREATE2 deployer is the composer itself, so the account's address is `keccak256(0xff || composerAddress || 0 || keccak256(initcode))[12:]`.

Because `composerAddress` is part of the derivation, two distinct composer deployments (e.g., on different chains) produce different per-redeemer account addresses for the same EVM redeemer. The composer does not aim for cross-chain account-address parity — there is only ever one composer per chain.

The composer does **not** use a frozen `creationCode` constant like Smart Accounts does. That's fine because the composer never depends on cross-chain parity, and the per-redeemer account address is irrelevant to anyone but the composer (the user's identity is the EVM `redeemer` field they put in the compose message, not the account address).

## Verifying a redeemer account

`IFAssetRedeemComposer.isRedeemerAccount(address)` returns `(true, owner)` only if:

1. There is code at the address.
2. The address responds to `owner()` and returns some `owner`.
3. `redeemerToRedeemerAccount[owner] == address`.

The third step closes a spoofing window where an arbitrary contract could return any EVM address from `owner()`.

`IFAssetRedeemComposer.getBalances(address)` returns `(fAsset, stableCoin, wNat)` for any address — it does not require the address to be a redeemer account, so off-chain UI can use it for both the user's main wallet and their per-redeemer account in one call.
