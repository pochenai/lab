# Tempo Subblock 机制分析

## 1. Subblock 设计目的

`subblock` 不是共识主块本身，而是给“下一位 proposer”的候选交易包(validator shared blockspace)。

SubBlock 的定位:
让交易供给从“proposer 单点构建”变成“验证者协作供给”，本质上就是一个 fallback 机制。

正常情况下，交易走 mempool → proposer 打包（450M gas, 90%），这条路径完全够用。SubBlock 提供了一条绕过 proposer 选择权的备用通道（50M gas, 10%）：

- 用户通过 nonce_key 编码 [0x5b | validator_pubkey_15bytes | ...] 将交易绑定到特定验证者, 该验证者预执行后打包成签名的 SubBlock 发给 proposer
- Proposer 通过 GasIncentive 机制被激励（非强制）包含这些 SubBlock

### 什么场景需要？
- Proposer 审查/不合作时：某笔支付交易被 proposer 忽略或故意不打包，subblock 提供了替代路径
- Proposer 交易池满时：450M gas 被填满的极端情况下，subblock 的 50M 独立空间仍可用
但 10% 的 gas 配额 + 非强制包含的设计，说明这确实更多是防御性的 fallback，而不是主力通道。对于一条支付链来说，"保证交易在极端情况下也能上链"本身就有价值，即使日常 99% 的流量走的是正常 mempool 路径。

对应实现入口：`crates/commonware-node/src/subblocks.rs`

---

## 2. Subblock 与普通 Block 的区别与联系

区别：

1. `block` 是共识对象，走 `simplex + marshal`，可被投票/finalize。
2. `subblock` 是辅助对象，不直接进入共识投票流程。
3. `subblock` 有局部约束（签名、发送者、size/gas、parent 一致性）后才被 proposer 采用。

联系：

1. `application` 提案时把 `subblocks.get_subblocks(parent)` 作为 payload builder 的输入。
2. 最终是否进入正式 block，由 payload builder 执行与裁剪结果决定。

代码：

- 拉取 subblocks：`crates/commonware-node/src/consensus/application/actor.rs:557`
- subblocks 服务 mailbox：`crates/commonware-node/src/subblocks.rs:646`

---

## 3. 是否有 proposer 必须包含 subblock 的硬约束

结论：当前实现里**没有**“必须包含某个/全部 subblock”的共识硬约束。

证据：

1. 提案侧拿不到 subblocks 时直接 `unwrap_or_default()`，说明是可选输入。  
   `crates/commonware-node/src/consensus/application/actor.rs:557`
2. 验证侧没有“包含特定 subblock”的规则；主要验证的是 EL 执行结果和 `extra_data`（DKG/dealer log）。  
   `crates/commonware-node/src/consensus/application/actor.rs:644`  
   `crates/commonware-node/src/consensus/application/actor.rs:833`

因此它更偏“性能协作机制（best-effort）”，而非“可惩罚的协议义务”。

---

## 4. 谁会给下一 proposer 发 subblock

不是“只有 proposer 才发”。

更准确是：

1. 运行了 `subblocks` 服务的验证者节点，都会尝试构建并发送给当前推导出的下一 proposer。
2. 发送是单播给下一 proposer。
3. 若下一 proposer 恰好是自己，则本地直接采纳，不走网络发送。

对应代码：

- 推导下一 proposer 并触发构建：`crates/commonware-node/src/subblocks.rs:327`
- 网络发送：`crates/commonware-node/src/subblocks.rs:487`
- proposer==self 时本地采纳：`crates/commonware-node/src/subblocks.rs:513`

可总结为：

`运行了 subblocks 服务的每个验证者节点，按节点 best-effort 给下一 proposer 供给 subblock。`

---

## 5. 下一 proposer 如何选择合适的 subblock

当前实现是“前置验证 + builder 最终裁剪”，而非 proposer 手写复杂打分器。

### 5.1 Subblocks 服务前置筛选

1. parent 必须等于当前 tip，否则丢弃。  
   `crates/commonware-node/src/subblocks.rs:405`
2. 签名、发送者身份、交易 proposer 标记、交易可执行性、size/gas 预算全部校验。  
   `crates/commonware-node/src/subblocks.rs:790`
3. 以 validator 为 key 收集（每个 validator 一份）。  
   `crates/commonware-node/src/subblocks.rs:457`
4. tip 变化时清空旧集合。  
   `crates/commonware-node/src/subblocks.rs:276`

### 5.2 Proposer 侧获取

提案时按 parent 拉取当前已验证集合：

- `crates/commonware-node/src/consensus/application/actor.rs:557`

### 5.3 Builder 最终裁剪与执行

在 payload builder 中进行最终裁剪与应用：

1. 取入参 subblocks：`attributes.subblocks()`  
   `crates/payload/builder/src/lib.rs:285`
2. 第一轮裁剪：`retain`（如过期交易）  
   `crates/payload/builder/src/lib.rs:293`
3. 执行 subblock 交易；执行失败会中止当前 payload 构建  
   `crates/payload/builder/src/lib.rs:507`

---

## 6. “builder.finish() 如何得到最终 block 交易列表”

交易不是在 `finish()` 时临时发现的，而是在每次 `execute_transaction()` 成功后就被累积。

上游 `reth evm` 的 `BasicBlockBuilder` 行为：

1. `execute_transaction...` 成功后 `self.transactions.push(tx)`。  
   `/home/po/.cargo/git/checkouts/reth-e231042ee7db3fb7/20ae9ac/crates/evm/evm/src/execute.rs:466`
2. `finish()` 时把累积的 `self.transactions` 交给 `assemble_block(...)` 组块。  
   `/home/po/.cargo/git/checkouts/reth-e231042ee7db3fb7/20ae9ac/crates/evm/evm/src/execute.rs:489`
3. Tempo 侧调用 `finish` 的位置：  
   `crates/payload/builder/src/lib.rs:565`

---

## 7. 结论

当前 subblock 机制的定位是：

1. 分布式预构建交易供给（性能和鲁棒性优化）。
2. 非强制包含、非可惩罚义务（没有 proposer 必须包含约束）。
3. 通过“前置校验 + payload builder 最终裁剪”实现可用性和安全性平衡。
