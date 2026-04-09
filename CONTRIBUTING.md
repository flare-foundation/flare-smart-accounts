# Contributing

If you want to contribute to this project, you MUST follow the guidelines below.

Any changes you make SHOULD be noted in the changelog.

For merge request to be accepted, it MUST pass all linter and formatter checks,
MUST pass all tests, and MUST be reviewed by at least one other contributor.

## Set up your dev environment

```bash
# Install packages
pnpm install

# install Foundryup
curl -L https://foundry.paradigm.xyz | bash
foundryup

# install dependencies
forge soldeer install

# compile contracts
forge build
```

### How to run

```bash
# all forge tests
forge test

# all tests of a test contract
forge test --mc <contract_name>

# specific test function
forge test --mt <test_name>

# generate coverage report
pnpm coverage
```

The default behavior for forge test is to only display a summary of passing and failing tests. To show more information change the verbosity level with the `-v` flag:

- `-vv`: displays logs emitted during tests, including assertion errors (e.g., expected vs. actual values);
- `-vvv`: shows execution traces for failing tests, in addition to logs;
- `-vvvv`: displays execution traces for all tests and setup traces for failing tests;
- `-vvvvv`: provides the most detailed output, showing execution and setup traces for all tests, including storage changes.

## Linting and formatting

There are currently the following linters and formatters included in this repository:

- `solhint` solidity linter
- `eslint` TypeScript linter
- `prettier` code formatter

### How to run
```bash
# run solhint
pnpm lint-sol

# run eslint on TypeScript
pnpm lint:check

# check formatting
pnpm format:check

# fix formatting
pnpm format:fix
```

## Deployment

### Supported Networks

The following networks are supported for deployment and verification:

- coston2
- coston
- flare
- songbird
- scdev

You can also use staging variants by appending `-staging` to any base network (e.g., `coston2-staging`).

### Prerequisites

- Install dependencies:
  ```bash
  pnpm install
  ```
- Create a `.env` file in the project root with:
  ```env
  <NETWORK>_RPC_URL=
  DEPLOYER_PRIVATE_KEY=0x...
  ```
  See .env.template for an example environment file.
- Ensure chain config (`deployment/chain-config/<network>.json`) is set up as needed.

### Deploying Contracts

Run the following command to deploy contracts:

```bash
pnpm deploy_contracts <network> <fullDeploy (true|false)>
```
where `<network>` is the target network (e.g., `coston2`), and `<fullDeploy>` indicates whether to perform a full deployment (`true`) or a partial deployment, which means deploying diamond contract with only base facets (DiamondCutFacet, DiamondLoupeFacet, OwnershipFacet) and without executing initialization (`false`).

This will:

- Load environment variables from `.env`
- Use Forge to deploy contracts with parameters from your config files

#### Example for Coston2

Set `COSTON2_RPC_URL` and `DEPLOYER_PRIVATE_KEY` in your `.env` file.

Check and if needed update config file [`deployment/chain-config/coston2.json`](deployment/chain-config/coston2.json).

Run

```bash
pnpm deploy_contracts coston2 true
```

### Contract Verification

To verify (on Blockscout explorer) all deployed contracts on a supported network run:

```
pnpm verify_contracts <network>
```
This will automatically verify all contracts listed in the deployment JSON for the selected network.

#### Example for Coston2

```
pnpm verify_contracts coston2
```

### Execute Diamond Cut
To execute a diamond cut on an existing diamond contract (or to only print execute transaction data), first create the cut file (see [cut-example.json](deployment/cuts/coston2/cut-example.json)) and put it in the `deployment/cuts/<network>` folder.

Then run the diamond_cut script with:

```bash
pnpm diamond_cut <network> <cut-file-name>
```

where `<network>` is the target network and `<cut-file-name>` is the name of the cut file (e.g., `cut-example`).

Do not include the `.json` extension unless otherwise specified; the script will automatically append it.

The script will read the `execute` flag from cut JSON file to determine whether to actually execute the cut or just print the transaction data.

#### Note on Internal Output Files
Intermediate files generated during diamond cut deployment are written to the `deployment/output-internal/` directory. These files are for internal use only and are not considered essential output or deployment artifacts. You generally do not need to track or use these files unless you are debugging or developing deployment scripts.

## Review scope and audits

When reviewing the code, either as part of a bug bounty program, audit competition, or regular code review, please consider the following scope.

### In scope

```
contracts/composer/**/*
contracts/smartAccounts/**/*
contracts/userInterfaces/**/*
contracts/utils/**/*
```

### Out of scope

```
contracts/diamond/**/*
contracts/mock/**/*
```