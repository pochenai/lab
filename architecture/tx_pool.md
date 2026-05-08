# 核心原理

Tempo 的 AA 2D 交易池本质上是一个 **k-way merge** 在 lane 维度更细的复用：每个 `(sender, nonce_key)` 是一条独立的 lane，lane 内 nonce 严格递增，lane 之间按 priority 排序。打包过程 = 每条 lane 暴露其"当前可执行头部" → 全局 priority queue 选最大 → 弹出后解锁该 lane 的 nonce+1 后继。

这跟普通 tx pool（reth 的 pending pool）的算法骨架完全一样，区别只在 lane key：
- 普通 pool：lane key = `sender`
- AA 2D pool：lane key = `(sender, nonce_key)` (= `AASequenceId`)

`independent_transactions` 字段就是"每条 lane 当前可执行头部"的索引（nonce == on_chain_nonce 的那条），它不是权威存储，是为了让全局 priority queue 直接拿到 k 个候选 head 而维护的派生缓存。

## 权威状态 vs 派生状态

真正的 source of truth 只有两个字段：

| 字段 | 类型 | 存的内容 |
|---|---|---|
| `by_id` | `BTreeMap<AA2dTransactionId, Arc<AA2dInternalTransaction>>` | 所有带 nonce_key 的 2D 交易 |
| `expiring_nonce_txs` | `HashMap<B256, PendingTransaction<TxOrdering>>` | 所有 expiring nonce 交易（key = expiring_nonce_hash） |

其它所有字段都可以从这两个 + 链上 nonce 重建出来：

| 派生字段 | 派生自 | 作用 |
|---|---|---|
| `independent_transactions` | `by_id` + 链上 nonce | k-way merge 的候选 head 表 |
| `by_hash` | `by_id` ∪ `expiring_nonce_txs` | hash → tx 的 O(1) 索引 |
| `by_eviction_order` | `by_id` ∪ `expiring_nonce_txs` | 容量裁剪时按 priority 排序 |
| `txs_by_sender` | `by_id` ∪ `expiring_nonce_txs` | per-sender 计数（DoS 防护） |
| `slot_to_seq_id` | `by_id` | storage slot → seq_id 反查（处理 state update） |
| `slot_to_expiring_nonce_hash` | `expiring_nonce_txs` | storage slot → expiring hash 反查 |

注意 `slot_to_*` 不是权威存储 —— 真正的交易数据在 `expiring_nonce_txs` 里；这两张反查表纯粹是因为 `on_state_updates` 拿到的输入是 storage slot 而不是 hash / seq_id，需要 O(1) 反查才存。

每次写操作都得同步多个派生表，所以这个池子写放大较高，但读路径几乎全部 O(1)/O(log N)。

## 池子的"写入面"——只有 4 个原子接口

不管 maintain 任务里有多少种触发条件、多少种链上事件，最终落到池子上的写操作只有 4 个：

1. **`add_transaction` / `add_expiring_nonce_transaction`** — 插入
2. **`notify_aa_pool_on_state_updates(bundle_state)`** — 状态机推进（mine / promote / demote / reorg）
3. **`remove_transactions(Vec<Hash>)`** — 按 hash 批量删
4. **`evict_invalidated_transactions(&updates)`** — 按谓词扫描删

外加一个池内自治的 `discard()`（容量裁剪），在每次 1~4 之后自动跑。

设计哲学：**池子不需要知道"为什么删"，只需要知道"删什么"**。所有的事件聚合、谓词构造、hash 集合计算都在 `maintain.rs` 里完成，池子只负责执行原子写。这条边界划得很干净。

## 触发面 —— 按触发源分类

### A. 用户/网络驱动 — 插入

| 入口 | 触发源 | 接口 |
|---|---|---|
| RPC submit / P2P 广播 | 外部 | `add_transaction` |
| unpause 恢复 re-inject | 链事件衍生 | `add_external_transactions` |
| transfer policy 改变后 re-validate | 链事件衍生 | `add_transactions_with_origins` |

注意后两条本质是被链事件**间接**触发的：先 remove 再 add，绕一圈过 validator 重新校验。

### B. 链事件驱动 — `chain_events.next()`（`Commit` / `Reorg` 共享同一段处理）

reorg 在 maintain 主循环里只 match 出 `new` 一条新规范链（`old` 被丢弃），跟 commit 走同一段代码。reorg 唯一额外的事是 AMM liquidity cache 的失效（孤立链上的缓存状态需要主动 repopulate），其它"清理 + 重新选 head"全部由 `on_state_updates` 自然完成。

#### B1. 状态机驱动 — `notify_aa_pool_on_state_updates(bundle_state)`
- 链上 nonce 推进 → mine 删除 / promote 提升 / demote 退回 / reorg 后重选 head
- expiring slot 被消费 → 删 expiring 交易

这是池子状态机的主驱动，所有"自然生命周期"的变化都靠它。

#### B2. 谓词扫描失效 — `evict_invalidated_transactions(&updates)`
单次池扫描，一次性处理所有"链上事件让某些交易语义失效"的场景：
- revoked keys（密钥撤销）
- spending limit changes / spends
- validator token changes
- user token changes
- blacklist additions / whitelist removals

合并到一个 pass 是为了避免每个事件都全池扫一遍。

#### B3. 按 hash 批量移除 — `remove_transactions(hashes)`
4 条独立路径分别在 maintain 里算出 hash 集合，再喂给同一个接口：
- **valid_before 到期**：本地 `state.drain_expired(tip_timestamp + buffer)` 算出 hash
- **fee token pause**：扫池子按 fee_token 分组后批量删，转入 paused_pool
- **transfer policy 变更**：扫池子按 token 找受影响的 hash，删了再 re-add
- **stale pending 清理**：~30 min 一次，详见 D

### C. 池内预算限制 — `discard()`
A / B 任何 mutation 结尾自动跑，按 `by_eviction_order` 裁掉超出 `pending_limit + queued_limit` 的尾部。池子自治，外面不管。

### D. 启发式时间触发 — Stale pending 清理

借**链上块 timestamp** 作为时钟，节流到 ~30 min 一次（`DEFAULT_PENDING_STALENESS_INTERVAL = 30 * 60`）。没有独立 timer 任务，挂在链事件入口下，所以链不出块这个 tick 也不走。

#### Two-snapshot 算法

每次触发时维护两个集合：
- `previous_pending`：上一次快照时所有 pending 交易的 hash
- `current_pending`：本次快照时所有 pending 交易的 hash

```
stale = previous_pending ∩ current_pending     // 两次都还在 = 太久没上链
previous_pending ← current_pending - stale     // 写回，给下一轮做对比
```

stale 的语义 = "从上一次快照活到这次快照都还没被矿出来 / 没被替换 / 没被踢"。

**淘汰时的年龄边界**：
- 下界 ~30 min：必须经历过完整一次 snapshot 间隔
- 上界 ~60 min：最坏情况（插入时点刚好错过 previous snapshot）

这个机制提供的是"30 min ≤ stale age ≤ 60 min"的近似保证，不是精确秒级。

**为什么不给每条 tx 打时间戳**：
- 省内存：不用每条 tx 存 insert_time，只维护两个 hash set
- 省 CPU：30 min 一次集合交，远比每块扫每条便宜
- 节流明确：把潜在的 O(N) 操作摊到很低频

写回时 `current_pending - stale` 而非直接 `current_pending` 是给 race 留缓冲：即使刚淘汰的 tx 因为竞争还没真删掉、下次扫描还能看到，也不会被识别成 stale 重复淘汰；要再等一个完整 30 min 窗口才有资格。

## 一张总表

| 类 | 触发源 | 接口 | 何时跑 |
|---|---|---|---|
| **A** 插入 | RPC / P2P / 二次注入 | `add_*` | 外部主动 |
| **B1** 状态机 | `Commit` / `Reorg` | `notify_aa_pool_on_state_updates` | 每个块 |
| **B2** 谓词扫描失效 | `Commit` / `Reorg` 衍生事件 | `evict_invalidated_transactions` | 每个块（有事件时） |
| **B3** 批量删除 | 多条上层路径算 hash | `remove_transactions` | 每个块（4 条独立路径） |
| **C** 容量裁剪 | A/B 操作完末尾 | `discard()`（私有） | A/B 后自动 |
| **D** 启发式清理 | tip_timestamp 节流 | `remove_transactions` | ~30 min/次（借块作为 tick） |

## 关键代码位置

代码引用使用 repo-root-relative 路径（基于 `tempo` 仓库根目录）：

- 池主体：`crates/transaction-pool/src/tt_2d_pool.rs`
  - `independent_transactions` 字段定义：line 52
  - 插入时登记 head：line 307-311
  - 状态推进时重新选 head：line 912-916
  - 状态推进时清理 stale head：line 928-929
  - `remove_independent`：line 663-679
  - `best_transactions()` 构造 k-way merge 候选集：line 506-525
- 维护任务：`crates/transaction-pool/src/maintain.rs`
  - `chain_events` 主循环（Commit/Reorg 入口）：line 405-418
  - 9 个块处理阶段：line 420 起
  - `notify_aa_pool_on_state_updates` 调用：line 649
  - `evict_invalidated_transactions` 调用：line 677
  - `PendingStalenessTracker` 定义：line 302-351
  - stale 清理调用：line 690-709
- 常量：
  - `EVICTION_BUFFER_SECS = 3`：line 35
  - `DEFAULT_PENDING_STALENESS_INTERVAL = 30 * 60`：line 294

## 设计上的几个值得记住的点

1. **派生字段 vs 权威字段**：写代码时心里要清楚改的是哪一类。改派生字段不需要触发其它同步；改权威字段必须把所有相关派生字段一起更新。

2. **maintain 和 pool 的边界**：链上事件解析、谓词构造、hash 集合计算 → maintain 里做；原子写 → pool 里做。新加一种"因为某种原因要踢交易"的场景时，先想清楚它属于 B2（谓词扫描）还是 B3（hash 批量），不要在 pool 里塞业务逻辑。

3. **reorg 不是特殊路径**：除了 AMM cache 那一项，所有清理都靠 state-driven update 自动完成。如果以后要从孤立块里 re-inject 交易，那是另一条路径（目前 `old` 是 `_` 丢弃的）。

4. **借块作为时钟**：D 类清理用的是 tip_timestamp 而不是 wall clock，链停 tick 也停。这种"近似定时器"在不需要精确触发的清理场景里很省事。
