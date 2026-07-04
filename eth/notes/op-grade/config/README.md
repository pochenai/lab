# config/ — 升级的"计划(intent/plan)"与"回执(artifacts)"

仿照 [QuarkChain 升级测试文档](https://github.com/QuarkChain/pm/blob/main/L2/contract_upgrade_test.md)的"配置即文档",把两条升级的输入/输出集中存放。每个文件的相对路径与角色:

## 共享

| 文件 | 角色 |
|------|------|
| [intent.toml](intent.toml) | devnet 部署 intent 快照。L1 角色地址 + **L2 Karst 激活**(`l2GenesisKarstTimeOffset`)都在这里。部署/fork 调度由 op-deployer 消费它。 |

## L1(OPCM add-game-type / upgrade)

| 文件 | 角色 | 类比 |
|------|------|------|
| [l1/add_game_type_config.json](l1/add_game_type_config.json) | **输入**:`UpgradeOPChainInput`(7×DisputeGameConfig),喂给 `op-deployer manage add-game-type-v2` | intent/plan 输入 |
| [l1/add_game_type_output.json](l1/add_game_type_output.json) | **计划(plan)**:op-deployer 产出的 `opcm.upgrade(...)` calldata(`{to, data}`,selector `0x8a847e2e`) | = L2 的 NUT bundle |
| [l1/upgrade-artifacts.json](l1/upgrade-artifacts.json) | **回执(result)**:地址 + 新增 game type + calldata + execution(delegatecall/txHash/gasUsed)+ inputs 指针 | 由 `run.sh` 执行后生成 |

## L2(Karst NUT bundle / L2CM)

| 文件 | 角色 | 类比 |
|------|------|------|
| [l2/karst_nut_bundle.json](l2/karst_nut_bundle.json) | **计划(plan)**:kona 实际内嵌执行的官方 bundle(committed) | = L1 的 opcm.upgrade calldata |
| [l2/karst_nut_bundle.generated.json](l2/karst_nut_bundle.generated.json) | 当前源码重生成的 bundle(provenance 对照用) | — |
| [l2/fork_lock.karst.toml](l2/fork_lock.karst.toml) | bundle 的完整性锁:`sha256` + 生成它的源 `commit` | OP 官方的"可信凭据" |
| [l2/l2-upgrade-artifacts.json](l2/l2-upgrade-artifacts.json) | **回执(observed result)**:激活块 / 注入 tx 数 / ConditionalDeployer impl 指针 before→after / kona 日志佐证 | 对应 L1 的 upgrade-artifacts;**注意这是我们自产的观测记录,OP 本身不产 L2 回执**(见下) |

## 为什么 L1 有"官方回执"而 L2 没有

- **L1** 是特权操作者/多签发的交易 → 有 tx、有 receipt,op-deployer + StandardValidator 提供事后核验。
- **L2** 由共识层在 fork 块**确定性执行**(kona 注入 deposit 交易),没有"操作者交易"可言。它的可信性前移到**执行前**:bundle 确定性 + `fork_lock.toml` 哈希锁 + `nut-provenance-verify`(在锁定 commit 重生成、字节比对)。"是否执行" = 读链(激活块的注入交易 + predeploy 状态)。所以 OP 不产 L2 回执;`l2-upgrade-artifacts.json` 是我们为 demo 额外记录的观测结果。
