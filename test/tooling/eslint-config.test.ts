import { strict as assert } from "node:assert";
import test from "node:test";
import { ESLint } from "eslint";

/**
 * The shared lint config relaxes every path under `test/`, and `eslint.config.mjs` exempts
 * `test/tooling/` from that so the deployment tooling's tests answer to the same rules as the
 * tooling. That exemption finds the shared block by its glob, so this pins the outcome rather than
 * the mechanism: a tooling test and the tooling it exercises must resolve to the same effective
 * rules, whatever the shared config does to its blocks.
 */

/** The rules ESLint would apply to `file`, typed: the API answers with `any`. */
async function effectiveRules(eslint: ESLint, file: string): Promise<Record<string, unknown>> {
  const config = (await eslint.calculateConfigForFile(file)) as { rules: Record<string, unknown> };
  return config.rules;
}

void test("a tooling test is linted exactly as the tooling it exercises", async () => {
  const eslint = new ESLint();
  const tooling = await effectiveRules(eslint, "test/tooling/networks.test.ts");
  const source = await effectiveRules(eslint, "deployment/utils/networks.ts");
  assert.deepEqual(tooling, source, "the relaxation the shared config gives test/** reached the tooling tests");
  // and the relaxation itself still exists for the rest of test/, or this check would prove
  // nothing: a hypothetical Solidity-adjacent helper there must resolve looser than the source
  const relaxed = await effectiveRules(eslint, "test/utils/example.ts");
  assert.notDeepEqual(relaxed, source, "the shared config no longer relaxes test/**, so the exemption is idle");
});
