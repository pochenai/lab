# L2 升级 Demo:激活 Karst,触发 NUT bundle 注入(L2CM 升级全部 predeploy)

## 目标(Goal)

在 devnet 上**激活 Karst 硬分叉**,让共识客户端 **kona** 在 Karst 激活块自动注入 `karst_nut_bundle.json`。该 bundle 会:部署 `ConditionalDeployer` + 全部 predeploy 新实现 + `L2ContractsManager`,最后一笔调用 `L2ProxyAdmin.upgradePredeploys()` → `delegatecall` → `L2CM.upgrade()`,**一次性原子升级所有 predeploy**。

这正是我们想验证的"最新的 Karst NUT bundle 注入方式"。**不需要新增任何 predeploy** —— 复用现成的 Karst bundle 即可演示完整的 L2CM 升级链路。

> 背景对照见上层笔记 [op_l1l2_upgrade.md](../../op_l1l2_upgrade.md) §5.2 / §6。

### 这就是官方流程(对照 spec)

本 demo **完全遵循** OP 官方 L2 升级执行规范 [l2-upgrades-1-execution.md](https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/l2-upgrades-1-execution.md),且只用 OP 已有的脚本/工具,没有任何手工拼装:

- **bundle 由官方脚本生成**:`karst_nut_bundle.json` 来自 `just generate-nut-bundle`(`GenerateNUTBundle.s.sol`),已提交并被 `fork_lock.toml` 哈希锁定;
- **fork 时间由 op-deployer 设置**:我们只在 intent 里加 `l2GenesisKarstTimeOffset`,`make run` 时 op-deployer 据此把 `karst_time` 写进 rollup/genesis 配置;
- **执行由共识层完成**:按 spec,运维方**唯一动作就是设定 fork 激活时间**;到点后 kona(CL)自动把 bundle 各笔作为 deposit 交易注入激活块并执行(`L2ProxyAdmin.upgradePredeploys → delegatecall → L2CM.upgrade`)。L2 侧**没有、也不需要**一个运维手动运行的"执行脚本"—— 这正是 NUT 机制的设计。

---

## 前置条件(Prerequisites)

- devnet toolkit 在 `$DEVNET_DIR`(默认 `/home/po/now/xlayer-toolkit/devnet`),`.env` 已设 `SEQ_CL=kona`。
- devnet 实际构建的 optimism 在 `$OPTIMISM_DIR`(默认 `/home/po/now/xlayer-reth/deps/optimism`,即 `.env` 的 `OP_STACK_LOCAL_DIRECTORY`)。
- `cast`(Foundry)已安装。

核对到的关键事实:

| 项 | 值 | 出处 |
|----|----|------|
| Karst intent 字段 | `l2GenesisKarstTimeOffset` | op-deployer `deploy_config.go`(测试见 `deploy_config_test.go`) |
| 当前 devnet 最新 fork | Jovian(`l2GenesisJovianTimeOffset = "0x0"`),**无 Karst** | `config-op/intent.toml.bak` |
| intent 生成 | `2-deploy-op-contracts.sh:171` 把 `intent.toml.bak` 拷成 `intent.toml` 再 sed | devnet 脚本 |
| kona 已 wire Karst | `Hardforks::KARST.txs()` 从 bundle 生成 31 笔交易 | `rust/kona/.../hardforks/src/forks.rs:67,93` |
| bundle 来源 | 编译期 `build.rs` 读 `op-core/nuts/bundles/karst_nut_bundle.json` | `rust/kona/.../hardforks/build.rs` |
| 注入入口 | `L2ProxyAdmin.upgradePredeploys`(`onlyDepositor`)→ delegatecall → `L2CM.upgrade()` | `src/L2/L2ProxyAdmin.sol` / `src/L2/L2ContractsManager.sol` |
| 由谁注入 | kona 在 Karst 激活块作为 deposit 交易注入 | — |

---

## 步骤(Steps)

### 0. 生成 bundle(官方流程,模拟完整链路)

复刻 `op-core/nuts/README.md` 的两-PR + 校验流程:

```bash
./run.sh generate          # PR1: just generate-nut-bundle (GenerateNUTBundle.s.sol)
# 可选:PROVENANCE=1 ./run.sh generate   # 额外跑 just nut-provenance-verify karst(在锁定 commit 重生成+字节比对)
```

`generate` 会:
- 跑官方 `GenerateNUTBundle.s.sol` → 产出当前源码的 bundle 到 [../config/l2/karst_nut_bundle.generated.json](../config/l2/karst_nut_bundle.generated.json);
- 拷贝 kona 实际内嵌的 committed bundle 到 [../config/l2/karst_nut_bundle.json](../config/l2/karst_nut_bundle.json);
- 抓取 [../config/l2/fork_lock.karst.toml](../config/l2/fork_lock.karst.toml)(`sha256` + 生成它的源 `commit`);
- 比对 generated vs committed。**实测二者不同**:committed 锁定在 commit `f2e5bfe4`,当前工作树已漂移 —— 这正是官方 `just nut-provenance-verify karst` 要"**在锁定 commit 重生成**再字节比对"的原因(我们当前树直接比对会因源码漂移而不同,属正常)。

> 官方两-PR 流程参见 `op-core/nuts/README.md`:PR1 `generate-nut-bundle` → `snapshots/upgrades/current-upgrade-bundle.json`;PR2 `nut-snapshot-for <fork>` → `op-core/nuts/bundles/<fork>_nut_bundle.json` + 更新 `fork_lock.toml`(脚本不自动跑 PR2,它会改动被跟踪文件)。

### 1. 激活 Karst(写入 intent 模板)

```bash
export DEVNET_DIR=/home/po/now/xlayer-toolkit/devnet
export OPTIMISM_DIR=/home/po/now/xlayer-reth/deps/optimism
export KARST_OFFSET=0x3c          # 60s:链先跑 Jovian,60s 后进入 Karst(便于 before/after 对比)

./run.sh activate
```

`activate` 会在 `intent.toml.bak` 的 Jovian 行后**幂等地**插入:

```toml
      l2GenesisJovianTimeOffset = "0x0"
      l2GenesisKarstTimeOffset = "0x3c"      # Karst fork activation (added for demo)
```

> 为什么用非零 offset:`0x0` 会让 Karst 与 Jovian 一起在创世激活,看不到"升级前→升级后"的对比。用 60s 让链先在 Jovian 上跑一会儿再跨入 Karst。

### 2. 确保重新编译(关键)

在 `$DEVNET_DIR/.env` 里:

```bash
SKIP_OP_STACK_BUILD=false     # 重新生成 genesis/rollup 配置与合约
SKIP_KONA_BUILD=false         # 确保 kona 镜像里带上 Karst NUT bundle 的注入逻辑
```

> 若你的 `kona:latest` 镜像已是从当前 `$OPTIMISM_DIR` 构建的(已含 Karst),可保留 `SKIP_KONA_BUILD=true`;不确定就设 `false` 重编一次最稳妥 —— 否则链跨入 Karst 时 CL 不知道怎么注入,会卡在激活块。
>
> **`SKIP_OP_CONTRACTS_BUILD` 保持 `true` 即可(无需开那个慢构建)**:Karst 升级用的全部 predeploy 实现字节码早已固化在 `karst_nut_bundle.json` 里(已提交、CI 哈希锁定),kona 直接注入;我们没有改动任何合约源码,所以不必重建 op-contracts 镜像。

### 3. 起 devnet

```bash
cd $DEVNET_DIR && make run
```

### 4. 验证(跨过 Karst 激活时间后)

```bash
# 回到本目录
export L2_RPC_URL=http://localhost:8123
./run.sh verify
```

---

## 验证(Verification)

`run.sh verify` 写出回执 [../config/l2/l2-upgrade-artifacts.json](../config/l2/l2-upgrade-artifacts.json),核心断言:

1. **ConditionalDeployer(`0x42..2C`)的 EIP-1967 实现指针 `0x0 → <impl>`** —— 它的 proxy 字节码在 genesis 就有(`cast code` 永远非空,不可作信号);真正的 Karst 证据是其**实现指针在激活块被设上**,因为 bundle 在激活块部署并接线了它;
2. **激活块的交易数 = 32**(31 笔 NUT + 1 笔 L1Info),而普通块只有 0–1 笔 —— 即 kona 在该块注入了整批 bundle;
3. kona 日志出现 `Sequencing karst upgrade block`。

(L1Block/GasPriceOracle 的 `version()` 在 Karst 前后**未变**,因为 Karst 没 bump 这两个 predeploy 的版本号 —— 所以版本号不是好的 before/after 信号,实现指针才是。)

### 实测结果(devnet,已通过)

kona sequencer 日志(铁证):

```
🍴 Scheduled Hardforks:  -> Karst Activation Time: 1781874633
Sequencing karst upgrade block
```

`config/l2/l2-upgrade-artifacts.json` 关键字段(实测):

```json
{
  "activation": { "karstTime": 1781874633, "genesisBlock": "8593921", "activationBlock": 8593981,
                   "injectedTxCountInBlock": 32, "injectedBy": "kona (consensus layer), depositor account" },
  "verification": {
    "conditionalDeployerImplPointer": {
      "before": "0x0000…0000",
      "after":  "0x000000000000000000000000906835344844979ffd3a752eaa23728d513db00b",
      "note": "0x0 before Karst -> impl set after (proves the bundle deployed+wired it)"
    },
    "konaEvidence": "... -> Karst Activation Time: 1781874633; ... Sequencing karst upgrade block;"
  }
}
```

手动 before/after(最能说明"升级"),EIP-1967 实现槽 = `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`:

```bash
CD=0x420000000000000000000000000000000000002C
SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
cast storage $CD $SLOT --block <激活块-1> --rpc-url http://localhost:8123   # 预期 0x0
cast storage $CD $SLOT                      --rpc-url http://localhost:8123   # 预期非零(impl 已设)
```

激活块 = 第一个 `timestamp >= karst_time` 的块(`run.sh verify` 用 rollup.json 的 `karst_time` + `l2_genesis.number` 二分查找)。

---

## 产物([../config/l2/](../config/l2/),索引见 [../config/README.md](../config/README.md))

| 文件(相对 op-grade/) | 角色 |
|------|------|
| [config/intent.toml](../config/intent.toml) | 部署 intent;Karst 激活(`l2GenesisKarstTimeOffset`)在此 |
| [config/l2/karst_nut_bundle.json](../config/l2/karst_nut_bundle.json) | **计划**:kona 内嵌执行的官方 bundle(committed),= L1 的 opcm.upgrade calldata |
| [config/l2/karst_nut_bundle.generated.json](../config/l2/karst_nut_bundle.generated.json) | 当前源码重生成(provenance 对照) |
| [config/l2/fork_lock.karst.toml](../config/l2/fork_lock.karst.toml) | bundle 完整性锁(`sha256` + 源 `commit`) |
| [config/l2/l2-upgrade-artifacts.json](../config/l2/l2-upgrade-artifacts.json) | **观测回执**:激活块/注入 tx 数/impl 指针 before→after/kona 佐证 |

## 说明:这条路径与 L1 的区别

- 整个 L2 升级**没有多签、没有运维传参**:由 kona(共识层)在 Karst 激活块自动注入 bundle,`L2CM.upgrade()` 无参数、从链上现状 `gather` 配置回填。
- 验证形态也不同:L1 用运行时 validator(post-execution),L2 靠**确定性可重生成的 bundle + CI 哈希锁 + fork 测试**在升级前保证(详见 [op_l1l2_upgrade.md](../../op_l1l2_upgrade.md) §6)。
- **OP 本身不产 L2 升级回执**:L2 不是特权交易(没有 tx/receipt),是共识层确定性执行,所以"计划"= bundle(+ `fork_lock` 锁 + provenance),"是否执行"= 读链。`l2-upgrade-artifacts.json` 是我们为 demo 额外记录的观测结果,不是 OP 官方产物(见 [../config/README.md](../config/README.md))。

---

## References

- `op-core/nuts/bundles/karst_nut_bundle.json` + `op-core/nuts/README.md`(生成/快照/校验流程)
- 官方 recipe:`just generate-nut-bundle`(`packages/contracts-bedrock/justfile`)、`just nut-snapshot-for <fork>` / `just nut-provenance-verify <fork>`(根 `justfile` → `ops/scripts/`)
- 生成脚本:`packages/contracts-bedrock/scripts/upgrade/GenerateNUTBundle.s.sol`
- `rust/kona/crates/protocol/hardforks/src/{forks.rs,karst.rs,nut_bundle.rs,build.rs}`
- `src/L2/L2ProxyAdmin.sol`(`upgradePredeploys`)、`src/L2/L2ContractsManager.sol`(`upgrade`)
- op-deployer fork 字段:`op-deployer/pkg/deployer/state/deploy_config.go`
- Spec: L2 Upgrades — Execution:https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/l2-upgrades-1-execution.md
