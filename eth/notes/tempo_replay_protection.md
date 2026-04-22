# Tempo Nonce-Free Expiring Transactions —— 防重放机制

> 覆盖 TIP-1009:用时间窗口替代顺序 nonce,实现并发、gasless、meta-tx 场景下的 replay protection。
>
> 相关代码:
> - `crates/precompiles/src/nonce/mod.rs`(on-chain 防重放算法)
> - `crates/revm/src/handler.rs`(gas 定价)
> - `crates/primitives/src/transaction/tt_signed.rs`(expiring_nonce_hash)
> - `crates/transaction-pool/src/maintain.rs`(mempool 淘汰)
> - `crates/transaction-pool/src/validator.rs`(入池校验)
> - `tips/tip-1009.md`(规范原文)

---

## 1. 问题:为什么需要 nonce-free?

传统 EVM 用 sequential nonce 做防重放,但它对几类场景不友好:

- **Gasless / Meta-tx**:relayer 要给不同用户管 nonce 队列
- **并发提交**:用户想同时发 5 笔独立 tx,必须分配 5 个严格递增 nonce,失败一笔后面全堵
- **故障恢复**:卡住的 tx 必须用同一个 nonce 发替换

TIP-1009 的设计:**用 `(tx hash, validBefore)` 替代 nonce,每笔 tx 在有限时间窗口内独立有效、独立防重放。**

启用方式:`nonceKey = uint256.max` + 必须设 `validBefore`。

---

## 2. 核心防御:三层结构

关键设计原则:**防重放的 authority 是链上状态,不是内存池,更不是挂钟。**

```
┌──────────────────────────────────────────────────────────────┐
│  层 1(authoritative):on-chain state                          │
│                                                                │
│     expiringNonceSeen[expiring_nonce_hash] = validBefore       │
│     —— 链上 precompile 的 storage slot                        │
│     —— tx 执行时写入,覆盖整个 [now, validBefore] 有效期       │
│     —— 任何重放到达此处都会被 revert "Replay"                  │
└──────────────────────────────────────────────────────────────┘
                          ▲
                          │ 最终裁决
┌──────────────────────────────────────────────────────────────┐
│  层 2(consensus time):validity window by block.timestamp    │
│                                                                │
│     now < validBefore <= now + MAX_EXPIRY_SECS (= 30s)         │
│     —— 用的是 block.timestamp(共识值,所有节点一致)           │
│     —— 过期 tx 在此被直接拒                                    │
└──────────────────────────────────────────────────────────────┘
                          ▲
                          │ 加速过滤
┌──────────────────────────────────────────────────────────────┐
│  层 3(advisory):mempool filter                              │
│                                                                │
│     入池前检查 + 维护循环提前 3s 踢                            │
│     —— 用的是 tip.header().timestamp(最近 canonical 块)      │
│     —— 启发式,提前丢掉必然失败的 tx,节省带宽和 CPU           │
│     —— 即便失效也不会导致双花,因为层 1 兜底                  │
└──────────────────────────────────────────────────────────────┘
```

**为什么这个设计 robust**:层 3 可以漂,层 2 是共识值不漂,层 1 是 deterministic state。三层咬合,任何一层被绕过都还有下一层。

### 2.1 层 1 的核心代码

`Nonce` precompile 在 tx 执行路径上被调用一次:

```rust
// crates/precompiles/src/nonce/mod.rs
pub fn check_and_mark_expiring_nonce(
    &mut self,
    expiring_nonce_hash: B256,
    valid_before: u64,
) -> Result<()> {
    let now: u64 = self.storage.timestamp().saturating_to();

    // 1. Validate expiry window
    if valid_before <= now || valid_before > now.saturating_add(EXPIRING_NONCE_MAX_EXPIRY_SECS) {
        return Err(NonceError::invalid_expiring_nonce_expiry().into());
    }

    // 2. Replay check
    let seen_expiry = self.expiring_nonce_seen[expiring_nonce_hash].read()?;
    if seen_expiry != 0 && seen_expiry > now {
        return Err(NonceError::expiring_nonce_replay().into());   // ← 重放在这里被拒
    }

    // 3-5. Ring buffer 插入 / 摊销清理(见第 5 节)
    // 6. 推进 ring pointer
    ...
}
```

**关键不变量**:只要 tx 仍在 `[now, validBefore]` 窗口内,`seen_expiry > now` 必为真 → 重放一定被拒。

---

## 3. 为什么用 `expiring_nonce_hash`,不用 `tx_hash`?

这是 TIP-1009 一个隐蔽但至关重要的设计选择。

### 攻击场景:Fee payer 替换

Tempo 支持 sponsored transaction —— 用户签 tx,另一个 fee payer 签一笔附加签名代付 gas。如果用普通 `tx_hash` 防重放:

```
用户 S 签 tx,validBefore = 30
    │
    ├─► Relayer1 附加 fee_payer_sig F1 ──► tx_hash_1 ──► 执行,seen[tx_hash_1] = 30
    │
    └─► Relayer2 附加 fee_payer_sig F2 ──► tx_hash_2 ──► 不同 hash,不撞 seen → 再执行一次!
                                                          ╰──── 双花!
```

用户意图是**一笔 tx**,但被两个 relayer 用不同的 fee 签名各执行了一次。

### 解法:`expiring_nonce_hash`

定义见 `crates/primitives/src/transaction/tt_signed.rs:115`:

```rust
pub fn expiring_nonce_hash(&self, sender: Address) -> B256 {
    let mut buf = Vec::with_capacity(
        self.tx.payload_len_for_signature() + sender.as_slice().len()
    );
    self.tx.encode_for_signing(&mut buf);  // ← 剥掉 fee_payer_sig 和 fee_token
    buf.extend_from_slice(sender.as_slice());  // ← 绑定 sender
    keccak256(&buf)
}
```

```
expiring_nonce_hash = keccak256( encode_for_signing(tx) ‖ sender )
```

两个关键属性:

| 属性 | 为什么需要 | 如何实现 |
|---|---|---|
| **Invariant to fee payer** | 防 sponsor 替换攻击 | `encode_for_signing` 不 commit fee_payer_sig 和 fee_token |
| **Unique per sender** | 两个用户签一样 payload 不相互冲突 | 末尾拼接 sender 地址 |

这是前面"`TempoTransaction` 为什么需要手写三种 hash 域"的直接应用 —— `encode_for_signing` 是同一套字段编码逻辑的第二种变体。

---

## 4. 时间语义:哪里用哪种时间

**整个防重放链路里,系统时钟(wall clock)不参与任何判定。** 这是安全性的硬性要求。

| 位置 | `now` 来自哪 | 何时读取 | 精度 |
|---|---|---|---|
| Precompile 执行(层 1/2) | 正在执行的块的 `block.timestamp` | tx 被打包进块、execute 时 | 精确到当前块 |
| Validator 入池校验(层 3) | `fork_tracker().tip_timestamp()` = 最近 canonical 块的 header | tx 入池时 | 滞后 1 块(~500ms) |
| Maintain 循环淘汰(层 3) | `tip.tip().header().timestamp()` | 每次新块 canonical 时 | 滞后 1 块 |

源码印证:

```rust
// 层 1/2 — crates/precompiles/src/nonce/mod.rs
let now: u64 = self.storage.timestamp().saturating_to();  // = block.timestamp

// 层 3 (maintain) — crates/transaction-pool/src/maintain.rs:574
let tip_timestamp = tip.tip().header().timestamp();

// 层 3 (validator) — crates/transaction-pool/src/validator.rs:141
let tip_timestamp = self.inner.fork_tracker().tip_timestamp();
```

### 为什么 mempool 用滞后的 tip 而不是本地时钟

1. **一致性**:所有节点对同一笔 tx "是否过期"必须判断一致。用本地时钟,各节点漂移不同会导致传播层混乱;用 `tip_timestamp`,至少在 tip 对齐的节点之间判断一致。
2. **保守估计**:`tip_timestamp` ≤ 真实当前时间,用它做 expiry 判断**只会更宽松**(保留一些已接近过期的 tx),不会误杀还未过期的 tx。
3. **对齐最终语义**:layer 1/2 最终按 `block.timestamp` 判,用 tip 时间预测最接近。

### `EVICTION_BUFFER_SECS = 3` 的真正含义

```rust
// crates/transaction-pool/src/maintain.rs:38
const EVICTION_BUFFER_SECS: u64 = 3;
```

这 3 秒**不是补偿挂钟漂移**,而是补偿 **(tip 滞后 + P2P 传播延迟 + 打包延迟)**。确保能广播出去的 tx 在对端打包时仍有余裕:

```
validBefore - 3s   ← mempool 主动踢(淘汰即将过期的 tx,不再广播)
validBefore        ← 链上判定过期
```

同样的 3 秒也用在入池校验([validator.rs:36](crates/transaction-pool/src/validator.rs)):

```rust
const AA_VALID_BEFORE_MIN_SECS: u64 = 3;
// 入池时要求: validBefore > tip_timestamp + 3
```

**入池和踢出用同一个 buffer**,保证"能进来的都还来得及发出去"。

---

## 5. Ring Buffer 自清理

TIP-1009 最漂亮的设计:**清理机制嵌入在插入流程里,无需任何后台 / 链下辅助,链上 state 上限恒定。**

### 存储布局

```solidity
contract Nonce {
    mapping(address => mapping(uint256 => uint64)) public nonces;    // slot 0 (2D nonce)
    mapping(bytes32 => uint64) public expiringNonceSeen;             // slot 1 — 防重放主表
    mapping(uint32 => bytes32) public expiringNonceRing;             // slot 2 — 环形缓冲
    uint32 public expiringNonceRingPtr;                              // slot 3 — 环指针
}
```

容量:`EXPIRING_NONCE_SET_CAPACITY = 300_000`(基于 10k TPS × 30s 窗口设计)。

### 插入即清理

```
新 tx 执行时:
  ┌────────────────────────────────────────────────────────┐
  │ 1. idx = expiringNonceRingPtr                          │
  │ 2. oldHash = expiringNonceRing[idx]   ← 当前位的占据者  │
  │                                                         │
  │ 3. if oldHash ≠ 0:                                     │
  │      oldExpiry = expiringNonceSeen[oldHash]            │
  │      if oldExpiry > now:                               │
  │          REVERT "BufferFull"         ← 拒绝覆盖未过期  │
  │      expiringNonceSeen[oldHash] = 0  ← 清理旧 entry    │
  │                                                         │
  │ 4. expiringNonceRing[idx] = newHash                    │
  │ 5. expiringNonceSeen[newHash] = validBefore            │
  │                                                         │
  │ 6. ptr = (ptr + 1) % CAPACITY                          │
  └────────────────────────────────────────────────────────┘
```

**三个漂亮的性质**:

1. **摊销清理**:每插入 1 笔,精确清理 1 笔 —— state 净增长恒为 0
2. **上限有界**:最多 `300_000 × 2` = 600k slots 被占用(ring + seen),永不膨胀
3. **Gas 自付**:清理 `seen[oldHash] = 0` 的 SSTORE 算在新 tx 的 gas 里,零外部化

### 环形覆盖的安全边界

```
ptr = 0, 1, 2, ..., 299999, 0, 1, 2, ...
                             ↑
                             这里绕回来时,原来 idx=0 位置的 tx
                             必须已经过期(oldExpiry <= now),
                             否则 REVERT "BufferFull"
```

换算:在 10k TPS 下,绕完一圈 = 30s,刚好等于 `MAX_EXPIRY_SECS`。
**超过 10k TPS 持续 30s 以上**就可能触发 `BufferFull`(协议拒绝接纳新 tx,保护旧 tx 防御)。

> **设计哲学**:宁可拒绝新的,也不让旧的失去防护。防重放不可妥协。

---

## 6. 特殊 Gas 定价

```rust
// crates/revm/src/handler.rs:97
pub const EXPIRING_NONCE_GAS: u64 = 2 * COLD_SLOAD_COST + 100 + 3 * WARM_SSTORE_RESET;
//                                 = 2 * 2100 + 100 + 3 * 2900
//                                 = 13_000 gas
```

### 常量来源:全部来自以太坊标准

| 常量 | 值 | 来源 EIP |
|---|---|---|
| `COLD_SLOAD_COST` | 2100 | EIP-2929 (Berlin) |
| `WARM_SLOAD_COST` | 100 | EIP-2929 |
| `WARM_SSTORE_RESET` | 2900 | EIP-3529 (London) |
| `SSTORE_SET` | 20000 | EIP-2200 |

这些常量**直接从 revm 导入**,Tempo 不定义新 gas 常量,只定义**如何组合**它们:

```rust
use revm::interpreter::gas::{COLD_SLOAD_COST, WARM_SSTORE_RESET, ...};
```

### 操作明细

| # | 操作 | 使用的 gas | 解释 |
|---|---|---|---|
| 1 | SLOAD `seen[txHash]` | `COLD_SLOAD_COST` = 2100 | 独立 slot,首次访问 |
| 2 | SLOAD `ring[idx]` | `COLD_SLOAD_COST` = 2100 | 独立 slot,首次访问 |
| 3 | SLOAD `seen[oldHash]` | 100(WARM) | `oldHash` 来自刚读的 `ring[idx]`,同一 slot 已 warm |
| 4 | SSTORE `seen[oldHash] = 0` | `WARM_SSTORE_RESET` = 2900 | 清理旧 entry |
| 5 | SSTORE `ring[idx] = newHash` | `WARM_SSTORE_RESET` = 2900 | 更新环 |
| 6 | SSTORE `seen[newHash] = validBefore` | `WARM_SSTORE_RESET` = 2900 | 新增 entry ⚠️ |
| 总计 | | **13,000** | |

被**摊销掉、不计费**的:
- `SLOAD / SSTORE expiringNonceRingPtr` —— 几乎每笔 expiring nonce tx 都碰,一个块内高频复用,摊销后 < 200 gas,协议直接吞了

### ⚠️ 关键的"不严谨"决策:第 6 行用 RESET 而不是 SET

严格按 EIP-2200 / 3529:对**原值为 0 的 slot** 写入**非零值**应该收 `SSTORE_SET = 20000`。

Tempo 故意违反这条规则,按 `SSTORE_RESET = 2900` 计价。理由见 [crates/revm/src/handler.rs:91-94](crates/revm/src/handler.rs#L91):

```
Why SSTORE_RESET (2,900) instead of SSTORE_SET (20,000) for `seen[tx_hash]`:
- SSTORE_SET cost exists to penalize permanent state growth
- Expiring nonce data is ephemeral: evicted within 30 seconds, fixed-size buffer (300k)
- No permanent state growth, so the 20k penalty doesn't apply
```

**论证链条**:

```
SSTORE_SET 20k 的目的        ──► 抑制永久 state 膨胀
                                       │
                                       ▼
Expiring nonce 设计约束     ──► 30s 内必被 ring buffer 覆盖清零
                                       │
                                       ▼
每笔 tx 对状态净增长         ──► 0(新增 1 个 entry ⇄ 清理 1 个 entry)
                                       │
                                       ▼
结论                        ──► 不应按膨胀惩罚计价,降到 RESET
```

如果按 SSTORE_SET 计价,单笔 expiring nonce gas = `2*2100 + 100 + 2*2900 + 20000 = 30100`,对 UX 不友好。Tempo 凭借**协议知道 state 生命周期**这个先验,给出比通用 EVM 更精确的定价 —— 这是 L1 协议设计优于"纯 EVM 兼容"的典型场景。

---

## 7. 常量与边界

```rust
// 链上判定
pub const EXPIRING_NONCE_MAX_EXPIRY_SECS: u64 = 30;       // 最大有效窗口
pub const EXPIRING_NONCE_SET_CAPACITY: u32 = 300_000;     // Ring buffer 容量
pub const EXPIRING_NONCE_GAS: u64 = 13_000;               // 单笔链上成本

// Mempool
const AA_VALID_BEFORE_MIN_SECS: u64 = 3;     // 入池时要求剩余有效期 > 3s
const EVICTION_BUFFER_SECS: u64 = 3;         // 提前 3s 踢出

// 交易字段硬约束
TEMPO_EXPIRING_NONCE_KEY = uint256.max       // 进入 expiring 模式的 sentinel
nonce == 0                                    // expiring 模式下 nonce 字段必须 0
```

### 容量设计耦合

```
EXPIRING_NONCE_SET_CAPACITY = MAX_TPS × MAX_EXPIRY_SECS
                            = 10_000  ×  30
                            = 300_000
```

**三者耦合,不能独立调整**:

| 想改 | 副作用 |
|---|---|
| 调大窗口到 60s | 容量必须 ≥ 600k,否则 10k TPS 下 ring 绕回来前旧 entry 还没过期,`BufferFull` |
| 目标 TPS 提升到 20k | 容量必须 ≥ 600k |
| 减容量到 100k | 实际可持续 TPS 降到 ~3300,或窗口缩到 10s |

---

## 8. 全流程时间线

```
用户 @ t=0 签 tx,validBefore = 30

  t=-∞ ─────────────────────────────────────────────────────────────── t=+∞
        │                                                          │
        │                                                          │
        ▼                                                          ▼
    ╔═══════════════════════════════════════════════════════════════╗
    ║  validBefore - 30                                             ║
    ║    │                                                          ║
    ║    ├─── 入池可接受窗口开始(validBefore > tip + 3)             ║
    ║    │    ↑                                                     ║
    ║    │    层 3 validator                                        ║
    ║    │                                                          ║
    ║    │         ├─── 被打包 + 执行 @ t=5                         ║
    ║    │         │    seen[hash] = 30 写入                        ║
    ║    │         │    ring[idx] = hash                            ║
    ║    │         │    ptr += 1                                    ║
    ║    │         │                                                ║
    ║    │         │         ├─── 任何重放尝试都命中 seen > now     ║
    ║    │         │         │    → revert "Replay"                 ║
    ║    │         │         │    ↑                                 ║
    ║    │         │         │    层 1(authoritative)             ║
    ║    │         │         │                                      ║
    ║    │         │         │         ├─── mempool 提前踢          ║
    ║    │         │         │         │    (t = validBefore - 3)   ║
    ║    │         │         │         │    ↑                       ║
    ║    │         │         │         │    层 3 maintain           ║
    ║    │         │         │         │                            ║
    ║    │         │         │         │    ├── 链上过期            ║
    ║    │         │         │         │    │   (t = validBefore)   ║
    ║    │         │         │         │    │   层 2 window check   ║
    ║    │         │         │         │    │                       ║
    ║    │         │         │         │    │                       ║
    ║    │         │         │         │    │      ... 过一段时间 ...║
    ║    │         │         │         │    │                       ║
    ║    │         │         │         │    │    ├─── ring 绕回来   ║
    ║    │         │         │         │    │    │    旧 tx 被下一个║
    ║    │         │         │         │    │    │    新 tx 搭便车  ║
    ║    │         │         │         │    │    │    清理(摊销)   ║
    ║    │         │         │         │    │    │                  ║
    ╚═══════════════════════════════════════════════════════════════╝
         t=0       t=3        t=5    validBefore-3  validBefore
                                        = 27        = 30
```

---

## 9. 一句话总结

> **内存池和挂钟都可能骗人,但 `expiringNonceSeen[hash] = validBefore` 这条链上记录不会。**
>
> 防重放的最终裁决在链上执行时由 precompile 做出,判定时间用 `block.timestamp`(共识值),去重 key 用 `expiring_nonce_hash`(剥离 fee payer 后的签名 hash + sender),ring buffer 靠插入摊销清理,gas 按 ephemeral state 逻辑走 `SSTORE_RESET` 而非 `SSTORE_SET`。
>
> 每一层都可被绕过,但三层咬合后,从经济、共识、数据结构三个维度都堵死了重放路径。

## 10. 与 2D Nonce 的本质区别

| 维度 | 2D Nonce | Expiring Nonce (TIP-1009) |
|---|---|---|
| 身份 key | `(sender, nonce_key, nonce)` | `(expiring_nonce_hash)` |
| 顺序依赖 | 同 key 内严格递增 | 无顺序,独立有效 |
| Storage 增长 | 随活跃 key 数线性增长 | 恒定(上限 ~19MB) |
| 并发 | 不同 key 间并发;同 key 串行 | 全并发(每笔独立) |
| 恢复机制 | 必须用同 nonce 发替换 tx | 无需恢复,新 tx 新 hash |
| 生命周期 | 永久(除非显式 reset) | 最长 30s 后自动失效 |
| 适用场景 | 用户自管 nonce 序列、账户抽象 | gasless、meta-tx、前端一把梭 |

**两者在 Tempo 里共存、互斥**:一笔 AA tx 要么用 2D nonce(`nonce_key < uint256.max`)、要么用 expiring nonce(`nonce_key == uint256.max`),由 `nonce_key` sentinel 区分。
