# Contributing

If you want to contribute to this project, you MUST follow the guidelines below.

Any changes you make SHOULD be noted in the changelog.

For merge request to be accepted, it MUST pass all linter and formatter checks,
MUST pass all tests, and MUST be reviewed by at least one other contributor.

## Set up your dev environment

```bash
# Install packages
yarn

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
yarn coverage-forge
```

The default behavior for forge test is to only display a summary of passing and failing tests. To show more information change the verbosity level with the `-v` flag:

- `-vv`: displays logs emitted during tests, including assertion errors (e.g., expected vs. actual values);
- `-vvv`: shows execution traces for failing tests, in addition to logs;
- `-vvvv`: displays execution traces for all tests and setup traces for failing tests;
- `-vvvvv`: provides the most detailed output, showing execution and setup traces for all tests, including storage changes.
-
## Linting and formatting

There are currently the following linters included in this repository:

- `solhint` solidity linter

### How to run
```bash
# run solhint
yarn lint

# run solhint on forge test contracts
yarn lint-forge
```

## Deployment

### Prerequisites

- Install dependencies:
  ```bash
  yarn
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
yarn deploy_contracts_<network>
```

This will:

- Load environment variables from `.env`
- Use Forge to deploy contracts with parameters from your config files

#### Example for Coston2

Set `COSTON2_RPC_URL` and `DEPLOYER_PRIVATE_KEY` in your `.env` file.

Check and if needed update config file [`deployment/chain-config/coston2.json`](deployment/chain-config/coston2.json).

Run

```bash
yarn deploy_contracts_coston2
```

### Contract Verification

To verify (on Blockscout explorer) all deployed contracts on a supported network run:

```
yarn verify_contracts_<network>
```
This will automatically verify all contracts listed in the deployment JSON for the selected network.

#### Example for Coston2

```
yarn verify_contracts_coston2
```

