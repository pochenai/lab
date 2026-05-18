# Flashblocks ↔ TxPool 接线（含 EIP-8130 / OpDualPool）

## TL;DR

xlayer-reth 的 flashblocks payload builder 不直接选 pool 类型。pool 由 upstream `OpPoolBuilder` 构造，通过 reth 框架的 `ComponentsBuilder::build_components` 把同一个 `pool` 实例注入到 `PayloadServiceBuilder::spawn_payload_builder_service`。EIP-8130 升级后，upstream 把 pool 类型换成 `OpDualPool`（内部 merge 协议池 + AA 池），下游因为是泛型接收，自然继承——零修改。

## 1. 泛型边界：`PoolBounds` 是怎么让接线"透明"的

`bin/node/src/payload.rs:108-112`：

```rust
impl<Node, Pool> PayloadServiceBuilder<Node, Pool, OpEvmConfig> for XLayerPayloadServiceBuilder
where
    Node: NodeBounds,
    Pool: PoolBounds,
{
    async fn spawn_payload_builder_service(
        self, ctx: &BuilderContext<Node>, pool: Pool, evm_config: OpEvmConfig,
    ) -> eyre::Result<...> { ... }
}
```

`PoolBounds` 定义在 `crates/builder/src/traits.rs:61-66`：

```rust
pub trait PoolBounds:
    TransactionPool<Transaction: OpPooledTx<Consensus = OpTransactionSigned>> + Unpin + 'static
{ }
```

只约束了 `TransactionPool` + 交易类型是 `OpPooledTx`。**没有钉死具体类型**。所以无论框架塞过来的是 `OpPool` 还是 `OpDualPool`，只要满足这两个 bound，编译都过。

下游 flashblocks builder 对 pool 的全部使用:

| 位置 | 调用 |
|---|---|
| `crates/builder/src/flashblocks/builder.rs:531` | `self.pool.best_transactions_with_attributes(ctx.best_transaction_attributes())` |
| `crates/builder/src/flashblocks/builder.rs:706` | 同上（每个 flashblock 切片 refresh） |

仅此而已。`OpDualPool::best_transactions_with_attributes` 内部已做 `MergeBestTransactions(protocol_pool, aa_pool, base_fee)`（见 `deps/optimism/rust/op-reth/crates/txpool/src/dual_pool.rs:1061-1072`），所以 AA tx 自动出现在 best iterator 里，调用方无感。

## 2. 接线分三段，xlayer-reth 一行没碰

### 段 1：选 pool builder 类型（在 OpNode 内部）

`deps/optimism/rust/op-reth/crates/node/src/node.rs:227-251`：

```rust
pub fn components<Node>(&self) -> OpNodeComponentBuilder<Node> {
    ComponentsBuilder::default()
        .node_types::<Node>()
        .executor(OpExecutorBuilder::default())
        .pool(                          // ← 把 OpPoolBuilder 钉进 ComponentsBuilder
            OpPoolBuilder::default()
                .with_enable_tx_conditional(self.args.enable_tx_conditional)
                .with_supervisor(...),
        )
        .payload(BasicPayloadServiceBuilder::new(OpPayloadBuilder::new(...)))
        .network(OpNetworkBuilder::new(...))
        .consensus(OpConsensusBuilder::default())
}
```

同文件 `node.rs:311-318` 把类型槽位钉死：

```rust
type ComponentsBuilder = ComponentsBuilder<
    N,
    OpPoolBuilder,                    // ← Pool builder slot
    BasicPayloadServiceBuilder<OpPayloadBuilder>,
    OpNetworkBuilder, OpExecutorBuilder, OpConsensusBuilder,
>;
```

### 段 2：`.payload(payload_builder)` 只换 payload，保留 pool

reth 主仓 `crates/node/builder/src/components/builder.rs:285-308`（git 依赖 `okx/reth@044b173`）：

```rust
pub fn payload<PB>(
    self, payload_builder: PB,
) -> ComponentsBuilder<Node, PoolB, PB, NetworkB, ExecB, ConsB>
where
    PB: PayloadServiceBuilder<Node, PoolB::Pool, ExecB::EVM>,   // ← 关键 bound
{
    let Self { pool_builder, payload_builder: _, network_builder, .. } = self;
    ComponentsBuilder { pool_builder, payload_builder, ... }    // ← pool_builder 原样透传
}
```

`PB: PayloadServiceBuilder<Node, PoolB::Pool, ExecB::EVM>` 这一行是关键——编译器要求"用户给的 payload builder 必须能吃 `PoolB::Pool`"。当前 `PoolB = OpPoolBuilder`，`PoolB::Pool = OpAaTransactionPool = OpDualPool<...>`，所以 `XLayerPayloadServiceBuilder` 必须用泛型 `Pool: PoolBounds` 才能匹配。

xlayer-reth 主入口 `bin/node/src/main.rs:168`：

```rust
.with_components(op_node.components().payload(payload_builder))
//                                    ^^^^^^^ 只覆盖 PayloadB slot
```

### 段 3：pool builder 实际构造 `OpDualPool`

`deps/optimism/rust/op-reth/crates/node/src/node.rs:1063-1242`：

```rust
impl<Node, T, Evm> PoolBuilder<Node, Evm> for OpPoolBuilder<T> ... {
    type Pool = OpAaTransactionPool<Node::Provider, DiskFileBlobStore, Evm, T>;
    //          ↑ 即 OpDualPool<OpPool, ...>（见 txpool/src/lib.rs:68）

    async fn build_pool(self, ctx, evm_config) -> Self::Pool {
        // ... 构造 inner_pool, validator
        let op_pool = OpPool::new(inner_pool, interop_filter_enabled);
        let transaction_pool = OpDualPool::with_node_config(
            op_pool, provider, aa_validator, &final_pool_config,
        );
        // 起 maintain_eip8130_state_future 等任务
        Ok(transaction_pool)
    }
}
```

## 3. 直接调用点：`build_pool` 由谁触发

不在 xlayer-reth、也不在 `deps/optimism/`，在 reth 主仓 git 依赖里。

`crates/node/builder/src/components/builder.rs:375-403`（`okx/reth@044b173`）：

```rust
impl<Node, PoolB, PayloadB, NetworkB, ExecB, ConsB> NodeComponentsBuilder<Node>
    for ComponentsBuilder<Node, PoolB, PayloadB, NetworkB, ExecB, ConsB>
where
    PoolB: PoolBuilder<Node, ExecB::EVM, Pool: TransactionPool>,
    PayloadB: PayloadServiceBuilder<Node, PoolB::Pool, ExecB::EVM>,
    ...
{
    async fn build_components(self, context: &BuilderContext<Node>) -> eyre::Result<Self::Components> {
        let evm_config = executor_builder.build_evm(context).await?;
        let pool = pool_builder.build_pool(context, evm_config.clone()).await?;   // ← 389: 这里调
        let network = network_builder.build_network(context, pool.clone()).await?;
        let payload_builder_handle = payload_builder
            .spawn_payload_builder_service(context, pool.clone(), evm_config.clone())
            .await?;                                                              // ← 同一个 pool 实例
        let consensus = consensus_builder.build_consensus(context).await?;
        Ok(Components { transaction_pool: pool, evm_config, network, payload_builder_handle, consensus })
    }
}
```

`build_components` 自身由 launcher 触发——`EngineNodeLauncher` / `DebugNodeLauncher`（同 reth crate，`crates/node/builder/src/launch/engine.rs` 等），对应 `bin/node/src/main.rs:319-325` 的 `EngineNodeLauncher::new(...).launch_with(launcher)` 入口。

## 4. 全链路图

```
bin/node/src/main.rs:88            OpNode::new(rollup_args)
                                              │
bin/node/src/main.rs:168           op_node.components()
                                              │  返回 OpNodeComponentBuilder
                                              │  = ComponentsBuilder<_, OpPoolBuilder, BasicPayloadSvc<OpPayloadBuilder>, ...>
                                              │
                                   .payload(XLayerPayloadServiceBuilder)
                                              │  只替换 PayloadB；OpPoolBuilder 原样保留
                                              │
bin/node/src/main.rs:325           builder.launch_with(EngineNodeLauncher::new(...))
                                              │
reth crate (okx/reth@044b173):
                                   ComponentsBuilder::build_components(ctx)
                                              │  (components/builder.rs:375)
                                              ├── OpPoolBuilder::build_pool(ctx, evm)
                                              │       │
                                              │       └── 构造 OpDualPool<OpPool, ...>
                                              │           (deps/optimism/rust/op-reth/crates/node/src/node.rs:1063-1242)
                                              │
                                              └── XLayerPayloadServiceBuilder::spawn_payload_builder_service(ctx, pool, evm)
                                                      │
                                                      └── FlashblocksBuilder { pool: OpDualPool, ... }
                                                            │
                                                            └── pool.best_transactions_with_attributes(...)
                                                                返回 MergeBestTransactions(protocol, aa, base_fee)
                                                                AA tx 自动进入 flashblock 切片
```

## 5. 为什么这次升级"无缝"

| 因素 | 作用 |
|---|---|
| `OpNode::components()` 内部把 `OpPoolBuilder` 钉死 | 下游无需感知 pool 类型变化 |
| reth `ComponentsBuilder::payload()` 只换 payload 槽位 | 下游 `op_node.components().payload(...)` 不影响 pool 链路 |
| xlayer-reth 用 `Pool: PoolBounds` 泛型接 payload builder | 任意满足 `TransactionPool + OpPooledTx` 的 pool 都能塞进来 |
| `OpDualPool` 实现 `TransactionPool` 时透明 merge AA 池 | `best_transactions_with_attributes` 调用方零修改 |
| EIP-8130 全部新增逻辑（验证、侧池、维护任务）在 `OpPoolBuilder::build_pool` 内完成 | 完全黑盒于下游 |

## 6. 剩余需要验证的点（非接线问题）

1. **AA 池延迟 vs flashblock 200ms 切片**：`prevalidate_aa` / `finalize_admit_aa` 时序如果 > 一个切片窗口，AA tx 会错过当前切片，下个 refresh 才进。属于上游 AA pool 的延迟特性。
2. **flashblock 广播路径中 `OpReceipt::Eip8130` 的编码**：`crates/builder/src/flashblocks/builder.rs:67` 的 `convert_receipt` 把它桥到 `op_alloy_consensus::OpReceipt::Eip8130`，需要 e2e 验证 peer 端能吃。
3. **`builder_tx.rs:474` 的 `eip8130: Default::default()`** 只用于 builder 自己的 1559 sim call，与 AA 用户 tx 路径无关，别误读。
