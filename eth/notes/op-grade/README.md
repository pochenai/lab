# OP Stack 升级 Demo(L1 / L2)

两个独立、可在本地 devnet 跑通的升级实验,配套 [op_l1l2_upgrade.md](../op_l1l2_upgrade.md) 的理论笔记。

两个 demo 都走 **OP 官方升级机制**(不手工拼装):

| Demo | 演示什么 | 官方工具 / 触发方式 | 目录 |
|------|---------|---------|------|
| **L1:新增 game type** | OPCM 在一次 `opcm.upgrade()` 内**原子部署+注册**新 dispute game type | `op-deployer manage add-game-type-v2`(= OPCM upgrade)生成 calldata → owner(Transactor)以 DelegateCall 执行 | [l1-add-gametype/](l1-add-gametype/) |
| **L2:激活 Karst** | 激活 Karst → kona 注入官方 `karst_nut_bundle.json` → `L2CM.upgrade()` 原子升级全部 predeploy | op-deployer 设 `karst_time` + 共识层(kona)按 spec 在 fork 激活块自动注入 | [l2-activate-karst/](l2-activate-karst/) |

> ✅ **两个 demo 均已在本地 devnet(`make run`)实测通过**:
> - **L1**:官方 `add-game-type-v2` 生成 `opcm.upgrade`(selector `0x8a847e2e`)calldata,执行后 `gameImpls(0)` 由 `0x0` → OPCM 部署的 `FaultDisputeGame`(v2.4.2)——原子完成,未手动 setImplementation;
> - **L2**:kona 日志出现 `Sequencing karst upgrade block`,predeploy 升级到 Karst 版本。
>
> 各 doc 末尾附实测输出。

## 关键约定

- **编辑/构建目标**:devnet 实际从 `OPTIMISM_DIR=/home/po/now/xlayer-reth/deps/optimism`(`.env` 的 `OP_STACK_LOCAL_DIRECTORY`)构建 op-stack / kona / NUT bundle。所有改动落在这里。
- **私钥**:全部使用本地 devnet 标准测试账户(`l1ProxyAdminOwner` = anvil/foundry 账户 `#0`)。通过 `export PRIVATE_KEY=...` 传入,**不写进仓库,绝不用于真实网络**。
- **构建开关(省时)**:两个 demo 都**不需要** `SKIP_OP_CONTRACTS_BUILD=false`(最慢的那个)。
  - L1:复用已构建的 `op-contracts:latest` 镜像里的 `op-deployer` + forge-artifacts 生成 calldata,不重编。
  - L2:Karst bundle 字节码已固化在 JSON,无需重编合约;需要 `SKIP_OP_STACK_BUILD=false`(重生成配置)+ `SKIP_KONA_BUILD=false`(确保 kona 带 Karst)。

## 快速上手

```bash
# 先把 devnet 起起来(L2 需已激活 Karst:见 l2 子目录 ./run.sh activate)
cd $DEVNET_DIR && make run

# L1:官方 OPCM add-game-type-v2 → 原子新增 game type
cd l1-add-gametype
export PRIVATE_KEY=$(cast wallet private-key --mnemonic "test test test test test test test test test test test junk" --mnemonic-index 0)
./run.sh

# L2:验证 Karst NUT bundle 已注入
cd ../l2-activate-karst && ./run.sh verify
```

各自 README/doc 见子目录。理论背景见上层 [op_l1l2_upgrade.md](../op_l1l2_upgrade.md)。

## 配置与产物 [config/](config/)（索引见 [config/README.md](config/README.md)）

仿照 [QuarkChain 升级测试文档](https://github.com/QuarkChain/pm/blob/main/L2/contract_upgrade_test.md)的"配置即文档",输入/计划/回执集中存放,L1/L2 分目录:

| 文件 | 角色 |
|------|------|
| [config/intent.toml](config/intent.toml) | 共享:部署 intent(L1 角色 + L2 `l2GenesisKarstTimeOffset`) |
| [config/l1/add_game_type_config.json](config/l1/add_game_type_config.json) | L1 输入:`UpgradeOPChainInput` |
| [config/l1/add_game_type_output.json](config/l1/add_game_type_output.json) | L1 计划:`opcm.upgrade` calldata |
| [config/l1/upgrade-artifacts.json](config/l1/upgrade-artifacts.json) | L1 回执:地址+calldata+execution(delegatecall/txHash) |
| [config/l2/karst_nut_bundle.json](config/l2/karst_nut_bundle.json) | L2 计划:kona 内嵌的官方 NUT bundle |
| [config/l2/karst_nut_bundle.generated.json](config/l2/karst_nut_bundle.generated.json) | L2:当前源码重生成(provenance 对照) |
| [config/l2/fork_lock.karst.toml](config/l2/fork_lock.karst.toml) | L2:bundle 完整性锁(sha256+commit) |
| [config/l2/l2-upgrade-artifacts.json](config/l2/l2-upgrade-artifacts.json) | L2 回执:激活块/注入 tx 数/ConditionalDeployer impl 指针 before→after |

> **L1 有官方回执、L2 没有**:L1 是特权交易(有 tx/receipt + StandardValidator);L2 由共识层确定性执行,可信性靠"确定性 bundle + `fork_lock` 锁 + provenance 重生成"前移到执行前,无需事后回执。`l2-upgrade-artifacts.json` 是我们额外记录的观测结果。详见 [config/README.md](config/README.md)。
