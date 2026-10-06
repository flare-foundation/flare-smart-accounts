# The test suites

How the suites are grouped, and the conventions every test follows, are in
[`AGENTS.md`](../AGENTS.md#testing). This file carries the detail that only matters while you are
working on one of these suites: which of them reach outside the repository, what each needs to run,
and what `pnpm coverage` leaves out.

## What `pnpm coverage` leaves out, and why

`forge coverage` builds with the optimizer disabled, and LayerZero's composer does not compile that
way. Every suite that instantiates one is therefore `--skip`ped: the canonical-compose integration
test, and the three OFT bridge suites, any of which instantiates `RelayLzEndpoint`.

Two deployment suites are skipped for the same class of reason.
`test/unit/deployment/DeploySmartAccountsGuards.t.sol` imports `DeploySmartAccounts`, which copies a
memory array of structs into storage and only the IR pipeline compiles (solc 1834).
`test/unit/deployment/DeployRemoteControllerThrowaway.t.sol` imports a script that assembles the
controller's constructor arguments, which is stack-too-deep without IR. Deploy scripts are pruned
from the coverage figure anyway, so these skips cost nothing.

Two tests are excluded by name rather than by file, through `--no-match-test` in `package.json`:
`testProxyCreationCodeLengthMatchesFreshCompilation` and
`testProxyCreationCodeMatchesFreshCompilationModuloMetadata`. Both compare a frozen
`PROXY_CREATION_CODE` constant against a fresh compilation, which under coverage's instrumented,
optimizer-disabled build is a different byte string by construction. The constants stay pinned by
their hash fixtures in the same suites, which do run.

## Integration suites

These run against contracts we did not write: either real deployed ones on a pinned mainnet fork, or
canonical ones deployed locally.

**`MorphoLoanSubaccountRemoteCanonicalCompose.t.sol`** runs the loan account against LayerZero's own
`MessagingComposer`. `contracts/mock/CanonicalComposeEndpoint.sol` is that contract verbatim plus an
`eid` getter, because the compose queue's rules are relied on rather than implemented.

**The fork suites skip themselves** unless the network they need is configured, so an offline run is
inert rather than failing. A `REQUIRE_*` variable turns the skip into a failure where CI must not let
a check go unmade.

- **`MorphoLoanSubaccountRemoteFork.t.sol`** needs `ETHEREUM_RPC_URL` to name an endpoint serving
  state at its pinned block, which is an archive read, and runs with
  `ETHEREUM_RPC_URL=<url> forge test --match-path "test/integration/*"`. `REQUIRE_FORK` is what the
  `test-integration-fork` job sets; that job is the only place a pipeline reaches mainnet, which is
  why it is separate from `test`. Most free tiers prune that far back. `https://eth-pokt.nodies.app`
  served it on 2026-09-09, and `cast block <FORK_BLOCK> --rpc-url <url>` plus one `eth_call` at that
  block is the quickest way to test a candidate before running the suite.
- **`LoanDeliveryGasFork.t.sol`** is the runbook's Part C item 3 on Ethereum. On the same fixture
  and block as the Morpho suite, it points the transport at the live endpoint and FXRP OFT. It
  delivers each loan action in LayerZero's two steps, the OFT's `lzReceive` and then the endpoint's
  `lzCompose`; the withdraw's return leg leaves through the OFT's real `send`. It prints the gas
  each step took and holds each step under the delivery options clients sign. Each step is its own
  top-level call, so it pays cold storage prices. It needs `ETHEREUM_RPC_URL`, and runs in
  `test-integration-fork` beside the Morpho suite.
- **`SepoliaMarketFork.t.sol`** needs `SEPOLIA_RPC_URL`, any current endpoint since it forks the
  latest block, and drives the rehearsal market script's phases against Morpho's real oracle factory
  and Morpho itself.
- **`FlareUpgradeRehearsalFork.t.sol`** is the runbook's Part C item 1. It needs `FLARE_RPC_URL` to
  serve its pinned block, which takes an archive endpoint once the block ages: the public endpoint
  already fails 1,000 blocks back. It applies the release to the live Flare controller as the runbook
  does: `build-cut.ts` over the committed cut file, the implementations, and the routes for the
  tests that need them, each through the owner Safe and the timelock. It then exercises live
  accounts, which are named by address in the suite. Only FDC proof verification is mocked.
  Re-pin the block and re-pick the accounts when the cut file changes. No CI job runs it, and
  `REQUIRE_FLARE_FORK` turns its skip into a failure.

**Three suites cover the OFT bridge** with LayerZero's own contracts rather than a model of them,
built on `contracts/mock/FeeOftAdapter.sol` and `FeeOftToken.sol` (its `OFTAdapter`/`OFT` plus the
`Fee` mixin, carrying the deployed variants' `_debitView` verbatim) over `RelayLzEndpoint.sol` (its
`MessagingComposer` plus the send path an OApp touches) and `RelayLzExecutor.sol`.

- **`OftFeeCreditToCompose.t.sol`** pins the transport itself: what a fee-bearing send debits, what
  the far side credits, and that the credited amount is what reaches the compose message, in both
  directions. One of its cases asserts the real packet is byte-identical to the form the other suites
  build by hand, which is what makes those suites evidence about the real wire format.
- **`PersonalAccountRemoteOftFunding.t.sol`** covers native drops into the real Personal Account
  proxy, receive-versus-compose funding, and starved deliveries.
- **`LoanOftRoundTrip.t.sol`** joins the two halves: the production account pair and frozen proxies on
  two INDEPENDENT forks of one empty local chain, so the real CREATE2 derivations and the same-address
  compose authentication run without any account code or storage being rewritten. It needs
  `F28_LOCAL_RPC_URL` and skips without it. `test/tooling/loan-oft-roundtrip.test.ts` starts that
  chain and sets `REQUIRE_LOAN_OFT_ROUNDTRIP` so no case inside can skip; it is one of the four files
  the Foundry-equipped `test-tooling-forge` job runs, alongside `decode-calls.test.ts`,
  `deploy-sepolia-market.output.test.ts` and `execute-diamond-cut.output.test.ts`.
