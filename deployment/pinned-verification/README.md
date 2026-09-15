# Pinned-contract verification inputs

The solc standard-json inputs that verify the four contracts deployed from `../pinned-init-code/` —
`MasterAccountController` and the three base facets — on an explorer that demands an exact
deployment-bytecode match, which in practice means Etherscan.

They are here for the same reason the init code is: **this repository cannot reproduce them.** That
code was compiled with solc 0.8.30 and flare-periphery 0.1.38, and the repository now builds 0.8.35.
The functional bytes are identical either way, but the compiler version lives in the metadata
trailer, so an exact match needs the original compilation and nothing else will do. Recovering it
depends on the Flare mainnet explorer still serving that verification; checked in, it does not.

| File | |
|---|---|
| `<Contract>.standard-input.json` | language, sources and settings — everything solc needs |
| `MasterAccountController.constructor-args.txt` | 960 bytes, no `0x`; the other three take none |

Compiler: `v0.8.30+commit.73712a01`. Everything else travels inside the JSON.

Verified 2026-09-15: each input compiled with solc 0.8.30 reproduces its contract's deployed runtime
byte for byte, metadata trailer included, at the Sepolia addresses in `../deploys/sepolia.json` —
which hold the same bytes as Flare, both having come from the same pinned init code. All four were
accepted by Etherscan that day.

Why the constructor arguments are recorded rather than derived: the deployment goes through the
EIP-2470 singleton factory, so the creating transaction's input is factory calldata and an explorer
has nothing to slice. These bytes are the tail of `../pinned-init-code/MasterAccountController.hex`
and decode to the three base facet cuts plus `DiamondArgs{owner: INITIAL_OWNER}`.

The full procedure, including how these were recovered and the one trap in doing it again, is the
"four pinned contracts" section of [`../README.md`](../README.md).
