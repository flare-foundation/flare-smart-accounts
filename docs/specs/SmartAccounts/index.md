# Smart Accounts

Account abstraction for XRPL users on Flare. The user signs XRPL `Payment` transactions; the protocol routes those into Flare-side state changes — minting and redeeming FXRP, depositing into yield vaults, executing arbitrary ERC-4337 `PackedUserOperation`s.

The contracts live under [`contracts/smartAccounts/`](../../../contracts/smartAccounts/) plus the shared diamond infrastructure in [`contracts/diamond/`](../../../contracts/diamond/). The single on-chain entry point is the [`MasterAccountController`](../../../contracts/smartAccounts/implementation/MasterAccountController.sol) diamond.

## Documents

- [Architecture](./Architecture.md) — the diamond, facets, libraries, namespaced storage
- [Personal Accounts](./PersonalAccounts.md) — per-user beacon proxies, CREATE2 derivation, frozen creation code
- [Payment-reference instructions](./PaymentReferenceInstructions.md) — proof-based flow, the 32-byte payment reference layout, replay protection
- [Memo instructions](./MemoInstructions.md) — direct-minting flow, the seven memo opcodes, nonces, executors, fee overrides
- [Payment proofs](./PaymentProofs.md) — FDC `IPayment.Proof` verification, source ID, provider wallets, validity window
- [Vaults](./Vaults.md) — agent-vault and Firelight/Upshift vault registries, instruction routing
- [Executors](./Executors.md) — default protocol executor and per-account pinned executors
- [Fees](./Fees.md) — instruction fees, default and per-instruction-ID overrides
- [Pause](./Pause.md) — pauser / unpauser roles, scope of `notPaused`
- [Timelock](./Timelock.md) — `onlyOwnerWithTimelock`, recording, executing, cancelling

## Key contracts and code layout

```text
contracts/smartAccounts/
├── facets/          # Diamond facets (thin entry points)
├── implementation/  # MasterAccountController, PersonalAccount
├── interface/       # II* internal interfaces (facet ↔ library)
├── library/         # Business logic + ERC-7201 namespaced storage
└── proxy/           # PersonalAccountProxy

contracts/diamond/
├── facets/          # DiamondLoupeFacet, OwnershipFacet
├── implementation/  # Diamond.sol (Nick Mudge reference)
├── interfaces/      # IDiamond, IDiamondCut, IDiamondLoupe, IERC165, IERC173
└── libraries/       # LibDiamond
```

Public interfaces — 12 `I*.sol` files under [`contracts/userInterfaces/facets/`](../../../contracts/userInterfaces/) plus the top-level [`IMasterAccountController`](../../../contracts/userInterfaces/IMasterAccountController.sol) and [`IPersonalAccount`](../../../contracts/userInterfaces/IPersonalAccount.sol).
