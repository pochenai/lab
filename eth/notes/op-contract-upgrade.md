# OP Stack Contract Upgrade Mechanism

> Code references are repo-root-relative paths (as text) in the optimism monorepo.

# 1. Terminology Explanation

|  | Terminology | Description |
|--|-------------|-------------|
| 1 | Predeploy | An L2 core contract that exists at a fixed address from genesis. Addresses live in the `0x4200…0000` ~ `0x4200…07FF` namespace (2048 slots) — e.g. L2CrossDomainMessenger, GasPriceOracle, GaslessWhitelist |
| 2 | Proxy | `packages/contracts-bedrock/src/universal/Proxy.sol`, an EIP-1967 transparent proxy. Holds no business logic; forwards calls to the implementation via `delegatecall`. State is stored on the proxy itself |
| 3 | Implementation | The contract that holds the actual business logic, executed by the proxy via `delegatecall`. Has no independent state; replaceable on every upgrade |
| 4 | L2ContractsManager (L2CM) | `packages/contracts-bedrock/src/L2/L2ContractsManager.sol`, the batch upgrade orchestrator for all L2 predeploys, executed via delegatecall |
| 5 | OPContractsManager (OPCM) | `packages/contracts-bedrock/src/L1/opcm/OPContractsManagerV2.sol`, the L1 upgrade orchestrator — L2CM's counterpart on L1 |
| 6 | L2ProxyAdmin | `packages/contracts-bedrock/src/L2/L2ProxyAdmin.sol`, the admin of all L2 proxies; the only contract authorized to change the implementation pointer |
| 7 | NUT (Network Upgrade Transactions) | A set of unsigned system transactions injected by the consensus layer at a hardfork activation block, used to deploy implementations / deploy L2CM / trigger the upgrade |
| 8 | CREATE2 | Deterministic deployment: `address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode))[12:]`. Same source + same salt + same deployer → the same, predictable address on every chain |
| 9 | DEPOSITOR_ACCOUNT | The privileged sender account used by the consensus layer when injecting deposit / system transactions; cannot be impersonated by normal users |

# 2. Background

## 2.1 The whole OP stack is proxy + implementation

Nearly all OP Stack core contracts on both L1 and L2 are `Proxy + Implementation`. An "upgrade" is fundamentally just pointing the proxy at a new implementation — **the proxy address (the address users interact with) never changes**, only the logic behind it does. This lets logic evolve without breaking address references or losing stored state.

## 2.2 L2 core contracts are all predeploys

There is no separate category of "ordinary core contract" on L2 — L2CrossDomainMessenger, L2StandardBridge, GasPriceOracle, L1Block, etc. are all predeploys, with their proxy shells laid down in the `0x4200…` namespace at genesis. Therefore "upgrading an existing L2 contract" and "upgrading a predeploy" are the same thing, the same mechanism.

## 2.3 Genesis lays down bare proxies across the entire namespace

`setPredeployProxies()` in `packages/contracts-bedrock/scripts/L2Genesis.s.sol` iterates over `PREDEPLOY_COUNT = 2048` addresses, etches `Proxy` bytecode at each (non-`notProxied`) address and sets the admin to L2ProxyAdmin — but **only enabled predeploys get an implementation pointer set**. This means a future predeploy address (e.g. GaslessWhitelist at `0x4200…0700`) **already has an empty proxy from genesis**; later it only needs the implementation wired in.

# 3. Motivation

## 3.1 Clarify the three upgrade paths

How L1 contracts, L2 predeploys, and existing L2 contracts are each upgraded, and who triggers each.

## 3.2 Explain the relationship between the two addresses

What actually links a predeploy's proxy address (`0x4200…` prefix) and the CREATE2-computed implementation address.

## 3.3 Pin down the relationship between upgrades and hardforks

Why, for an already-live chain, adding / wiring a predeploy requires a hardfork.

# 4. Explaination

## 4.1 How OP upgrades work (L1 / L2 predeploy / existing L2 contracts)

All three share the same "swap implementation behind a proxy" core; the difference is the **orchestrator** and the **trigger**:

| Dimension | L1 contracts | L2 predeploy / existing L2 contracts |
|-----------|--------------|--------------------------------------|
| Orchestrator | OPContractsManagerV2 (OPCM) | L2ContractsManager (L2CM) |
| Trigger | ProxyAdminOwner (governance multisig / Safe) sends a normal L1 transaction | Consensus layer injects NUTs at a hardfork activation block (sent by DEPOSITOR_ACCOUNT) |
| Targets | L1 proxies: OptimismPortal, SystemConfig, L1StandardBridge, DisputeGameFactory, etc. | All L2 predeploy proxies |

### Key L2CM design points

- **Stateless, relies on delegatecall**: the first line of `upgrade()` is `if (address(this) == THIS_L2CM) revert OnlyDelegatecall`. It must be delegatecalled in by L2ProxyAdmin, borrowing the admin's authority to upgrade each proxy.
- **New implementation addresses are baked into constructor args**: every upgrade deploys a brand-new L2CM, with this round's new implementation addresses written in as immutables.
- **`_apply()` upgrades each one in turn**: for each predeploy it calls `L2ContractsManagerUtils.upgradeToAndCall` — first point the proxy at StorageSetter to clear the `_initialized` flag → then point at the new implementation → call `initialize(...)`, atomically upgrading a dozen-plus predeploys in one shot.

### L2-side trigger chain

```
op-node injects NUTs at the hardfork activation block
  → L2ProxyAdmin.upgradePredeploys(l2cm)   // only DEPOSITOR_ACCOUNT may call
  → L2ProxyAdmin.delegatecall(L2CM.upgrade())
  → L2CM iterates each predeploy and runs upgradeToAndCall
```

In `L2ProxyAdmin.upgradePredeploys`: `if (msg.sender != Constants.DEPOSITOR_ACCOUNT) revert` — only the consensus-layer system account can trigger it; normal users cannot. L1 has no "system-injected transaction" and relies on the privileged owner sending a transaction; this is the fundamental difference in how L1 vs L2 are triggered.

### Who actually calls `ConditionalDeployer.deploy` (it is *not* L2CM)

The trigger chain above is only the **last** transaction of the bundle. A common misread is that L2CM calls `ConditionalDeployer.deploy` to deploy the new implementations — it does not. L2CM never references `deploy`; its only contact with ConditionalDeployer is (a) holding `CONDITIONAL_DEPLOYER_IMPL` as a constructor immutable and (b) upgrading the ConditionalDeployer **proxy** like any other predeploy in `_apply` (`packages/contracts-bedrock/src/L2/L2ContractsManager.sol:432`).

`ConditionalDeployer.deploy` is called by the **deployment NUTs**, which are siblings of the L2CM-upgrade NUT in the same bundle generated by `packages/contracts-bedrock/scripts/upgrade/GenerateNUTBundle.s.sol`. Each such NUT is a CALL with `to = CONDITIONAL_DEPLOYER` and `data = abi.encodeCall(ConditionalDeployer.deploy, (salt, code))`, built in `UpgradeUtils.createDeploymentTxnWithArgs` (`packages/contracts-bedrock/scripts/libraries/UpgradeUtils.sol:229`). The bundle runs in phases:

```
NUT bundle (injected in order at the activation block)
  [karst-only] deploy + upgrade the ConditionalDeployer proxy itself
  ── deploy phase ─────────────────────────────────
  for each impl to upgrade:
      CONDITIONAL_DEPLOYER.deploy(salt, implCode)     // idempotent CREATE2, returns impl addr
  CONDITIONAL_DEPLOYER.deploy(salt, l2cmCode)         // L2CM itself is deployed the same way
  ── upgrade phase ────────────────────────────────
  L2ProxyAdmin.upgradePredeploys(l2cm)                // the trigger chain above
      → delegatecall L2CM.upgrade() → _apply() → upgradeToAndCall per predeploy
```

So the ordering is: **all implementations (and L2CM itself) are deployed first via `ConditionalDeployer.deploy`, then the freshly-deployed L2CM is delegatecalled to wire every proxy to those implementations.** Deploy and wiring are two separate phases of the bundle, not nested calls — `_apply` only *consumes* the implementation addresses that the deploy phase produced. Because the addresses are deterministic (same salt + bytecode → same CREATE2 address), the addresses baked into L2CM's constructor necessarily match what the deploy NUTs land at. The deploy phase's idempotency (auto-skip of unchanged impls) is detailed in [§4.4](#44-incremental-upgrades-what-gets-skipped-vs-re-done).

### "Contracts that already exist on L2"

They are predeploys already; there is no third mechanism — they go through this same L2CM flow.

## 4.2 Relationship between the CREATE2 implementation address and the proxy address (`0x4200…` prefix)

**The two addresses are independent and cannot be derived from each other**; they are linked at runtime via a **storage-slot pointer** inside the proxy.

### Three addresses are involved — don't conflate them

| Address | How it is set | Changes? |
|---------|---------------|----------|
| Predeploy proxy address (e.g. `0x4200…0700`) | A manually assigned constant in the `0x4200…` namespace | Never changes; the user-facing address |
| Genesis implementation address | `Predeploys.predeployToCodeNamespace`: replaces the `0x4200…` prefix with `0xc0D3C0d3…` | Used only in genesis state |
| Post-upgrade implementation address | CREATE2(DeterministicDeploymentProxy, salt, bytecode) | Changes with code each upgrade, but deterministic and predictable |

The post-upgrade implementation address is computed by `computeCreate2Address` in `packages/contracts-bedrock/scripts/libraries/UpgradeUtils.sol`, with salt `keccak256("optimism.network-upgrade")` (fixed) and the deployer being the preinstalled universal CREATE2 factory DeterministicDeploymentProxy. The address is computed off-chain and baked into L2CM's constructor args; the on-chain NUT deploys with the same salt and necessarily lands at the same address.

### The linking mechanism (with proxy P = `0x4200…0700`, implementation I)

The proxy address holds the `Proxy.sol` forwarding shell; every call goes through `_doProxyCall`:

```solidity
function _doProxyCall() internal {
    address impl = _getImplementation();   // ① read impl = I from the EIP-1967 implementation slot
    require(impl != address(0), "Proxy: implementation not initialized");
    // ② delegatecall to I; code runs in P's storage context
    delegatecall(gas(), impl, 0x0, calldatasize(), 0x0, 0x0);
}
```

The implementation slot is the EIP-1967 standard slot:
`slot = keccak256("eip1967.proxy.implementation") - 1 = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`

The action that writes I into that slot is `_setImplementation` (a single `sstore`) inside `upgradeTo` / `upgradeToAndCall`. In the predeploy case it is triggered by L2CM during the upgrade:

```
L2ContractsManagerUtils.upgradeToAndCall(P, I, ...)
  → IProxy(P).upgradeToAndCall(I, initData)
  → P's implementation slot ← I, then delegatecall(I, initialize(...))
```

### Three key points

1. **State always lives on the proxy, not the implementation** (delegatecall semantics). So swapping the implementation during an upgrade loses no data — only the logic pointer changes.
2. **Upgrade = change this one slot**: next upgrade, the implementation lands at a new address and L2CM does another sstore; the proxy address stays the same. The admin slot (`keccak256("eip1967.proxy.admin")-1`) is a separate pointer holding the L2ProxyAdmin address, which decides who may change the implementation slot.

## 4.3 NUTs are strictly gated by `IsXxxActivationBlock(nextL2Time)`

In `op-node/rollup/derive/attributes.go`, every group of network upgrade transactions is gated on a fork activation timestamp:

```go
if ba.rollupCfg.IsEcotoneActivationBlock(nextL2Time) { upgradeTxs = EcotoneNetworkUpgradeTransactions() ... }
if ba.rollupCfg.IsFjordActivationBlock(nextL2Time)   { ... }
if ba.rollupCfg.IsIsthmusActivationBlock(nextL2Time) { ... }
if ba.rollupCfg.IsJovianActivationBlock(nextL2Time)  { ... }
if ba.rollupCfg.IsL2CMActivationBlock(nextL2Time)    { nutTxs, nutGas = UpgradeTransactions(forks.Karst) ... }  // from Karst, loaded from a NUT bundle
if ba.rollupCfg.IsInteropActivationBlock(nextL2Time) { ... }
```

### Conclusion: relationship between adding / wiring a predeploy and a hardfork

- **New chain (not yet launched)**: just put it in genesis — no hardfork needed.
- **Already-live chain (e.g. mainnet)**: a hardfork is required. Wiring the empty proxy to the new implementation can only be done by a consensus-injected privileged transaction, and that injection is strictly tied to a fork activation block.

### Why even "wiring up a pointer" requires a hardfork

1. **The injected transaction is unsigned and system-generated**: each node generates it deterministically. For the whole network to produce identical blocks, all nodes must agree on "at which block to inject" and "exactly which bytes" — this network-wide synchronized rule change is, by definition, a hardfork.
2. **The upgrade block needs extra gas allocated** (from Karst on); changing gas rules is itself a consensus-level change.
3. Hence Ecotone / Fjord / Granite / Holocene / Isthmus / Jovian / Karst are all hardforks, each carrying out contract upgrades / predeploy additions along the way.

### What got easier after Karst

- It is no longer "one fork per predeploy." From Karst on, the upgrade logic changed from "each fork hardcodes a Go upgrade function" to a **generic NUT bundle mechanism** (`UpgradeTransactions(forks.Karst)` reads from a packaged file). Adding a predeploy on the contract side now only requires: add the `.sol` + register it in the various lists + regenerate the bundle, with no new Go upgrade function — but it **still needs a fork activation** to go live, and multiple predeploys can be batched into the same fork.
- **Deploying a contract by itself does not require a hardfork** (anyone can send a CREATE2 transaction); only the privileged wiring of a fixed-address predeploy does. If it were not made a predeploy but instead an ordinary contract at an ordinary address, no fork would be needed — at the cost of losing the predeploy benefits of a fixed address, network-wide reservation, and unified upgrades.

## 4.4 Incremental upgrades: what gets skipped vs re-done

When a chain has already been live for a while and a new predeploy is added, the NUT bundle still lists **all** predeploys. The two layers behave differently:

| Layer | Skipped if already done? | Mechanism |
|-------|--------------------------|-----------|
| Implementation **deployment** | **Yes — auto-skipped** | `ConditionalDeployer` idempotency, keyed by CREATE2 address |
| Proxy **wiring + initialize** | **No — re-done in full every time** | `L2CM._apply` unconditionally re-points and re-initializes every predeploy |

### Implementation deployment is idempotent (auto-skip)

Each implementation deployment tx calls `ConditionalDeployer.deploy(salt, code)` (`packages/contracts-bedrock/src/L2/ConditionalDeployer.sol`) rather than a raw CREATE2:

```solidity
function deploy(bytes32 _salt, bytes memory _code) external returns (address implementation_) {
    address expectedImplementation = /* CREATE2(salt, code) */;
    if (expectedImplementation.code.length != 0) {   // already deployed
        emit /* ...Skipped... */;
        return expectedImplementation;                 // skip, no redeploy
    }
    // otherwise deploy via DeterministicDeploymentProxy
}
```

The "already deployed?" check is keyed by **address = CREATE2(salt, bytecode)**:

| Case | CREATE2 address | ConditionalDeployer behavior |
|------|-----------------|------------------------------|
| A predeploy's code is **unchanged** | identical to last time | `code.length != 0` → **skip, no redeploy** |
| A predeploy's code **changed** | bytecode differs → new address | new address has no code → **deploy new impl** (old impl left at old address, unused) |
| A **newly added** predeploy (e.g. GaslessWhitelist) | brand-new address | no code → **first-time deploy** |

So unchanged predeploys are not redeployed; only changed and newly added ones are.

### Proxy wiring + initialize is re-done every time (not skipped)

`L2CM._apply()` calls `upgradeToAndCall` for **every** predeploy in its list unconditionally. There is no "already at this version → skip" logic; the only check is a **downgrade guard** (`packages/contracts-bedrock/src/libraries/L2ContractsManagerUtils.sol`):

```solidity
address implementation = L2ProxyAdmin(PROXY_ADMIN).getProxyImplementation(_proxy);
if (implementation.code.length != 0
        && SemverComp.gt(ISemver(_proxy).version(), ISemver(_implementation).version())) {
    revert L2ContractsManager_DowngradeNotAllowed(_proxy);   // only blocks downgrades
}
```

Even when an implementation address is unchanged, L2CM still: (1) points the proxy at StorageSetter to clear the `_initialized` flag, (2) points it back to the implementation (a harmless sstore to the same address), (3) re-runs `initialize(...)`. This is deliberate: the bundle expresses the **target full state**, and every upgrade makes the chain **converge** to it regardless of current state. Re-pointing is cheap, and re-initializing is safe because StorageSetter cleared the `_initialized` flag first (otherwise the `initializer` modifier would revert).

## 4.5 How re-running initialize avoids clobbering live state

Re-running `initialize` on every upgrade is the riskiest part of this design. Whether a value survives depends on two rules:

### Rule 1 — initialize only touches what it explicitly writes; everything else is untouched

StorageSetter clears **only the `_initialized` flag slot**, nothing else. So any variable **not written by `initialize`** is preserved across the upgrade. Example — GaslessWhitelist's initialize only sets the owner:

```solidity
function initialize(address _owner) external initializer {
    _assertOnlyProxyAdminOrProxyAdminOwner();
    __Ownable_init();
    _transferOwnership(_owner);   // only sets owner
}
```

It never touches `gaslessEnabled` or the `fullyGaslessTargets` / `gaslessTransferTokens` mappings, so all whitelist entries and the global enable flag **survive the upgrade untouched**. The code comment states this explicitly: *"`gaslessEnabled` intentionally remains unchanged, so re-running this initializer during an L2ContractsManager upgrade preserves the current global enable flag."*

### Rule 2 — for variables initialize does write, L2CM feeds back the value read from current state

For a variable that **is** written by initialize (e.g. owner), L2CM avoids resetting it to a default by **reading the current on-chain value first** in `_loadFullConfig` and passing it back in:

```solidity
address gaslessWhitelistImpl =
    IL2ProxyAdmin(PROXY_ADMIN).getProxyImplementation(Predeploys.GASLESS_WHITELIST);
if (gaslessWhitelistImpl.code.length == 0) {
    // first introduction: no impl yet → default to ProxyAdmin.owner()
    fullConfig_.gaslessWhitelistOwner = IL2ProxyAdmin(PROXY_ADMIN).owner();
} else {
    // already deployed: read the current owner and feed it back
    fullConfig_.gaslessWhitelistOwner = IGaslessWhitelist(GASLESS_WHITELIST).owner();
}
```

So even if the owner was transferred after launch, L2CM reads that current owner and re-applies it — `_transferOwnership(currentOwner)` is a no-op. **"Re-initialize" here equals "preserve the current value."** (`__Ownable_init()` first sets owner to `msg.sender`, but the following `_transferOwnership(_owner)` overrides it back to the value read from state.) FeeVault's `readFeeVaultConfig`, LiquidityController's `owner()` read-back, and CDM's `OTHER_MESSENGER()` read-back all follow the same pattern.

### The danger case — and the checklist for new predeploys

A live value **would** be clobbered if either:

1. `initialize` writes a variable to a **hardcoded constant / default** instead of from a parameter → reset on every upgrade; or
2. `_loadFullConfig` reads it wrongly / falls back to a default and feeds that back → overwrites the live value.

Hence the rule when writing a new predeploy: **any operator-mutable state that must survive upgrades must either (a) be excluded from `initialize` (like `gaslessEnabled` and mappings), or (b) be read-from-current-state-and-fed-back in `_loadFullConfig` (like owner / fee-vault config).** A variable that is written by `initialize` but lacks a read-back in `_loadFullConfig` is the bug to watch for.

# 5. Reference

- `packages/contracts-bedrock/src/L2/L2ContractsManager.sol` — L2 predeploy upgrade orchestrator
- `packages/contracts-bedrock/src/libraries/L2ContractsManagerUtils.sol` — `upgradeToAndCall` implementation
- `packages/contracts-bedrock/src/L2/L2ProxyAdmin.sol` — `upgradePredeploys` trigger entry
- `packages/contracts-bedrock/src/universal/Proxy.sol` — EIP-1967 proxy forwarding shell
- `packages/contracts-bedrock/src/libraries/Predeploys.sol` — predeploy address constants and namespace mapping
- `packages/contracts-bedrock/scripts/L2Genesis.s.sol` — genesis proxy/implementation setup
- `packages/contracts-bedrock/scripts/libraries/UpgradeUtils.sol` — CREATE2 implementation address computation
- `packages/contracts-bedrock/scripts/upgrade/GenerateNUTBundle.s.sol` — NUT bundle generation
- `packages/contracts-bedrock/src/L2/ConditionalDeployer.sol` — idempotent CREATE2 deployment (auto-skip if already deployed)
- `packages/contracts-bedrock/src/L1/opcm/OPContractsManagerV2.sol` — L1 upgrade orchestrator (counterpart)
- `op-node/rollup/derive/attributes.go` — NUT injection gated by fork activation block
