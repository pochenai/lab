# OP Stack L2 Hardfork Upgrade Mechanism

> Ecotone / Fjord / Granite / Holocene / Isthmus / Jovian / Interop 全都在用的统一范式。
> 后续任何 L2 fork都应该遵循这套模型。

---

## TL;DR

- **一切 L2 fork 激活都等价于"激活块里多了几笔协议合成的 deposit tx"。**
- **CL 合成，EL 执行。** 两端对 fork timestamp / intent / deployer / bytecode 的理解必须位对齐。
- **deployer 地址**是 CL 用来 CREATE 预部署合约的伪 EOA；它不是预部署合约地址本身，也不是 EL 关心的东西。
- **`SourceHash` 用协议域 2 和 intent 字符串的确定性哈希**，保证全网节点算出同一笔 upgrade deposit 的同一个 hash。
- **不存在"EL 偷偷做状态变更"的 fork**——这是 OP Stack 刻意的架构选择，replay safety 的根源。

## 1. 核心原理：一切状态变化都必须通过一笔 tx

OP Stack 在设计 L2 时定下一条硬规则：

> **L2 状态只能通过 block 中的 transaction 变化，没有别的路径。**

这条规则非常严格，它否决了"EL 在 hardfork 那一刻直接往 state 里写字节码 / 改 storage"的所有捷径。原因只有一个——**可重放性（replay safety）**：

- 一个刚同步的节点从 L1 开始重建 L2 状态时，它把每个 L2 block 的 tx 列表依次执行即可。
- 如果 fork 激活涉及"EL 独立做的 side effect"，那重建就必须信任节点版本、执行时机和原节点一致——任何代码漂移都会让状态根发散，产生硬分叉。
- 而只要所有激活动作都打包成标准 tx 放进 block 里，那 block 本身就是执行的"证据"；新节点照样处理完就拿到相同状态。

所以 OP 把 fork 激活时需要做的所有事情——部署新合约、升级代理、开关功能位、注入 EIP-4788 的 beacon-roots 预部署——**全部用 "upgrade deposit transaction" 这种标准 tx 表达**，塞进激活块的 tx 列表里。

---

## 2. 谁来合成这些 tx？—— CL（op-node）

关键点：这些 upgrade deposit tx **不从 L1 来，也不从用户 mempool 来**。它们由 **CL（op-node）在推导 L2 block 时，按协议规则凭空合成**，追加到当前要发出的 payload 的 tx 列表尾部。

在 op-node 里，这事发生在 `attributes.go` 的 `PreparePayloadAttributes` 阶段：

```go
// op-node/rollup/derive/attributes.go (简化)
var upgradeTxs []hexutil.Bytes
if ba.rollupCfg.IsEcotoneActivationBlock(nextL2Time) {
    upgradeTxs, _ = EcotoneNetworkUpgradeTransactions()
}
if ba.rollupCfg.IsFjordActivationBlock(nextL2Time) {
    fjord, _ := FjordNetworkUpgradeTransactions()
    upgradeTxs = append(upgradeTxs, fjord...)
}
// …Isthmus / Jovian / Interop 同理…

// tx 列表的最终装配顺序：
//   [0]      L1 Attributes deposit (每块一笔，记 L1 info)
//   [1..N]   User deposits from L1
//   [N+1..]  Upgrade deposits (只有激活块会非空)
txs := make([]hexutil.Bytes, 0, 1+len(depositTxs)+len(upgradeTxs))
txs = append(txs, l1InfoTx)
txs = append(txs, depositTxs...)
txs = append(txs, upgradeTxs...)
```

这套 tx 列表通过 Engine API（`engine_forkchoiceUpdatedVX` 的 `PayloadAttributesVX.transactions`）交给 EL，EL 当作普通 block payload 来执行。**EL 不知道也不关心这些 tx 是 CL 合成的**——它只执行标准 `TxDeposit`。

---

## 3. Deposit Transaction 基础：为什么不签名、四类来源、金额如何保证

在深入 upgrade deposit 具体字段之前，先铺好 deposit tx 的通用模型——所有四种 deposit（用户桥接、L1 info、fork upgrade、interop invalidated）都遵循同一套规则。

### 3.1 为什么 deposit 不需要 ecdsa 签名

常规 EIP-1559 / legacy tx 的授权模型是"私钥签 digest → `ecrecover` 出 from → 用 from 做 nonce / balance 检查"。签名 = 授权。

Deposit tx 走的是完全不同的授权模型：**授权来自 L1，不来自 L2 私钥。**

- L1 上某个事件（用户调 Portal、L1 block 新增、CL 判定 fork 激活）已经发生；
- 每个 op-node 独立从 L1 拉取相同的数据，按协议规则**合成字节一致的 deposit tx**；
- 这笔 tx 的合法性 = "它是 L1 事件的确定性 derivation 结果"——不是由签名证明，而是由"全网节点用同一套规则算出同一个东西"证明。

Deposit tx 里承载这个证明的字段是 `SourceHash`。它由协议域 + 源数据的确定性哈希组成：

```go
// op-node/rollup/derive/deposit_source.go
const (
    UserDepositSourceDomain        = 0
    L1InfoDepositSourceDomain      = 1
    UpgradeDepositSourceDomain     = 2
    InvalidatedBlockSourceDomain   = 4
)

// 四种 SourceHash 公式：
UserDeposit:     keccak(0 ‖ keccak(l1_block_hash ‖ log_index))
L1InfoDeposit:   keccak(1 ‖ keccak(l1_block_hash ‖ seq_number))
UpgradeDeposit:  keccak(2 ‖ keccak(intent_string))
Invalidated:     keccak(4 ‖ output_root)
```

任何节点给定相同 L1 block / 相同协议常量，必然算出同一 `SourceHash`。这是 replay safety 的底层锚。

### 3.2 四类 deposit 的对照

| Domain | 种类 | `From` 字段含义 | 谁合成 | 每块数量 | 位置 |
|---|---|---|---|---|---|
| `0` | **User deposit** | L1 上真实调用 Portal 的地址（合约要加 alias offset） | CL 读 L1 log 解码 | 0..N | `txs[1..N]` |
| `1` | **L1Info deposit** | `0xDeaDDeaDDeaDDeaDDeaDDeaDDeaDDeaDDeAD0001`（伪地址） | CL 每块合成 | 恰好 1 | `txs[0]` |
| `2` | **Upgrade deposit** | `0x4210000000000000000000000000000000000000 + N`（伪 deployer） | CL 仅激活块合成 | 激活块 M 笔；其他块 0 笔 | `txs[N+1..N+M]` |
| `4` | **Invalidated deposit**（interop） | 协议预留 | CL 在 interop 块失效回滚时合成 | 罕见 | 视场景 |

区分重点：

- **数据来源**：user deposit 的数据是"L1 上 `TransactionDeposited` 事件的内容"；L1Info deposit 的数据是"当前 L1 block 的 hash/number/timestamp/baseFee"；upgrade deposit 的数据是"CL 源码里硬编码的常量 + 合约 bytecode"。
- **`From` 的性质**：user 是 L1 真实 EOA 或 aliased 合约地址；系统 deposit 的 from 是**协议预留的伪 EOA**（`0xdead...0001`、`0x4210...N`），没有私钥，也永远不会收到外部转账。
- **是否占 block 固定位置**：L1Info 永远 `txs[0]`；user 紧接其后；upgrade 再后；user txs（正常 ECDSA tx）最后。

### 3.3 用户 deposit 的金额怎么保证对的

这是 L1↔L2 桥的安全核心。整条信任链：

**Step 1：L1 上把钱"锁进"Portal 合约**

用户在 L1 调 `OptimismPortal.depositTransaction{value: X}(...)`：

```solidity
// OptimismPortal2.sol (简化)
function depositTransaction(address _to, uint256 _mint, uint64 _gas, bool _isCreation, bytes _data) payable {
    address from = msg.sender;
    if (msg.sender != tx.origin) {
        from = AddressAliasHelper.applyL1ToL2Alias(msg.sender);  // 合约 from 加 offset
    }

    // 关键约束：事件里的 _mint 必须等于用户真实付进来的 ETH
    require(_mint == msg.value, "mint must equal msg.value");

    emit TransactionDeposited(from, _to, DEPOSIT_VERSION,
        abi.encodePacked(_mint, _value, _gas, _isCreation, _data));
}
```

ETH 留在 Portal 合约里（L1 侧真的被"锁"住）。

**Step 2：每个 op-node 独立读 L1 log**

```go
// op-node/rollup/derive/deposit_log.go::UnmarshalDepositLogEvent
dep.From  = common.BytesToAddress(ev.Topics[1][12:])
dep.To    = common.BytesToAddress(ev.Topics[2][12:])     // 或 nil（isCreation）
dep.Mint  = uint256(opaqueData[0:32])
dep.Value = uint256(opaqueData[32:64])
dep.Gas   = uint64(opaqueData[64:72])
dep.Data  = opaqueData[73:]

source := UserDepositSource{ L1BlockHash: ev.BlockHash, LogIndex: uint64(ev.Index) }
dep.SourceHash = source.SourceHash()
```

所有 op-node 从同一条 L1 链拉 receipts，解码出**字节完全一致**的 `DepositTx`。

**Step 3：EL 执行 deposit → 凭空铸 ETH**

EL 执行 deposit tx 时，对 `Mint` 字段做特殊动作：

```
state.balance[dep.From] += dep.Mint       // L2 侧铸新 ETH
// 再按正常 tx 规则执行 from -> to 的转账 / 合约调用
```

L1 锁 X ETH ↔ L2 铸 X ETH，1:1 对应。

**四层防线说明"为什么没人能伪造金额"**：

1. **L1 Portal 合约的 `require`**：`_mint == msg.value` 强制"log 里的 mint = 实际转入的 ETH"。想在 log 里写假的 `mint` = 攻击 L1 本身。
2. **L1 block 是全网共识**：恶意 op-node 伪造 log，需要它的 L1 节点同谋；L1 节点间的 P2P 会立刻发现 block hash 对不上。
3. **`SourceHash` 抗碰撞**：`keccak(0 ‖ keccak(l1_block_hash ‖ log_index))`，L1 block hash 真，SourceHash 就确定。
4. **L2 state root 共识**：恶意节点把假 deposit 塞进它的 L2 block，state root 会 ≠ 诚实节点的 state root。P2P 拒收，fraud-proof / zk-proof 能反证。

整条信任链：

```
L1 安全（以太坊主网共识）
  → OptimismPortal 合约的 require 条件
    → L1 block 的 log（所有 op-node 读同一份）
      → Deposit tx 的 mint 字段（全网一致）
        → L2 执行时 mint 动作（1:1）
          → L2 state root 一致（P2P / proof 共识）
```

**没有一环靠 "deposit tx 的签名"** —— 签名这条路径根本不参与。

### 3.4 Deposit 和 ECDSA tx 在 EL 里走的两套规则

| 规则 | ECDSA tx (0x00/01/02/04) | Deposit tx (0x7E) |
|---|---|---|
| 签名验证 | ecrecover 必须成功 | 跳过 |
| nonce 检查 | `from.nonce == tx.nonce` | 跳过（不推进 from.nonce） |
| 扣 gas 费 | `from.balance -= gas * price` | 不扣（L1 侧已付） |
| 可以 mint ETH | 不可以 | 可以（`mint` 字段凭空铸出） |
| 执行失败 | nonce 推进、gas 扣除、state 回滚 | state 回滚但 deposit 仍视为"已消费"，不可重发 |
| 可被 sequencer 审查跳过 | 可以（mempool tx 拒收） | 不可以（L1 用户 deposit 是 force-include） |

差异根源就是"授权来自 L1，不来自 L2 key"的模型。

### 3.5 L2 block 里的完整 tx 序列

结构上固定，不是 EL "先跑一轮 deposit 再跑一轮 user tx"——**整个 tx 列表是单一序列**，EL 按 index 逐笔执行：

```
[0]           L1Attributes deposit                   系统（每块一笔）
[1..N]        User deposits from L1 Portal logs     用户（L1 上有人 deposit 才有）
[N+1..N+M]    Upgrade deposits                      系统（仅激活块非空）
[N+M+1..]     User txs from mempool                 正常 ECDSA tx
```

前缀区（deposits）由 L1 确定性推导；后缀区（user txs）由 sequencer 从 mempool 打包。两段走不同的 tx 处理规则但在同一个 state transition 里。

### 3.6 常被问到的几个细节

**(a) 合约地址的 L1→L2 alias**  
如果 L1 调用者是合约（非 EOA），Portal 做 `applyL1ToL2Alias(addr) = addr + 0x1111000000000000000000000000000000001111`。防止 L1 合约冒充 L2 同地址合约产生跨链消息伪造。EOA 不做 alias（共享 L1/L2 同地址 + 私钥，无伪造风险）。

**(b) L1Info deposit 的伪 `From`**  
`0xDeaDDeaDDeaDDeaDDeaDDeaDDeaDDeaDDeAD0001`。L2 的 `L1Block` 预部署合约里有 `require(msg.sender == this address)`，只允许这个伪地址调用来更新 L1 block info——把系统和用户通道彻底隔离。

**(c) L1 reorg 怎么处理**  
L1 有 reorg 风险。op-node 维护三级 head 指针：`unsafe` / `safe` / `finalized`。只有 finalized 的 L1 block 里的 deposit 才会被 derivation 用来构造 finalized L2 block。L1 reorg 到 deposit 不在 canonical 链，对应的 L2 block 会被 reset & re-derive。

**(d) Gas 谁付**  
user deposit 的 gas 是 L1 那一刻用户就付掉的（Portal 按 L2 gas price 收 L1 gas）。L2 执行时用这个 gas limit，不向 from 扣 ETH（因为 from 在 L2 上可能刚 mint 完第一笔，或者是代理合约）。执行失败也不退——这是 OP Stack 的设计，和 ECDSA tx 不一样。

---

## 4. Upgrade deposit tx 长什么样

它就是一笔 type-`0x7E` 的 deposit 交易，结构和 L1 来的 user deposit 完全一样，区别在 `from` 字段和 `SourceHash` 的计算方式。看 Ecotone 的实际构造（`op-node/rollup/derive/ecotone_upgrade_transactions.go`）：

```go
deployL1BlockTransaction := types.NewTx(&types.DepositTx{
    SourceHash: deployL1BlockSource.SourceHash(),           // (a)
    From:       L1BlockDeployerAddress,                     // (b) 0x4210...0000
    To:         nil,                                        // (c) CREATE
    Mint:       big.NewInt(0),
    Value:      big.NewInt(0),
    Gas:        375_000,
    Data:       l1BlockDeploymentBytecode,                  // (d) 合约 runtime bytecode
})
```

逐字段展开：

### (a) `SourceHash` —— 协议域的确定性哈希

`SourceHash` 是 deposit tx 的 replay 防护字段，每种 deposit 来源有自己的 "domain"：

| Domain ID | 来源 | 计算方式 |
|---|---|---|
| `0` | `UserDeposit`（L1 转账） | `keccak(0 ‖ keccak(l1_tx_hash ‖ log_index))` |
| `1` | `L1InfoDeposit`（每块第一笔） | `keccak(1 ‖ keccak(l1_block_hash ‖ seq_number))` |
| `2` | `UpgradeDeposit` | **`keccak(2 ‖ keccak(intent_string))`** |

对 upgrade deposit 来说，`intent_string` 就是协议约定的明文，比如 `"Ecotone: L1 Block Deployment"`、`"Fjord: GasPriceOracle Deployment"`。**它是协议常量，每个节点都独立算出同一个 `SourceHash`。**

```go
// op-node/rollup/derive/deposit_source.go
const UpgradeDepositSourceDomain = 2

func (dep *UpgradeDepositSource) SourceHash() common.Hash {
    intentHash := crypto.Keccak256Hash([]byte(dep.Intent))
    var domainInput [64]byte
    binary.BigEndian.PutUint64(domainInput[24:32], UpgradeDepositSourceDomain)
    copy(domainInput[32:], intentHash[:])
    return crypto.Keccak256Hash(domainInput[:])
}
```

这就是 replay-safe 的核心保证：任何节点在重建 L2 时，只要它知道 fork 的 `intent` 列表，就能精确还原出每一笔 upgrade deposit，和原生产节点字节一致。

### (b) `From` —— "deployer" 协议地址

`From` 字段用一组协议预留的确定性地址，OP 在 `0x4210000000000000000000000000000000000000 + N` 命名空间按 fork 顺序递增分配：

```
0x4210...0000   L1BlockDeployer                (Ecotone)
0x4210...0001   GasPriceOracleDeployer         (Ecotone)
0x4210...0002   Fjord deployer 1
0x4210...0003   Fjord deployer 2
0x4210...0004   Granite deployer
0x4210...0005   Holocene deployer
0x4210...0006   Isthmus deployer 1
0x4210...0007   Jovian GasPriceOracle deployer
---- Base/EIP-8130 复用这条命名空间继续往后排 ----
0x4210...0008   K1Verifier deployer
0x4210...0009   P256Verifier deployer
0x4210...000a   WebAuthn Verifier deployer
0x4210...000b   AccountConfiguration deployer
0x4210...000c   DelegateVerifier deployer
0x4210...000d   DefaultAccount deployer
```

为什么每个合约一个 deployer？因为 CREATE 地址由 `CREATE(from, nonce)` 推出，而 deposit tx 不维护 nonce（固定为 0），所以**一个 deployer 只能 CREATE 一个合约**——`CREATE(0x4210...0000, 0)` 就是 L1Block 合约的最终地址。想部署 N 个合约，就得用 N 个 deployer EOA。

重要：**这些 `0x4210...` 地址从来没被"生成"过**，它们只是一串协议约定的常量。EL 执行 deposit tx 时不检查 from 有没有签名（deposit 本来就没 secp256k1 签名），所以 CL 可以合法地用这些地址 CREATE 合约。

### (c) `To` —— CREATE 或者代理升级

Upgrade deposit 有两类：

**类 A：部署新合约**（`To == nil`）  
`CREATE(From, 0)` 落地到一个确定性地址，`Data` 就是合约的 runtime bytecode。对应 `deployL1BlockTransaction` 那笔。

**类 B：升级既有代理指向新实现**（`To == <proxy_address>`）  
对应 `updateL1BlockProxy`：

```go
updateL1BlockProxy := &types.DepositTx{
    SourceHash: updateL1BlockProxySource.SourceHash(),
    From:       common.Address{},                           // 0x00...000
    To:         &predeploys.L1BlockAddr,                    // 0x4200...0015 的代理
    Gas:        50_000,
    Data:       upgradeToCalldata(newL1BlockAddress),       // proxy.upgradeTo(0xCREATE_addr)
}
```

`From` 用零地址代表 "system"，`To` 指向既有的 proxy 预部署，`Data` 是 ABI 编码的 `upgradeTo(implementation)` 调用——让代理把 implementation 切换到刚才 CREATE 出来的新地址。

### (d) `Data` —— 字节码或 ABI 调用

- 类 A：合约 runtime bytecode，**硬编码在 op-node 源码里**（`l1BlockDeploymentBytecode`）。整段十六进制字面量 ~1-2KB。编译产物入版本控制，保证所有节点看到同一份字节码。
- 类 B：selector + 参数，通过 `abi` helper 编码。

---

## 5. 激活块的完整 tx 布局

走一遍激活 Ecotone 时的 block `N`（`nextL2Time == ecotone_time`）：

```
[0]  L1Attributes deposit         L1 info 注入 (每块都有，非 fork 专属)
[1]  UpgradeDeposit               deploy new L1Block implementation
     from=0x4210...0000, to=nil, data=l1BlockDeploymentBytecode
[2]  UpgradeDeposit               deploy new GasPriceOracle implementation
     from=0x4210...0001, to=nil, data=gpoDeploymentBytecode
[3]  UpgradeDeposit               L1Block proxy.upgradeTo(newL1Block)
     from=0x00..0,    to=L1BlockProxy
[4]  UpgradeDeposit               GasPriceOracle proxy.upgradeTo(newGPO)
     from=0x00..0,    to=GasPriceOracleProxy
[5]  UpgradeDeposit               gpo.setEcotone()   打开 Ecotone 计费逻辑
     from=L1InfoDepositer, to=GasPriceOracleProxy
[6]  UpgradeDeposit               EIP-4788 beacon-roots deploy
     from=EIP4788From, to=nil, data=eip4788CreationData
[7..] User deposits from L1 (如有)
[n..] User txs (sequencer 从 mempool 打包)
```

激活块之后所有块回归正常：只有 `[0]` 的 L1Attributes + 用户 tx。Upgrade deposits **只在激活块这一个高度出现一次**——`IsEcotoneActivationBlock` 的判定精确要求 `parent_time < ecotone_time <= next_time`。

---

## 6. 两端的 chainspec 必须位对齐

这是 CL 和 EL 对激活的共同锚点：

- **op-node 的 `rollup.json`**：`ecotone_time`、`fjord_time` 等字段是 unix timestamp（秒）。CL 用它判定激活块、触发 upgrade tx 合成。
- **op-reth 的 `OpChainSpec` / reth-optimism-forks::`OpHardfork`**：同样的 timestamp，EL 用来切换 EVM 语义（gas schedule、预编译可用性、receipt 格式等）。

**任何 drift 都是硬分叉**。典型事故：op-node 配置成 `ecotone_time = 1710374400`，op-reth 配置成 `ecotone_time = 1710374401`，那中间那一秒 CL 会发 upgrade deposits、EL 不承认 Ecotone 语义——节点直接 reorg 或卡死。

运维层面这通常靠：
- `superchain-registry` 仓库托管每条链的 chain config（两端都从这里读）
- 或者 deploy-config 工具在发布时同时生成 op-node rollup.json 和 op-reth chainspec.json

---

## 7. 一次 fork 对应的代码改动清单（op-node / op-reth）

每次加一个 fork，两端都要动的地方基本固定：

### op-node (Go / CL)

| 文件 | 改动 |
|---|---|
| `rollup/chain_spec.go` / `rollup/types.go` | 加 `IsFooActivationBlock(t)` / `IsFoo(t)` 判定 + rollup.json 解析字段 |
| `rollup/derive/foo_upgrade_transactions.go` | **新文件**：硬编码 deployer 地址、`SourceHash` intent 字符串、合约 runtime bytecode、ABI 编码调用数据，导出 `FooNetworkUpgradeTransactions()` |
| `rollup/derive/attributes.go` | 在 `PreparePayloadAttributes` 里插一个 `if IsFooActivationBlock(...) { append(...) }` |
| `rollup/derive/deposit_source.go` | 如果引入新的 source-hash 域（罕见），加域常量 |
| `op-batcher/...` | span-batch / channel 编码若引入新 tx 类型需要透传（如 EIP-8130 的 0x7B），加入白名单 |

### op-reth (Rust / EL)

| 文件 | 改动 |
|---|---|
| `reth-optimism-forks::OpHardfork` | 加 `Foo` variant |
| `reth-optimism-chainspec` | rollup.json / chainspec.json 解析加 `foo_time` 字段 |
| `reth-optimism-evm` | EVM handler 按 timestamp 切换 gas schedule / 预编译可用性 |
| `reth-optimism-primitives` | 如果 fork 改了 receipt / tx 格式，Compact 编码要动 |
| `reth-optimism-rpc` | receipt / tx JSON 渲染按 fork 分支 |

特别注意：**EL 不需要知道 deployer 地址、bytecode、intent string**——这些全是 CL 的职责。EL 只要执行收到的 deposit tx 就能拿到对的状态。

---

## 8. 为什么这套方案能保证 replay safety

把 replay 过程切开看：

```
新节点从 L1 genesis 开始同步:
  for each L1 block b:
      1. 读出 b 里 OP-specific 的数据 (batcher txs, deposits, ...)
      2. 做 derivation: 输出一组 L2 block attributes
      3. 对每一个 attributes:
         a. 调用 PreparePayloadAttributes —— 里面嵌了 upgrade tx 合成逻辑
         b. 判定 IsEcotoneActivationBlock → 自动 append EcotoneNetworkUpgradeTransactions()
         c. 交给 EL via engine_forkchoiceUpdated / engine_newPayload
      4. EL 按 tx 列表顺序执行每一笔 deposit
         → CREATE 落地预部署合约
         → proxy.upgradeTo 切换实现
         → setEcotone 打开功能位
      5. 拿到新的 state root
```

只要两个输入相同——**同一份 op-node 源码 + 同一份 chainspec**——每一步都确定性，最终状态根必然一致。**没有任何"只在第一次激活时发生"的 side effect**，所有逻辑都是激活块里那几笔 tx 的函数。

对比"EL 自己改状态"的反例：

```
激活块 N:
  EL 看到 block.timestamp >= ecotone_time:
    在 pre_block_hook 里:
        state.set_code(L1Block_new_addr, hardcoded_bytecode_v2)
        state.set_storage(L1BlockProxy, 0x00, L1Block_new_addr)
        state.set_storage(GasPriceOracle, IS_ECOTONE_SLOT, 1)
```

重放时只要新版本 EL 里硬编码的 `hardcoded_bytecode_v2` 有任何字节变化，状态根立刻不同。且 block 里没有 tx 痕迹，用户和审计无从在 explorer 上看到发生了什么。——这就是为什么 OP 从不走这条路。


