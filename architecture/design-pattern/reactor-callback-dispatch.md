# Reactor with Callback Dispatch 模式

> 输入通过 channel 多路复用（Reactor 风格），输出通过 callback 同步派发。
> 数据结构声明"我需要什么"，外部协调器决定"怎么获取"。

## 核心思想

这个模式有两个互补的视角：

### 视角一：非对称通信

```
┌─────────────────────────────────────────────────────────────┐
│                  Reactor Actor                              │
│                                                             │
│   输入 ◄── channel ──────  (消息传递，Reactor 风格)          │
│     │                                                       │
│     │  select_biased!                                       │
│     ▼                                                       │
│   处理状态                                                  │
│     │                                                       │
│   输出 ──callback──►   (同步回调，立即收集)                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

- **输入侧**：channel + select 多路复用（Actor/Reactor 风格）
- **输出侧**：callback 同步回调（非 Actor）

### 视角二：声明式数据获取

将**数据需求声明**与**数据获取逻辑**分离：
- 数据结构通过 callback 声明缺失的数据
- 外部收集这些声明，批量/异步获取
- 获取结果后再反馈给数据结构

```rust
// 数据结构声明需求，外部批量获取
trie.update_leaves(updates, |missing_key, depth| {
    pending_targets.push((missing_key, depth));  // 只声明，不获取
});

// 外部批量获取
let proofs = provider.get_batch_proof(pending_targets).await;

// 反馈给数据结构
trie.reveal(proofs);
```

## 与替代方案对比

### vs Cursor/Provider 链（Pull 模式）

| 维度 | Cursor (Pull) | Reactor + Callback (Push) |
|------|---------------|---------------------------|
| 控制流 | 调用方驱动 | 数据结构驱动 |
| 数据获取 | 逐个同步 | 批量异步 |
| 耦合度 | 高（依赖 provider） | 低（只需 callback） |
| 可测试性 | 需 mock provider | 传 closure 即可 |
| 并行化 | 难 | 天然支持 |

```rust
// ❌ Cursor 模式：数据结构直接依赖 provider
impl Trie {
    async fn update(&mut self, ...) {  // async 病毒式传播
        let proof = self.provider.get(key).await;  // Trie 依赖 async provider
    }
}

// ✓ Reactor + Callback：Trie 保持同步
impl Trie {
    fn update(&mut self, ..., callback: impl FnMut(...)) {
        callback(key);  // 纯同步，只是通知
    }
}
```

### vs 纯 Actor 模式

| 维度 | 纯 Actor | Reactor + Callback |
|------|----------|-------------------|
| 输入 | mailbox + 消息 | channel + select |
| 输出 | 发送消息给其他 Actor | callback 同步回调 |
| 解耦 | 完全解耦 | callback 处有耦合 |
| 适用 | 分布式/高并发 | 单进程、需要立即收集结果 |

```rust
// ❌ 纯 Actor 风格：发消息后等待回复
trie.update_leaves(updates);  // 返回
// 然后等 trie 发消息过来... 但 trie 没有 mailbox！

// ✓ Reactor + Callback：立即收集
trie.update_leaves(updates, |key, parent| {
    pending_targets.push(key);  // 同步回调，立即收集
});
```

## 为什么异步场景特别适合

### 1. 避免 async 污染数据结构

```rust
// ❌ 持有锁时 await
async fn update(&mut self, ...) {  // &mut self 持有锁
    let proof = self.provider.get().await;  // 等待期间锁不释放 → 死锁风险
}

// ✓ 快速完成，释放控制权
fn update(&mut self, ..., callback) {  // 同步，快速完成
    callback(key);
}
// 锁释放后，外部再异步获取
```

### 2. 批量优化

```rust
// ❌ 逐个获取：N 次异步开销
for key in missing_keys {
    let proof = provider.get(key).await;  // N 次 await
}

// ✓ 批量获取：1 次异步开销
let proofs = provider.get_batch(missing_keys).await;  // 1 次 await
```

## 典型结构

```rust
struct ReactorActor {
    // 输入 channels
    input_a_rx: Receiver<EventA>,
    input_b_rx: Receiver<EventB>,

    // 输出 handles（通过它们调用 callback）
    worker_handle: WorkerHandle,

    // 内部状态
    pending_work: Vec<WorkItem>,
}

impl ReactorActor {
    fn run(&mut self) {
        while !self.is_done() {
            // 1. SELECT: 多路复用输入
            select_biased! {
                recv(self.input_a_rx) -> msg => self.on_a(msg),
                recv(self.input_b_rx) -> msg => self.on_b(msg),
            }

            // 2. DISPATCH: 通过 callback 收集工作（Declare Don't Fetch）
            self.trie.update_leaves(&mut self.updates, |key, parent| {
                self.pending_work.push(...);  // callback 立即收集
            });

            // 3. SEND: 批量派发给 worker
            if !self.pending_work.is_empty() {
                self.worker_handle.dispatch(take(&mut self.pending_work));
            }
        }
    }
}
```

## 实际案例：reth SparseTrieCacheActor

```
┌─────────────────────────────────────────────────────────────────┐
│  SparseTrieCacheActor (协调器)                                   │
│                                                                 │
│  1. select_biased!                                              │
│     ├─ recv(update_rx) → on_update()                            │
│     └─ recv(proof_result_rx) → on_proof_results()               │
│                                                                 │
│  2. trie.update_leaves(updates, |key, parent| {                 │
│         pending_targets.push(key);  // callback 收集缺失         │
│     })                                                          │
│                                                                 │
│  3. dispatch(pending_targets) ──channel──► ProofWorker          │
│                                              │                  │
│                                    provider.get_batch_proof()   │
│                                              │                  │
│  4. trie.reveal(proofs) ◄────────────────────┘                  │
│                                                                 │
│  5. 重复直到所有 updates 应用完成                                 │
└─────────────────────────────────────────────────────────────────┘
```

关键设计：
- `ArenaParallelSparseTrie` 是纯内存数据结构，不接触 provider
- 通过 `proof_required_fn` callback 声明缺失的 proof（Declare Don't Fetch）
- `SparseTrieCacheActor` 收集声明，批量发给 worker
- Worker 用 provider 计算 proof，结果通过 channel 返回

## 适用场景

| 条件 | 适合此模式 | 替代方案 |
|------|-----------|----------|
| 同步 + 迭代 + 单线程 | ✗ | Cursor/Provider 链 |
| 异步 + 批量 + 跨线程 | ✓ | **此模式** |
| 需要完全解耦 / 分布式 | ✗ | 纯 Actor |
| 单进程 + 需要同步收集结果 | ✓ | **此模式** |

## 优缺点

### 优点

1. **立即收集**：callback 同步返回结果，无需等待消息往返
2. **批量优化**：收集完所有需求后一次性派发
3. **解耦数据结构**：Trie 保持同步纯粹，不依赖 provider
4. **可测试性**：callback 可以是纯 closure，无需 mock provider
5. **避免死锁**：快速完成同步操作，释放控制权后再异步

### 缺点

1. **耦合**：callback 处有调用方和被调用方的耦合
2. **阻塞风险**：callback 内不能做耗时操作
3. **不如 Actor 解耦**：无法分布式部署

## 决策树

```
需要访问外部数据 + 多输入源协调？
│
├─ 同步 + 迭代 + 单线程？
│   └─► Cursor/Provider 链 (Pull)
│
├─ 需要完全解耦 / 分布式？
│   └─► 纯 Actor 模式
│
└─ 异步 + 批量 + 跨线程 + 单进程？
    └─► Reactor + Callback Dispatch
        - channel + select 处理输入
        - callback 同步收集输出（Declare Don't Fetch）
        - 批量派发给 worker
```

## 总结

**Reactor with Callback Dispatch** = Reactor 的事件多路复用 + Callback 的同步收集 + 声明式数据获取

- **输入侧**：享受 Actor/Reactor 的异步解耦
- **输出侧**：享受 Callback 的简单直接
- **数据获取**：数据结构声明需求，外部批量获取（Declare Don't Fetch）
- **适用**：单进程内"多输入汇聚、批量处理、异步协调"的场景
