/**
 * What `deploy_remote_account_implementations` should actually deploy.
 *
 * The script used to deploy every remote implementation on every run. Once one of them is live,
 * that is wrong twice over: the unchanged one gets a new address for no reason, its record is
 * replaced, and the operator is left choosing between a pointless timelocked re-registration and a
 * record naming an implementation the diamond does not serve — which `verify_implementation
 * --stage live` then reports as a mismatch.
 *
 * Two things fix it, and neither is sufficient alone. Naming which to deploy stops the accidental
 * redeploy; comparing what is already there stops the deliberate one from being wasted. So the
 * caller must name a selection (there is no default — `all` is something to ask for, not something
 * to get by forgetting), and each named implementation is still skipped when the address already
 * recorded carries this exact code.
 *
 * The selection is a LIST OF NAMES, never a row of flags. More subaccount types are expected — the
 * type allocations in `deployment/lib/SubaccountTypes.sol` say so — and a positional boolean per
 * implementation would turn into `true false false true` at the call site, which is a miscount
 * waiting to happen and unreadable in a runbook. Adding an implementation here is one row in the
 * table below and one branch in the script's dispatch; no existing argument moves.
 *
 * Equality is runtime code modulo its own trailing metadata, the same comparison the cut planner
 * makes about facets. That is sound for these specifically: none has immutables or linked
 * libraries, and the constructor they inherit writes only the lock sentinel
 * (`ControlledAccountBase`), so nothing chain- or deployment-specific is baked into the runtime.
 * It proves the code is equivalent and nothing else — in particular it says nothing about storage
 * layout, which stays the upgrade validator's job. A skipped deploy must never be read as a layout
 * that was checked.
 *
 * A reused address is NOT a registered one. The diamond registers implementations through a
 * timelocked governance call, so an implementation can sit recorded and unregistered for as long as
 * the timelock and the signers take. The plan therefore reports registration separately, and a
 * reuse leaves any pending registration exactly as pending as it was.
 */

import { stripMetadata } from "./facet-code";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/** One remote implementation: how an operator names it, its artifact, and its record entry. */
export interface RemoteImplementation {
  /** The operator-facing name, as the wrapper's selection takes it. */
  slug: string;
  /** The artifact and source name, which is what the deploy script dispatches on. */
  contract: string;
  /** The name its entry carries in `deployment/deploys/<network>.json`. */
  recordName: string;
}

/**
 * Every remote implementation a deploy can be asked for. A new subaccount type adds a row; nothing
 * else about the interface changes.
 */
export const REMOTE_IMPLEMENTATIONS: RemoteImplementation[] = [
  {
    slug: "personal-account",
    contract: "PersonalAccountRemote",
    recordName: "PersonalAccountRemoteImplementation",
  },
  {
    slug: "morpho-loan-subaccount",
    contract: "MorphoLoanSubaccountRemote",
    recordName: "MorphoLoanSubaccountRemoteImplementation",
  },
];

/** The selection that means every implementation, spelled out rather than implied by omission. */
export const ALL = "all";

export function knownSlugs(): string[] {
  return REMOTE_IMPLEMENTATIONS.map((implementation) => implementation.slug);
}

/**
 * Resolves a selection — a comma-separated list of slugs, or `all` — to implementations.
 *
 * An unknown name is refused rather than ignored: silently deploying a shorter list than the
 * operator asked for is how an implementation gets left behind. A repeat is refused for the same
 * reason, since it usually means one of the two was meant to be a different name.
 */
export function resolveSelection(selection: string): RemoteImplementation[] {
  const names = selection
    .split(",")
    .map((name) => name.trim())
    .filter((name) => name.length > 0);
  if (names.length === 0) {
    throw new Error(`name what to deploy: ${ALL}, or a comma-separated list of ${knownSlugs().join(", ")}`);
  }
  if (names.includes(ALL)) {
    if (names.length > 1) {
      throw new Error(`${ALL} already means every implementation; drop the rest of "${selection}"`);
    }
    return [...REMOTE_IMPLEMENTATIONS];
  }
  const resolved: RemoteImplementation[] = [];
  for (const name of names) {
    const implementation = REMOTE_IMPLEMENTATIONS.find((candidate) => candidate.slug === name);
    if (implementation === undefined) {
      throw new Error(`unknown implementation: ${name}. Known: ${knownSlugs().join(", ")}, or ${ALL}`);
    }
    if (resolved.includes(implementation)) {
      throw new Error(`${name} is named twice in "${selection}"`);
    }
    resolved.push(implementation);
  }
  return resolved;
}

export type PlanAction = "DEPLOY" | "REUSE";

export interface ImplementationPlanEntry {
  slug: string;
  contract: string;
  recordName: string;
  action: PlanAction;
  /** Why, in the operator's words. */
  reason: string;
  /** The address a REUSE keeps. Absent on a DEPLOY, which has none yet. */
  address?: string;
  /**
   * What the diamond's registry holds for this implementation today: the registered address, or
   * `undefined` when the registry's facet is not cut yet. Reported, never acted on.
   */
  registered?: string;
  /** True when the plan's address is not what the registry holds, so a registration is still due. */
  registrationPending?: boolean;
}

export interface ImplementationPlan {
  entries: ImplementationPlanEntry[];
  /** Notes that belong to the run rather than to one entry. */
  notes: string[];
}

/** The record entry a plan reads, in the shape the deployment record stores. */
export interface RecordedImplementation {
  name: string;
  address: string;
}

export interface PlanInputs {
  /** A comma-separated list of slugs, or `all`. */
  selection: string;
  /** Every entry of the network's deployment record, so duplicates are visible. */
  record: RecordedImplementation[];
  /** The artifact's runtime code, by contract name. */
  artifactCode(contract: string): Buffer;
  /** Runtime code on chain, `0x` or empty when the address carries none. */
  code(address: string): Promise<string>;
  /**
   * What the diamond's registry holds, or `undefined` when its facet is not cut. Optional: a plan
   * can be made without a chain registry, and then says nothing about registration.
   */
  registered?(contract: string): Promise<string | undefined>;
}

function hexToBuffer(code: string): Buffer {
  const body = code.startsWith("0x") ? code.slice(2) : code;
  return Buffer.from(body, "hex");
}

/**
 * The record is keyed by name and the recorder replaces the FIRST match, so a duplicated name
 * means a later run would update one entry while other tooling reads the other. Refused before
 * anything is broadcast rather than after.
 */
function requireNoDuplicateNames(record: RecordedImplementation[], names: string[]): void {
  for (const name of names) {
    const matches = record.filter((entry) => entry.name === name);
    if (matches.length > 1) {
      throw new Error(
        `the deployment record holds ${matches.length} entries named ${name} ` +
          `(${matches.map((entry) => entry.address).join(", ")}). The recorder replaces the first ` +
          `match, so a deploy would update one and leave the rest to be read by other tooling. ` +
          `Remove the stale entries before deploying.`
      );
    }
  }
}

export async function planRemoteImplementations(inputs: PlanInputs): Promise<ImplementationPlan> {
  const wanted = resolveSelection(inputs.selection);
  requireNoDuplicateNames(
    inputs.record,
    wanted.map((implementation) => implementation.recordName)
  );

  const entries: ImplementationPlanEntry[] = [];
  const notes: string[] = [];

  for (const implementation of wanted) {
    const recorded = inputs.record.find((entry) => entry.name === implementation.recordName);
    const registered = inputs.registered ? await inputs.registered(implementation.contract) : undefined;
    const current = stripMetadata(inputs.artifactCode(implementation.contract));
    const base = {
      slug: implementation.slug,
      contract: implementation.contract,
      recordName: implementation.recordName,
    };

    let entry: ImplementationPlanEntry;
    if (recorded === undefined) {
      entry = { ...base, action: "DEPLOY", reason: "nothing recorded under this name yet" };
    } else {
      const deployed = hexToBuffer(await inputs.code(recorded.address));
      if (deployed.length === 0) {
        entry = {
          ...base,
          action: "DEPLOY",
          reason: `the recorded address ${recorded.address} carries no code on this chain`,
        };
      } else if (stripMetadata(deployed).equals(current)) {
        entry = {
          ...base,
          action: "REUSE",
          reason: "the recorded address already carries this code",
          address: recorded.address,
        };
      } else {
        entry = {
          ...base,
          action: "DEPLOY",
          reason: `the recorded address ${recorded.address} carries different code`,
        };
      }
    }

    if (registered !== undefined) {
      entry.registered = registered;
      const target = entry.address;
      entry.registrationPending = target === undefined || target.toLowerCase() !== registered.toLowerCase();
      // whatever the registry holds is named whenever it is not what this plan will register, on a
      // DEPLOY as much as on a REUSE. It is most worth seeing while a replacement is being prepared:
      // the address about to be superseded is the one positions are held against today. The plan
      // reports it and changes nothing - which of the two is intended is a question for a person,
      // and overwriting the record would answer it silently
      if (entry.registrationPending === true && registered !== ZERO_ADDRESS) {
        const replacing =
          entry.action === "REUSE"
            ? `The deploy reuses the recorded address and changes neither`
            : `The deploy replaces the record with a new address; the registry keeps ${registered} ` +
              `until governance registers the replacement`;
        const named = recorded === undefined ? "nothing" : recorded.address;
        notes.push(
          `${implementation.contract}: the record names ${named} while the diamond has ` +
            `${registered} registered. ${replacing}; decide which is intended before registering.`
        );
      }
    }

    entries.push(entry);
  }

  if (entries.every((entry) => entry.action === "REUSE")) {
    notes.push("nothing to deploy: every selected implementation is already on chain as this code");
  }

  return { entries, notes };
}

/** The artifact names to deploy, in the order the script will take them. */
export function contractsToDeploy(plan: ImplementationPlan): string[] {
  return plan.entries.filter((entry) => entry.action === "DEPLOY").map((entry) => entry.contract);
}

export function formatPlan(plan: ImplementationPlan): string[] {
  const lines = plan.entries.map((entry) => {
    const address = entry.address === undefined ? "" : ` ${entry.address}`;
    const registration = entry.registrationPending === true ? " - registration still pending" : "";
    return `  ${entry.action.padEnd(6)} ${entry.slug}${address}: ${entry.reason}${registration}`;
  });
  return [...lines, ...plan.notes.map((note) => `  note: ${note}`)];
}
