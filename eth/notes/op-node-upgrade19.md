# op-node 升级分析：v1.16.7 → v1.19.2（X Layer optimism-cp）

> 目标：把开发分支 `main` rebase 到上游 `op-node/v1.19.2`，并把当前主网（tag `v0.1.5`）升级上来。
> 本文所有代码引用为仓库根相对路径的纯文本（如 `op-node/rollup/types.go`），可在工作区根打开。

---

## 0. 版本关系与两条 delta

| 角色 | 对应 ref | 上游基线 |
|---|---|---|
| **主网（生产）** | tag `v0.1.5`（HEAD 提交 "Sync upstream v1.16.7"） | 上游 `op-node/v1.16.7` |
| **开发分支 main** | `op-node/v1.19.0-224-g4dc796fed1` | 上游 `op-node/v1.19.0`（不含 v1.19.1/v1.19.2） |
| **升级目标** | `op-node/v1.19.2` | — |

由此需要区分三条 delta：

1. **生产面对的完整上游跳跃**：`v1.16.7 → v1.19.2`（跨 v1.17 / v1.18 / v1.19.0 / v1.19.1 / v1.19.2）——这是主网真正经历的变化，本文主体。
2. **main 实际还需拉取的上游增量**：`v1.19.0 → v1.19.2`（≈227 commits，其中 **v1.19.1 是主体 218 个**，v1.19.2 仅 9 个）——这是 rebase 的实际工作量。
3. **fork 本地改动**：`v0.1.5 → main`（1046 commits，含 gasless / whitelist / kona-1.6.0 / okx-reth pin / Karst 处理）——rebase 冲突主要来源，见 §6。

---

## 1. TL;DR 与风险排序

**核心结论**

- 本区间上游只新增了 **两个主线硬分叉**：**Karst**（v1.17.0 引入激活机制）与 **Lagoon**（v1.19.1，承接原 **Interop** 更名 + 新增 SDM）。Holocene / Isthmus / Jovian 的对 EL 语义在本区间**未变**（`op-node/rollup/derive/l1_block_info.go` 全程无 diff）。
- **我们不激活 Karst**：只要不设置 `karst_time`（保持 nil），Karst / Osaka / NUT bundle / `getPayloadV5` 全部惰性不触发；代码会被编入二进制但默认关闭。详见 §5。
- **upgrade-19 官方通知**：Karst 为强制升级，要求 **op-node ≥ v1.19.1、op-reth ≥ v2.3.3**；`op-geth` / `op-program` 已于 **2026-05-31 结束支持**，官方要求迁移到 op-reth。激活时间 Sepolia 2026-06-17 16:00:01 UTC，Mainnet 2026-07-08 16:00:01 UTC。**目标 v1.19.2 满足 op-node 版本要求。**
- **对外 JSON-RPC 契约只增不减**（新增 `superroot` 命名空间 + 2 个 `admin_` 方法），老客户端不受影响。
- **P2P 协议 ID / gossip topic / ENR 全部未变**，新旧节点可正常组网；唯一行为变化是新版删除了 alt-sync 拉取客户端（不再主动 P2P 回补历史区块，改依赖 EL sync / L1 派生）。

**rebase 风险排序（工程量从大到小）**

1. **okx/reth fork 从 reth v2.2.0 派生 → 上游 v1.19.1 已升到 reth v2.3.0（v1.19.2 用 tag v2.3.0）**。当前 `rust/Cargo.toml` 钉在 `github.com/okx/reth @ 4ce77265…`（v2.2.0 派生）。这不是改一行 pin，而是**先把 okx/reth fork 自身 rebase 到 reth v2.3.0**（携带其上的 gasless/okx 定制）的独立升级工程。**头号风险。**
2. **gasless 特性横跨 5 处共识/执行路径**（`rust/alloy-op-evm`、`rust/op-revm/handler`、`rust/op-reth`{txpool,rpc,payload}、`rust/kona`），而上游 v1.19.1 全量重写了 op-reth txpool（interop failsafe/filter）与 op-revm handler/spec，冲突面极大，且 gasless 是 **block building 与 validation 双路径**，任何行为漂移都会分叉链。
3. **Interop → Lagoon 重命名回翻**：fork 在 port gasless 时曾把 `Lagoon→Interop`（提交 `4f686b1f1a`、`eeb50c0dfa`），rebase 后需全部翻回 Lagoon（确定性冲突）；叠加 op-program / op-supervisor / op-validator 目录整体删除带来的大面积机械冲突。
4. **contracts**：gasless 白名单 predeploy（`XlayerGaslessWhitelist.sol` + oz-upgradeable-v5 submodule）与上游 v1.19.x 的 L2CM / predeploy 建模改动冲突。
5. **Karst 保持不激活**（低风险，但需守住 `KarstTime=nil` 与 op-geth pin 的测试期望联动，见 §5）。

---

## 2. 每版本上游亮点

| 版本 | 硬分叉 | 破坏性 / 默认值 / 结构变化 | 归属提示 |
|---|---|---|---|
| **v1.17.0** | **引入 Karst 激活机制**（#19250）；Karst NUT bundle 执行、L2CM toggle（#19888） | `--syncmode.req-resp` 默认→**false**；移除 `ProtocolVersions` 链上信号（watching/halt）| — |
| **v1.18.0** | 无新分叉 | 内部重构（移除 `eth.BlockInfo` Header 逃生口 #20531）；op-geth bump | — |
| **v1.19.0** | Interop 激活作为 L2CM bundle（#20723）；移除 op-node 内联 interop 索引/managed 派生 | 新增 `--syncmode.offset-el-safe`（默认 **12h**）、`--l1.beacon.slot-duration-override`；**删除** `--rollup.halt` / `--rollup.load-protocol-versions` / `--interop.rpc.*` | **main 已到此** |
| **v1.19.1** | **Karst Mainnet 配置**；**Osaka EIPs 挂到 Karst + `engine_getPayloadV5`**（#21337）；**Interop 重命名为 Lagoon**（#21105/#21370）；SDM（Sequencer-Defined Metering） | **`--l2.enginekind` 默认 Geth→Reth**（#21295，op-geth EOL）；**移除 Req/Resp CL P2P 同步客户端**（#21498）；**移除 op-program**（#21271）/ op-supervisor / op-validator；**reth 升到 v2.3.0**（#21348）；op-core 模块化 | **增量主体** |
| **v1.19.2** | 无新分叉 | 9 个收尾 commit：`#21587` 容忍 EL 裁剪的 genesis 历史；`#21574` Karst/Osaka 下 estimateGas 的 `tx_gas_limit_cap`；`#21477` l2cm 接入 genesis；kona-sp1 range-executor | **增量收尾** |

---

## 3. Bootstrapping & Configuration 兼容性

### 3.1 CLI Flag 变更（升级前必须处理）

| flag（env） | 变更 | 影响 | 版本 |
|---|---|---|---|
| `--rollup.halt`（`OP_NODE_ROLLUP_HALT`） | **删除** | **破坏性**：旧命令带此 flag → unknown flag 启动失败 | v1.19.0 |
| `--rollup.load-protocol-versions` | **删除** | **破坏性**：ProtocolVersions 链上信号功能整体移除 | v1.19.0 |
| `--interop.rpc.addr` / `.port` / `.jwt-secret` | **删除** | **破坏性**：旧内嵌 supervisor 对接配置失效 | v1.19.0 |
| `--l1.beacon.slot-duration-override` | 新增 Uint64（默认 0=关闭） | 非破坏；>0 绕过 beacon spec 查询，devnet/anvil 用 | v1.19.0 |
| `--syncmode.offset-el-safe` | 新增 Duration（默认 **12h**） | 非破坏；仅 `--syncmode=execution-layer` 生效 | v1.19.0 |
| `--l2.engine-kind`（`OP_NODE_L2_ENGINE_KIND`） | **默认 Geth→Reth** | **潜在破坏**：用 op-geth 且未显式设置时，`SupportsPostFinalizationELSync` 等派生行为改变 → 建议显式 `--l2.engine-kind=geth`（若仍用 geth） | v1.19.1 |
| `--syncmode.req-resp` / `--p2p.sync.onlyReqToStatic` | 降级为**已废弃 no-op**（Hidden） | 半破坏：仍被接受不报错，但功能失效（req/resp CL 同步客户端已删） | v1.19.1 |
| `--override.interop` | 替换为 `--override.lagoon` | 脚本用到需改名 | v1.19.1 |
| `--override.keep-karst-upgrade-gas` | 新增 Bool（Karst 相关） | 非破坏；不激活 Karst 时无需设置 | v1.19.1 |

相关文件：`op-node/flags/flags.go`、`op-node/flags/p2p_flags.go`、`op-service/flags/flags.go`、`op-node/service.go`。

### 3.2 配置（rollup.json）契约变更

- **字段重命名/增删**（`op-node/rollup/types.go`）：
  - `interop_time` → **删除**（无 JSON alias）；新增 `lagoon_time`、`karst_time`、`keep_karst_upgrade_gas`；移除 `protocol_versions_address`。
- **解析不再严格**：`ParseRollupConfig` 移除了 `json.DisallowUnknownFields()`。
  - 好处：旧 `rollup.json` 残留 `protocol_versions_address` 不再报错。
  - **陷阱**：旧 `interop_time` 会被**静默忽略而非报错** —— 若某链靠它激活 interop，需手动改名 `lagoon_time`，否则 fork 不激活且**无任何告警**。
- **Interop dependency-set 加载语义变化**（`op-node/service.go` `NewDependencySetFromCLI`）：未设 `--interop.dependency-set` 时会**自动从 superchain-registry 按 chainID 加载**；`config.Check` 仅在 `lagoon_time` 已设却无 depset 时报错。
- **superchain-registry 来源迁移**（`op-node/rollup/superchain.go`）：import 从 `go-ethereum/superchain` → `op-core/superchain`；depset 从 `op-supervisor/.../depset` → `op-core/interop/depset`（内部依赖迁移，不影响外部配置）。
- **L2 genesis 校验放宽（v1.19.2，#21587）**：`CheckL2GenesisBlockHash` 在 EL 因历史裁剪（EIP-4444，reth 返回 JSON-RPC code 4444）或 NotFound 无法返回 genesis 时，改为 warn+跳过而非启动失败。**若用裁剪型 EL（op-reth `--minimal`/pruning）此补丁必需。**

---

## 4. Consensus Correctness & Fault Proof

### 4.1 fork 顺序与激活

`op-core/forks/forks.go` @ v1.19.2 顺序：`… Holocene → Isthmus → Jovian → Karst → Lagoon → PectraBlobSchedule`。

- **Interop 从主线 fork 列表移除**，其特性重新挂到 Lagoon（`op-node/rollup/toggles.go`）：`IsInterop(t)=IsLagoon(t)`、`IsSDM(t)=IsLagoon(t)`。
- **Karst = L2 Contracts Manager（L2CM）**：`IsL2CM(t)=IsKarst(t)`；激活块通过 NUT bundle 注入一批网络升级交易。

### 4.2 共识关键变更清单（最高优先级）

| # | 变更 | 文件 | 风险 |
|---|---|---|---|
| 1 | **激活块 `gasLimit = SystemConfig.GasLimit + NUT gas`** | `op-node/rollup/derive/attributes.go` | op-node 与 op-reth 必须对激活块 gasLimit 一致，否则 block hash 分歧、fault proof 失败 |
| 2 | **Karst 后 `getPayload` 切 `engine_getPayloadV5`（Osaka）** | `op-node/rollup/types.go`、`op-service/eth/types.go` | op-reth 不支持 V5 → Karst 后无法出块（**不激活则不触发**） |
| 3 | **SDM 新增 `PostExecTxType`**（合成、未签名、链无关，`v=0`，不校验 chainID）；span batch 编解码 + Lagoon 前丢弃校验 | `op-node/rollup/derive/span_batch_tx.go`、`batches.go` | Lagoon 后 op-reth 需支持该交易类型执行/哈希 |
| 4 | **NUT source hash 规则**：intent 字符串首字母大写拼接算 `UpgradeDepositSource` hash；**Lagoon bundle 特意用 label `"interop"`** 保持与 kona 确定性一致 | `op-node/rollup/derive/upgrade_transaction.go`、`op-core/nuts/bundles/{karst,lagoon}_nut_bundle.json` | op-reth/kona 若自行推导 NUT 存款交易必须遵循同一规则 |
| 5 | **`KeepKarstUpgradeGas`**：修复"Karst 一次性 upgrade gas 被之后每块保留"的 bug；op-node 仅加载并打印，实际行为由 **EL 实现** | `op-node/rollup/types.go` | op-node 与 op-reth flag 必须一致，否则后续块 gas limit 分歧 |
| 6 | **Interop→Lagoon 重命名，`InteropTime` 字段删除** | `types.go`/`superchain.go`/`toggles.go` | 旧 `interop_time` 配置被静默忽略（v1.19.1） |
| 7 | `InvalidatedBlockSourceDepositTx`（interop 乐观块失效路径）| `op-node/rollup/derive/deposit_source.go` | op-reth 需按相同参数（sender=`0xdead…0002`, gas=36000）复现交易与 source hash |

> 注：`op-node/rollup/derive/system_config.go` 把 eip1559 参数解析从 `go-ethereum/consensus/misc/eip1559` 换到 `op-core/eip1559`（multierror→`errors.Join`）——需确认 `op-core/eip1559` 与 EL 的 base fee 计算（含 Jovian min base fee）逐位一致。

### 4.3 reth / op-reth API 语义

- **PayloadAttributes 结构无字段变更**；`attributes_queue.go` 无变化。唯一逻辑变化是升级交易来源改为 NUT bundle + 激活块加 gas（见 4.2 #1）。
- Engine 方法版本映射（`ForkchoiceUpdatedVersion`/`NewPayloadVersion` 不变；`GetPayloadVersion`：Karst→V5 / Isthmus→V4 / Ecotone→V3 / else V2）。注意不对称：`NewPayloadVersion` 仍停在 V4。

### 4.4 Fault Proof

- **op-program 整体移除（v1.19.1）**：`op-program/` 从 147 文件降为 0（约 7 万行删）；kvstore 迁移到 `op-challenger/kvstore/*`。fault-proof 客户端/host 转向外部 **kona-host / cannon-kona / op-reth proofs**。**若 CI/构建依赖 op-program（cannon prestate、verify 脚本）需改为外部来源。**
- op-node 内 `op-node/rollup/interop/`（indexing）与 `l1_traversal_managed.go` 整体移除（v1.18→v1.19.0），interop 索引下沉到 op-supervisor/supernode。
- op-challenger：新增 `op-challenger/kvstore/*`，`runner/game_inputs.go`/`factory.go` 重构，新增 `scripts/check-game-block-hashes.sh` 等（工具/迁移性，无新共识判定语义）。

---

## 5. Karst 硬分叉（**我们不激活**，单独列项）

**Karst 引入的内容**：L2CM（激活块经 `karst_nut_bundle.json` 注入升级存款交易）；激活块额外 gas；Engine 升到 `getPayloadV5`（Osaka）；EVM 变更（bn256Pairing 输入限 300 对、EIP-7823 modexp 上界、EIP-7934/7825、L2 tx gas 上限 16,777,216 且 deposit 豁免）；fault proof 游戏类型由 `CANNON(0)` 改为 `CANNON_KONA(8)`。upgrade-19 中 `keep_karst_upgrade_gas` / 激活后 `setGasLimit()` 等运维动作，**在不激活前提下均不适用**。

**不激活的做法（安全默认）**：

1. **保持 `karst_time = nil`（不设置）**。此时 `IsKarst()`/`IsL2CM()` 恒 false → 不注入 NUT bundle、gas limit 保持 `SystemConfig.GasLimit`、`GetPayloadVersion` 停在 `GetPayloadV4`（**不会向 op-reth 请求 V5/Osaka**，op-reth 无需支持 Osaka）。
2. **连带不要设置 `lagoon_time`**：fork 顺序上 Lagoon 严格晚于 Karst，且 Lagoon 会拉起 interop/SDM（要求 EL 支持 PostExec 等）。若确需 interop 但不要 Karst，需先评估这一顺序约束。
3. 当前 `op-node/flags/` 无独立 Karst flag，激活完全由链配置时间戳驱动 —— 不设时间戳即为关闭。`--override.keep-karst-upgrade-gas` 不传即可（默认 false）。

**fork 已做的处理（需在 rebase 中守住）**：

- **XLayer 自有链为硬编码 fork 时间**（非从 registry 加载），**未设 KarstTime**。
- **op-geth pin 联动**：提交 `1ce43d65a1` 把 `TestGetRollupConfig` 中 OP mainnet/sepolia 的 `KarstTime` 期望值改为 **nil**，因为 go.mod 把 `go-ethereum/superchain` replace 到 **okx/op-geth**（pin 早于 Karst，`GetRollupConfig` 加载的 KarstTime 就是 nil）。注释注明"restore when op-geth is upgraded"。

**rebase 到 v1.19.2 关于 Karst 的注意点**：

1. Karst / Osaka-at-Karst 代码会被合入并编译，需保证**编译通过 + 默认关闭**。
2. **op-geth pin 与测试期望联动**：若 rebase 中一并升级 okx/op-geth（含 Karst），`chains_test.go` 的 nil 期望需**同步恢复为真实时间戳**；若继续 hold op-geth pin，则保留 nil 并解决合并冲突。
3. `#21574`（Karst/Osaka 下设 `tx_gas_limit_cap` 使 estimateGas 正确）触及 op-reth estimateGas，与 gasless（§6.A1）estimateGas 同区 —— 不激活 Karst 走非-Karst 分支，需确认**不改变 gasless 既有 estimateGas 行为**。
4. **superchain-registry 同步**（v1.19.x 多次 update registry）可能带来 OP 链真实 KarstTime；须确认不影响 XLayer 硬编码链、也不因 registry 加载路径变化而意外给 XLayer 赋值。
5. NUT bundle / L2CM toggle 默认关闭，Karst 未激活时不执行。

---

## 6. Fork 本地改动 v0.1.5 → main（重点关注/测试点）

### A. Gasless 交易（最大、最高风险）

核心 port：`4184d6c2ba feat(gasless): port xlayer gasless onto optimism main (kona-1.6.0)`（27 文件 / +2306 行），横跨共识执行路径：

- `rust/alloy-op-evm/src/block/xlayer_gasless_contract.rs`（新增）：区块执行前对链上 gasless 合约做一次**未提交的系统调用**（`SYSTEM_ADDRESS`，selector `getGaslessAllowance(address,bytes)`=`0xbad12ebe`）返回 `(allowed, gasLimit)`；合约地址按 chain_id 派生（devnet 195 / testnet 1952 / mainnet 196）。注释强调 "consensus-uniform across block building and validation" —— **共识关键**。
- `rust/op-reth/crates/txpool/src/xlayer_gasless.rs`（新增）+ `validator.rs`：mempool 侧校验、pending 生命周期驱逐（默认 600s）。
- `rust/op-reth/crates/rpc/src/eth/gasless.rs` + `call.rs`/`transaction.rs`：gasless RPC / estimateGas。
- `rust/op-revm/src/handler.rs`：EVM handler 对零价交易的费用处理。
- CLI：`rust/op-reth/crates/node/src/args.rs` 新增 `--rollup.allow-gasless`（默认 false）、`--rollup.gasless-mock-gas-price-percentile`、`--rollup.gasless-pending-lifetime`。
- kona 支持：`bf3546a799 feat(kona): kona support gasless`、`9fe93ee3b5`（no_std `alloc::vec` 修复）。

> **测试点**：sequencer 出块与 verifier/kona 重放对同一 gasless tx 的 allowed/gasLimit 判定必须**逐位一致**；estimateGas 在 reth v2.3.0 下仍返回正确结果；上游 op-reth txpool 全量重写后 gasless 校验/驱逐逻辑无回归。

### B. Whitelist 合约（gasless 白名单 predeploy）

- `bf93de28df` 新增 `packages/contracts-bedrock/src/L2/XlayerGaslessWhitelist.sol`（可升级代理，CREATE2 地址与 A1 devnet 地址一致）；`fc9acd5661` 接入 `GASLESS_WHITELIST` predeploy、引入 oz-upgradeable-v5 submodule、更新 ABI/storageLayout 快照与 semver-lock。关联本地合约 `DepositedOKBAdapter`。

> **测试点**：predeploy 地址与 A1 Rust 侧硬编码地址是**同一常量的两处副本**，rebase 后须校验一致；oz-upgradeable-v5 submodule 与上游 L2CM/predeploy 建模（#21346/#21442）冲突概率高。

### C. kona 升级到 1.6.0

- `a5ceefb13f feat(rust): upgrade rust/ to kona-1.6.0`。gasless port 基于 kona-1.6.0。上游 v1.19.x 有大量 kona 改动（interop→lagoon、kona-sp1 引入、predeploys 迁到 kona-genesis #21442），子树冲突多。

### D. reth 依赖 pin（**头号 rebase 工程**）

- 历程：`b2165ea59b` 先对齐到 paradigmxyz/reth `81c026181`（v1.19.0 所用）→ `2ba5939280` 切到 `github.com/okx/reth`（分支 `xl/upstream/dev-7680d6d`）→ 当前 `rust/Cargo.toml` 钉在 okx/reth `4ce77265…`（**reth v2.2.0 派生**）。
- 上游 v1.19.1 已 `rust: update reth to v2.3.0 (#21348)`，v1.19.2 用 **reth tag v2.3.0**。
- **结论**：rebase 前必须先把 **okx/reth fork 自身升级到 reth v2.3.0**（携带 gasless/okx 定制），否则 rust workspace 无法统一编译。op-rbuilder 独立 workspace 需一并核对。

### E. op-node / 共识路径本地改动（较少）

- op-node 侧多数非 merge 提交实为上游合并（带 PR 编号）。真正本地定制：`1ce43d65a1`（KarstTime 测试期望→nil，见 §5）、`85363e284c`（drop 未知 `protocol_versions_address` 字段）、`2f9f9e3b06`（lint 修复）、XLayer 链硬编码 fork 时间。未见对 DA challenge 的本地共识改动。

> **测试点**：XLayer 自有链 rollup.Config（硬编码 forks）在新 op-node 下解析/校验通过；`--l2.follow.source.*` / supernode 等上游新特性不误伤 XLayer 单链部署。

---

## 7. Network & External Interface

### 7.1 Protocol / API 版本

- op-node 版本号格式与 RPC 上报机制**不变**。
- fork 枚举：`Interop` 移除，新增 `Karst`/`Lagoon`（见 §4.1）。
- rollup 配置字段契约破坏：`interop_time` 删除、新增 `karst_time`/`lagoon_time`（跨版本配置不互认）。
- `engine_signalSuperchainV1` 从 `op-service/sources/engine_client.go` 移除 —— op-node 不再对 EL 发起协议版本信号调用。

### 7.2 P2P 协议与可达性 —— **无组网破坏**

- gossip topic 未变：`/optimism/<L2ChainID>/{0,1,2,3}/blocks`（V1–V4）。
- req-resp 协议 ID 未变：`/opstack/req/payload_by_number/%d/0`。
- discovery（ENR）未变。
- **行为变化**：alt-sync **拉取客户端被删除**（`SyncClient`/`RequestL2Range`/`altSync`）——新版出现区块 gap 时不再主动 P2P 回补，改依赖 EL sync / L1 派生；但**保留服务端** `ReqRespServer` 继续为老节点供数，故**新↔旧仍可互操作**。
- gossip 区块签名验证新增 **signer 轮换宽限期**（`PreviousP2PSequencerAddress()`/`ConfirmCurrentSigner()`），消息格式/topic 不变，向后兼容。

### 7.3 Engine API

| 方法 | 变更 |
|---|---|
| `forkchoiceUpdated` | 无变化（Ecotone→V3 / Canyon→V2 / else V1） |
| `newPayload` | 无变化（Isthmus→V4 / Ecotone→V3 / else V2） |
| `getPayload` | **新增 Karst→V5（Osaka）**；其余不变 |
| `signalSuperchainV1` | **移除** |

`PayloadAttributes` 结构无字段变更。**`engine_getPayloadV5` 仅在 Karst 激活后触发**（我们不激活则不需要 op-reth 支持 Osaka）。

### 7.4 对外 JSON-RPC —— **只增不减**

- 新增命名空间 **`superroot`**：`superroot_atTimestamp`（`op-node/node/superroot_api.go`）。
- 新增 `admin_setSdmPostExecOptIn(bool)`、`admin_sdmStatus()`（SDM opt-in，`op-node/node/api.go`）。
- `opp2p` / `optimism` / `opstack` 方法与签名无删除、无破坏。老客户端不受影响。

### 7.5 JSON-RPC 新旧一致性回归脚本

用于对比同一批请求在旧版（v0.1.5 / v1.16.7）与新版（v1.19.2）op-node 上响应是否一致。端点经环境变量 `$OLD_RPC` / `$NEW_RPC` 传入，**不硬编码任何 URL/凭证**；规范化时递归排序 key 并剔除易变字段。

用例文件 `cases.json`：

```json
[
  { "method": "optimism_syncStatus",   "params": [] },
  { "method": "optimism_rollupConfig", "params": [] },
  { "method": "optimism_version",      "params": [] },
  { "method": "opp2p_self",            "params": [] },
  { "method": "opp2p_peers",           "params": [true] }
]
```

运行：`OLD_RPC=http://old-node:9545 NEW_RPC=http://new-node:9545 python3 rpc_regress.py cases.json`

```python
#!/usr/bin/env python3
"""op-node JSON-RPC 新旧版本响应一致性回归对比。
端点从环境变量 OLD_RPC / NEW_RPC 读取，绝不硬编码 URL 或凭证。
用法: OLD_RPC=... NEW_RPC=... python3 rpc_regress.py cases.json
"""
import json, os, sys, urllib.request, urllib.error, difflib
from copy import deepcopy

# 已知易变字段（按 key 名剔除，忽略大小写与 -/_）：时间戳、peer/node 标识、连接数、瞬时同步进度等。
VOLATILE_KEYS = {
    "timestamp", "time", "now", "current_l1", "peerid", "peer_id",
    "nodeid", "node_id", "enr", "addresses", "peers", "peercount",
    "connected", "known", "latency", "gossipblocks", "uptime",
    "seenat", "lastseen", "unsafe_l2",   # unsafe_l2 瞬时进度可能不同；需严格比对可移除
}
TIMEOUT = 15

def _norm_key(k):
    return k.lower().replace("-", "").replace("_", "")

_VOL = {_norm_key(v) for v in VOLATILE_KEYS}

def rpc_call(url, method, params, req_id=1):
    payload = json.dumps({"jsonrpc": "2.0", "id": req_id,
                          "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=payload,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.URLError as e:
        return {"__transport_error__": str(e)}
    except json.JSONDecodeError as e:
        return {"__decode_error__": str(e)}

def normalize(obj):
    if isinstance(obj, dict):
        out = {}
        for k in sorted(obj.keys()):
            out[k] = "<volatile-omitted>" if _norm_key(k) in _VOL else normalize(obj[k])
        return out
    if isinstance(obj, list):
        return [normalize(x) for x in obj]
    return obj

def canon(obj):
    return json.dumps(normalize(deepcopy(obj)), indent=2, ensure_ascii=False, sort_keys=True)

def strip(r):
    if not isinstance(r, dict):
        return r
    if "result" in r:
        return {"result": r["result"]}
    if "error" in r:
        code = r["error"].get("code") if isinstance(r["error"], dict) else r["error"]
        return {"error_code": code}
    return r

def main():
    if len(sys.argv) != 2:
        sys.exit("usage: rpc_regress.py <cases.json>")
    old_url, new_url = os.environ.get("OLD_RPC"), os.environ.get("NEW_RPC")
    if not old_url or not new_url:
        sys.exit("error: 必须通过环境变量 OLD_RPC 和 NEW_RPC 提供端点")
    with open(sys.argv[1], encoding="utf-8") as f:
        cases = json.load(f)
    diffs = 0
    for i, case in enumerate(cases, 1):
        method, params = case["method"], case.get("params", [])
        old_c = canon(strip(rpc_call(old_url, method, params, i)))
        new_c = canon(strip(rpc_call(new_url, method, params, i)))
        if old_c == new_c:
            print(f"[OK]   #{i} {method}")
        else:
            diffs += 1
            print(f"[DIFF] #{i} {method}")
            for line in difflib.unified_diff(old_c.splitlines(), new_c.splitlines(),
                                             fromfile="OLD", tofile="NEW", lineterm=""):
                print("    " + line)
    print(f"\n汇总: {len(cases)} 用例, {diffs} 处差异")
    sys.exit(1 if diffs else 0)

if __name__ == "__main__":
    main()
```

> 脚本要点：JSON-RPC 2.0 over HTTP POST；`normalize()` 递归排序 key 并把易变字段替换为占位符；`strip()` 只比对 `result` 主体或 `error.code`，忽略 id 与 message 文案；有差异退出码 1，便于接入 CI。`VOLATILE_KEYS` 按需增删。

---

## 8. 代码冲突热点与 impact 分析（v1.19.0 → v1.19.2 实测交集）

> 方法：`git diff --name-only op-node/v1.19.0 main`（fork 在 v1.19.0 之上的全部改动，448 文件）∩ `git diff --name-only op-node/v1.19.0 op-node/v1.19.2`（上游增量，1401 文件）。**交集 = 260 个潜在冲突文件。**

### 8.1 交集按目录分布

| 目录 | 冲突文件数 | 说明 |
|---|---|---|
| `rust/kona` | 96 | 最大文本冲突面：kona-1.6.0（fork）× 上游 interop→lagoon/kona-sp1/predeploys 迁移 |
| `rust/op-reth` | 81 | gasless 寄生地 × reth v2.3.0 + txpool/interop_filter 重写 |
| `rust/op-rbuilder` | 21 | 独立 workspace，flashblocks/context 重写 |
| `rust/rollup-boost` | 9 | 主要是 Cargo.lock/依赖 |
| `rust/alloy-op-evm` | 8 | 含 gasless 系统调用与 env.rs |
| `packages/contracts-bedrock` | 5 | gasless 白名单 wiring × 上游合约 |
| `op-node/*` `op-core/*` `op-service/*` | 12 | Go 侧，多为上游重构 × fork 小改 |
| `rust/op-revm` | 2 | **含 handler.rs（EVM 费用处理，最高危）** |

**结论：约 90% 的冲突在 Rust 侧（kona + op-reth + op-rbuilder = 198/260）**；Go（op-node）侧冲突面很小（12 文件、多为轻量）。

### 8.2 冲突分四类（按处理方式区分）

- **A｜文本冲突**：fork 与上游改到同一文件 → `git` 会标 `<<<<`，需手工合并。
- **B｜静默编译失败（最危险）**：fork 新增文件，`git` **不报冲突**，但依赖被上游重写的 API → 合并"干净"却编译不过甚至行为漂移。**gasless 的核心风险在此**。
- **C｜符号消失编译错误**：fork 引用了被上游改名/删除的符号（如 `InteropTime`/`forks.Interop`）→ 合并后编译报 undefined。
- **D｜语义/共识 impact**：即使编译通过，行为需与新版逐位一致，否则分叉链或 fault proof 失败。

### 8.3 高危冲突热点（含处理建议）

| 文件 | 上游改动量 | 类型 | 严重度 | impact / 处理 |
|---|---|---|---|---|
| `rust/op-revm/src/handler.rs` | +138/-7 | **A** | 🔴 极高 | fork 为 gasless 零价交易改了 +275 行费用处理；上游同区域大改（reth v2.3.0 handler/spec）。**逐块手工合并 + 出块/校验双路径一致性验证** |
| `rust/op-reth/crates/txpool/src/xlayer_gasless.rs`（+`rpc/eth/gasless.rs`） | 上游未动（fork 新增） | **B** | 🔴 极高 | git 不报冲突，但寄生的 `txpool/` 被上游重写（`maintain.rs`+286/-98、`pool.rs`、`error.rs`、`interop_filter/client.rs`+821/-78）→ **必然编译失败**。需按 reth v2.3.0 新 txpool trait 重新接线 gasless validator/pending 驱逐 |
| `rust/alloy-op-evm/src/block/xlayer_gasless_contract.rs` | 上游未动（fork 新增） | **B** | 🔴 极高 | 共识关键系统调用；上游 `env.rs`(+132/-4)、`block/tests.rs`(+1204) 大改 → 新增文件依赖的 EVM/BlockExecutor API 变了。**必须验证 block building 与 validation 仍逐位一致** |
| `rust/alloy-op-evm/src/env.rs` | +132/-4 | **A** | 🟠 高 | fork 经 kona-1.6.0 升级改过；上游大改 → 文本冲突，且影响上一行的 gasless 系统调用环境 |
| `rust/op-reth/crates/txpool/src/{validator.rs,pool.rs}`、`rpc/src/eth/call.rs`、`node/src/args.rs` | 混合 | **A** | 🟠 高 | gasless 校验/estimateGas/CLI 开关的挂载点被上游改动，需保留 fork 逻辑 |
| `rust/kona/crates/proof/executor/src/builder/core.rs` 等 kona 96 文件 | 大量 | **A** | 🟠 高 | kona gasless 支持 × 上游 kona 大改；子树冲突多，量大但多为机械 |
| `rust/kona/tests/proofs/{nut_bundle_activation_test.go,helpers/env.go}` | — | **C** | 🟡 中 | fork 提交 `4f686b1f1a`/`eeb50c0dfa` 把 `forks.Lagoon→Interop`、用 `InteropTime`；v1.19.2 已删这些符号 → **回翻为 Lagoon/`LagoonTime`** 否则编译报 undefined |
| `packages/contracts-bedrock/src/L1/{OptimismPortal2.sol,SuperchainConfig.sol}` | 混合 | **A** | 🟠 高 | fork 的 gasless 白名单/OKB wiring × 上游合约改动；连带 `semver-lock.json`/`foundry.toml`/`exclusions.toml` 机械冲突 + oz-upgradeable-v5 submodule |
| `op-node/rollup/driver/driver.go` | +48/-42 | **A** | 🟡 中 | 上游 supervisor→supernode/cross-safe 重构 × fork 小改；Go 侧最大冲突，但可控 |
| `op-node/{service.go,node/node.go,config/config.go,flags/flags.go}`、`op-core/superchain/init.go` | 轻量 | **A** | 🟢 低 | 多为上游重构叠加 fork 的 XLayer 硬编码/字段适配，逐处对齐即可 |

### 8.4 三个最容易被低估的 impact

1. **gasless 的"合并干净但编译不过/行为漂移"**（B 类）：因为 gasless 主体是 fork 新增文件，`git merge` 完全不会提示，极易误判"没冲突"。**真正的工作量在 §8.1 步骤 1（先把 okx/reth 升到 v2.3.0）**——这一步没做好，后面全塌。务必让 gasless 单测 + 出块/校验双路径重放先在纯 op-reth 层面绿。
2. **reth v2.3.0 的连锁 workspace 影响**：`rust/Cargo.lock`(+4283/-784) 说明依赖图整体位移，op-rbuilder / rollup-boost / op-alloy 都会被拖动，需统一到 v2.3.0，不能只改 op-reth。
3. **Interop→Lagoon 的双向性**（C 类）：上游把 Interop 改成 Lagoon，而 fork 在 port gasless 时**反向**改回过 Interop。合并后不是简单接受一方，而要确保最终全部收敛到 Lagoon，且 NUT source hash 仍用 label `"interop"`（§4.2 #4）——命名与哈希两套语义不要混。

---

## 9. 升级步骤（建议顺序）

> 前置事实：main 已在上游 v1.19.0，实际上游增量是 v1.19.0→v1.19.2（主体 v1.19.1）。真正难点在 Rust 侧（reth）而非 Go 侧（op-node）。冲突热点见 §8。

1. **升级 okx/reth fork 到 reth v2.3.0**（独立前置工程，见 §6.D）：把 okx/reth 的 gasless/okx 定制 rebase 到 reth v2.3.0，验证 op-reth 单独可编译、gasless 单测通过。
2. **拉取上游 v1.19.0→v1.19.2 到 main**：`git merge`/`rebase` op-node/v1.19.2。预期机械冲突集中在——
   - Interop→Lagoon 重命名回翻（fork 曾反向改，见 §6，把 `4f686b1f1a`/`eeb50c0dfa` 翻回 Lagoon）；
   - op-program / op-supervisor / op-validator 目录删除；
   - contracts（gasless 白名单 predeploy vs L2CM/predeploy 建模）；
   - rust/kona 子树。
3. **更新依赖 pin**：`rust/Cargo.toml` reth → 升级后的 okx/reth（reth v2.3.0 派生）；确认 `go.mod` okx/op-geth pin 与 Karst 测试期望策略（§5 注意点 2）。
4. **清理已删除的 CLI flag / 配置**（§3.1/§3.2）：从启动命令与 env 中移除 `--rollup.halt`、`--rollup.load-protocol-versions`、`--interop.rpc.*`；核对 rollup.json 无 `interop_time`（若有改 `lagoon_time` 或删）；确认 `--l2.engine-kind` 显式设置（用 op-reth 则 reth，用 geth 则显式 geth）；`--override.interop`→`--override.lagoon`。
5. **守住不激活 Karst/Lagoon**：确认 XLayer 链配置 `karst_time`/`lagoon_time` 均未设置；`--override.keep-karst-upgrade-gas` 不传。
6. **编译与单测**：Go（op-node、op-service、op-e2e）+ Rust（op-reth、op-revm、alloy-op-evm、kona）全量编译；恢复/调整因删除 op-program 而失效的 CI 步骤（§4.4）。
7. **回归与一致性验证**：见 §10。

---

## 10. 测试 / 验证清单

**共识一致性（最高优先级）**

- [ ] gasless tx 的 allowed/gasLimit 判定在 sequencer 出块与 verifier/kona 重放下逐位一致（block building vs validation 双路径）。
- [ ] 全链重放一段主网/testnet 区块，逐块比对 op-node 与 op-reth 的 block hash（确认 §4.2 各项无漂移）。
- [ ] estimateGas 在 reth v2.3.0 + gasless 下返回正确（注意 §5 的 #21574 与 gasless estimateGas 同区）。
- [ ] `op-core/eip1559` 与 EL base fee 计算一致（Jovian min base fee）。

**接口 / 网络**

- [ ] 运行 §7.5 脚本对比 v0.1.5 与 v1.19.2 的 `optimism_*` / `opp2p_*` RPC 输出（预期只增不减）。
- [ ] 新版节点与旧版节点混合组网：gossip 区块传播、`payload_by_number` req-resp 服务端响应正常。
- [ ] Engine API：确认不激活 Karst 时不出现 `engine_getPayloadV5` 调用；`getPayloadV4`/`newPayloadV4` 正常。

**配置 / 启动**

- [ ] 用清理后的启动命令拉起 op-node，无 unknown flag、无 rollup.json 静默忽略导致的 fork 未激活。
- [ ] 若用裁剪型 op-reth，确认 v1.19.2 的 `#21587`（EL-expired genesis）生效，L2 config 校验不失败。

**Karst 关闭校验**

- [ ] `karst_time`/`lagoon_time` 未设时，日志中 `IsKarst`/`IsLagoon` 恒 false，NUT bundle 不注入，gasLimit 保持 `SystemConfig.GasLimit`。
- [ ] op-geth pin 与 `chains_test.go` 的 KarstTime 期望策略一致（§5）。

---

## 11. 排查结果

### 11.0 总览（2026-07-29，reth v2.3.0 基线 rev 25009c940f）

排查对象：用户给定的 v2.3.0/v2.4.0 修复清单逐项判定是否已在 xlayer-reth 当前 pin 的 okx-reth 基线（`xl/reth-v2.3.0` = upstream v2.3.0 merge + okx 本地补丁）中；缺失项评估对 XLayer 的影响与 cherry-pick 冲突。判定方法：`git merge-base --is-ancestor <sha> HEAD`。

**优先级汇总（缺失项）**：

| 优先级 | PR | 类别 | 理由 |
|---|---|---|---|
| P0 | #25242 | Engine/Payload | resolve 命令懒发送，直接命中 flashblocks 自定义 PayloadJob 的 resolve 路径，getPayload 挂起风险；零冲突可 pick |
| P0 | #26332（清单外） | Engine/State root | sparse trie prune retention set 构造错误；正确性风险，且压在 okx 补丁最重的 payload_processor 上 |
| P1 | #25410 | Storage/Pruning | 开 receipts prune 的 RPC 副本对已 prune 区块返回错误的空/不完整 receipts（正确性） |
| P1 | #26325/#26327 | Engine | state-root task dispatch 失败被吞 → 永久 hang；bug 形态在基线真实存在（中等冲突） |
| P1 | #25612 | Gas/estimateGas | EIP-7825 estimateGas 根因修复；当前靠 deps/optimism 的 op 侧 workaround（标注 TODO 临时）兜底 |
| P1 | #25133 | RPC | trace_filter buffer 限流，保护 RPC 副本稳定性；零冲突 |
| P2 | #25460/#25462 | Engine | execution cache 生命周期；小补丁手工套用，注意与 okx 补丁在 payload_processor 的交叠 |
| P2 | #26334 #26265 #25086 #25921 | P2P | 均验证可干净应用，适合低风险批量 pick（#26334 优先：unban 不重置 reputation） |
| P2 | #24719 #25079+#25074 | RPC | eth_getProof 空 trie / simulate 修复；前者零冲突，#25074 需先 pick #25079 |
| P2 | #26108 #26363 | Storage | prune static-file 超额保留（磁盘）；import EOF 校验（仅 reth import 路径） |
| P3 | #26367 | State root | 仅 BAL/EIP-7928 路径可触发，OP-stack 当前 decoded_bal 恒 None；防御性移植 |
| P3 | #26067 | Fees | fee-history 按 receipt gas 加权，XLayer 现为 no-op（仅 EIP-8037 后分叉生效）；随下次 rebase |
| 跳过 | #25412 | Txpool | ⚠️不建议单独 pick：sequencer-only L2 全部用户流量走 RPC，改判 Local 会绕过 max_account_slots/驱逐，叠加 gasless 放大池占用攻击面 |
| 跳过 | #26113 | Txpool | OP 池拒绝 EIP-4844，OpPooledTransaction 无 4844 变体，不可达 |
| 跳过 | #25258 | Fees | 2×basefee 默认值在 XLayer basefee≈0 下无实际影响 |
| 不适用 | #26080 #26356 | Engine | 修的是 v2.4 周期引入/重构后的回归，v2.3.0 结构上不成立 |

**已在 v2.3.0 基线、无需动作**：#24506 #24584 #24359（state root）、#24875 #24967 #24390（engine）、#24903 #24267 #24760（storage）、#24387（simulate gas 默认）、#24494 #24474（txpool）、#24505 #23600 #24503 #24499（RPC）、#25031 #24536 #24427 #24406（p2p）。

**EIP-7825 estimateGas 专项结论**：当前无 bug。XLayer 三网最高 fork 为 Jovian（映射 PRAGUE），Osaka/7825 cap 未激活；U19 时的 bug 根因（estimate 读原始字段而非 effective gas cap）已被 deps/optimism 侧 workaround 覆盖并有回归测试（estimate_gas_7825）。建议仍 pick #25612 落根因修复。

**结构性提醒**：
- reth v2.3/v2.4 主仓已不含 op-* crates，OP 专属执行层修复全部在 deps/optimism 侧——本清单对 OP 侧修复零覆盖，需另行筛查。
- 未来升 v2.4 的冲突热区：engine tree 的 payload_validator / payload_processor（上游改动 24/18 次）；上游 #26139 删除 deferred_trie.rs，okx 引擎死锁补丁（等价 #24870）将失去宿主文件，需整段重移植。
- 工作区中混有未提交的 KMS feature（submodule 指针 + main.rs 大段改动），勿随升级 PR 带入。

---

### 11.1 Consensus / State root

排查基线：okx-reth 分支 `xl/reth-v2.3.0`（HEAD=25009c940f，基于 upstream tag v2.3.0 + okx 本地补丁）。判定方法：`git merge-base --is-ancestor <sha> HEAD`。

#### #24506 — Recompute hashed state on state root task failures

- **状态**：✅ 已在 v2.3.0 基线（IN_BASE）
- **upstream sha**：`278c60216f`（fix: recompute hashed state on state root task failures (#24506)），首个包含 tag：v2.3.0
- **修复内容**：`crates/engine/tree/src/tree/payload_validator.rs` — 当并行 state-root 任务失败回退到同步计算时，重新从执行输出计算 hashed state，避免复用可能不完整的中间状态导致 state root 错算。
- **结论**：随 v2.3.0 一并升级已带入，无需处理。

#### #26367 — elide empty new accounts from hashed state

- **状态**：❌ 缺失 — 修复在 v2.4.0（`git tag --contains` = v2.4.0, v2.4.1）
- **upstream sha**：`f0a41795d7`（fix(tree): elide empty new accounts from hashed state (#26367)）
- **修复内容**：`crates/engine/tree/src/tree/payload_processor/prewarm.rs` 的 BAL（EIP-7928 Block Access List）并行 state-root 路径。触发条件：同一区块内 tx1 给新账户打钱、tx2 对该地址 CREATE2 且 init code 里 SELFDESTRUCT，最终账户完全为空（balance/nonce/code 全零）。旧代码无条件 `hashed_state.accounts.insert(hashed_address, Some(account))`，把这种"空账户"当作存在的账户送入 sparse trie，会与串行执行结果产生 **state root 分歧**。修复为 `let account = (!account.is_empty()).then_some(account);`，空账户记为 `None`（删除语义）。
- **对 XLayer 的影响**：**当前为潜伏性 bug，实际不可触发。** 该路径仅在 `PrewarmMode::BlockAccessList` 下运行，前提是 payload 携带 EIP-7928 BAL 且通过 `bal_path_eligible` 检查（Amsterdam 硬分叉特性）。XLayer 是 OP-stack L2，未启用 Amsterdam/BAL，`env.decoded_bal` 恒为 `None`，实际走 `PrewarmMode::Transactions` 或 `Skipped`，故 sequencer / validator / RPC 副本当前均不受影响。已检查 xlayer-reth 定制代码：`crates/builder/src/flashblocks/builder.rs` 的 flashblocks state-root 计算走标准 `state_provider.hashed_post_state(&state.bundle_state)`（bundle state 本身正确处理空/销毁账户），未复制受影响的 prewarm/BAL 逻辑；其余 crates 无 wrap。
- **cherry-pick 建议与冲突评估**：建议低优先级带上（防未来启用 BAL 类分叉时踩雷）。直接 `git cherry-pick` **会冲突**：v2.4.0 已将该函数重构为 `hashed_update_stream.on_hashed_state_update(...)` + `account_fields.into_account(...)` 风格，而我们基线仍是 `to_sparse_trie_task.send(StateRootMessage::HashedStateUpdate(...))` + 内联构造 `Account` 的旧结构。但语义修复只有一处：把 `send_bal_hashed_state` 末尾的 `insert(hashed_address, Some(account))` 改为 `insert(hashed_address, (!account.is_empty()).then_some(account))`，手工移植是一行改动，风险极低。

#### #24584 — state provider creation fix

- **状态**：✅ 已在 v2.3.0 基线（IN_BASE）
- **upstream sha**：`808d6f01b3`（fix: state provider creation (#24584)），首个包含 tag：v2.3.0
- **修复内容**：修正 `crates/engine/execution-cache/src/cached_state.rs`、`crates/engine/tree/src/tree/payload_validator.rs` 及 BAL execute/worker 中 state provider 的创建方式，避免用错 provider 层导致读到不一致状态。
- **结论**：随 v2.3.0 已带入，无需处理。

#### #24359 — trie: accept B256::ZERO as non-existent account in EIP-1186 proof

- **状态**：✅ 已在 v2.3.0 基线（IN_BASE）
- **upstream sha**：`5363ac9786`（fix(trie): accept B256::ZERO as non-existent account in from_eip1186_proof (#24359)），首个包含 tag：v2.3.0
- **修复内容**：`crates/trie/common/src/proofs.rs` — `from_eip1186_proof` 接受 `storageHash`/`codeHash` 为 `B256::ZERO` 的响应（部分客户端对不存在账户返回全零而非 empty-root/KECCAK_EMPTY），避免误判 proof 无效。
- **结论**：随 v2.3.0 已带入，无需处理。

#### 小结

| PR | 状态 | upstream sha | 进入版本 | 对 XLayer 风险 | 建议 |
|---|---|---|---|---|---|
| #24506 recompute hashed state on task failure | ✅ IN_BASE | `278c60216f` | v2.3.0 | 已覆盖 | 无需动作 |
| #26367 elide empty new accounts (BAL prewarm) | ❌ MISSING | `f0a41795d7` | v2.4.0 | 潜伏（XLayer 未启用 EIP-7928 BAL，路径不可达） | 低优先级手工移植一行修复；直接 cherry-pick 会因 v2.4.0 重构冲突 |
| #24584 state provider creation | ✅ IN_BASE | `808d6f01b3` | v2.3.0 | 已覆盖 | 无需动作 |
| #24359 B256::ZERO in EIP-1186 proof | ✅ IN_BASE | `5363ac9786` | v2.3.0 | 已覆盖 | 无需动作 |

结论：本类别 4 个 PR 中 3 个已随 v2.3.0 基线带入；唯一缺失的 #26367 位于 BAL（EIP-7928）并行 state-root 路径，XLayer 当前不可触发，无现实的 sequencer/validator state-root 分歧风险，建议作为防御性修复择机移植。

---

### 11.2 Engine / Payload building（liveness）

基线说明：okx-reth 分支 xl/reth-v2.3.0（HEAD=25009c940f，基于 upstream tag v2.3.0 + okx 本地补丁）。okx 本地补丁中与本节相关的有：7680d6d8a9（等价 #24870 的 chain-state deadlock fix）、4a0688a46f（PayloadProcessor 包 Arc&lt;Mutex&gt;）、c87fab7eba（跨 payload processor spawn 保留 StateRootHandle）——后两者触及 `crates/engine/tree/src/tree/payload_processor/mod.rs`，会增加本节部分 cherry-pick 的冲突面。

#### #26356 — fix(sparse_trie): fix dead lock for the late arrived hints
- **状态**：❌ 缺失-在 v2.4.0（sha `8db1aa9af6`，进入 v2.4.0/v2.4.1）
- **修复内容**：`SparseTrieCacheTask::make_progress` 原按 "updates 通道非空" 跳过收尾工作；在收到 `FinishedStateUpdates` 之后又排队进来的 prefetch hint（`PrefetchProofs`）会让该判断永远为真，任务无法收敛 → state root 计算 hang。修复为 finish 标记之后的排队消息视为不可执行的 hint（`!self.finished_state_updates && !self.updates.is_empty()`）。
- **对 XLayer 影响**：**较低/不直接适用**。被修复的 `make_progress` 抽取发生在 v2.4 开发周期（该 fix 的 pre-image 已含 #26325 及后续重构）；v2.3.0 基线的 `run()` 是内联 select! 循环，late hint 会作为普通消息被 select 唤醒并消费，随后 `updates.is_empty()` 即成立、正常走到 break——该特定死锁形态在 v2.3.0 结构上不成立。
- **cherry-pick 建议**：不单独 pick。基线与该 fix 父提交的 `sparse_trie.rs` 差异高达 443(+)/132(-)（v2.3.0..v2.4.1 之间该文件有 12 个提交），直接 pick 必然大面积冲突且语义对不上。如需该保护，随整体升级 v2.4.x 获得。

#### #24875 — fix(chain-state): avoid state overlay cache deadlock
- **状态**：✅ 已在 v2.3.0 基线（sha `84d8e471ea`，v2.3.0 tag 内）
- 一句话确认：已随 v2.3.0 merge 进入基线；注意与 okx 本地补丁 7680d6d8a9（等价 #24870，改 `deferred_trie.rs`/`get_overlay` 的锁持有方式）是**两个不同的** chain-state deadlock fix，两者都已具备，不要混淆。

#### #26325 / #26327 — fix(engine): error on stalled sparse trie proofs / log pending stalled proof targets
- **状态**：❌ 缺失-在 v2.4.0（#26325 sha `89a006c08b`；#26327 sha `476401f02a`，为其日志增强、依赖前者）
- **修复内容**：#26325 前，`dispatch_pending_targets` 中 proof dispatch 失败只 `error!` 记日志后继续；任务随后在 select! 上永久等待一个永远不会到达的 proof result → 块验证 hang（活锁转死等）。修复引入 `in_flight_proof_batches` 计数、dispatch 失败上抛 `StateRootTaskError::ProofDispatch`，并新增 `ensure_not_stalled()`：检测到 "有未完成 trie 更新但无 in-flight proof 也无排队消息" 时直接报错退出而不是 hang。#26327 在报错时把 pending 的 account/storage proof targets 打进日志便于定位。
- **对 XLayer 影响**：**bug 形态在基线真实存在**。基线 `crates/engine/tree/src/tree/payload_processor/sparse_trie.rs` 的 `dispatch_pending_targets()`（约 813 行起）就是 "只 error! 不上抛" 的旧版；一旦 proof worker pool 关闭/dispatch 失败（如 worker panic、任务取消竞态），state-root task 将永久卡住 → 新 payload 验证 hang、engine 停摆。okx 本地补丁 c87fab7eba/4a0688a46f 恰好改动了 payload processor 的生命周期（跨 spawn 复用 handle、Arc&lt;Mutex&gt; 共享），worker handle 生命周期路径与上游不同，这类 dispatch 失败竞态窗口值得额外警惕。
- **cherry-pick 建议**：**建议移植（中等工作量）**。基线与 #26325 父提交在 `sparse_trie.rs` 上的偏移约 69 行、`crates/trie/parallel/src/error.rs` 偏移 29 行，自动 pick 会有冲突但补丁语义独立（加错误变体 + 计数 + 停滞检查），手工适配可行；#26327 随 #26325 一起带上。或以升级 v2.4.x 整体解决。

#### #26080 — fix(engine): restore state root task parallelism gate
- **状态**：❌ commit 缺失（sha `b224494e25`，v2.4.0），**但对应回归不在 v2.3.0 —— 无需处理**
- **修复内容**：v2.4 开发周期中 #26069 等重构误删了 `has_enough_parallelism`（<5 可用线程时禁用 state-root task、回退同步计算）的 gate，低核数主机上 state-root 流水线（engine 主线程 + multiproof + sparse trie + proof 计算 + storage root，5 条互相阻塞的线程）会互相饿死 → payload 验证 stall；#26080 把 gate 恢复。
- **对 XLayer 影响**：基线未受影响：`crates/engine/primitives/src/config.rs:81` 存在 `has_enough_parallelism()`，`use_state_root_task()`（config.rs:584，且额外考虑 `legacy_state_root`）在 `crates/engine/tree/src/tree/payload_validator.rs:1778` 的策略选择中生效。
- **cherry-pick 建议**：无需 pick。仅提示：若未来升 v2.4.x，确认拿到的是含 #26080 的版本（v2.4.0 已含）。

#### #25460 / #25462 — execution cache lifecycle（track SavedCache usage via ExecutionCache / wait for workers before writing cache）
- **状态**：❌ 均缺失-在 v2.4.0（#25460 sha `4c22c7b7dc`；#25462 sha `43196ba7b5`）
- **修复内容**：
  - #25460：`SavedCache` 原用独立的 `usage_guard: Arc<()>` 判定 "缓存是否空闲"，但真正被各任务持有的是 `ExecutionCache` 的 clone，两者计数脱节 → 缓存可能在仍被上一个块的任务（prewarm worker 等）持有时被判为 available 并交给下一个块并发使用。修复改为直接用 `Arc::strong_count(&ExecutionCache.0)` 计数。
  - #25462：BAL prewarm 池的 `end_block()` 原是 fire-and-forget（只投递 `EndBlock` 消息就返回），随后立刻通知 cache 保存路径；worker 可能尚未处理完队列中的 warm 请求，缓存已被作为 `SavedCache` 存回供下一块使用 → 旧块数据继续写入已移交的缓存。修复让 `end_block()` 通过 `SendOnDrop` + oneshot 阻塞等待全部 worker 处理完毕。
- **对 XLayer 影响**：**bug 形态在基线真实存在**。基线 `crates/engine/execution-cache/src/cached_state.rs:990` 仍是 `usage_guard: Arc<()>`；`crates/engine/tree/src/tree/payload_processor/bal_prewarm_pool.rs:87` 的 `end_block()` 仍是非阻塞发送；`prewarm.rs`（约 426 行）`pool.end_block(); prefetch_tx.send(())` 的旧时序原样存在。后果是跨块的缓存内容错乱（执行读到脏缓存 → state root 不一致、块导入失败）乃至缓存并发使用引发的卡死。XLayer 是持续出块的 L2 sequencer，块间隔短，prewarm 收尾与下一块开始的竞态窗口比以太坊 L1 更容易被踩中。
- **cherry-pick 建议**：**建议移植（补丁小、手工适配为主）**。两个 fix 本体都很小且思路清晰；但基线与其父提交在 `prewarm.rs`（264 行偏移）、`cached_state.rs`（171 行偏移）上漂移较大，自动 pick 会冲突，建议按语义手工套用。注意 #25460 触及 `payload_processor/mod.rs`，与 okx 本地补丁 4a0688a46f/c87fab7eba 的改动同文件，需回归验证 PayloadProcessor 复用逻辑。

#### #25242 — fix: send payload resolve command before returning future
- **状态**：❌ 缺失-在 v2.4.0（sha `ee6740086a`）
- **修复内容**：`PayloadBuilderHandle::resolve_kind` 原为 `async fn`——`PayloadServiceCommand::Resolve` 是懒发送，首次 poll 返回的 future 才发出；若调用方持有 future 但未及时 poll（select!/超时竞速）或 poll 前 drop，Resolve 命令**永远不会发出**，payload job 不会被终止/结算。修复改为构造时即同步发送命令再返回 future，并明确 cancellation-safety 语义；同时**删除了 `resolve_kind_fut` API**。
- **对 XLayer 影响**：**直接命中 flashblocks 路径，本节最高优先级**。xlayer-reth 的 `crates/builder/src/flashblocks/generator.rs` 实现了自定义 `PayloadJob`（`BlockPayloadJob::resolve_kind`，generator.rs:296），其语义完全依赖 Resolve 命令到达 service：收到后才 `self.cancel.cancel()` 停止 flashblocks 构建循环、并等待 `BlockCell` 出值（`KeepPayloadJobAlive::No`）。`crates/builder/src/flashblocks/service.rs` 把该 generator 挂进上游 `PayloadBuilderService`/`PayloadBuilderHandle`，engine `getPayload`（upstream `crates/rpc/rpc-engine-api/src/engine_api.rs` 经 `PayloadStore::resolve`）即走此懒发送路径。命令延迟/丢失 = flashblocks job 不停不结 → `engine_getPayload` 挂起或拿不到 payload，sequencer 出块中断。已在基线的 #24967（见下）只修了 service 侧 "先 drop 后 send" 的另一半，handle 侧懒发送这一半仍缺。
- **cherry-pick 建议**：**强烈建议 pick，且是干净 pick**——受影响两文件（`crates/payload/builder/src/service.rs`、`crates/payload/builder/src/traits.rs`）在基线与该 fix 父提交完全一致（diff 为空）。已确认 xlayer-reth 与 okx-reth 均无 `resolve_kind_fut` 调用方，API 删除无破坏。

#### #24967 — fix(payload): defer resolved job drop until after send
- **状态**：✅ 已在 v2.3.0 基线（sha `8b902fe0b3`，v2.3.0 tag 内）
- 一句话确认：resolve 后的 job 延迟到响应发送之后再 drop，已随 v2.3.0 进入基线，flashblocks 的 `KeepPayloadJobAlive::No` 路径已受保护。

#### #24390 — fix(engine): reject zero multiproof chunk size
- **状态**：✅ 已在 v2.3.0 基线（sha `788677a69e`，v2.3.0 tag 内）
- 一句话确认：`--engine.multiproof-chunk-size 0` 参数校验拒绝零值，已随 v2.3.0 进入基线。

#### 小结

| PR | sha | 状态 | 进入版本 | 对 XLayer | 建议 |
|---|---|---|---|---|---|
| #26356 late-hint sparse-trie deadlock | `8db1aa9af6` | ❌ 缺失 | v2.4.0 | 特定死锁形态在 v2.3.0 结构上不成立 | 不单独 pick，随升级 v2.4.x |
| #24875 state overlay cache deadlock | `84d8e471ea` | ✅ 在基线 | v2.3.0 | 已修（另有 okx 补丁 7680d6d8a9=#24870，勿混淆） | 无 |
| #26325/#26327 stalled proofs → error | `89a006c08b` / `476401f02a` | ❌ 缺失 | v2.4.0 | bug 形态真实存在：dispatch 失败被吞 → state-root task 永久 hang | 建议移植，中等冲突需手工适配 |
| #26080 parallelism gate | `b224494e25` | ❌ 缺失（回归不在 v2.3.0） | v2.4.0 | 基线已有 gate（config.rs:81 / payload_validator.rs:1778），不受影响 | 无需处理 |
| #25460 SavedCache usage 追踪 | `4c22c7b7dc` | ❌ 缺失 | v2.4.0 | usage_guard 与真实持有者脱节 → 缓存被并发复用 | 建议移植（小补丁手工套用） |
| #25462 wait workers before cache write | `43196ba7b5` | ❌ 缺失 | v2.4.0 | end_block 非阻塞 → 缓存移交后仍被旧块 worker 写入 | 建议移植（小补丁手工套用） |
| #25242 resolve 命令先发再返回 future | `ee6740086a` | ❌ 缺失 | v2.4.0 | **直接命中 flashblocks resolve 路径，getPayload 挂起风险** | **强烈建议 pick，零冲突** |
| #24967 defer resolved job drop | `8b902fe0b3` | ✅ 在基线 | v2.3.0 | 已修 | 无 |
| #24390 reject zero chunk size | `788677a69e` | ✅ 在基线 | v2.3.0 | 已修 | 无 |

---

### 11.3 Storage / DB / Pruning（High）

基线说明：xlayer-reth pin 的 okx fork 分支基于 upstream `v2.3.0` merge，另含 11 个 okx 本地补丁。以下 6 个 PR 中 3 个已在基线、3 个缺失（均落在 v2.4.0/v2.4.1）。**okx 本地补丁未触碰下述任何受影响文件**（已逐一用 `git log v2.3.0..HEAD -- <file>` 验证，包括 `crates/storage/provider/src/providers/rocksdb/` 整个目录），因此缺失项的 cherry-pick 冲突风险仅取决于 upstream 自身漂移。

---

#### #24903 — fix: avoid clearing rocksdb unnecessarily

- **状态**：✅ 已在 v2.3.0 基线（sha `c8d9e0484c`，tags: v2.3.0 / v2.4.0 / v2.4.1）
- **修复内容**：`crates/storage/provider/src/providers/rocksdb/invariants.rs` 中 `AccountsHistory` / `StoragesHistory` 的不变量检查顺序有误——`checkpoint == 0` 的"清空并重建 genesis history"快速路径排在 `sf_tip == checkpoint`（状态一致，无需动作）判断之前。导致处于 genesis 状态（`sf_tip == checkpoint == 0`）的节点每次启动都会无谓地清空并重建 RocksDB history 表。修复将一致性检查前移。
- **对 XLayer 影响**：直接命中 XLayer 生产依赖的 RocksDB index tables（storage v2 核心路径）。sequencer 与 RPC 副本同样受益。
- **结论**：一句话确认——该修复已包含在基线中，无需动作。

#### #24267 — fix(stages): fix off-by-one bug

- **状态**：✅ 已在 v2.3.0 基线（sha `52a259237e`，tags: v2.3.0 / v2.4.0 / v2.4.1）
- **修复内容**：`crates/stages/stages/src/stages/merkle.rs` 分块增量更新 trie 时 `chunk_to = start_block + incremental_threshold` 少减 1，导致相邻 chunk 各多含 1 个重叠区块，同一区块的 changeset 被重复应用，可能造成增量 state root 计算错误 / pipeline 同步时 state root mismatch。
- **对 XLayer 影响**：影响 pipeline 同步（首次同步、大范围追块、unwind 后重执行）走 merkle 增量分块路径的场景，sequencer / RPC 副本均可能触发。
- **结论**：一句话确认——该修复已包含在基线中，无需动作。

#### #26108 — fix(prune): derive receipts static-file size from prune distance

- **状态**：❌ 缺失，首次出现于 v2.4.0（sha `6bd6bf28a5`，tags: v2.4.0 / v2.4.1）
- **修复内容**：static file 分段以"整文件删除"方式做 prune；receipts 段默认每文件 500k 区块（`DEFAULT_BLOCKS_PER_STATIC_FILE`），因此配置 `--prune.receipts.distance N` 时，最坏要等 prune 目标越过整个 500k 文件才能删除，实际保留量可超配置约 500k 区块。修复在 `crates/node/builder/src/launch/common.rs` 中：若用户未显式配置 receipts 段的 `blocks_per_file` 且 prune 模式为 `Distance(d)`，则用新增的 `blocks_per_file_for_prune_distance(d)`（= d/4，下限 1000、上限 500k，见 `crates/static-file/types/src/lib.rs`）自动推导文件大小，使保留量超额控制在约 25% 内。
- **对 XLayer 影响**：
  - **RPC 副本（通常开 receipts distance prune 的场景）**：直接命中——磁盘上 receipts 实际保留量远超配置的 distance，表现为磁盘占用偏大、prune 看似"不生效"。这是磁盘/运维问题，不是数据正确性问题。
  - **sequencer / 不 prune receipts 的全节点**：不触发（无 `Distance` 模式则代码路径不变）。
  - 注意：该修复只影响*新建*的 static files 文件大小；已有 500k 大文件不会被回溯切分，需等其整体过期删除后收益才完全体现。
- **cherry-pick 建议**：**建议 cherry-pick，预计干净**。`common.rs` 在 v2.3.0..v2.4.1 之间仅此一个 commit 触碰；`static-file/types/src/lib.rs` 的上下文（`find_fixed_range`、`DEFAULT_BLOCKS_PER_STATIC_FILE`）在我们分支中逐字存在；okx 本地补丁未改这两个文件。diff 使用 let-chains 语法，workspace 已是 edition 2024，无编译障碍。

#### #25410 — fix(provider): return none for incomplete block receipts

- **状态**：❌ 缺失，首次出现于 v2.4.0（sha `e7ebeb8693`，tags: v2.4.0 / v2.4.1）
- **修复内容**：`crates/storage/provider/src/providers/database/provider.rs` 的 `receipts_by_block`：当区块 body 存在但 receipts 只写入/保留了一部分（数量 != `body.tx_count`）时，原实现直接返回不完整的 receipts 列表；修复改为返回 `Ok(None)`。同时修正了测试语义：被 prune 掉 receipts 的区块现在返回 `None` 而不是 `Some(空列表)`。
- **对 XLayer 影响**：
  - **RPC 副本（开 receipts prune）**：数据正确性问题——`eth_getBlockReceipts` 等接口对已 prune 的区块可能返回空数组 / 不完整数组而非 `null`，下游（浏览器、索引器、桥监控）会把"数据不存在"误当成"该区块无交易/部分交易"。XLayer 已迁移到 static files 存 receipts，此路径（tx_range 非空但 receipts 数量对不上）真实可达。
  - **sequencer / 不 prune 的全节点**：正常运行时 receipts 完整，基本不触发；仅在写入中间态或损坏场景下作为兜底防护。
- **cherry-pick 建议**：**建议 cherry-pick，预计干净或近乎干净**。核心 hunk 的上下文行 `self.receipts_by_tx_range(tx_range).map(Some)` 在我们分支中逐字存在（provider.rs:2147）；它是 v2.3.0..v2.4.1 间触碰该文件的 4 个 commit 中最早的一个，直接落在 v2.3.0 之上；okx 本地补丁未改此文件。测试 hunk 若有轻微偏移也仅限测试代码。

#### #24760 — fix(provider): reject expired recovered blocks

- **状态**：✅ 已在 v2.3.0 基线（sha `63598af37b`，tags: v2.3.0 / v2.4.0 / v2.4.1）
- **修复内容**：`DatabaseProvider` 的 block-with-senders 类查询（recovered block 路径）在区块号低于 `static_file_provider.earliest_history_height()`（已过期/被 history expiry 删除）时返回 `ProviderError::BlockExpired`，而不是继续读取并可能返回错误数据。
- **对 XLayer 影响**：保护开启 history expiry / prune 的 RPC 副本查询过期区块时的行为正确性；sequencer 通常保全量历史，低相关。
- **结论**：一句话确认——该修复已包含在基线中，无需动作。

#### #26363 — fix(import): reject incomplete block at EOF

- **状态**：❌ 缺失，首次出现于 v2.4.1（sha `bb0c5cd14e`，tags: v2.4.1）
- **修复内容**：`crates/net/downloaders/src/file_client.rs` 的 `ChunkedFileReader`（`reth import` 离线导入路径）：文件（含 gzip）在 EOF 处若残留无法解码为完整区块的字节，原实现会静默丢弃这段尾部数据，导入"成功"但末尾区块缺失；修复在 EOF 且残留字节非空时返回 `FileClientError::Rlp(InputTooShort, ...)` 报错。
- **对 XLayer 影响**：仅影响 `reth import` 文件导入流程，与在线运行的 sequencer / RPC 副本无关。若 XLayer 运维用 export/import 做副本引导或数据迁移（storage v1→v2 迁移已完成，但未来扩副本可能用到），截断的导出文件会静默产生尾部缺块的数据目录，属隐蔽的运维风险；不用该流程则零影响。
- **cherry-pick 建议**：**低优先级，如需则预计干净**。`file_client.rs` 在 v2.3.0..v2.4.1 间仅此一个 commit 触碰，`FileReader::Gzip(GzipDecoder...)`、`Ok(0) => return Ok(!chunk.is_empty())` 等上下文在我们分支逐字存在；okx 本地补丁未改此文件。

---

#### 小结

| PR | 状态 | sha | 影响面（XLayer） | 建议 |
|---|---|---|---|---|
| #24903 avoid clearing RocksDB | ✅ 已在基线 (v2.3.0) | `c8d9e0484c` | RocksDB history 表启动时无谓清空重建 | 无需动作 |
| #24267 stages off-by-one | ✅ 已在基线 (v2.3.0) | `52a259237e` | merkle 增量分块重叠 → state root 风险 | 无需动作 |
| #26108 receipts SF size from prune distance | ❌ 缺失 (v2.4.0) | `6bd6bf28a5` | 开 receipts distance prune 的 RPC 副本磁盘超额保留 | 建议 cherry-pick（预计干净） |
| #25410 none for incomplete receipts | ❌ 缺失 (v2.4.0) | `e7ebeb8693` | RPC 副本对已 prune 区块返回错误的空/不完整 receipts | 建议 cherry-pick（预计干净） |
| #24760 reject expired blocks | ✅ 已在基线 (v2.3.0) | `63598af37b` | 过期区块查询返回 `BlockExpired` 兜底 | 无需动作 |
| #26363 import reject incomplete EOF | ❌ 缺失 (v2.4.1) | `bb0c5cd14e` | 仅 `reth import` 离线导入；截断文件静默丢尾块 | 低优先级，需要时 cherry-pick（预计干净） |

三个缺失修复的 cherry-pick 均无 okx 本地补丁冲突（相关文件在 v2.3.0..HEAD 无本地改动），且各自是 v2.3.0 之后首个（或唯一）触碰对应文件的 upstream commit，冲突风险极低。若开 receipts prune 的 RPC 副本是标准部署形态，建议 #25410（正确性）优先于 #26108（磁盘），#26363 视运维流程决定。

---

### 11.4 Gas / Fees 与 EIP-7825 estimateGas

基线：okx/reth 分支 `xl/reth-v2.3.0`，HEAD = `25009c940f`（= upstream v2.3.0 + 11 个 okx 补丁）。判定方法：`git log --oneline v2.4.1 --grep "#NNNNN"` 定位 sha，再 `git merge-base --is-ancestor <sha> HEAD`。

---

#### #25612 — Use effective tx gas cap for estimates

- **状态**：❌ MISSING（首发于 v2.4.0）
- **sha**：`2ef00fd19d`；`git tag --contains` → `v2.4.0`、`v2.4.1`
- **修复内容**：`crates/rpc/rpc-eth-api/src/helpers/estimate.rs` 中 `eth_estimateGas` 的 trial 上界原来直接读 `evm_env.cfg_env.tx_gas_limit_cap`（`Option<u64>` 字段），字段为 `None` 时回退到 block gas limit。修复改为调用 **effective 方法** `cfg_env.tx_gas_limit_cap()`——该方法（revm-context 18.0.3 `src/cfg.rs:424`）在字段未设置时按 spec 推导：Osaka 起返回 `eip7825::TX_GAS_LIMIT_CAP`（2^24 = 16,777,216），否则 `u64::MAX`。即修的是"字段没人赋值时 7825 cap 在估算路径失效"的 bug。
- **XLayer 影响**：这正是 U19 期间 estimateGas 用户可见 bug 的根因本体（详见下方 EIP-7825 专项）。但当前基线已被 OP 侧 workaround 抵消（optimism fork commit `20636578d2`，在 alloy-op-evm 的 `evm_env_for_op` 中于 Osaka-base spec 时给字段赋值 2^24，且该 commit 在 xlayer-reth 记录的 submodule gitlink `486e52a7` 内）。该 workaround 自带 `TODO(21583)` 注明"vendor 到含 #25612 的 reth 后移除"，属临时补丁。
- **cherry-pick**：`git apply --check` 干净无冲突（基线 estimate.rs 的被删行与 patch 前像完全一致，`Cfg` trait 已在 imports 中）。**建议 pick**：根因修复，摆脱对 op 侧临时 workaround 的依赖。

---

#### #26067 — weight fee-history rewards by receipt gas

- **状态**：❌ MISSING（首发于 v2.4.0）
- **sha**：`6d38c7373f`；`git tag --contains` → `v2.4.0`、`v2.4.1`
- **修复内容**：`eth_feeHistory` 的 reward percentile 计算（`crates/rpc/rpc-eth-types/src/fee_history.rs` 的 `calculate_reward_percentiles_for_block`）原以 `header.gas_used` 为百分位阈值分母；修复改为最后一张 receipt 的 `cumulative_gas_used`。二者仅在 **EIP-8037（Amsterdam）** 下会分叉——8037 可使 header gas_used 超过 per-tx receipt gas 之和，导致百分位阈值偏大、reward 采样系统性偏向高价交易。
- **XLayer 影响**：`eth_feeHistory` 的 reward 通道确实是 XLayer 的定价命脉（base fee≈0，钱包/SDK 靠 reward percentiles 建议 priority fee，即真实 gas price）。**但**本 fix 只有在 Amsterdam/EIP-8037 激活后才产生行为差异；XLayer 最高 fork 为 Jovian（无 8037），当前 `header.gas_used == 末张 receipt cumulative_gas_used`（deposit tx 也计入 receipts），两种算法结果逐字节相同。所以对 XLayer **现阶段是 no-op，实际严重度低于上游标的 Medium**，而非更高。风险在未来：升级到含 8037 的基线时若漏掉此 fix，feeHistory 建议价将被污染，对"priority fee 即真实价格"的 XLayer 是直接的用户资金面问题。
- **cherry-pick**：`git apply --check` 干净（含新增单测）。**建议随下次 rebase 带上**；单独紧急 pick 无必要。

---

#### #25258 — eth_fillTransaction default maxFeePerGas 对齐 go-ethereum

- **状态**：❌ MISSING（首发于 v2.4.0）
- **sha**：`b8b2d3fbf0`；`git tag --contains` → `v2.4.0`、`v2.4.1`
- **修复内容**：`crates/rpc/rpc-eth-api/src/helpers/transaction.rs` 中 `eth_fillTransaction` 缺省 `maxFeePerGas` 从 `base_fee + tip` 改为 `2 * base_fee + tip`（对齐 geth `setLondonFeeDefaults`），为 base fee 上涨预留 headroom，不改变实际支付价。
- **XLayer 影响**：XLayer 费用模型将 EIP-1559 中和（elasticity=1 + denominator=100M ⇒ base fee ≈ 0 且几乎不波动）。`2 × (≈0) + tip ≈ tip`，与旧算式 `≈0 + tip` 实际无差别；该 fix 防护的"base fee 在打包前上涨导致交易失效"场景在 XLayer 结构上不存在。**影响可忽略，低优先级**。
- **cherry-pick**：`git apply --check` 干净。可随批量 rebase 顺带，无需单独动作。

---

#### #24387 — eth_simulateV1 per-call gas 默认为剩余 block gas

- **状态**：✅ IN_BASE（v2.3.0 已包含）
- **sha**：`b8116b42b8`；`git tag --contains` → `v2.3.0`、`v2.4.0`、`v2.4.1`
- **修复内容**：`eth_simulateV1` 每个 call 未指定 `gas` 时默认取 `blockGasLimit - soFarUsedGasInBlock`（此前是整块 gas limit），并把 RPC gas cap 作为 request 级剩余预算逐 call 扣减；含 8037 双轨（regular/state gas）核算。
- **XLayer 影响**：已在基线，无需动作。附带核对：simulate 路径在 `validation=false` 时会显式 `cfg_env.tx_gas_limit_cap = Some(u64::MAX)` 禁用 7825 cap（okx-reth `crates/rpc/rpc-eth-api/src/helpers/call.rs:149`），`validation=true` 时依赖 env 里的 cap 字段——OP 侧 workaround 已覆盖（见下），行为正确。
- **cherry-pick**：不适用。

---

#### EIP-7825 estimateGas 专项结论

**结论先行：当前生产无 bug；风险是"未来激活 Karst 时"的，且已有双保险之一在位。**

1. **XLayer 尚未激活 EIP-7825 对应 fork。** OP 侧 7825 随 **Karst**（`OpSpecId::KARST → SpecId::OSAKA`，见 optimism 仓 `rust/op-revm/src/spec.rs:46`；Jovian 仅映射 PRAGUE）生效。XLayer 三网 chainspec（xlayer-reth `crates/chainspec/src/lib.rs`）最高只配置到 Jovian（mainnet 2025-12-02、testnet/devnet 2025-11-28 已激活），**Karst 未配置** ⇒ 7825 的 16,777,216 上限当前不生效，estimateGas 上界为 block gas limit，行为正确。
2. **基线 reth 确实缺 #25612 的根因修复。** okx-reth `crates/rpc/rpc-eth-api/src/helpers/estimate.rs:97-105` 读的是 `cfg_env.tx_gas_limit_cap` **字段**而非 effective 方法；reth 自己只在 L1 路径给字段赋值（`crates/ethereum/evm/src/lib.rs:254-255`），OP 路径不经过那里。
3. **但 OP 侧已有等效 workaround 在位。** optimism fork commit `20636578d2`（"set tx_gas_limit_cap for Osaka so eth_estimateGas works under Karst"）在 `rust/alloy-op-evm/src/env.rs:129-134` 的 `evm_env_for_op`（block/next-block/payload env 的共同咽喉）中：spec 的 eth base ≥ OSAKA 时设 `cfg_env.tx_gas_limit_cap = Some(2^24)`。已确认该 commit 在 xlayer-reth 记录的 submodule gitlink（`486e52a7`）与当前 checkout 中。字段被赋值后，基线 estimate.rs 的字段式 clamp 即可正确工作。optimism 仓还留有直指 U19 事故的回归测试 `rust/op-reth/crates/node/tests/it/estimate_gas_7825.rs`（引用 reth#25612 与 optimism#21337）。
4. **若两道保险都缺时的触发条件**（即 U19 当时的 bug 形态）：Karst 激活 + block gas limit > 16.77M（XLayer genesis gas limit：mainnet 0x2faf080=50M、testnet 0x1c9c380=30M、devnet 0xbebc200=200M，全部超限）+ 请求为非 basic-transfer 且未带 `gas` 字段 ⇒ trial gas limit 回退到 block gas limit > 2^24 ⇒ Osaka EVM 拒绝，`-32000: intrinsic gas too high`，所有合约调用的 estimateGas 全挂。
5. **gasless（zero fee-cap）与 estimateGas 无不良交互。** estimate.rs 的余额限制（`caller_gas_allowance`）仅在 `tx_env.gas_price() > 0` 时参与 min（estimate.rs:138-142）；gasless 请求 fee cap=0 ⇒ gas_price=0 ⇒ 跳过 allowance，零余额账户照常估算，不会被 balance-based 上界误伤。okx gasless 补丁 `50b7955895` 仅改动 transaction-pool（config/best/pending/txpool/validate）与 node args，不触碰 RPC 估算路径。
6. **xlayer-reth 自身未覆写 estimateGas。** `crates/rpc` 只有 `xlayer_ext` 自定义扩展；`crates/legacy-rpc/src/service.rs` 仅按区块高度把 `eth_estimateGas` 路由到 legacy 后端或本地实现，无重实现。OpEthApi 用的是 reth 默认 `EstimateCall`/`EthFees` trait 实现（optimism 仓 `rust/op-reth/crates/rpc/src/eth/call.rs:22`、`eth/mod.rs:385`）。

**建议**：
- 仍建议把 #25612 cherry-pick 进 okx-reth（apply 干净），让根因修复落在 reth 侧，而不是长期依赖 op 侧 `TODO(21583)` 临时补丁；二者共存无害（belt-and-suspenders）。
- 未来给 XLayer 配置 Karst 激活时间时，把 `estimate_gas_7825.rs` 回归测试纳入升级 checklist 必跑项。
- 关注 4：`eth_createAccessList` 与 `eth_call` 路径基线已显式 `Some(u64::MAX)` 禁用 cap（call.rs:492、call.rs:880），与上游意图一致，无需处理。

---

#### 小结

| PR | 主题 | 基线状态 | sha | XLayer 实际影响 | 建议 |
|---|---|---|---|---|---|
| #25612 | estimateGas 用 effective tx gas cap | ❌ MISSING（v2.4.0 起） | `2ef00fd19d` | U19 bug 根因；当前被 op 侧 workaround（optimism `20636578d2`）抵消，Karst 未激活亦无触发面 | **建议 cherry-pick**（apply 干净），去掉对临时 workaround 的依赖 |
| #26067 | feeHistory reward 按 receipt gas 加权 | ❌ MISSING（v2.4.0 起） | `6d38c7373f` | 仅 EIP-8037 后有行为差异；XLayer 现为 no-op，但 feeHistory 是 XLayer 定价命脉，升级含 8037 基线前必须带上 | 随下次 rebase 带上（apply 干净） |
| #25258 | fillTransaction 默认 maxFeePerGas=2×basefee+tip | ❌ MISSING（v2.4.0 起） | `b8b2d3fbf0` | base fee≈0 ⇒ 新旧算式几乎等价，影响可忽略 | 低优先级，顺带即可（apply 干净） |
| #24387 | simulateV1 per-call gas=剩余 block gas | ✅ IN_BASE（v2.3.0 含） | `b8116b42b8` | 已在基线 | 无需动作 |
| EIP-7825 专项 | estimateGas × 7825 cap | ⚠️ 结构性缺口已被 op 侧补丁覆盖 | — | 当前无 bug（Karst 未配置/未激活；gasless 路径无交互；xlayer-reth 无覆写）；风险为未来激活 Karst 且丢失 workaround 时复发 | pick #25612 + Karst 升级 checklist 加回归测试 |

---

### 11.5 Txpool（tx admission & propagation，Medium）

判定基线：okx-reth `xl/reth-v2.3.0`（HEAD=25009c940f，= upstream v2.3.0 + okx 补丁）。gasless 补丁 commit：50b7955895（`feat(txpool): add gasless (zero fee-cap) transaction support`），改动面：`crates/transaction-pool/src/{config.rs, pool/best.rs, pool/pending.rs, pool/txpool.rs, validate/eth.rs}` + `crates/node/core/src/args/txpool.rs`。

#### #26113 — Account for blob tx access-list size ❌ MISSING（但对 XLayer 不适用）

- **状态**：❌ 不在基线。sha `7cb6d016d3`，`git tag --contains` → v2.4.0 / v2.4.1（v2.3.0 之后合入）。
- **修复内容**：`crates/transaction-pool/src/validate/eth.rs` 的 `is_eip4844` 分支中，oversized 检查原先只算 `input().len()`，修复后叠加 access-list 的 RLP 编码长度（`input + access_list.length()` 对比 `max_tx_input_bytes`），防止 blob tx 用超大 access list 绕过体积上限占用池内存。附带一个新单测。仅 1 个文件、+55/-9。
- **XLayer 适用性查证**：该路径在 XLayer 上**不可达**——
  1. op-reth（optimism monorepo `rust/op-reth`）的 `OpTransactionValidator::validate_one_with_state`（`crates/txpool/src/validator.rs:210`）在进入任何 eth 校验前就对 `is_eip4844()` 直接返回 `InvalidTransactionError::TxTypeNotSupported`；
  2. 更根本地，op-alloy 的 `OpPooledTransaction`（`crates/consensus/src/transaction/pooled.rs:22`）只有 Legacy/Eip2930/Eip1559/Eip7702 变体，**没有 EIP-4844 变体**，blob tx 连解码进 OP 池类型都不可能。
- **与 gasless 交互 / cherry-pick 评估**：与 gasless 补丁同文件（`validate/eth.rs`），但 hunk 不重叠——#26113 改的是 ~486 行的 4844 分支和文件尾部测试模块；gasless 改的是结构体字段（~97）、`minimum_priority_fee` 检查（~522）和 builder（~985+）。若要 pick 预计干净应用或仅上下文级微调。
- **建议**：可跳过，不必单独 cherry-pick（L2 禁 blob tx，代码不可达）；随后续整体升到 v2.4.x 自然带入，无 gasless 冲突风险。

#### #25412 — treat eth_sendRawTransaction as local path ⚠️ MISSING（需谨慎评估，不建议盲目 pick）

- **状态**：❌ 不在基线。sha `e1995a6ef8`，`git tag --contains` → v2.4.0 / v2.4.1。
- **修复内容**：`crates/rpc/rpc-eth-api/src/helpers/transaction.rs` 中默认的 `send_raw_transaction` 把入池 origin 从 `TransactionOrigin::External` 改为 `Local`（对齐 geth 语义：凡经本节点 RPC 提交的都算 local）；另一处 `crates/rpc/rpc/src/eth/helpers/transaction.rs` 仅为测试断言。
- **Local vs External 在 reth 池内的实际差异**（基于 v2.3.0 基线代码核对）：
  1. **准入过滤**：`minimum_priority_fee` 只对非 local 生效（`validate/eth.rs` ~522，正是 gasless 补丁插入豁免的那条检查）；反向地，`tx_fee_cap`（`--rpc.txfeecap`，默认 1 ETH）**只对 local 生效**——pick 后 RPC 提交的高费交易会开始被 fee-cap 拒绝，这是用户可见的行为变化。
  2. **反垃圾限制**：local 交易绕过 `max_account_slots` 每发送者槽位上限（`pool/txpool.rs:1879`）。
  3. **驱逐保护**：pending 池超限截断时跳过 local 交易（`pool/pending.rs:471` `!remove_locals && tx.is_local()`）。
  4. **传播**：`propagate_local_transactions` 默认 true，local 仍会 gossip；ordering 本身按 fee 排序，与 origin 无关。
- **op-stack / XLayer 场景分析**：XLayer 只有 sequencer 出块，**全部**用户流量都经 RPC 进入——replica 节点的 `OpEthApi::send_transaction`（op-reth `crates/rpc/src/eth/transaction.rs`）把 raw tx 转发给 sequencer 后仍以同一 origin 留存本地池；sequencer 收到的转发交易也是走它自己的 `eth_sendRawTransaction`。因此 pick 之后**整个池几乎全是 local 交易**：每发送者槽位限制和池溢出驱逐两道 DoS 防线同时失效。这在 L1（RPC 只是众多入口之一）是合理对齐，在 sequencer-only L2 上是明显的放大风险。
- **与 gasless 交互**：文件无重叠（gasless 不碰 rpc-eth-api），但语义有叠加——
  1. gasless 补丁对 `minimum_priority_fee` 的豁免条件是 `!is_local && ...`，pick 后 RPC 提交的 gasless tx 因 is_local 直接跳过该检查，豁免逻辑退化为仅对 p2p 来源生效（不冲突，但补丁的存在意义变弱）；
  2. 更需警惕：zero fee-cap 交易本来无法被更高出价挤出，再叠加 local 驱逐保护后，gasless 交易一旦入池几乎不可清退，池占用攻击成本进一步降低。
- **cherry-pick 冲突评估**：直接 pick 会有上下文冲突——v2.3.0 基线该处调用的是 `self.send_transaction(TransactionOrigin::External, ...)`（`helpers/transaction.rs:85`），而修复是写在 v2.4.x 重构后的 `send_pool_transaction` 上；手工适配只是一个词（External→Local），改动本身极小。
- **建议**：⚠️ 不建议单独 cherry-pick。如确需对齐 geth 语义（例如用户依赖 RPC 交易不被驱逐），应同时：确认 `--rpc.txfeecap` 配置符合预期、评估 sequencer 池的溢出保护（`max_account_slots`/截断均失效的后果）、并复核 gasless 豁免逻辑是否要同步收紧。否则维持 External 现状更安全。

#### #24494 — use tx_hash for transaction identity ✅ IN_BASE

- **状态**：✅ 在基线。sha `00f9bd2a9c`，`git tag --contains` → v2.3.0 / v2.4.0 / v2.4.1，`merge-base --is-ancestor` 确认 IN_BASE，无需处理。

#### #24474 — cached transaction hashes ✅ IN_BASE

- **状态**：✅ 在基线。sha `ec9b772dca`，`git tag --contains` → v2.3.0 / v2.4.0 / v2.4.1，`merge-base --is-ancestor` 确认 IN_BASE，无需处理。

#### 小结

| PR | 状态 | sha | 引入版本 | 与 gasless 冲突 | 建议 |
|---|---|---|---|---|---|
| #26113 blob tx access-list size | ❌ MISSING | `7cb6d016d3` | v2.4.0 | 同文件不同 hunk，可干净应用 | 跳过：OP validator 拒 4844 且 `OpPooledTransaction` 无 4844 变体，代码不可达 |
| #25412 sendRawTransaction as local | ❌ MISSING | `e1995a6ef8` | v2.4.0 | 文件无重叠；语义上削弱 gasless 豁免、放大 local 驱逐保护 | ⚠️ 不建议单独 pick：sequencer-only L2 上会使全池变 local，槽位限制+驱逐保护失效 |
| #24494 tx_hash identity | ✅ IN_BASE | `00f9bd2a9c` | v2.3.0 | — | 无需处理 |
| #24474 cached tx hashes | ✅ IN_BASE | `ec9b772dca` | v2.3.0 | — | 无需处理 |

---

### 11.6 RPC（Medium——RPC 副本正确性与稳定性）

基线：okx-reth 分支 `xl/reth-v2.3.0`（HEAD=`25009c940f`，= upstream v2.3.0 + okx 补丁）。判定方法：`git merge-base --is-ancestor <sha> HEAD`。

#### #24505 — Preserve legacy block RLP serialization ✅ IN_BASE

- **sha**：`dfd0148600`（`git tag --contains` → v2.3.0 / v2.4.0 / v2.4.1，随 v2.3.0 一并进入基线）
- **修复内容**：`crates/rpc/rpc-api/src/reth_engine.rs` 中 `RethNewPayloadInput`（`reth_newPayload` 的入参类型）原来用 `#[serde(untagged)]` 派生 Serialize，导致无 `bal` 时被序列化成 `{"block":"0x.."}` 对象而非旧版裸 RLP bytes 字符串 `"0x.."`。改为手写 `Serialize`：无 `bal` 时序列化为裸 bytes（legacy 形态），有 `bal` 时才输出 struct。
- **与 xlayer-reth legacy-rpc 的关系**：核对了 xlayer-reth `crates/legacy-rpc/src/service.rs`——legacy-rpc 是 **JSON-RPC 请求路由中间件**（按 `cutoff_block` 把 `eth_getBlockByNumber/ByHash`、`eth_getBlockReceipts`、`eth_getLogs` 等 pre-cutoff 请求整体转发到 legacy endpoint，透传对端 JSON），**自身不做任何 block RLP/JSON 序列化**；且路由表只覆盖 `eth_*`，不含 `reth_*` engine 命名空间。上游这个 fix 的表面其实是 `reth_newPayload` 客户端序列化，与 legacy-rpc 不同表面，既不会被我们的层遮蔽，也不需要在 legacy-rpc 侧同步同样的修复（xlayer-reth 全仓 grep 无 `RethNewPayloadInput`/`reth_newPayload` 引用）。
- **结论**：已在基线，无需动作。

#### #23600 — trace_filter: reject pruned-history ranges ✅ IN_BASE

- **sha**：`e9507f5907`（v2.3.0 / v2.4.0 / v2.4.1）
- **修复内容**：`crates/rpc/rpc/src/trace.rs` `trace_filter` 入口新增 7 行：用 `provider().earliest_block_number()` 校验 `start`，落在已 prune（EIP-4444）历史内直接返回 `PrunedHistoryUnavailable`。
- **结论**：已在基线。XLayer RPC 副本即便按归档配置（不开 prune），该检查也是 no-op，无副作用；若未来开 history expiry 则天然受保护。另注：`trace_filter` 不在 legacy-rpc 路由表内，pre-cutoff 高度的 trace 请求本就只能打到本地 reth，该守卫恰好覆盖这一缺口。

#### #25133 — trace_filter: buffer block replays ❌ MISSING

- **sha**：`d062b3fba4`（仅 v2.4.0 / v2.4.1）
- **修复内容**：重写 `crates/rpc/rpc/src/trace.rs` 的 `trace_filter`（+171/−68）：原实现按 `max_tracing_requests` 为 chunk 一次性 `try_join_all` 并发 replay 全部区块；改为 `futures::stream::iter(...).buffered(N)`，并发上限 `min(max_tracing_requests, TRACE_FILTER_BLOCK_BUFFER_SIZE=4)`，每 block replay 持 `acquire_trace_permit`，provider 按 `TRACE_FILTER_FETCH_CHUNK_SIZE=16` 分批读。
- **XLayer 影响**：直接命中本类别关注点——RPC 副本上大范围 `trace_filter`（配合默认较大的 `max_trace_filter_blocks`）会瞬时铺开大量 block replay，占满 blocking 线程池并把其他 RPC 拖垮；有并发上限后延迟换稳定。与 prune 无关（是否开 prune 都受益）。
- **cherry-pick 评估**：`git diff d062b3fba4^ HEAD -- crates/rpc/rpc/src/trace.rs` 为空 ⇒ 基线文件与该 commit 父版本逐字一致（其前置 #23600 已在基线），**可干净 cherry-pick，零冲突**。建议：优先级最高的一个，建议合入。

#### #24719 — eth_getProof: empty proof for empty tries ❌ MISSING

- **sha**：`3db05c4caf`（仅 v2.4.0 / v2.4.1）
- **修复内容**：`crates/trie/common/src/proofs.rs` 新增 `normalize_eip1186_empty_trie_proof`：空 trie 内部表示为单个 `0x80` 哨兵节点，此前 `eth_getProof` 会把它作为 proof 数组返回；修复后在 EIP-1186 响应边界剥掉哨兵，返回 `[]`，与 geth/规范一致（account proof 与 storage proof 两处），底层 proof 构造不动。附单测（`crates/trie/db/tests/proof.rs` +30）。
- **XLayer 影响**：与 basefee≈0 费率模型无交互，按常规评估——影响面是查询不存在账户/空 storage trie 的 `eth_getProof` 响应形状；对做 proof 校验的下游（轻客户端、跨链桥、索引器）属兼容性/正确性修复，且升级前后（v1.x 基线行为如与 geth 不一致）用户可感知。
- **cherry-pick 评估**：pre-image 与基线一致（diff 为空），**可干净 cherry-pick**。建议合入。

#### eth_simulateV1 correctness batch ⚠️ 部分 MISSING

在 `v2.3.0..v2.4.1` 范围内按 "simulate" 关键词 + 按 `simulate.rs` 路径双重搜索，**只有以下 2 个** simulate 相关 commit（任务提示中的 fork handling / block hashes / fee defaults / empty-block gap fill 若指其他 PR，则它们不在该范围——要么已随 v2.3.0 进基线，要么晚于 v2.4.1）：

1. **#25079 — fix nonce related fails in eth_simulate** ❌ MISSING，sha `ae0218dc93`（v2.4.0/v2.4.1）
   - `crates/rpc/rpc-eth-types/src/simulate.rs` + `error/api.rs`：新增 `EthSimulateError::NonceMaxValue`（错误码 INTERNAL_ERROR_CODE）；`resolve_transaction` 增加 `disable_nonce_check` 参数——validation-off 模式下 `nonce == u64::MAX` 的请求改置 0，绕过 revm 的 max-nonce guard，使行为与 `eth_call` 对齐。
   - cherry-pick：pre-image 与基线一致，**干净**。注意 `resolve_transaction` 签名变化（多一个 bool 参数）——xlayer-reth 侧 grep 无对 `resolve_transaction` 的直接调用，无适配成本。
2. **#25074 — align eth simulate missing block error code** ❌ MISSING，sha `7f05780ef1`（v2.4.0/v2.4.1）
   - `crates/rpc/rpc-eth-api/src/helpers/call.rs` + `simulate.rs`：base block 不存在时不再返回 `HeaderNotFound`，改为新 variant `EthSimulateError::BlockNotFound`（code -32000，message `block not found: <id>`），与 geth 对齐。
   - cherry-pick：**文本上依赖 #25079**（`git diff 7f05780ef1^ HEAD -- simulate.rs` 差异恰好等于 #25079 的改动）。按 `#25079 → #25074` 顺序 pick 则两者都干净；单独 pick #25074 会在 `simulate.rs` 冲突。
   - XLayer 影响：两者均为错误码/边界正确性，legacy-rpc 不路由 `eth_simulateV1`（不在路由表），请求全部走本地 reth，修复直接生效；风险低、收益是与 geth 客户端兼容。建议按序合入。

#### #24503 / #24499 — blocking-IO semaphore（eth_simulateV1 / eth_callMany）✅ IN_BASE

- **sha**：`f2d2bd2330`（#24503）、`b7a7a8a729`（#24499），均含于 v2.3.0 / v2.4.0 / v2.4.1
- **修复内容**：`crates/rpc/rpc-eth-api/src/helpers/call.rs` 中 `simulate_v1` 与 `call_many` 各加 2 行 `let _permit = self.acquire_owned_blocking_io().await;`，纳入 blocking-IO 信号量限流。
- **结论**：已在基线，一句话确认：RPC 副本上这两个重接口已受并发保护，无需动作。注意 #25074 的 diff 上下文以该 permit 行为锚点，进一步佐证 pick 顺序无碍（该行基线已有）。

#### 小结

| PR | 主题 | 基线状态 | sha | cherry-pick | 建议 |
|---|---|---|---|---|---|
| #24505 | reth_newPayload legacy RLP 序列化 | ✅ IN_BASE (v2.3.0) | `dfd0148600` | — | 无需动作；与 legacy-rpc 表面无关 |
| #23600 | trace_filter 拒绝 pruned 范围 | ✅ IN_BASE (v2.3.0) | `e9507f5907` | — | 无需动作 |
| #25133 | trace_filter 限流 block replay | ❌ MISSING | `d062b3fba4` | 干净，零冲突 | **建议合入**（副本稳定性，优先级最高） |
| #24719 | eth_getProof 空 trie 返回空 proof | ❌ MISSING | `3db05c4caf` | 干净，零冲突 | 建议合入（geth 兼容） |
| #25079 | eth_simulate nonce 修复 | ❌ MISSING | `ae0218dc93` | 干净 | 建议合入（先于 #25074） |
| #25074 | eth_simulate 缺块错误码 | ❌ MISSING | `7f05780ef1` | 依赖 #25079，按序则干净 | 建议随 #25079 合入 |
| #24503 | eth_simulateV1 blocking-IO 信号量 | ✅ IN_BASE (v2.3.0) | `f2d2bd2330` | — | 无需动作 |
| #24499 | eth_callMany blocking-IO 信号量 | ✅ IN_BASE (v2.3.0) | `b7a7a8a729` | — | 无需动作 |

---

### 11.7 P2P / Network

> 前提：以下影响均以"若节点间启用 EL p2p"为条件。若 EL p2p 完全关闭（纯 CL 派生同步），本节所有 PR 影响趋近于零；但鉴于 devnet 曾出现 op-reth EL-P2P 连不上导致 RPC 节点 EL-sync 卡死的先例，p2p 路径不可视为无关。

#### #25031 — fix(rlpx): bound mux outbound buffer fairly ✅ IN_BASE

- **sha**: `01cbe9bdad`（v2.3.0 / v2.4.0 / v2.4.1 均包含）
- 重写 `crates/net/eth-wire/src/multiplex.rs`（+267/-46），对 RLPx 多路复用的出站缓冲做公平限额，防止单个子协议撑爆缓冲。
- 已在基线，无需处理。

#### #24536 — fix(net): add eth/72 to supports_eth ✅ IN_BASE

- **sha**: `c3ced87e19`（v2.3.0 起包含）
- `crates/net/eth-wire-types/src/capability.rs` 一行级修复：`supports_eth` 漏判 eth/72 能力。
- 已在基线，无需处理。

#### #26265 — fix(net): advertise bound RLPx port in discv5 ENR ❌ MISSING

- **sha**: `7bd98ac642`（v2.4.0 起才包含，v2.3.0 基线没有）
- 修复内容：当配置的 RLPx TCP 端口为 0（OS 随机分配）时，discv5 ENR 里广播的是 0 而不是实际绑定端口，其他节点无法回连。改动为在 `crates/net/network/src/discovery.rs` 启动 discv5 前用实际监听端口回填（`set_bound_rlpx_port_if_unset`），纯新增 +47 行。
- **触发条件**：使用 discv5 发现 **且** RLPx 端口配置为 0。XLayer 节点通常固定 30303 类端口、且 sequencer↔RPC 走 trusted-peer 静态连接不依赖发现，命中概率低；主要影响端口随机分配的测试/devnet 场景。
- **建议**：可选 cherry-pick。已验证 `git apply --check --3way` 在基线 HEAD 上干净应用。

#### #24427 — fix(rpc): trusted-peer hostname resolution ✅ IN_BASE

- **sha**: `89c930a006`（v2.3.0 起包含）
- `admin_addTrustedPeer` / trusted-peer 配置支持 hostname（DNS）而非仅 IP，改动覆盖 `crates/net/network/src/peers.rs`、`crates/net/peers/src/lib.rs`、`crates/rpc/rpc/src/admin.rs` 等 7 个文件。
- **对 XLayer 最相关的一条**（sequencer↔RPC 常用 docker/k8s 域名做 trusted peer），好在已在基线，无需处理。

#### #24406 — fix(net): remove untrusted peers from resolver ✅ IN_BASE

- **sha**: `b05e68db85`（v2.3.0 起包含）
- #24427 的配套修复：peer 被移除 trusted 身份后从 `trusted_peers_resolver` 中同步清除，避免继续对其做 DNS 周期解析/重连。仅 +7 行。
- 已在基线，无需处理。

#### #26334 — fix(net): reset reputation when unbanning ❌ MISSING

- **sha**: `1e700d8b1f`（v2.4.0 起才包含）
- 修复内容：`admin_removePeer`/unban 后只从 ban list 移除，但 peer 的 reputation 仍是 banned 值，导致解禁不生效（很快又被判为 banned、无法重连）。修复在 `unban_peer_by_admin` 里同时 `peer.unban()` 并下发 `PeerAction::UnBanPeer`。
- **触发条件**：运维通过 admin RPC 手动解禁某 peer。若 XLayer 内部节点（尤其 trusted peer 之外的 RPC 互连）曾被误 ban，解禁操作会静默失败——这在排查"EL p2p 连不上"类问题时会造成困惑。
- **建议**：推荐 cherry-pick（运维可预期性问题）。已验证 3-way 干净应用；注意 diff 使用 let-chains 语法，基线为 edition 2024 无碍。

#### #25086 — fix(net): respect full-tx broadcast peer count ❌ MISSING

- **sha**: `fdcd3ac510`（v2.4.0 起才包含）
- 修复内容：`crates/net/network/src/transactions/mod.rs` 中全量交易广播的 peer 计数用了 `peer_idx > max_num_full`（含被 propagation policy 跳过的 peer 且存在 off-by-one），实际全量广播的 peer 数可能偏多/偏少。修复改为独立计数 `num_full_peers < max_num_full`。
- **触发条件**：EL p2p 启用且节点做交易 gossip。XLayer 上交易主要经 sequencer 直收（RPC 转发），p2p tx 广播占比取决于拓扑；偏差只影响带宽/传播效率，不影响正确性。
- **建议**：低优先级，可随批量 cherry-pick 带上。3-way 干净应用。

#### #25921 — fix(net): wire max pending imports setting ❌ MISSING

- **sha**: `d24629dedd`（v2.4.0 起才包含）
- 修复内容：CLI 的 `--max-pending-imports` 参数一直没有接线，`TransactionsManager` 固定用 `DEFAULT_MAX_COUNT_PENDING_POOL_IMPORTS`。修复把该值加入 `TransactionsManagerConfig` 并从 `crates/node/core/src/args/network.rs` 贯通。
- **触发条件**：仅当运维显式设置过 `--max-pending-imports`（此前是静默无效）。XLayer 若未使用该参数则完全无影响；若配置文件里写了它，需知道它在 v2.3.0 基线上不生效。
- **建议**：低优先级。确认部署参数里是否用到该 flag 即可决定是否 cherry-pick；3-way 干净应用。

#### 小结

| PR | 状态 | sha | 修复 | XLayer 影响（若启用 EL p2p） | 建议 |
|---|---|---|---|---|---|
| #25031 | ✅ IN_BASE | `01cbe9bdad` | rlpx mux 出站缓冲公平限额 | — | 无需处理 |
| #24536 | ✅ IN_BASE | `c3ced87e19` | supports_eth 补 eth/72 | — | 无需处理 |
| #26265 | ❌ MISSING | `7bd98ac642` | discv5 ENR 广播实际绑定端口 | 仅端口 0 + discv5 场景，低 | 可选 pick |
| #24427 | ✅ IN_BASE | `89c930a006` | trusted peer 支持 hostname | 对 sequencer↔RPC 静态连接关键，已在基线 | 无需处理 |
| #24406 | ✅ IN_BASE | `b05e68db85` | resolver 移除非 trusted peer | 配套修复，已在基线 | 无需处理 |
| #26334 | ❌ MISSING | `1e700d8b1f` | unban 时重置 reputation | admin 解禁静默失效，干扰 p2p 排障 | 推荐 pick |
| #25086 | ❌ MISSING | `fdcd3ac510` | 全量 tx 广播 peer 数计数修正 | 仅传播效率偏差，低 | 低优先级 |
| #25921 | ❌ MISSING | `d24629dedd` | `--max-pending-imports` 接线 | 仅显式用了该 flag 才受影响 | 查部署参数后定 |

4 个缺失补丁均已通过 `git apply --check --3way` 验证可在基线 HEAD 干净应用，可作为一组低风险 cherry-pick 批次处理。

---

### 11.8 清单外的其他风险点

#### 11.8.1 上游 v2.3.0..v2.4.1 修复筛查（PR 清单之外）

范围内共 209 个 commit，`grep -iE "fix|bug"` 命中 56 条；扣除其他小节已覆盖的 PR、纯 L1 共识（beacon/blob/era/Amsterdam L1 侧）、CLI/docs/bench/JIT(revmc)/nix/docker 等无关项后，以下是清单之外、认为对 XLayer 有实际风险的修复：

| sha | PR | 修复内容 | 为什么与 XLayer 相关 | 风险等级 |
|---|---|---|---|---|
| 9cc0bbd768 | #26332 | fix(engine): 在 sparse trie 任务内部构建 prune retention set——将保留集从外部传入的 `TriePrefixSetsMut` 改为按 `ExecutedBlock` 列表在任务内构建（`None`=不裁剪，`Some(vec![])`=仍裁剪），此前构造方式有误可能错误裁剪内存中的 sparse trie 缓存 | 直接命中状态根计算 + sparse trie 缓存裁剪路径，是 #26325/#26327（stalled proofs 系列）之外**未被清单覆盖**的同系列修复；且它大幅重构 `crates/engine/tree/src/tree/payload_processor/mod.rs`——正是 okx fork 补丁最重的文件 | 高 |
| 8bbc5e6b7f | #26111 | refactor(trie): 用 prefix sets 保留 sparse trie 路径——虽标 refactor，实为 sparse trie 路径保留正确性系列（#25738/#26139 的前置），改动 `crates/trie/sparse/src/state.rs` 与 engine tree | sparse trie 保留/复用逻辑与 XLayer 状态根性能路径强相关；v2.3.0 缺此改动意味着停留在旧的保留语义 | 中 |
| 178fc26923 | #25609 | fix(deps): memmap2 升至 0.9.11（上游标为 fix 的依赖修复） | static file 读写全部走 mmap；okx fork 自己就带两个 static-file mmap 补丁（映射 offset、非零 genesis 区块范围），同一子系统的底层依赖缺陷值得跟进确认 changelog | 中 |
| ae0218dc93 | #25079 | fix(rpc): 修复 `eth_simulateV1` 中 nonce 相关的失败（rpc-eth-types/simulate.rs） | XLayer 对外提供 eth RPC，`eth_simulateV1` 是钱包/基础设施常用接口，nonce 处理错误直接造成模拟结果错误 | 中 |
| 7f05780ef1 | #25074 | fix(rpc): 对齐 `eth_simulate` 缺块时的错误码 | 同上，仅影响错误码兼容性（客户端按错误码分支时行为不一致） | 低 |
| dd77224620 | #25324 | fix(rpc): capability retention 按 QUANTITY 序列化（rpc-eth-types/capabilities.rs） | RPC 返回格式与 geth 兼容性问题，影响面小 | 低 |
| e72588ef5e | #25268 | fix(engine): 缓存已验证 payload 的 block access lists（BAL） | BAL 属 Amsterdam/EIP-7928 语义，XLayer 当前硬分叉未激活则为死代码；但 engine tree 的 payload 验证缓存结构被改，升 v2.4 时留意 | 低 |
| 92aeca4d6c | #26273 | fix(trie): sparse trie 并行工作继承 tracing span | 仅可观测性——不修此项则 sparse trie 并行段的 trace 断链，排障时误导 | 低 |
| 603ce0b42c | #25541 | fix(trie): 消除 sparse arena HashSet 告警日志 | 仅日志噪音，可能污染告警面板 | 低 |
| 0be4e28b24 | #26078 | fix(download): 模块化 snapshot 下载支持文件归档 | 仅当用 reth 自带 `download` 引导节点才相关；XLayer 若走自有快照流程则无影响 | 低 |

**筛查中的一个结构性发现**：reth v2.3.0/v2.4.1 主仓 `crates/` 下已**不含任何 op-\* crate**（`git ls-tree` 为空），XLayer 的 OP 栈执行层代码全部在 deps/optimism 子模块里。因此"upstream reth v2.3.0..v2.4.1"这个范围**天然覆盖不到 OP 专属修复**（op-payload-builder、op-txpool、op-rpc 等）；OP 侧的同类 fix 筛查需要另行对照 deps/optimism 所跟的上游，本节及 PR 清单均不构成对 OP 侧的完整覆盖。

#### 11.8.2 okx fork 本地补丁地图与未来 v2.4.x 冲突热区

okx-reth 分支 `xl/reth-v2.3.0`（v2.3.0 merge + okx 补丁）共 7 个实质补丁：

| 补丁 | 子系统 | 触碰的关键文件 |
|---|---|---|
| 7680d6d8a9 fix(chain-state): avoid engine deadlock from locks held across the trie compute | chain-state / 延迟状态根 | crates/chain-state/src/deferred_trie.rs、state_trie_overlay.rs |
| 4a0688a46f refactor(engine): wrap PayloadProcessor in Arc\<Mutex\> | engine tree | crates/engine/tree/src/tree/payload_processor/mod.rs（±300 行）、payload_validator.rs |
| c87fab7eba feat(trie,engine): preserve StateRootHandle across payload processor spawns | engine tree + 并行状态根 | payload_processor/mod.rs、payload_validator.rs、crates/trie/parallel/src/state_root_task.rs |
| 359c1d03df fix(static-file): correct block range for non-zero genesis blocks | static-file | crates/static-file/types/src/segment.rs、storage/provider static_file/{manager,writer}.rs |
| 7395055c24 fix(staticdb): fix static file in-memory mapping offset | static-file | storage/db static_file/cursor.rs、provider static_file/manager.rs |
| 50b7955895 feat(txpool): add gasless (zero fee-cap) transaction support | txpool | transaction-pool pool/{txpool,pending,best}.rs、validate/eth.rs、config.rs |
| 25009c940f fix(engine): construct PayloadProcessorInner in cache test | engine tree（测试） | payload_processor/mod.rs |

对照上游 v2.3.0..v2.4.1 对这些文件的改动密度，冲突热区排序：

- **热区一（最高危）：engine tree**。`payload_validator.rs` 上游改了 **24 次**、`payload_processor/mod.rs` **18 次**、`state_root_task.rs` **8 次**。okx 最重的三个补丁（Arc\<Mutex\> 重构、StateRootHandle 保留、死锁修复配套）全压在这几个文件上；且上文 #26332 恰好重写了 payload_processor 的 spawn/裁剪结构。升 v2.4 时这三个补丁大概率无法自动合并，需按新结构重实现。
- **热区二（补丁失去宿主文件）**：上游 #26139 (`chore: consolidate lazy trie data`) 在 v2.4.x 中**整体删除了 `crates/chain-state/src/deferred_trie.rs`**（连同 trie/common/src/lazy.rs），合并进新文件 `crates/trie/common/src/trie_data.rs`。okx 的引擎死锁补丁 7680d6d8a9 正落在被删文件上——升级时不是解冲突而是**整段重移植**，且需重新验证死锁场景（锁的持有结构已被上游重排）。
- **低冲突区**：static-file 三个补丁触碰的文件上游 v2.4.x 几乎零改动（0 次），gasless 触碰的 txpool 文件仅 0–1 次（validate/eth.rs 4 次），预计可干净 rebase。

#### 11.8.3 xlayer-reth 工作区未提交改动

值得注意两点：(1) `deps/optimism` 子模块指针前移（486e52a→8e15824，引入 rust/xlayer-kms 目录），与 `bin/node/src/main.rs` 新增约 311 行 KMS 密钥预解析逻辑（clap 解析前把 `kms:<name>` 引用换成明文，p2p key 经 memfd 传递不落盘）、未跟踪的 `.okone-cicd/dockerfile/Dockerfile.kms` 属于同一个**未提交的 KMS feature**——它混在升级验证分支的工作区里，注意不要随升级 PR 一起带入，且密钥经 argv/env 传递的做法应单独走安全评审；(2) 除此之外无与 reth 升级本身相关的风险信号。

## 12. 参考

- 官方 op-node 发布说明：https://docs.optimism.io/releases/op-node
- upgrade-19（Karst）通知：https://docs.optimism.io/notices/upgrade-19
- 上游 diff 命令（在 op-node fork 仓库执行）：
  - `git diff op-node/v1.16.7 op-node/v1.19.2 -- op-node/`（生产完整 delta）
  - `git diff op-node/v1.19.0 op-node/v1.19.2 -- op-node/`（main 增量）
  - `git log --oneline v0.1.5..main`（fork 本地改动）



