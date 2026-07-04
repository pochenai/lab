# L1 升级 Demo:用 OPCM 官方流程原子新增一个 Dispute Game Type

## 目标(Goal)

用 **OP 官方的 OPCM 那一套**给运行中的链**原子新增**一个 dispute game type,并验证生效。具体走 op-deployer 的 `manage add-game-type-v2` 命令 —— 它在 OPCM V2 里其实就是 **OPCM `upgrade` 流程的别名**:由 OPCM 在一次 `opcm.upgrade()` 调用里**自动部署 + 注册**目标 game type 的实现(原子)。

> 这与上层笔记 [op_l1l2_upgrade.md](../../op_l1l2_upgrade.md) §4.1.2 的"OPCM 引擎 × 任务模板 × TOML"一致。上游较新版本提供独立的 `OPCM.addGameType()`(`AddGameTypeTemplate.sol` 封装它);本 fork(OPCM v7.x)**没有** `addGameType`,官方做法就是用 `add-game-type-v2`(= `upgrade`)。

> 全部使用本地 devnet 标准测试账户,**任何私钥都不要用于真实网络。**

---

## 为什么不是手动 setImplementation

直接用 owner 私钥调 `DisputeGameFactory.setImplementation` 能跑通,但**绕过了 OPCM**:不会由 OPCM 部署规范的 `FaultDisputeGame`、不经过 OPCM 的配置校验与原子性,失去了"标准化 + 原子部署"的意义。本 demo 因此走 OPCM。

---

## 原理:add-game-type-v2 = OPCM upgrade,产出 calldata 给 owner 执行

```
op-deployer manage add-game-type-v2 --config cfg.json --outfile out.json
   └─ 跑 OPCM upgrade 脚本(模拟 EVM)→ 产出 opcm.upgrade(UpgradeInputV2) 的 calldata
      out.json = [ { "to": <prank=l1ProxyAdminOwner>, "data": "0x8a847e2e…" } ]   # selector 0x8a847e2e = opcm.upgrade

执行(无 Safe 版):owner 私钥 → Transactor.DELEGATECALL(opcm, data)
   └─ OPCM.upgrade 在 Transactor(=DGF owner)上下文里 delegatecall 执行
      → 原子地部署 + 注册新 game type 的 FaultDisputeGame 实现
```

生产环境里这段 `data` 由 ProxyAdminOwner 的 **Safe 以 DelegateCall** 执行;本 devnet `OWNER_TYPE=transactor`,owner 是 `Transactor` 合约,我们就用它的 `DELEGATECALL(target,data)`(owner-only)执行同一段 calldata —— 单私钥、无 Safe。

### 为什么必须 delegatecall(不能用普通 call)

两个叠加原因,缺一不可:

1. **OPCM 强制**:`upgrade()` 第一行 `_onlyDelegateCall()`,只要 `address(this) == opcm` 就 revert(见 `packages/contracts-bedrock/src/L1/opcm/OPContractsManagerV2.sol:230,1083`)。普通 `CALL` 进 OPCM 时 `address(this)==opcm` → revert。
2. **权限身份**:OPCM 自己无任何权限。`upgrade()` 内部调 `DisputeGameFactory.setImplementation` / `ProxyAdmin.upgrade`,这些 onlyOwner 调用的 `msg.sender = address(this)`。只有 delegatecall 让 `address(this)` = Transactor(= DGF owner / ProxyAdminOwner),内部调用才通过。

即 owner 必须"把身份借给 OPCM"。这正是生产环境 Safe 用 `operation=DelegateCall(1)` 的原因;`Transactor.CALL(opcm,data)` 会两道关都过不了。

---

## 前置条件(Prerequisites)

- 一条已起来的 devnet(`cd $DEVNET_DIR && make run`)。
- `cast`(Foundry)、`jq`、`docker` 已安装;`op-contracts:latest` 镜像存在(devnet 构建时已生成,含 `op-deployer` 与 forge-artifacts)。

核对到的链上事实(本 devnet 实测):

| 项 | 值 |
|----|----|
| OPCM v2 | `0x9611b3093e7d02269cd9277eee5c8a93e9188c5d` |
| SystemConfig proxy | `0x774445cd570a1e3852d4c54430533752ca3e836d` |
| DisputeGameFactory | `0x150ea83a7fc8da01398cac6abc96c7cecfef5eb9` |
| l1ProxyAdminOwner / prank | `0x5FbDB2315678afecb367f032d93F642f64180aa3`(`Transactor`,owner = anvil #0) |
| 现有 game 集 | 仅 `PERMISSIONED_CANNON`(type 1) |
| 本 demo 新增 | `CANNON`(type 0,permissionless) |
| absolutePrestate(复用链上) | `0x038512e02c4c3f7bdaec27d00edf55b7155e0905301e1a88083e4e0a6764d54c` |

---

## 配置:[../config/l1/add_game_type_config.json](../config/l1/add_game_type_config.json)

`UpgradeOPChainInput`(op-deployer `embedded` 包格式):`prank` / `opcm` / `upgradeInput{systemConfig, 7×disputeGameConfigs, extraInstructions}`。要点:

- 7 个 game 配置必须齐全(顺序:Cannon0 / PermissionedCannon1 / CannonKona8 / SuperCannon4 / SuperPermCannon5 / SuperCannonKona9 / ZK10);要启用的 `enabled:true` 并给 prestate,其余 `enabled:false`+`initBond:0`。
- `extraInstructions: [{ "key":"PermittedProxyDeployment", "data":"<base64('DelayedWETH')>" }]` —— OPCM v<8.0.0 升级时允许部署 DelayedWETH 代理的白名单指令。
- prestate / proposer / challenger 复用链上现值,避免 upgrade 校验失败。

---

## 步骤(Steps)

```bash
export DEVNET_DIR=/home/po/now/xlayer-toolkit/devnet
export L1_RPC_URL=http://localhost:8545
export PRIVATE_KEY=$(cast wallet private-key --mnemonic "test test test test test test test test test test test junk" --mnemonic-index 0)  # Transactor owner (account #0)
export VERIFY_GAME_TYPE=0     # 期望新增的 type

./run.sh
```

`run.sh` 会:① docker 跑 `op-deployer manage add-game-type-v2`(`--override-artifacts-url` 指向镜像内 forge-artifacts)生成 calldata;② 用 `Transactor.DELEGATECALL(opcm, data)` 执行;③ 校验 `gameImpls(0)` 变为 OPCM 部署的实现。

> **gas 注意**:L1 dev geth 每笔 tx gas cap = `2^24 = 16777216`;且 `Transactor.DELEGATECALL` **不冒泡内层 revert**,导致 `eth_estimateGas` 会低估 → 必须显式 `--gas-limit`(脚本默认用 geth cap)。否则会出现"外层 status=1、内层被吞、状态没变"的假成功。

---

## 验证(Verification)— 实测结果(devnet 已通过)

```
==> OPCM      = 0x9611b3093e7d02269cd9277eee5c8a93e9188c5d
==> prank     = 0x5FbDB2315678afecb367f032d93F642f64180aa3   (Transactor / executor)
==> BEFORE gameImpls(0) = 0x0000000000000000000000000000000000000000
==> generated calldata: to=0x5fbd… selector=0x8a847e2e (== opcm.upgrade)
==> Executing via Transactor.DELEGATECALL(opcm, data) ...
    status 1, gasUsed ~1.4M, logs 非空(SystemConfig / OwnershipTransferred / DGF 事件)
==> AFTER  gameImpls(0) = 0xDF72886AA88C9AB09d5749a0f474745E84F57944
==> OK: OPCM atomically deployed + registered game type 0
==>     impl.version()=2.4.2  impl.gameType()=0
```

核心断言:**`gameImpls(0)` 由 `0x0` → OPCM 部署的真实 `FaultDisputeGame`(version 2.4.2)**,且 `initBonds(0)` 被设置 —— 全部在一次 `opcm.upgrade()` 内原子完成,由官方 `add-game-type-v2` 生成的 calldata 驱动。

---

## 产物([../config/l1/](../config/l1/),索引见 [../config/README.md](../config/README.md))

仿照 [QuarkChain 升级测试文档](https://github.com/QuarkChain/pm/blob/main/L2/contract_upgrade_test.md)的"配置即文档",L1 的输入/计划/回执集中在 `config/l1/`(`intent.toml` 为 L1/L2 共享,放在 `config/` 根):

| 文件(相对 op-grade/) | 内容 |
|------|------|
| [config/intent.toml](../config/intent.toml) | 部署 intent 快照(含 L1 角色 + L2 `l2GenesisKarstTimeOffset`) |
| [config/l1/add_game_type_config.json](../config/l1/add_game_type_config.json) | `add-game-type-v2` 的输入(`UpgradeOPChainInput`:7×game 配置) |
| [config/l1/add_game_type_output.json](../config/l1/add_game_type_output.json) | op-deployer 产出的 `opcm.upgrade` calldata(`{to, data}`)——L1 的"计划" |
| [config/l1/upgrade-artifacts.json](../config/l1/upgrade-artifacts.json) | **合并回执**:地址 + 新增 game type + calldata(selector/data)+ execution(delegatecall / txHash / gasUsed)+ inputs 指针 |

`config/l1/upgrade-artifacts.json` 由 `run.sh` 每次执行后生成,实测样例:

```json
{
  "chain": "l1",
  "addresses": { "opcm": "0x9611…", "l1ProxyAdminOwner_prank": "0x5FbD…", "disputeGameFactory": "0x150e…", "systemConfig": "0x7744…" },
  "addedGameType": { "id": 0, "deployedImpl": "0xDF72886AA88C9AB09d5749a0f474745E84F57944", "implVersion": "2.4.2", "initBond": "80000000000000000 [8e16]" },
  "calldata": { "generatedBy": "op-deployer manage add-game-type-v2", "function": "opcm.upgrade(...)", "selector": "0x8a847e2e", "to": "0x5fbd…", "data": "0x8a847e2e…" },
  "execution": { "method": "delegatecall", "via": "Transactor.DELEGATECALL(opcm,data)",
                 "reason": "OPCM._onlyDelegateCall + inner DGF/ProxyAdmin calls need msg.sender==owner",
                 "gasLimit": 16777216, "txHash": "0x34be…", "gasUsed": "1257471" },
  "inputs": { "intentToml": "../config/intent.toml", "upgradeConfig": "add_game_type_config.json", "opDeployerOutput": "add_game_type_output.json" }
}
```

---

## References

- op-deployer `manage add-game-type-v2`(= upgrade 别名):`op-deployer/pkg/deployer/manage/add_game_type.go`、`pkg/deployer/upgrade/`
- 输入格式:`op-deployer/pkg/deployer/upgrade/embedded/upgrade.go`(`UpgradeOPChainInput` / `UpgradeInputV2` / `DisputeGameConfig`)
- OPCM upgrade 入口:`src/L1/opcm/OPContractsManagerV2.sol`(`upgrade`,selector `0x8a847e2e`)
- 上游模板(供对照,本 fork 无 addGameType):https://github.com/ethereum-optimism/superchain-ops/blob/main/src/template/AddGameTypeTemplate.sol
