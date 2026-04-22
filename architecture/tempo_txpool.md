# Tempo Transaction Pool 架构

> 代码位置:`crates/transaction-pool/`

## 1. 总览

Tempo 的交易池本质上是一个 **facade over reth's TransactionPool**,对外伪装成一个标准的 `TransactionPool`,内部却**同时维护两个子池**:

- 一个 **reth 原生** 的池,处理以太坊标准 tx 和一维 nonce 的 AA tx
- 一个 **Tempo 自写** 的池(`AA2dPool`),处理二维 nonce 的 AA tx

这个设计是为了**最大复用 reth 生态**,同时在 reth 池数据模型不够用的地方(2D nonce)**插入自研组件**,避免 fork 整个 reth transaction-pool crate。

顶层入口:`TempoTransactionPool<Client>`
外部视角:实现 `reth_transaction_pool::TransactionPool` + `TransactionPoolExt`

## 2. 模块地图

```
crates/transaction-pool/src/
├── lib.rs           — crate 根,导出三大类型
├── transaction.rs   — TempoPooledTransaction:池内 tx 数据载体
├── tempo_pool.rs    — TempoTransactionPool:顶层 facade
├── tt_2d_pool.rs    — AA2dPool:2D nonce 专用子池
├── validator.rs     — TempoTransactionValidator:tx 入池前校验
├── maintain.rs      — maintain_tempo_pool:后台维护任务(状态变更订阅 + 淘汰)
├── amm.rs           — AmmLiquidityCache:fee token 流动性缓存
├── best.rs          — MergeBestTransactions:两个子池的归并迭代器
├── paused.rs        — PausedFeeTokenPool:fee token 暂停时的挂起池
├── metrics.rs       — 指标
└── test_utils.rs    — 测试辅助
```

## 3. 三个核心模块:`TempoPooledTransaction` / `AA2dPool` / `TempoTransactionPool`

### 3.1 `TempoPooledTransaction` — `crates/transaction-pool/src/transaction.rs`

**角色:池内一条交易的数据载体(不是容器)。**

包装 reth 的 `EthPooledTransaction<TempoTxEnvelope>`,并附加 **Tempo 专属的缓存字段**:

| 字段 | 作用 |
|---|---|
| `inner: EthPooledTransaction<TempoTxEnvelope>` | 底层 tx + cost + encoded_length |
| `is_payment: bool` | TIP-20 支付分类缓存(strict / v2),块构建热路径使用 |
| `is_expiring_nonce: bool` | 是否 `nonce_key == U256::MAX`(过期型 nonce) |
| `nonce_key_slot: OnceLock<Option<U256>>` | 2D nonce 在 `NonceManager` 中的存储槽,供 AA2dPool 反查 |
| `tx_env: OnceLock<TempoTxEnv>` | 预构建的 EVM 执行环境,payload building 时零开销复用 |
| `key_expiry: OnceLock<Option<u64>>` | Keychain key 过期时间(校验时写入,维护任务读) |
| `resolved_fee_token: OnceLock<Address>` | 校验时解析的 fee token(含 user token 默认值) |

**核心价值**:这些字段都是"**贵但稳定**"的计算结果 —— 一次算好,被 pool 的排序、淘汰、best_transactions、块构建等多条路径反复读取。不缓存会导致每次 `best_transactions()` 遍历都重算一遍 TIP-20 分类。

它实现 reth 的 `PoolTransaction` / `EthPoolTransaction` / `Encodable2718` trait,所以**两个子池都能存同一种类型**,查询合并时不需要类型转换。

### 3.2 `AA2dPool` — `crates/transaction-pool/src/tt_2d_pool.rs`

**角色:二维 nonce AA 交易的专用子池(~5600 行)。**

只接收满足 `is_aa_2d()` 的 tx —— 即 `nonce_key > 0` 的 AA 交易,**包括 expiring nonce(`nonce_key == U256::MAX`)**。

#### 为什么必须自写

reth 原生 `Pool` 的 `TransactionId = (SenderId, u64 nonce)`,它假设**每个 sender 一条 nonce 序列**。Tempo AA tx 的 nonce 是 `(sender, nonce_key) → nonce` 二维的,**不同 nonce_key 之间可以并行执行**,这与 reth 的 promote/queue 逻辑不兼容。

与其 fork / 魔改 reth 的 Pool,不如把 2D nonce 单独提出来自己实现。

#### 内部数据结构

```rust
pub struct AA2dPool {
    submission_id: u64,
    independent_transactions: HashMap<AASequenceId, PendingTransaction<TxOrdering>>,
    by_id: BTreeMap<AA2dTransactionId, Arc<AA2dInternalTransaction>>,
    by_hash: HashMap<TxHash, Arc<ValidPoolTransaction<TempoPooledTransaction>>>,
    expiring_nonce_txs: HashMap<B256, PendingTransaction<TxOrdering>>,
    slot_to_seq_id: U256Map<AASequenceId>,
    seq_id_to_slot: HashMap<AASequenceId, U256>,
    by_eviction_order: BTreeSet<EvictionKey>,
    txs_by_sender: AddressMap<usize>,
    config: AA2dPoolConfig,
    metrics: AA2dPoolMetrics,
}
```

| 字段 | 作用 |
|---|---|
| `independent_transactions` | 每个 `(sender, nonce_key)` 序列上"下一条可执行 tx"(即 pending 头) |
| `by_id` | 按 `(seq_id, nonce)` 排序的全部 tx,支持按序遍历 |
| `by_hash` | 按 tx hash 的快速查找 |
| `expiring_nonce_txs` | Expiring nonce tx 走独立路径:它们没有序列,总是 pending,按 hash 索引 |
| `slot_to_seq_id` / `seq_id_to_slot` | 链上状态更新时用 storage slot 反查序列,触发 promote/drop |
| `by_eviction_order` | 按优先级排序,支持 O(log N) 淘汰。Tempo base fee 恒定 → priority 插入后不变 → 增量维护 |
| `txs_by_sender` | 每个 sender 的 tx 数量(DoS 限额) |

#### 对外暴露

- `add_transaction(tx, state_nonce, hardfork)` —— 入池
- `on_state_updates(state)` —— 链上状态变更驱动 promote / mined drop
- `best_transactions()` —— 按 priority 递减遍历
- `pending_transactions()` / `queued_transactions()` —— 查询
- `remove_transactions(...)` —— 淘汰

**不实现** reth 的 `TransactionPool` trait —— 它是内部组件,只给 `TempoTransactionPool` 用。

### 3.3 `TempoTransactionPool<Client>` — `crates/transaction-pool/src/tempo_pool.rs`

**角色:顶层 facade,对外的 `TransactionPool` 实现。**

```rust
pub struct TempoTransactionPool<Client> {
    protocol_pool: Pool<
        TransactionValidationTaskExecutor<TempoTransactionValidator<Client>>,
        CoinbaseTipOrdering<TempoPooledTransaction>,
        InMemoryBlobStore,
    >,
    aa_2d_pool: Arc<RwLock<AA2dPool>>,
}
```

只有**两个字段**,职责也只有三件事:**路由**、**合并**、**业务淘汰**。

#### 1. 路由新 tx — `tempo_pool.rs:440 add_validated_transaction`

```
if tx.is_aa_2d() → aa_2d_pool.add_transaction(...)
else            → protocol_pool.inner().add_transactions(...)
```

路由判据就是 `TempoPooledTransaction::is_aa_2d()`(`transaction.rs:121`):是 AA tx 且 `nonce_key != 0`。

#### 2. 合并查询结果

外部调用 `best_transactions()` / `all_transactions()` / `pending_transactions()`,需要把两个子池的结果合并:

- **`best_transactions()`** 用 `best.rs` 的 `MergeBestTransactions`,以 priority 为序归并两个子池的迭代器(双路 priority 归并,流式输出)
- **其他查询方法**大多是简单 `extend` 合并

同步路径需要同时读两个池,`aa_2d_pool` 用 `RwLock` 保护,绝大多数查询走读锁。

#### 3. 业务层淘汰 — `tempo_pool.rs:167 evict_invalidated_transactions`

处理 reth 池不懂的 Tempo 特有事件:

| 事件 | 淘汰依据 |
|---|---|
| Keychain key 撤销 | `keychain_subject().matches_revoked(...)` |
| Spending limit 变化 | 新 limit < tx cost |
| Spending limit 被实际消耗(未发事件的隐式扣减) | 重读链上 remaining,对比 cost |
| Validator token 变化 | 重跑流动性检查 |
| TIP-403 黑名单新增 / 白名单移除 | fee payer / fee manager 策略查询 |
| 用户 fee token 偏好变化 | 无显式 fee_token 且 sender 变了 token 的 tx 失效 |

这段 270 行逻辑是**整个 `tempo_pool.rs` 最复杂的部分**,已经具备拆分成独立模块的条件(详见"重构建议")。

## 4. 关系图

```
┌──────────────────────────────────────────────────────────────────────┐
│   外部使用者 (RPC / EngineAPI / payload builder / P2P)                │
│   通过 reth_transaction_pool::TransactionPool trait 看到统一接口       │
└──────────────────────────┬───────────────────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│   TempoTransactionPool<Client>     (facade, 实现 TransactionPool)     │
│   ┌────────────────────────────────────┐  ┌────────────────────────┐ │
│   │  protocol_pool                      │  │  aa_2d_pool            │ │
│   │    reth::Pool<                      │  │    Arc<RwLock<         │ │
│   │      TempoTransactionValidator,     │  │       AA2dPool>>       │ │
│   │      CoinbaseTipOrdering,           │  │                        │ │
│   │      InMemoryBlobStore>             │  │                        │ │
│   │                                     │  │                        │ │
│   │  处理:                              │  │  处理:                │ │
│   │   - Legacy / EIP-2930 / 1559 / 7702 │  │   - nonce_key > 0 的   │ │
│   │   - AA with nonce_key == 0          │  │     AA tx              │ │
│   │                                     │  │   - expiring nonce tx  │ │
│   └──────────────────┬──────────────────┘  └───────────┬────────────┘ │
│                      │             共同存储             │              │
│                      ▼                                  ▼              │
│        ┌──────────────────────────────────────────────────────┐       │
│        │   ValidPoolTransaction<TempoPooledTransaction>        │       │
│        │   ─ reth 的 pool 包装器 + Tempo 的 tx 包装器           │       │
│        └──────────────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────────────────┘
                           ▲
                           │ 构造
┌──────────────────────────┴───────────────────────────────────────────┐
│   TempoTransactionValidator<Client>   (validator.rs)                  │
│     ─ 校验 AA 特有规则(calls 数量、authorization list、keychain 签名、│
│       validBefore/validAfter、AMM 流动性、spending limit、TIP-403 策略)│
│     ─ 生成 TempoPooledTransaction 并填入缓存字段                       │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│   maintain_tempo_pool   (maintain.rs, 后台 async task)                │
│     订阅 CanonStateNotification → 解析 block logs → 产出               │
│     TempoPoolUpdates → 调用 pool.evict_invalidated_transactions(...)   │
└──────────────────────────────────────────────────────────────────────┘
```

## 5. 关键数据流

### 5.1 入池(ingress)

```
RPC / P2P 收到 raw tx
        │
        ▼  decode / recover
TempoTxEnvelope + sender
        │
        ▼  TempoTransactionValidator
   校验(结构 / 签名 / 链上状态 / fee token / policy)
        │
        ▼  TempoPooledTransaction::new(...)
   填入 is_payment / is_expiring_nonce / resolved_fee_token
        │
        ▼  TempoTransactionPool::add_validated_transaction
   根据 is_aa_2d() 路由
        ├────── true ──────► AA2dPool::add_transaction
        │                    ─ 插入 by_id / by_hash / by_eviction_order
        │                    ─ on_chain_nonce 匹配则 promote 到 pending
        │                    ─ 通知 protocol_pool 的 event listener
        │                      (统一事件语义)
        │
        └────── false ─────► reth Pool::add_transactions
                             ─ reth 原生处理
```

### 5.2 查询(egress)

```
caller: pool.best_transactions()
        │
        ▼
protocol_pool.inner().best_transactions()  ──┐
                                              ├─► MergeBestTransactions
aa_2d_pool.read().best_transactions()    ────┘     按 priority 归并迭代
```

### 5.3 链上状态更新(块被 import)

```
reth 发出 CanonStateNotification
        │
        ▼  maintain_tempo_pool 订阅者
解析 block logs:KeychainRevoked / SpendingLimitUpdated / PolicyAdded /
                 ValidatorTokenSet / UserTokenSet / FeePause / ...
        │
        ▼  聚合为 TempoPoolUpdates
        │
        ├─► pool.on_canonical_state_change(update)
        │     ├─► protocol_pool.on_canonical_state_change (reth 原生 nonce 追账)
        │     └─► aa_2d_pool.on_state_updates (按 storage slot 找到 seq_id,
        │                                      promote / drop 已 mined 的 tx)
        │
        └─► pool.evict_invalidated_transactions(updates)
              └─► 跑 6 种 check,产出 to_remove,调用 remove_transactions
```

## 6. 为什么这么拆

### `TempoPooledTransaction` 与池分离

- 两个子池要存**同一个 tx 类型**,才能在查询层合并。类型独立定义避免了循环依赖。
- 缓存字段(`is_payment`、`tx_env` 等)**属于 tx 本身**,不属于池 —— tx 从 P2P 收到到最终落块,会在 validator、池、块构建器之间流转,缓存跟着 tx 走才合理。

### `AA2dPool` 与 `TempoTransactionPool` 分离

- `AA2dPool` 内部数据结构和 reth 的 `Pool` 完全不同(2D nonce vs 1D nonce),强耦合会让代码难以演化。
- 分离后 `AA2dPool` 可以**独立做单元测试**,不依赖 reth 的 Pool 脚手架。
- `TempoTransactionPool` 只负责"选哪个池 + 合并结果",逻辑极薄,容易推理。

### Facade 层吸收差异

- 外部(RPC、payload builder、P2P)只看一个 `TransactionPool` 接口,不关心下面有几个池。
- 以后 2D nonce 的实现策略变化(换数据结构、加 sharding、换锁模型)都不会影响外部。
- 新增第三个子池(如某类特殊 tx)只需改 facade 的路由,不改用户代码。

## 7. 重要的横切关注点

### AMM 流动性缓存

`AmmLiquidityCache`(`amm.rs`)跟踪 fee token 与 validator 的 AMM 池流动性,校验 / 淘汰时判断"这 tx 的 fee token 能否被兑成原生 token"。由 `TempoTransactionValidator` 持有并通过 pool 暴露给 `evict_invalidated_transactions` 用。

### Keychain 主体(`KeychainSubject`)

抽出 `(account, key_id, fee_token)` 三元组,用于把**池中的 tx**和**链上事件**(`KeychainKeyRevoked` / `SpendingLimitUpdated`)做匹配。定义在 `transaction.rs:1010`。

### Fee Token 暂停

`PausedFeeTokenPool`(`paused.rs`)处理某个 fee token 被暂停(TIP-403 `pause`)后,依赖它的 tx 被暂存起来,解除暂停时再重新投递。

### Validator 架构

`TempoTransactionValidator<Client>`(`validator.rs`)包一层 reth 的 `EthTransactionValidator`,在其之上加 AA 特有校验:

- `calls` 数量(≤32)、单 call input 大小(≤128KB)
- `authorization_list` 大小(≤16)
- Access list 大小(accounts ≤256, keys ≤2048)
- `valid_before` / `valid_after` 时间窗
- Keychain call scope / selector rule / recipient 数量
- AMM 流动性足够付 fee
- Spending limit / TIP-403 策略允许 fee 转账

## 8. 可以做的重构(如果要降复杂度)

### 🟢 高优先级:把 eviction 逻辑拆出去

当前 `tempo_pool.rs` 有 1765 行,其中:

- ~270 行的 `evict_invalidated_transactions`
- ~70 行的 `get_sender_policy_ids` / `get_recipient_policy_ids` 自由函数
- ~400 行的 eviction 相关测试

拆成 `tempo_pool/eviction.rs` 后,主文件能降到 ~1000 行,职责回到"池的编排"。

### 🟡 中优先级:`impl TransactionPool` 拆到单独文件

~570 行的 trait 转发,修改节奏和主逻辑独立,单独成文件可降到 600 行核心。用同模块跨文件(不是 submodule)保持可见性。

### 🔴 不建议

- 单独拆 `Clone` / `Debug` impl(20 行,无意义)
- 单独拆 `add_validated_transaction`(和字段强耦合,应留在主文件)

## 9. 对标以太坊 / reth

| 方面 | reth / 原生以太坊 | Tempo |
|---|---|---|
| 池接口 | `TransactionPool` | 相同(通过 facade 伪装) |
| Nonce 模型 | 1D(sender → u64) | 1D + 2D(sender × nonce_key → u64) |
| 队列 / 就绪 | 单池内状态转换 | protocol_pool 用 reth 原生;aa_2d_pool 按 seq_id 自管 |
| Fee token | 原生 ETH | 多 TIP-20 token,需 AMM 流动性校验 |
| 策略验证 | 无 | TIP-403 黑白名单、spending limit、keychain 授权 |
| 后台维护 | `maintain_transaction_pool` | `maintain_tempo_pool`(多几种事件源) |
| 淘汰 | nonce 超过 / 余额不足 / blob 过期 | 上述 + 6 种 Tempo 业务淘汰 |

Tempo 的池在"交易模型"(2D nonce + AA)和"业务规则"(多 token + 策略 + 限额)两个维度上扩展了 reth,**结构上仍然严守 reth 的抽象边界**,而不是替换它。这是它能跟上 reth 上游迭代的关键。

## 10. 一句话小结

**`TempoTransactionPool` 是门面,装着 reth 原生池和自写的 `AA2dPool` 两个子池,两者都存同一种 `TempoPooledTransaction`;路由按 `nonce_key` 分叉,查询归并返回,业务淘汰由 facade 层单独承担。**
