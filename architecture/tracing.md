## 完整的 rust tracing macro 家族
https://github.com/tokio-rs/tracing

```
// 事件（一次性日志）—— 五个级别一一对应
trace!(...)    debug!(...)    info!(...)    warn!(...)    error!(...)

// 块级 span（作用域开始到结束）—— 五个级别一一对应
trace_span!(...)    debug_span!(...)    info_span!(...)    warn_span!(...)    error_span!(...)

// 通用形式（要自己写 level 参数）
event!(Level::DEBUG, ...)
span!(Level::DEBUG, ...)

// 函数级 span（attribute macro，来自 tracing-attributes）
#[instrument(level = "debug", ...)]
全部来自 tracing crate（#[instrument] 由 tracing-attributes 实现，由 tracing re-export）
```

还有一个细节：tracing-log 桥接。reth 依赖的某些第三方库（比如 hyper、reqwest、某些老 crate）内部还在用 log crate。怎么把这些 log 也收进 tracing 体系？

```
答案是 tracing-log 这个桥接 crate：

// 程序启动时调一次
tracing_log::LogTracer::init().unwrap();
```

---

# reth 链路追踪与调试

## 一、机制

### 1. reth 的链路追踪/调试机制（都来自 tracing 库）

reth 统一使用 Rust 生态的 `tracing` 库（不是 `log`）。它把"调试输出"分成两个正交概念：

- **Event（事件 / 一次性日志）**：`error!` / `warn!` / `info!` / `debug!` / `trace!`，对应五个级别。写法都一样，关键是结构化字段（`?` = Debug，`%` = Display）：
  ```rust
  debug!(target: "engine::tree", ?block_hash, txs = block.body.len(), "executed block");
  ```
- **Span（跨度 / 一段执行过程的上下文作用域）**：圈出一段时间，期间所有 event 自动带上该 span 的字段。两种创建方式：
  - **`#[instrument]` 属性宏**：给整个函数包一个 span，最常用。
    常用参数：`level` / `target`；`skip(self)` / `skip_all`（不把参数自动记进字段）；`fields(...)`（手动加字段）；`name = "..."`（自定义 span 名，默认是函数名）；`ret` / `err`（自动记录返回值/错误）。
  - **`debug_span!` / `info_span!` / `trace_span!`**：手动建 span，控制更精细。
    ```rust
    // 进入即生效，guard drop 时退出
    let _g = debug_span!(target: "...", "Retrieving reverts").entered();
    // 只包裹一个闭包
    debug_span!(target: "...", "execution").in_scope(|| executor.execute())?;
    ```

**target 的角色**：target 不是唯一标识，而是命名空间 / 分类维度（层级用 `::` 分隔），唯一作用是过滤。通过 `RUST_LOG` 精确控制：
```bash
RUST_LOG="info,engine::tree=debug,trie::proof_task=trace"
```
reth 常见高频 target：`reth::cli`、`engine::tree`、`rpc::eth`、`net::tx`、`txpool`、`payload_builder`、`trie::proof_task`、`engine::tree::payload_validator` 等。

### 2. 链路追踪用什么做唯一标识？

reth 没有分布式系统那种全局 `trace_id`，而是用**领域对象的自然主键**（通常是 hash / number）放进 span 字段来串联链路：

| 场景 | 标识字段 |
|---|---|
| 区块 | `block_hash`(B256)、`block_number` |
| 交易 | `tx_hash` / `hash` |
| Payload 构建 | `payload_id` |
| P2P 会话 | `peer_id`、`remote_addr` |
| RPC/IPC | `conn_id`、`method` |
| Trie worker | `worker_id` |
| ExEx | `id` |

把标识字段放进**外层 span 的 `fields(...)`**，该 span 内所有 event（哪怕在很深的调用栈里）都会自动携带。这就是链路串联方式：grep `block_hash=0xabc...` 即可把一个区块从校验→执行→插入树的全过程串起来，无需每条日志手动重复传。

之所以用 hash/number 而非 UUID：区块链场景的天然主键已经是稳定且全局唯一的标识符。

两个维度小结：
- **target** = 横向"在哪个子系统"（分类、过滤开关）
- **span 字段（hash/number/id）** = 纵向"针对哪个具体对象的一次处理"（串联链路）

### 3. `#[instrument]` / `*_span!` 本身不会单独打印一行日志

Span 不是日志，而是"上下文作用域"。它只在别人输出 event 时，作为**前缀贴在那条 event 上**。

- 如果一个被 `#[instrument]` 装饰的函数体里一条 event 都没打，那么在默认配置下它**完全静默**（只对 tracing-tracy / samply 这类 span 计时后端有意义）。
- reth 的 fmt layer 默认是 `FmtSpan::NONE`（没开 `with_span_events`），所以平时看不到 span 自身的 enter/exit/close 行，只看到 event 上的 span 前缀。

如insert_blocks 里没有任何 debug!/info!,那instrument里包含的fields相关日志就不存在了。
```
#[instrument(level = "debug", target = "providers::db", skip_all, fields(block_count = blocks.len()))]
fn insert_blocks(&self, blocks: Vec<Block>) -> Result<()> {
    debug!(target: "providers::db", first = %blocks[0].number, "inserting");
    // ...
    Ok(())
}
```

一行日志的格式拆解：
```
2026-06-18T09:12:04Z TRACE execute_block{block=0xabc1.. number=100}: engine::tree: executing tx tx=0xdead..
─────────────────── ───── ──────────────────────────────────────  ────────────  ────────────────────────
     时间戳         LEVEL        span 前缀（name{fields}）            target(event)   message + event 字段
```

三种 `--log.stdout.format`（`crates/tracing/src/formatter.rs`：terminal / logfmt / json）下同一条日志：
- **terminal**（默认，人读）：`... TRACE execute_block{block=0xabc1.. number=100}: engine::tree: executing tx tx=0xdead..`
- **logfmt**（key=value，适合 grep/Loki）：`level=trace ... target=engine::tree execute_block.block=0xabc1.. msg="executing tx" tx=0xdead..`
- **json**（适合机器采集）：span 字段独立放进 `span` / `spans` 数组，比 terminal 的 `{}` 前缀更好解析——接 Loki/ELK 时一般用 json 或 logfmt。

若想看到 span 的进入/退出/耗时，需要在构建 fmt layer 时加 `.with_span_events(FmtSpan::CLOSE)`（reth 默认未开），CLOSE 行会带 `time.busy` / `time.idle`。

### 4. 嵌套日志（span 如何传播到子函数）

`#[instrument]` 建的 span 在**整个函数体执行期间都激活**，包括它调用的所有子函数（同一线程、同步调用）。

- **子函数没有 `#[instrument]`**：子函数里的 event 直接挂在父 span 下，前缀就是父 span。
- **子函数也有 `#[instrument]`**：形成父子嵌套，内部 event 带上**两层** span 前缀，用 `:` 连接：
  ```
  DEBUG on_new_payload{block_hash=0xabc.. block_num=100}:try_insert_payload: engine::tree: inserting
  ```

关键点：
1. span 是"作用域继承"，不是"复制字段到子函数签名"。`#[instrument]` 不修改子函数代码，只是让父 span 在调用期间保持激活。
2. 子函数无需重复写 `block_hash`。即使子函数 `#[instrument]` 是 `skip_all` 没带字段，父 span 的标识字段已在前缀里——这就是为什么 reth 只在最外层入口放标识字段，内层 `skip_all` 即可。
3. **唯一例外是跨线程**：`spawn` / `spawn_blocking` 到别的线程时，新线程默认拿不到父 span，链路会断。

**target 为什么不重复输出**：target 不是 span 前缀的一部分，它属于产生那一行的 event，所以一行只有一个 target。即使父子 span 的 `#[instrument]` 都写了 `target = "engine::tree"`，这些 target 也不会渲染进前缀（前缀里只有 span 名）。span 上的 target 只用于过滤（决定 span 是否启用），不参与输出格式。reth 里 span 和 event 常写相同 target，纯粹是为了 `RUST_LOG` 过滤时行为一致（一起开/一起关），不是为了输出好看。

> 前缀 = span 名链（target 不出现）；冒号后的 target = 那条 event 的 target。两者独立。

## 二、使用注意

### 1. 在 async 里更要用 `#[instrument]`（因为手动写易错）

`tracing` 文档强调 `#[instrument]` 用于 async，意思是"async 里更要用它"，**不是只能用于 async**——它对同步函数同样适用，且这是它最原始、最常见的用途。reth 在大量同步函数（provider、trie walker、engine tree，如 `on_downloaded_block`）上用它，完全正确。

差异在 `.await`：`tracing::Span` 的 enter guard 绑定**线程**，而 async task 会在 `.await` 点让出线程。

```rust
async fn handle(&self) {
    let span = debug_span!("handle");
    let _g = span.entered();   // ❌ bug：_g 跨 .await 仍 alive
    something().await;          // task 在此挂起，线程去跑别的 task，
                                // 但 span 还"激活"着 → 别的 task 日志被错误归到 handle span
}
```

正确做法：要么 `future.instrument(span).await`，要么直接用 `#[instrument]`——它对 async 函数做了特殊处理：只在 future 被 poll 时 enter、被让出时 exit，自动对齐 task 的实际执行片段。

| | 同步 fn | async fn |
|---|---|---|
| `#[instrument]` | ✅ 可用，等价于手动 span | ✅ 推荐，自动处理 `.await` 让出 |
| 手动 `span.entered()` | ✅ 可用 | ⚠️ 跨 `.await` 会串台，要改用 `.instrument()` |

## 三、举例：engine::tree 区块执行的 trace 链路全景

从共识层 `engine_newPayloadV*` 进来，到区块执行完插入树，span 嵌套关系（缩进 = 嵌套层级，`{}` 内是该 span 的标识字段，行尾是代码位置）：

```
on_new_payload{block_hash=0x.. block_num=N}                         crates/engine/tree/src/tree/mod.rs:555  入口
└─ insert_block_or_payload{block_id}                               crates/engine/tree/src/tree/mod.rs:2556
   └─ validate_block_with_state{parent=0x.. type_name=..}          payload_validator.rs:325  执行主干
      ├─ state provider                                            payload_validator.rs:375 (debug_span)取父状态 provider
      ├─ evm env                                                   payload_validator.rs:400  构建 EVM 环境
      ├─ spawn_payload_processor{strategy}                         payload_validator.rs:873  按 StateRootStrategy 决定算法
      │  └─ payload processor                                      payload_processor/mod.rs:215 (name=)
      │     ├─ [并发线程] spawn_all（prewarm 预热缓存）              prewarm.rs:167  parent: 显式挂回
      │     └─ [并发线程] multiproof / sparse trie（状态根计算）      multiproof.rs
      ├─ execute_block  → 内部 metrics.rs 执行循环：                payload_validator.rs:646
      │  ├─ pre execution                                          metrics.rs:90
      │  ├─ execution                                              metrics.rs:95
      │  │  └─ execute tx{tx_hash=0x.. gas_used=<动态填>}（每笔交易一个） metrics.rs:104
      │  ├─ finish                                                 metrics.rs:125
      │  └─ merge transitions                                      metrics.rs:142
      ├─ await_state_root                                          payload_processor/mod.rs:622  等状态根算完
      └─ validate_post_execution                                   payload_validator.rs:791
         ├─ validate_header_against_parent                         payload_validator.rs:812
         ├─ validate_block_post_execution                          payload_validator.rs:823
         └─ validate_block_post_execution_with_hashed_state        payload_validator.rs:839
```
（`payload_validator.rs` / `metrics.rs` 等均位于 `crates/engine/tree/src/tree/` 下；`prewarm.rs` / `multiproof.rs` / `mod.rs(payload_processor)` 位于 `crates/engine/tree/src/tree/payload_processor/`。）

**串联标识符**：整条链路靠最外层 `on_new_payload{block_hash, block_num}` 一次性放进字段，内层所有 event 自动继承；交易粒度再补 `tx_hash`。

**动态字段技巧**（metrics.rs:104）：建 `execute tx` span 时 gas 还未知，先用 `gas_used = tracing::field::Empty` 占位声明，执行完用 `enter.record("gas_used", gas_used)` 回填——把这笔交易的耗时 span 和它消耗的 gas 绑在一起。

**target 分层**（横向过滤维度）：
```
engine::tree                                  主流程（入口、执行循环 metrics）
engine::tree::payload_validator               校验 + 执行编排
engine::tree::payload_processor               状态根任务编排
engine::tree::payload_processor::prewarm      缓存预热（并发）
engine::tree::payload_processor::multiproof   多证明 / 状态根计算（并发）
```
只看一个区块的执行、又不想被预热/证明的海量 trace 淹没：
```bash
RUST_LOG="info,engine::tree=debug,engine::tree::payload_processor=info"
```

**关键细节：跨线程的 span 传播**。prewarm / multiproof 是 `spawn_blocking` 到别的线程跑的，而当前 span 是线程局部的——子线程默认拿不到父 span，链路会在线程边界断掉。reth 的办法是手动捕获 + 显式挂回父 span：
```rust
// 在原线程构造时先抓住当前 span（prewarm.rs 中的 parent_span 字段）
parent_span: Span::current(),
// 到了 spawn_blocking 的新线程里，用 parent: 显式指定父 span（prewarm.rs:167）
let _enter = debug_span!(target: "...prewarm", parent: span, "spawn_all").entered();
```
凡是 `spawn` / `spawn_blocking` 出去的 span，都要这样传 `Span::current()` + `parent:`，否则链路断裂——这是异步/多线程链路追踪最常见的坑。同步调用链（`on_new_payload → try_insert_payload → insert_payload → ...`）则全程自动继承，无需额外处理。

**实跑观察**：
```bash
RUST_LOG="engine::tree=trace,engine::tree::payload_validator=debug" reth node ...
# 再 grep 某个区块即可拉出整条链：
grep 'block_hash=0xabc1' reth.log
```