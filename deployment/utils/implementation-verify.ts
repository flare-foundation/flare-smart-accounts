// Registration is the deployment's one blind step: `setPersonalAccountImplementation` and
// `setSubaccountImplementation` check only that the address has code, and a wrong but
// `initialize`-compatible implementation would let permissionless creation materialize proxies
// over the wrong storage layout - permanently, since initialization cannot be replayed. This is
// the check that closes that hole, at the three moments it has to hold: before the timelocked
// call is queued, again before it executes, and after it has. Everything here is pure over two
// readers - one for the chain, one for the repository - so the regression tests drive the same
// code with a fake chain; verify-implementation.ts wires web3 and the filesystem to it.
import Web3 from "web3";
import { type Check, check, checkEq } from "./diamond-verify";
import { ZERO_CODE, compareFacet, hexToBytes } from "./facet-code";
import { FLARE_FAMILY_CHAIN_IDS, LOAN_CHAIN_IDS } from "./networks";

/** Which registry an implementation is registered in. */
export type RegistryTarget = "personalAccountBeacon" | "subaccountType";

/** Where an implementation belongs and how it is registered. */
export interface ImplementationSpec {
  target: RegistryTarget;
  /** The subaccount type it is registered for, for `subaccountType` targets. */
  subaccountType?: number;
  /**
   * Which chain family the implementation lays out storage for. The deploy scripts refuse the
   * wrong family (a remote implementation registered on Flare would corrupt every Personal
   * Account's storage); registration is the second, later chance to catch it.
   */
  family: "flare" | "remote";
}

/** `SUBACCOUNT_TYPE_LOAN` in contracts/userInterfaces/facets/ISubaccountsFacet.sol. */
export const SUBACCOUNT_TYPE_LOAN = 1;

/** The four implementations that get registered, by artifact name. */
export const IMPLEMENTATIONS: Record<string, ImplementationSpec> = {
  PersonalAccount: { target: "personalAccountBeacon", family: "flare" },
  PersonalAccountRemote: { target: "personalAccountBeacon", family: "remote" },
  LoanSubaccount: { target: "subaccountType", subaccountType: SUBACCOUNT_TYPE_LOAN, family: "flare" },
  MorphoLoanSubaccountRemote: { target: "subaccountType", subaccountType: SUBACCOUNT_TYPE_LOAN, family: "remote" },
};

/**
 * The moment being verified. `pre`: before the timelocked registration is queued. `queued`:
 * after queueing, before execution. `live`: after execution.
 */
export type Stage = "pre" | "queued" | "live";

/** The ERC-1967 beacon slot, `keccak256("eip1967.proxy.beacon") - 1`, where BeaconProxy keeps it. */
export const BEACON_SLOT = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/** One materialized account's identity, as its own getters report it. */
export interface AccountIdentity {
  controller: string;
  /** A Personal Account's XRPL owner. */
  xrplOwner?: string;
  /** A subaccount's parent Personal Account. */
  parent?: string;
  /** A subaccount's type. */
  subaccountType?: bigint;
}

/** Reads of one chain state, every one at the block the reader was built for. */
export interface ChainReader {
  /** Runtime code at `address`, `0x` when there is none. */
  code(address: string): Promise<string>;
  /** The 32-byte word at `slot` of `address`. */
  storage(address: string, slot: string): Promise<string>;
  /**
   * `implementation()` or `implementationForType(type)` on the diamond; `undefined` when the
   * diamond does not serve that selector, which means the registry's facet is not cut yet.
   */
  registered(diamond: string, spec: ImplementationSpec): Promise<string | undefined>;
  /**
   * `getExecuteTimelockedCallTimestamp(encodedCall)`, zero when the call is not queued - the
   * getter reverts `TimelockInvalidSelector()` in that case, which the reader maps to zero.
   */
  timelockMaturity(diamond: string, encodedCall: string): Promise<bigint>;
  /** `getTimelockDurationSeconds()`; `undefined` when the timelock facet is not cut. */
  timelockDuration(diamond: string): Promise<bigint | undefined>;
  /** `getPersonalAccount(owner)`, registered if it exists, else the computed address. */
  personalAccount(diamond: string, xrplOwner: string): Promise<string>;
  /** `getSubaccount(owner, type)`, registered if it exists, else the computed address. */
  subaccount(diamond: string, xrplOwner: string, subaccountType: number): Promise<string>;
  /** The account's own view of what it is. */
  accountIdentity(account: string, target: RegistryTarget): Promise<AccountIdentity>;
}

/** The repository's view of a contract: its artifact and its source. */
export interface RepoReader {
  hasArtifact(contractName: string): boolean;
  /** Whether the implementation's source file still exists under `contracts/`. */
  hasSource(contractName: string): boolean;
  deployedCode(contractName: string): Buffer;
  creationCode(contractName: string): Buffer;
}

export interface VerificationInputs {
  network: string;
  chainId: number;
  /** The diamond that owns both registries and acts as the accounts' beacon. */
  diamond: string;
  /** The implementation's artifact name; must be one of `IMPLEMENTATIONS`. */
  contract: string;
  /** The address about to be registered, or already registered. */
  implementation: string;
  stage: Stage;
  /** An XRPL owner whose account is checked for identity and initialization, `live` only. */
  sampleXrplOwner?: string;
  repo: RepoReader;
  chain: ChainReader;
}

export interface VerificationResult {
  checks: Check[];
  /** Observations that are not checks (what the registry holds today, a maturity, a note). */
  notes: string[];
  /** The exact call governance must queue and execute, for the operator to compare. */
  encodedCall: string;
}

const PROXY_CONTRACT = "PersonalAccountProxy";

/** Runs every check for the stage; throws on inputs that make verification meaningless. */
export async function verifyImplementation(inputs: VerificationInputs): Promise<VerificationResult> {
  const { chain, repo, diamond, implementation, stage } = inputs;
  const spec = IMPLEMENTATIONS[inputs.contract];
  if (!spec) {
    throw new Error(
      `${inputs.contract} is not a registered implementation; expected one of ${Object.keys(IMPLEMENTATIONS).join(", ")}`
    );
  }
  if (!/^0x[0-9a-fA-F]{40}$/.test(implementation)) {
    throw new Error(`${implementation} is not an address`);
  }
  if (implementation.toLowerCase() === diamond.toLowerCase()) {
    throw new Error("the implementation cannot be the controller itself");
  }
  if (inputs.sampleXrplOwner !== undefined && stage !== "live") {
    throw new Error("a sample account can only be checked once the registration is live");
  }

  const checks: Check[] = [];
  const notes: string[] = [];
  const encodedCall = encodeRegistration(spec, implementation);

  // 1. the address holds the reviewed artifact's code, from a source that still exists. This is
  // the check the setters do not make, and it is re-run at every stage because the operator's
  // confidence has to be about the address as it is now, not as it was when it was reviewed
  const hasSource = repo.hasSource(inputs.contract);
  checks.push(
    check(
      `source: ${inputs.contract} still exists in contracts/`,
      hasSource,
      "present",
      hasSource ? "present" : "removed from source"
    )
  );
  checks.push(await codeCheck(chain, repo, inputs.contract, implementation));

  // 2. the chain family: the Flare accounts and the remote accounts lay out storage for
  // different proxy lineages, and each looks like a legitimate artifact on the other's chain.
  // Allowed by family, from the same two sets the deploy scripts use; a chain in neither is
  // refused for both
  const belongs =
    spec.family === "flare" ? FLARE_FAMILY_CHAIN_IDS.includes(inputs.chainId) : LOAN_CHAIN_IDS.includes(inputs.chainId);
  checks.push(
    check(
      `chain: ${inputs.contract} belongs on ${inputs.network} (chain ${inputs.chainId})`,
      belongs,
      spec.family === "flare" ? "a Flare-family chain" : "a loan chain",
      belongs ? "correct family" : `${inputs.contract} lays out the ${spec.family} lineage's storage`
    )
  );

  // 3. the registry, and the queued call that changes it. The maturity is read for the exact
  // encoded call, so a queued call for any other address simply is not this one
  const registered = await chain.registered(diamond, spec);
  const maturity = await chain.timelockMaturity(diamond, encodedCall);
  const duration = await chain.timelockDuration(diamond);
  const targetName =
    spec.target === "personalAccountBeacon" ? "the Personal Account beacon" : `subaccount type ${spec.subaccountType}`;
  const facetName = spec.target === "personalAccountBeacon" ? "PersonalAccountsFacet" : "SubaccountsFacet";
  if (registered === undefined) {
    // the diamond answered FunctionNotFound: there is no registry to register into, so this
    // registration cannot be queued or executed at all until that facet is cut
    checks.push(
      check(
        `registry: ${facetName} is cut on the controller`,
        false,
        "the registry's selector is served",
        `${diamond} does not serve it - cut ${facetName} first`
      )
    );
  } else if (stage === "live") {
    checks.push(checkEq(`registry: ${targetName} points at the implementation`, implementation, registered));
  } else {
    // not yet live: say what it holds today rather than failing, since replacing a live
    // implementation is a legitimate registration too
    notes.push(
      `registry: ${targetName} currently holds ${registered === ZERO_ADDRESS ? "no implementation" : registered}`
    );
    const already = registered.toLowerCase() === implementation.toLowerCase();
    checks.push(
      check(
        `registry: ${targetName} is not already the implementation`,
        !already,
        "a registration is still pending",
        already ? "already registered - this stage has already happened" : "not yet registered"
      )
    );
  }
  if (stage === "queued") {
    checks.push(
      check(
        "timelock: exactly this registration is queued",
        maturity !== 0n,
        "queued",
        maturity === 0n ? "no queued call with this calldata - queue it, or it names another address" : "queued"
      )
    );
    notes.push(`timelock: executable after ${maturity.toString()} (unix seconds)`);
  }
  if (stage !== "live") {
    // a zero duration would let the registration execute in the same breath as it is queued, so
    // the call this run hands to governance is not a queue step at all - which has to be known
    // before it is handed over, not discovered afterwards. Any deliberate zero-delay bootstrap
    // configuration is then an explicit decision rather than a surprise here
    checks.push(
      check(
        "timelock: the duration is non-zero",
        duration !== undefined && duration !== 0n,
        "non-zero",
        duration === undefined ? "TimelockFacet is not cut on the controller" : `${duration.toString()} seconds`
      )
    );
  }
  if (stage !== "queued") {
    if (maturity !== 0n) {
      notes.push(`timelock: this registration is already queued, executable after ${maturity.toString()}`);
    }
    notes.push(
      duration === undefined
        ? "timelock: TimelockFacet is not cut on the controller"
        : `timelock: duration ${duration.toString()} seconds`
    );
  }

  // 4. a sample account, once the registration is live: the proxy must be initialized and must
  // know this controller. Code at the derived address can only have come from the diamond's own
  // CREATE2 with the frozen proxy creation code, and that creation code commits to the
  // constructor arguments, so what is left to prove is that `initialize` ran and recorded the
  // right identity. Asking for a sample is asking for that proof: an account that is not
  // materialized fails the request rather than passing quietly
  if (stage === "live" && inputs.sampleXrplOwner !== undefined) {
    const owner = inputs.sampleXrplOwner;
    const personalAccount = await chain.personalAccount(diamond, owner);
    const account =
      spec.target === "personalAccountBeacon"
        ? personalAccount
        : await chain.subaccount(diamond, owner, spec.subaccountType ?? SUBACCOUNT_TYPE_LOAN);
    const accountCode = await chain.code(account);
    const materialized = accountCode !== ZERO_CODE;
    checks.push(
      check(
        `sample: ${owner}'s account at ${account} is materialized`,
        materialized,
        "code present",
        materialized
          ? "code present"
          : "not materialized - create it, or drop --xrpl-owner to verify the registry alone"
      )
    );
    if (materialized) {
      // only the Personal Account's proxy is an OZ BeaconProxy, which records the beacon in the
      // ERC-1967 slot; SubaccountProxy is a plain proxy holding the controller and the type as
      // immutables and resolving `implementationForType(type)` on every call, so it has no slot
      // to read - for those the registry check above is what proves which implementation serves
      // them, together with the type this account reports below
      if (spec.target === "personalAccountBeacon") {
        checks.push(
          checkEq(
            `sample: ${account} is served by this controller as its beacon`,
            diamond,
            addressInWord(await chain.storage(account, BEACON_SLOT))
          )
        );
      }
      const identity = await chain.accountIdentity(account, spec.target);
      checks.push(checkEq(`sample: ${account} reports this controller`, diamond, identity.controller));
      if (spec.target === "personalAccountBeacon") {
        checks.push(
          check(
            `sample: ${account} was initialized for ${owner}`,
            identity.xrplOwner === owner,
            owner,
            identity.xrplOwner ?? "<unset>"
          )
        );
      } else {
        checks.push(
          checkEq(
            `sample: ${account}'s parent is ${owner}'s Personal Account`,
            personalAccount,
            identity.parent ?? ZERO_ADDRESS
          )
        );
        const type = BigInt(spec.subaccountType ?? SUBACCOUNT_TYPE_LOAN);
        checks.push(
          check(
            `sample: ${account} is of type ${type.toString()}`,
            identity.subaccountType === type,
            type.toString(),
            (identity.subaccountType ?? 0n).toString()
          )
        );
      }
    }
  }

  return { checks, notes, encodedCall };
}

/** The exact calldata governance queues and executes for this registration. */
export function encodeRegistration(spec: ImplementationSpec, implementation: string): string {
  const web3 = new Web3();
  if (spec.target === "personalAccountBeacon") {
    return web3.eth.abi.encodeFunctionCall(
      {
        type: "function",
        name: "setPersonalAccountImplementation",
        inputs: [{ type: "address", name: "_newImplementation" }],
      },
      [implementation]
    );
  }
  return web3.eth.abi.encodeFunctionCall(
    {
      type: "function",
      name: "setSubaccountImplementation",
      inputs: [
        { type: "uint256", name: "_subaccountType" },
        { type: "address", name: "_implementation" },
      ],
    },
    [String(spec.subaccountType ?? SUBACCOUNT_TYPE_LOAN), implementation]
  );
}

/** The address packed into the low 20 bytes of a storage word. */
function addressInWord(word: string): string {
  return `0x${word.slice(2).padStart(64, "0").slice(-40)}`.toLowerCase();
}

/** The planner's REUSE verdict as a check: the on-chain code is the artifact's functional code. */
async function codeCheck(chain: ChainReader, repo: RepoReader, name: string, address: string): Promise<Check> {
  const title = `code: ${name} at ${address} matches the artifact`;
  if (!repo.hasArtifact(name)) {
    return check(title, false, "artifact present", `missing artifact for ${name} - run forge build`);
  }
  const deployedCodeHex = await chain.code(address);
  if (deployedCodeHex === ZERO_CODE) {
    return check(title, false, "code present", "no code at the address");
  }
  const plan = compareFacet(
    name,
    address,
    hexToBytes(deployedCodeHex),
    repo.deployedCode(name),
    repo.creationCode(PROXY_CONTRACT)
  );
  return check(title, plan.action === "REUSE", "REUSE", `${plan.action}: ${plan.reason}`);
}
