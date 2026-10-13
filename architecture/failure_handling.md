# Rust 服务的 Failure Handling：从局部 task 失败到进程退出

异步服务中的“失败处理”主要处理的是不能接收的失败（非正常error），比如一次请求失败、一个后台 task 退出、一个数据库事务未提交，以及整个节点必须停机，这些failure分别处在不同层级。

本文以 Reth 这类执行客户端的任务运行时、engine、存储与 P2P（peer-to-peer，对等网络）为背景，整理一套实用分类。重点不是罗列模式名称，而是为每个模式回答三个问题：失败的边界是什么、状态由谁拥有、何时应该升级为进程退出。

`task` 指异步执行单元，`runtime` 指 Tokio 调度器及其 I/O、定时器和 blocking pool；代码均省略不影响控制流的业务类型与错误定义。

## 总览：先选失败边界，再选处理方式

下图按处理目标组织模式。前两层尽量让请求或局部工作恢复；中间两层限制影响范围或等待外部条件；最后一层才销毁运行时和进程。

```text
Failure Handling
│
├── 1. Prevention / Protection（预防与保护）
│   ├── Rate Limiting（限流）
│   ├── Load Shedding（过载丢弃）
│   └── Circuit Breaking（熔断）
│
├── 2. Recovery（故障恢复）
│   ├── Retry（重试）
│   ├── Fallback（降级）
│   ├── Rollback（回滚）
│   └── Compensation（补偿）
│
├── 3. Containment（故障隔离）
│   ├── Reject / Fail Request（拒绝请求）
│   ├── Isolate Task（隔离任务）
│   └── Disable Component（禁用组件）
│
├── 4. Suspension / Escalation（暂停与升级）
│   ├── Block / Pause（阻塞或暂停）
│   └── Dead Letter Queue（死信队列）
│
└── 5. Termination（终止）
    ├── Graceful Shutdown（优雅退出）
    └── Immediate Shutdown（立即退出）
```

这些类别不是互斥状态机。一个安全的典型路径可以是：先因并发上限拒绝请求；若请求已经开始则重试可重试错误；若已改变状态则回滚；若关键状态无法证明一致，停止接收新工作、持久化可安全持久化的状态，最后退出。

为了贯穿全文，先看一个最容易误解的边界：Tokio task 的 panic。

```rust
tokio::spawn(async {
    panic!("worker failed");
});
```

在采用 `panic = "unwind"` 的构建中，这个 panic 默认只使该 task 的 `JoinHandle` 变成错误；它不会自动停止同一 runtime 的其他 task，也不会自动退出主进程。需要全局退出的系统必须显式提升故障等级。Reth 的 critical task 用 `catch_unwind` 捕获 panic，并向 `TaskManager` 发送 `TaskEvent::Panic`；CLI 再把该事件转换为 node 级错误。

这个前提不能省略：panic strategy 也可能设为 `panic = "abort"`。后者会直接终止进程，既不会产生 `JoinError`，也不会执行 `catch_unwind` 的 promotion 或 graceful cleanup 路径。Reth 的 reproducible build 便采用此配置：

```toml
[profile.reproducible]
inherits = "release"
panic = "abort"
```

## 1. Prevention / Protection（预防与保护）：在状态被压垮前限制工作

保护机制的共同目标是限制进入昂贵路径的工作量。它们不修复已发生的错误，而是让错误不会首先演化成内存耗尽、排队延迟失控或下游雪崩。

### Rate Limiting（限流）：限制时间配额与在途资源

限流至少有两个正交维度：单位时间的准入次数，以及同时进行的昂贵工作数。对执行客户端而言，trace、EVM 执行或 blocking I/O 通常还需要并发上限；但 semaphore 只能限制 in-flight 数量，不能表达 “100 TPS”。

```rust
use std::sync::Arc;
use tokio::sync::Semaphore;

async fn expensive_rpc(limit: Arc<Semaphore>) -> Result<Response, RpcError> {
    let _permit = limit
        .try_acquire_owned()
        .map_err(|_| RpcError::Busy)?;

    run_expensive_operation().await
}
```

`OwnedSemaphorePermit` 在请求结束或 future 被 drop 时归还 permit，因此并发配额不会永久泄漏。permit 不会在固定时间后自动归还：一个任务运行 1ms 或 1min 都占用同一个 permit，直至结束。这适合保护 CPU、数据库连接或 blocking worker；它不是时间限流。若把 permit 定时归还来模拟 TPS，语义会混淆且容易积压，fixed window、token bucket 或 GCRA 更直接。

按时间限流还要区分两个语义。非平滑 fixed window 的配额属于离散的 block/consensus 时间桶；相邻桶之间允许突发，是协议允许的行为。平滑 token bucket 的配额按经过的连续时间补回，目标是保护本机 mempool、RPC 或预执行资源。

#### Fixed Window（固定窗口，非平滑）：以共识时间桶为边界

若协议定义为“每个 consensus 秒最多 N 笔”，就应使用 consensus timestamp 或 block height 派生 bucket，不能用本机 wall-clock。N 笔落在 bucket 的结尾、另外 N 笔落在下一个 bucket 的开头，可能在很短的真实时间内观察到接近 `2 × N`；但它们属于两个独立协议窗口，因此不违反这个配额。

```rust
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct ConsensusWindowState {
    bucket: Option<u64>,
    used: u64,
}

#[derive(Clone, Default)]
struct FixedWindowRateLimiter {
    state: Arc<Mutex<ConsensusWindowState>>,
}

impl FixedWindowRateLimiter {
    fn try_acquire(&self, consensus_timestamp_ms: u64, max_per_second: u64) -> bool {
        let bucket = consensus_timestamp_ms / 1_000;
        let Ok(mut state) = self.state.lock() else {
            return false; // mutex poisoned: fail closed instead of exceeding the quota.
        };

        if state.bucket.map_or(true, |current| bucket > current) {
            state.bucket = Some(bucket);
            state.used = 0;
        }
        if state.bucket != Some(bucket) || state.used >= max_per_second {
            return false;
        }

        state.used += 1;
        true
    }
}
```

这段代码适合在 block 打包或执行时应用的协议配额。`FixedWindowRateLimiter` 可被多个 task clone；mutex 覆盖“读窗口、判断、递增”的完整临界区，不能在持锁期间 `.await`。Sui 的 gasless transaction limiter 则有两层 gate：本地层按 `Instant` 计算固定一秒窗口，限制单 validator 的即时准入；consensus 层由已提交 commit 回灌，按 consensus timestamp 分桶，反映全网已提交的用量。二者都低于 `max_tps` 才在本地放行。它是 fail-fast 的 TPS admission，而不是 semaphore。固定窗口实现可见 [Sui `gasless_rate_limiter.rs`](https://github.com/MystenLabs/sui/blob/cc59dbd5eafa02b022b84cfa0a58b6ac62a7e3c2/crates/sui-core/src/gasless_rate_limiter.rs#L76)。

consensus 层是全网 usage 的反馈 gate，不会随着本地时间自行滚动；它也不为并发 admission 原子预留全网额度。固定窗口的边界突发在协议时间桶语义下不是缺陷；只有它压垮 validator 的本地资源时，才需要额外的平滑层。

#### Token Bucket（令牌桶，平滑）：保护本地资源

若目标是限制连续时间内的平均速率，而不是实现 block 配额，可在协议 gate 之外使用 lazy-refill token bucket。不需要一个定时补 token 的 task，`Instant` 也避免 wall-clock 回拨。它只能改善单 validator 的流量平滑，不能修复全网配额的同步或预留语义。下面用固定点 credit（`SCALE` 个 credit 等于一个 token）避免浮点累计误差。

```rust
use std::sync::{Arc, Mutex};

const SCALE: u128 = 1_000_000_000;

struct TokenBucketState {
    credits: u128,
    last: std::time::Instant,
}

#[derive(Clone)]
struct TokenBucketRateLimiter {
    state: Arc<Mutex<TokenBucketState>>,
    rate_per_sec: u64,
    burst: u64,
}

impl TokenBucketRateLimiter {
    fn new(rate_per_sec: u64, burst: u64) -> Self {
        Self {
            state: Arc::new(Mutex::new(TokenBucketState {
                credits: u128::from(burst) * SCALE,
                last: std::time::Instant::now(),
            })),
            rate_per_sec,
            burst,
        }
    }

    fn try_acquire(&self) -> bool {
        let now = std::time::Instant::now();
        let Ok(mut state) = self.state.lock() else {
            return false; // mutex poisoned: fail closed.
        };
        let elapsed = now.checked_duration_since(state.last).unwrap_or_default();
        let refill = elapsed.as_nanos().saturating_mul(u128::from(self.rate_per_sec));
        state.credits = state
            .credits
            .saturating_add(refill)
            .min(u128::from(self.burst) * SCALE);
        state.last = now;

        if state.credits < SCALE {
            return false;
        }
        state.credits -= SCALE;
        true
    }
}
```

`new` 初始化 `credits = burst × SCALE`。`burst = 1` 接近均匀间隔；较大的 `burst` 则允许经过空闲期后的一小段突发。`TokenBucketRateLimiter` 也可被多个 task clone；mutex 在单次临界区内完成 refill、判断与扣 token。两类 limiter 的共同要求是状态更新原子化，且持锁期间不应 `.await`。若同一请求还要限制在途执行，先拿 semaphore permit，再调用 `try_acquire`；若 token 不足则立即 drop permit。这样 semaphore 拒绝不会消耗 TPS 配额，两种限制各自保持语义。

### Load Shedding（过载丢弃）：容量不足时丢弃可再获得的工作

当排队本身比丢弃更危险时，应选择可丢弃的数据。关键前提是上游能够重试、重新广播或从其他来源重新下载；不可重建的提交命令不能这样处理。

```rust
match queue.try_send(job) {
    Ok(()) => Ok(()),
    Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
        metrics.dropped_jobs.increment(1);
        Err(ServiceError::Overloaded)
    }
    Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => Err(ServiceError::Unavailable),
}
```

执行客户端的交易抓取器通常对已公告、但尚未拿到的交易 hash 维护全局容量、候选 peer 数和尝试次数；超限或没有候选来源时移除该 hash。交易仍可能由其他 gossip 或后续公告重新到达，因此这里的丢弃是有界降载，而不是丢失链状态。

### Circuit Breaking（熔断）：暂时停止向已知坏依赖发起工作

熔断把“持续失败的调用”转成“短路失败”，避免所有 worker 都阻塞在同一依赖上。它通常至少有 closed、open 和 half-open 三种状态；half-open 只允许少量探测请求。

```rust
if breaker.is_open() {
    return Err(DependencyError::TemporarilyUnavailable);
}

match call_peer().await {
    Ok(value) => {
        breaker.record_success();
        Ok(value)
    }
    Err(error) => {
        breaker.record_failure();
        Err(error)
    }
}
```

Reth 的 peer 管理没有把这套状态命名为 circuit breaker，但对连接失败采用相近的局部策略：peer 被 backoff，严重错误增加计数，达到条件后 ban 或移除；trusted/static peer 使用较短 backoff 以便后续重连。这保护的是单个 peer，不是服务级流量切换。

## 2. Recovery（故障恢复）：已失败的工作如何重新取得正确结果

预防只能减少失败，无法消除网络超时、暂态资源错误和链重组。恢复策略的关键是区分“同一输入再次执行是否安全”与“已经可见的状态是否必须逆转”。

### Retry（重试）：仅重试可重试且幂等的操作

重试必须有边界：最大次数、超时预算、退避和幂等键至少应明确其中一部分。否则故障期间的重试会成为额外负载。

```rust
for attempt in 0..MAX_ATTEMPTS {
    match fetch_from_peer().await {
        Ok(value) => return Ok(value),
        Err(error) if error.is_transient() && attempt + 1 < MAX_ATTEMPTS => {
            tokio::time::sleep(backoff(attempt)).await;
        }
        Err(error) => return Err(error),
    }
}
unreachable!("loop either returns success or its final error");
```

Reth 的交易抓取器有明确上限：单一来源第一次 timeout 可重试一次，否则优先改用其他候选 peer；达到每个 hash 的最大尝试次数就停止追踪。

Reth 的 pipeline 对普通 non-fatal `StageError` 也会丢弃当前事务并立即重跑 stage；当前路径没有统一 backoff 或全局最大次数，因此它适合预期短暂且很少发生的错误，而不适合作为远端依赖故障的通用策略。

### Fallback（降级）：主路径不可用时换到语义等价但成本不同的路径

降级不等于忽略错误。正确的 fallback 必须仍满足调用者所依赖的正确性条件，只是延迟、吞吐或功能集可能变差。

```rust
let state_root = match compute_parallel_state_root(input).await {
    Ok(root) if root == expected_root => root,
    Ok(_) | Err(_) => compute_serial_state_root(input)?,
};
```

Reth 的 state-root 计算正是这种模式：并行 sparse-trie task 报错、超时、断开或返回不匹配的 root 时，转为串行计算；成功 fallback 会记录指标。结果正确性未降低，代价是吞吐和延迟。

### Rollback（回滚）：撤销尚未完成或不再属于正确历史的状态

回滚的前提是系统保留了可验证的恢复点。例如数据库事务可以在 commit 前 abort，区块处理可以回退到 checkpoint，再从可信的高度继续。

```rust
let tx = database.begin_rw()?;
apply_stage(&tx, input)?;
tx.save_checkpoint(next_checkpoint)?;
tx.commit()?; // 此前任意错误都让 tx 在 Drop 时 abort。
```

Reth pipeline 在 stage 成功时把状态变更与 checkpoint 一起 commit；错误时显式 drop RW provider transaction。坏块、执行错误或静态文件数据缺失会返回 `ControlFlow::Unwind`，随后回到指定 checkpoint。

### Compensation（补偿）：为已提交的外部副作用执行反向操作

rollback 处理的是尚未提交或本地可回退的状态；compensation 处理的是已经对外可见、不能靠本地事务回滚的副作用。补偿命令也必须幂等，因为它自身可能失败或被重复投递。

```rust
let reservation = reserve_inventory(order_id).await?;
if let Err(error) = charge_payment(order_id).await {
    release_inventory(reservation.id).await?;
    return Err(error);
}
```

区块链节点没有通用 Saga 框架：已经传播到网络的交易或请求无法可靠“撤回”。Reth 最接近补偿的机制是链重组和 static-file 一致性修复：当文件与数据库的提交顺序产生不一致时，启动检查会修复可修复文件，或给 pipeline 返回 unwind target。这更准确地说是存储恢复与状态回滚，而不是业务补偿事务。

## 3. Containment（故障隔离）：让坏输入或坏组件不扩大影响

当失败不能立刻恢复时，下一目标是缩小爆炸半径。隔离的对象可以是请求、peer、task 或整个可选组件；选择哪个对象取决于错误是否污染共享状态。

### Reject / Fail Request（拒绝请求）：拒绝输入，不把它升级成节点故障

无效 payload 是调用级错误：执行客户端应把它报告为 `INVALID`，而不是让 node 停机。处理时还需要缓存已知无效头，避免重复执行同一坏输入。

```rust
match validate_payload(payload) {
    Ok(valid) => execute(valid).await,
    Err(validation_error) => {
        invalid_cache.insert(payload.hash());
        Ok(PayloadStatus::invalid(validation_error))
    }
}
```

Reth 将共识错误、access-list 解码错误和执行验证错误归为 validation error；provider error 或内部执行错误则升级为 `InsertBlockFatalError`。对于 validation error，tree 会记录 invalid header 并返回 `PayloadStatus::Invalid`。

### Isolate Task（隔离任务）：把 task 失败变成可观察事件

在 `panic = "unwind"` 构建中，Tokio task panic 默认局限在该 task。对于非关键 task，这种隔离可以防止单个辅助功能拖垮整个进程；对于关键 task，则应捕获 panic、记录 task 名称，并由上层决定是否升级。

设 `worker` 为被监控的 task，`on_shutdown` 为共享 shutdown future；`event_tx` 将 `TaskEvent::Panic` 发送给 `TaskManager`，`describe` 将 panic payload 转成诊断信息。核心控制流如下：

```rust
use futures_util::FutureExt;

let task = std::panic::AssertUnwindSafe(worker)
    .catch_unwind()
    .map_err(|payload| {
        let _ = event_tx.send(TaskEvent::Panic(describe(payload)));
    });
let task = std::pin::pin!(task);

// 正常完成或 panic promotion 都使 task ready；收到 shutdown 则 drop task。
let _ = futures_util::future::select(on_shutdown, task).await;
```

Reth 的 `spawn_critical_*` 使用同一结构：正常完成时 wrapper 完成；panic 时 `catch_unwind` 发送 `TaskEvent::Panic`；全局 shutdown 先到时，`select` drop 内层 task。后者没有额外 cleanup hook，因此只适用于可直接取消的工作。也就是说，`catch_unwind` 在这里隔离了 Rust unwind 边界和诊断信息，并不表示系统继续提供服务。

### Disable Component（禁用组件）：以明确的降级边界保留其余服务

禁用组件适用于可选功能：组件连续失败后停止该组件、拒绝相关请求或改用替代实现，而核心状态机继续运行。实现的关键是让调用者看到组件状态，不能静默返回过期或伪造结果。

```rust
if !indexer_enabled.load(std::sync::atomic::Ordering::Acquire) {
    return Err(ApiError::FeatureUnavailable);
}
```

Reth 没有统一的运行时“组件熔断并动态禁用”框架。可选 add-on、配置开关与 peer 级 ban 是不同粒度的机制；不要把 peer backoff 或 task panic 误称为通用组件禁用。

## 4. Suspension / Escalation（暂停与升级）：暂不处理，或交给持久化人工流程

有些失败既不能安全重试，也不该直接丢弃。系统可以暂停输入等待依赖恢复，或把失败事件移入独立的持久化处理通道。

### Block / Pause（阻塞或暂停）：用背压暂停输入，保护更昂贵的状态

暂停与 load shedding 的区别在于：前者保留工作并延迟处理，后者明确丢弃工作。背压需要队列边界；无界队列只能把压力从一个内存区域转移到另一个区域。

```rust
while persistence_in_progress() && queue_is_above_threshold() {
    wait_for_persistence_completion().await?;
}
process_next_request().await?;
```

Reth engine tree 在 persistence 落后超过阈值时停止从 engine 输入 channel 取新消息，优先等待持久化完成。它明确标注这是 soft backpressure：Engine API 没有真正背压语义，consensus client 仍可能 timeout 后重发，且上游 channel 仍可能增长。

### Dead Letter Queue（死信队列）：持久化无法自动处理的工作

死信队列（DLQ）将超过重试预算、格式无法解析或需要人工判断的消息持久化，并保留 payload、失败原因、尝试次数和关联 ID。它适合订单、通知、工作流等业务消息；不适合把共识状态机的内部错误悄悄延后。

```rust
async fn dead_letter(job: Job, error: &Error, store: &DlqStore) -> Result<()> {
    store.append(DeadLetter {
        job,
        reason: error.to_string(),
        attempts: MAX_ATTEMPTS,
    }).await
}
```

Reth node 核心路径没有通用 DLQ。交易抓取器达到尝试上限后移除 hash，pipeline fatal error 则使同步失败并上升到 node 退出；二者都不是“持久化待人工重放”的死信机制。

## 5. Termination（终止）：停止服务与停止 runtime 是两个阶段

前面的模式假设系统仍可定义局部边界。当关键状态无法继续证明一致，或关键任务已经消失时，终止比继续服务更安全。终止仍分为应用层收尾与调度器销毁两个阶段。

### Graceful Shutdown（优雅退出）：停止接收新工作，完成可安全完成的收尾

Reth 的 `GracefulShutdown` 是一个共享 shutdown future 加计数 guard。任务创建时 guard 计数加一；收到 signal 后，任务执行其收尾逻辑，drop guard 后计数减一。`do_graceful_shutdown` 广播事件并等待计数归零，直到超时。核心不是单独 `await shutdown`，而是让正常运行的 service future 与 shutdown future 竞争；下面是一个网络管理器的实际控制流。

作为对照，普通 `spawn_task` 的 wrapper 只有“正常 task 完成”与“全局 shutdown 先到”两条路径；后一条直接 drop 原 future，没有给它补跑清理逻辑的机会。

```rust
let fut = std::pin::pin!(fut);
let _ = futures_util::future::select(on_shutdown, fut).await;
```

需要 flush、关闭连接或持久化的 task 因而不能只依赖这个 wrapper，而要像 network 一样持有 `GracefulShutdown` guard 并把 cleanup 放在自身的 `select!` 汇合点之后。

```rust
pub async fn run_until_graceful_shutdown<F, R>(
    mut self,
    shutdown: GracefulShutdown,
    shutdown_hook: F,
) -> R
where
    F: FnOnce(Self) -> R,
{
    let mut graceful_guard = None;

    tokio::select! {
        // 正常路径：NetworkManager 自己结束，随后同样运行网络收尾和 hook。
        _ = &mut self => {},
        // shutdown 路径：保留 guard，直到 hook 完成。
        guard = shutdown => {
            graceful_guard = Some(guard);
        },
    }

    self.perform_network_shutdown();
    let res = shutdown_hook(self);
    drop(graceful_guard);
    res
}
```

两条路径在 `select!` 后汇合：正常结束时，未被轮询的 `shutdown` 被 drop；收到 shutdown 时，guard 被延长到 `shutdown_hook` 返回之后。因此 `perform_network_shutdown` 与 hook 始终执行，而 graceful guard 只覆盖“由 shutdown 触发”的收尾窗口。网络收尾应停止接收和发起连接、以 `ClientQuitting` 断开 session、丢弃 pending connection；hook 可在这里保存 known peers。

另一个必须收尾的 task 是 consensus engine。它收到 graceful signal 后向 tree thread 发送 `Terminate` 并等待完成；tree thread 会等待 in-flight persistence、处理必要的磁盘 reorg，并将内存中已执行但尚未持久化的 block 刷到 head。

```rust
async fn terminate_engine(mut to_tree: ToTree, shutdown: GracefulShutdown) {
    let guard = shutdown.await;
    let (done_tx, done_rx) = tokio::sync::oneshot::channel();

    let _ = to_tree.send(FromOrchestrator::Terminate { done: done_tx });
    let _ = done_rx.await; // tree drain in-flight persistence and flushes safe blocks.
    drop(guard);
}
```

本地交易备份 task 也可在持有 guard 的窗口内把 local transaction 写入文件，以便下次启动重新导入。

### Immediate Shutdown（立即退出）：销毁 runtime，停止剩余调度工作

立即退出的目标是保证进程不继续运行，不是执行业务收尾。CLI 的上层控制流等待 command 完成（`Ok` 或 `Err`）、退出信号或 critical task panic；只有 `Ok(())` 的正常完成或退出信号路径才等待 graceful hook。任何 `Err`——包括 command error 与 promoted critical panic——记录日志后直接进入 `runtime_shutdown`；任一路径最后都会 teardown runtime。

```rust
let command_res = runtime.handle().block_on(run_to_completion_or_panic(
    task_manager_handle,
    run_until_ctrl_c(command(context)),
));

match &command_res {
    Ok(()) => runtime.graceful_shutdown_with_timeout(graceful_timeout),
    Err(error) => tracing::error!(%error, "shutting down due to error"),
}

runtime_shutdown(runtime, true);
command_res
```

`runtime_shutdown` 随后在独立的 `rt-shutdown` thread 中调用 `Runtime::shutdown_timeout`：它取出 owned Tokio runtime，并调用 Tokio 的 `shutdown_timeout`，避免在 runtime 的 async context 内阻塞。

Tokio teardown 后，普通 async task 在下一次 yield 时会被 drop，不能保证跑完；`spawn_blocking` 的闭包无法被强制取消，超时后调用方停止等待，工作可能继续运行。因而 teardown 必须放在 graceful 收尾之后，而不能替代 graceful 收尾。

#### Immediate Shutdown（立即退出）与 panic（恐慌）的区别

panic 是 Rust 的控制流和错误报告机制；immediate shutdown 是系统生命周期操作。两者不能互相替代。

```rust
// 在 panic = "unwind" 构建中，只影响这个 Tokio task；其他 task 仍可运行。
tokio::spawn(async { panic!("worker invariant broken") });

// 这是进程级决策：停止 runtime 后由顶层决定退出码。
runtime.shutdown_timeout(Duration::from_secs(5));
std::process::exit(1);
```

在 `panic = "unwind"` 构建中，若 panic 发生在一个 Tokio child task，Tokio 将该 task 标记为失败，主 task 与其他 child task 不会自动 panic。Reth 因此把 critical child task 的 panic promotion 为 `PanickedTaskError`：critical wrapper 发送 `TaskEvent::Panic`，`TaskManager` 结束，CLI 的 `run_to_completion_or_panic` 返回错误。若构建使用 `panic = "abort"`，则会直接终止进程，以下 promotion 路径不会执行。

在 Reth 的当前 CLI 路径中，正常完成或 Ctrl-C/SIGTERM 才显式调用 `graceful_shutdown_with_timeout`；critical panic 导致的错误路径记录日志后直接进入 `runtime_shutdown`。`TaskManager` 被 drop 仍会让共享 shutdown signal 触发，因此其他 shutdown-aware task 能收到停止通知，但 CLI 不等待 graceful guard 完成。这是 best-effort 通知加 fail-stop，而不是保证刷盘完成的优雅退出。顶层在 command 返回 `Err` 时打印错误并执行 `std::process::exit(1)`；正常退出则从 `main` 返回。

## 结语：按状态可恢复性决定升级等级

- 纯内存、可从网络或链状态重建的工作，可以限流、丢弃或取消。
- 单个未提交的 MDBX（嵌入式数据库事务层）写事务可依靠 `Drop` abort；已提交事务保持原子性。
- static file、checkpoint 与多个存储层之间的中断，需要启动一致性检查、修复或 pipeline unwind。
- 关键 engine、provider、state-root 或持久化不变量失败时，应停止提供服务；恢复责任转移到已提交事务、启动校验与重新同步。
- 优雅退出负责执行仍然安全的协议动作和持久化（比如退出前存储内存中的 blocks、peers 等）；runtime teardown 负责停止 async task 的继续调度，并在 deadline 内等待 runtime 的 blocking pool；超过 deadline 的不可取消 blocking work 不能由它保证终止；顶层进程退出负责给监督器明确的失败结果。

因此，设计新 task 时应先写下它的停止契约：它是可直接丢弃、需要事务 abort、需要 graceful flush，还是必须把故障 promotion 为 node 级退出。这个契约比“是否使用 `spawn`”更能决定错误处理是否正确。
