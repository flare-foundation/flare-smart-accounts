<p align="center">
  <a href="https://flare.network/" target="blank"><img src="https://content.flare.network/Flare-2.svg" width="400" height="300" alt="Flare Logo" /></a>
</p>

# Development

## Using Hardhat

## Using Foundry

### Environment
```bash
# install Foundryup
curl -L https://foundry.paradigm.xyz | bash
foundryup

# initialize the forge-std submodule
git submodule update --init --recursive

# compile contracts for forge
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