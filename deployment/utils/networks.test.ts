import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CHAIN_IDS,
  FLARE_FAMILY_CHAIN_IDS,
  FLARE_FAMILY_NETWORKS,
  LOAN_CHAIN_IDS,
  LOAN_CHAIN_NETWORKS,
  SUPPORTED_BASE_NETWORKS,
  baseNetworkName,
  expectedChainId,
  resolveRpcUrl,
  validateNetwork,
} from "./networks";

void test("the two families are pinned, disjoint and complete", () => {
  // pinned by member, not by iterating the module's own lists: a test that consults the list it
  // is testing loses its case the moment an entry is dropped, and silently passes
  assert.deepEqual(FLARE_FAMILY_NETWORKS, ["coston2", "coston", "flare", "songbird"]);
  assert.deepEqual(LOAN_CHAIN_NETWORKS, ["ethereum", "sepolia"]);
  assert.deepEqual(SUPPORTED_BASE_NETWORKS, [...FLARE_FAMILY_NETWORKS, ...LOAN_CHAIN_NETWORKS]);
  assert.deepEqual(CHAIN_IDS, { flare: 14, songbird: 19, coston: 16, coston2: 114, ethereum: 1, sepolia: 11155111 });
  // the id lists are the names' ids, family by family - the same sets DeployNetworks.sol holds
  assert.deepEqual([...FLARE_FAMILY_CHAIN_IDS].sort(), FLARE_FAMILY_NETWORKS.map((name) => CHAIN_IDS[name]).sort());
  assert.deepEqual([...LOAN_CHAIN_IDS].sort(), LOAN_CHAIN_NETWORKS.map((name) => CHAIN_IDS[name]).sort());
  assert.equal(
    FLARE_FAMILY_CHAIN_IDS.some((id) => LOAN_CHAIN_IDS.includes(id)),
    false
  );
});

void test("a Flare-family staging alias is a network, a loan chain's is not, and an unknown name never is", () => {
  validateNetwork("coston2");
  validateNetwork("coston2-staging");
  validateNetwork("ethereum");
  validateNetwork("sepolia");
  assert.throws(() => validateNetwork("sepolia-staging"), /only the pinned deployment/);
  assert.throws(() => validateNetwork("ethereum-staging"), /only the pinned deployment/);
  // there is no local-development network: a chain in neither family has no record here to write
  assert.throws(() => validateNetwork("scdev"), /Invalid network: scdev/);
  assert.throws(() => validateNetwork("goerli"), /Invalid network: goerli/);
  assert.equal(baseNetworkName("coston2-staging"), "coston2");
  assert.equal(baseNetworkName("coston2"), "coston2");
});

void test("every network has one chain id, its staging alias the same one, and nothing else has any", () => {
  assert.equal(expectedChainId("sepolia"), 11155111);
  assert.equal(expectedChainId("ethereum"), 1);
  assert.equal(expectedChainId("coston2-staging"), 114);
  assert.throws(() => expectedChainId("scdev"), /Invalid network: scdev/);
});

void test("the RPC is the network's variable, else Flare's public endpoint; the loan chains have no default", () => {
  assert.equal(resolveRpcUrl("coston2", {}), "https://coston2-api.flare.network/ext/C/rpc");
  assert.equal(resolveRpcUrl("coston2-staging", { COSTON2_RPC_URL: "http://127.0.0.1:8545" }), "http://127.0.0.1:8545");
  assert.equal(resolveRpcUrl("sepolia", { SEPOLIA_RPC_URL: "https://rpc.example" }), "https://rpc.example");
  assert.throws(() => resolveRpcUrl("sepolia", {}), /SEPOLIA_RPC_URL is required for the sepolia network/);
  assert.throws(() => resolveRpcUrl("ethereum", {}), /ETHEREUM_RPC_URL is required for the ethereum network/);
});
