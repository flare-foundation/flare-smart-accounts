// @ts-check
import { includeIgnoreFile } from "@eslint/compat";
import { defaultConfig } from "@flarenetwork/eslint-config-flare";
import prettier from "eslint-config-prettier";
import path from "node:path";
import { fileURLToPath } from "node:url";

const gitignorePath = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  ".gitignore",
);

// The shared config relaxes `test/**/*.ts` - looser typing, unused values, async functions with
// nothing to await - which suits Solidity-adjacent fixtures but not `test/tooling/`, whose files
// are the deployment tooling's own node tests and are held to the same rules as the tooling they
// exercise. Rather than re-listing what to re-enable, which would drift as the shared config
// changes, the relaxation is simply not applied there. The block is looked up by its glob, so a
// shared config that renames or splits it would silently hand the tooling tests the relaxed rules
// again; hence the count is asserted, and `test/tooling/eslint-config.test.ts` compares the
// effective rules of a tooling test with those of the tooling itself.
const TEST_RELAXATION_GLOB = "test/**/*.ts";
const relaxations = defaultConfig.filter(
  (block) => Array.isArray(block.files) && block.files.includes(TEST_RELAXATION_GLOB),
);
if (relaxations.length !== 1) {
  throw new Error(
    `expected exactly one shared block relaxing ${TEST_RELAXATION_GLOB}, found ${relaxations.length}: ` +
      "the exemption for test/tooling/ no longer knows which block to exempt it from",
  );
}
const strictToolingTests = defaultConfig.map((block) =>
  block === relaxations[0]
    ? { ...block, ignores: [...(block.ignores ?? []), "test/tooling/**/*.ts"] }
    : block,
);

export default [includeIgnoreFile(gitignorePath), ...strictToolingTests, prettier];
