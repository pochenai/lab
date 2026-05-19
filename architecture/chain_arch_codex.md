# tempo / base / optimism rust 技术栈分层与 wrap 边界

日期：2026-05-14

范围：

- tempo: `/home/po/now/tempo`
- base: `/home/po/now/base`
- optimism: `/home/po/now/optimism/rust`，只看 Rust 目录

这里的 "wrap" 指：上游模块的核心语义不变，只通过 trait、builder、adapter、newtype、配置或组合方式接入。  
"不能 wrap" 指：链自己的协议语义已经进入编码、trie root、交易有效性、EVM 状态转移、payload 排序、区块头字段或共识校验；这类地方必须成为本链的一等实现，最多复用上游的框架接口，不能把上游实现当黑盒包起来。

## 总体结论

三者都在复用 Reth 的 execution-client 工程骨架，但复用深度不同：

| 项目 | 实际直接 upstream | 架构形态 | 主要协议 delta | 总体取舍 |
| --- | --- | --- | --- | --- |
| tempo | reth | Reth SDK 外壳 + Tempo 自有协议内核 | 毫秒时间戳、稳定币 fee、AA 交易、2D nonce、payment lane/subblock/system tx、Commonware Simplex consensus | 上游复用面大，协议内核改得深；Reth 升级依赖 trait 稳定性 |
| optimism rust | reth / alloy / revm | OP Stack 分层：op-alloy + op-revm/alloy-op-evm + op-reth + kona | deposit tx、OP receipt、L1 data fee、DA footprint、OP header 字段、derivation/proof | 模块边界最清楚，但 fork 触点多，每次协议升级要跨多 crate 协调 |
| base | reth，外加自己 port/改写 OP 语义 | Reth SDK + Base 本地 OP-like 栈 + Base 自有 builder/proof/AA | EIP-8130、Base hardfork、Base revm/precompile、txpool ordering、flashblocks/engine-tree/proof infra | 自主性最高，能快速做 Base-specific 产品和协议；OP 逻辑维护成本最大 |

用户的直觉基本成立：Base 理论 lineage 是 Optimism/OP Stack，但代码组织上并不是简单以 `op-reth` 作为 upstream。它更像是直接站在 Reth 上，把 OP 的类型/执行/节点结构 port 到 `base-*` crate，再继续加入 Base 自己的协议和产品能力。

## 判断标准：哪些可以 wrap，哪些不能

可以 wrap 的条件通常是：

- 上游已经通过 trait 暴露边界，例如 `NodeTypes`、`ComponentsBuilder`、`PayloadBuilder`、`ConfigureEvm`、`FullConsensus`、txpool validator/builder。
- 本链只改配置、入口、RPC、链参数、调度方式、排序策略，未改变共识可见结果。
- 上游模块产出的 trie root、receipt encoding、block hash、state transition 与本链协议仍一致。

不能只 wrap 的条件通常是：

- 交易 envelope、receipt、header 的编码或 typed transaction id 变了。
- EVM transaction env、precompile、gas charging、system call、pre/post block transition 变了。
- payload 构造顺序、强制交易、system transaction、subblock、DA limit、lane accounting 变了。
- 区块头字段、withdrawals root、blob gas 字段、extra_data、base fee 参数、timestamp 语义变了。
- txpool 的可接收性、nonce 模型、balance/fee validity、best transaction iteration 变了。

这些点一旦做错，不是功能 bug，而是共识 bug。所以工程上通常会保留 Reth 的框架，把本链语义放进自己的 primitives / evm / consensus / payload / txpool crate。

## tempo

### upstream 与分层

Tempo 的直接 upstream 是 Reth。`/home/po/now/tempo/Cargo.toml` 里大量依赖 `reth-*` crate，来自同一个 Reth git revision；同时引入 `commonware-*` 作为 consensus/CL 侧能力。

节点装配在 `/home/po/now/tempo/crates/node/src/node.rs`：

- `NodeTypes` 换成 Tempo 自己的类型：
  - `Primitives = TempoPrimitives`
  - `ChainSpec = TempoChainSpec`
  - `Storage = EthStorage<TempoTxEnvelope, TempoHeader>`
  - `Payload = TempoPayloadTypes`
- component 仍用 Reth node-builder 风格：
  - pool: `TempoPoolBuilder`
  - executor/EVM: `TempoExecutorBuilder` / `TempoEvmConfig`
  - payload: `BasicPayloadServiceBuilder<TempoPayloadBuilderBuilder>`
  - network: `EthereumNetworkBuilder`
  - consensus: `TempoConsensusBuilder`
- RPC 通过 Reth add-on 体系挂接，增加 `TempoToken`、`TempoEthExt`、`TempoSimulate`、`TempoAdminApi`、`TempoOperatorRpc`、`TempoForkScheduleRpc` 等。

这说明 Tempo 没有 fork 成一个完全独立 client，而是把 Reth 当 execution-client SDK：外壳、provider、network、RPC、payload service 调度、db/trie 基础设施尽量复用；协议核心自己实现。

### 可以 wrap 的模块

Tempo 可以比较自然 wrap 的部分：

- Reth node-builder 组装层：`NodeTypes` / `ComponentsBuilder` / add-ons 的边界足够明确。
- provider、database、storage、trie/state root 基础设施：Tempo 改的是 typed primitives 和执行语义，不是底层 KV/provider 模型。
- network builder：目前基本沿用 `EthereumNetworkBuilder`，只要 wire types 与交易广播接口能承载 `TempoTxEnvelope`。
- RPC server 框架：模块注册、server 启动、Eth API 外壳可以复用，Tempo 增加自己的 API。
- payload service 调度器：`BasicPayloadServiceBuilder` 可以 wrap，但真正的 payload 构造逻辑不能。
- 部分 Ethereum consensus 检查：`TempoConsensus` 内部包了 `EthBeaconConsensus<TempoChainSpec>`，可复用通用 body/post-execution 检查。

### 不能只 wrap 的模块

Tempo 的协议语义已经进入这些核心模块，不能只套一层 adapter：

1. primitives / encoding

   相关路径：

   - `/home/po/now/tempo/crates/primitives/src/header.rs`
   - `/home/po/now/tempo/crates/primitives/src/transaction/envelope.rs`

   `TempoHeader` 不是普通 Ethereum header。它把 `general_gas_limit`、`shared_gas_limit`、`timestamp_millis_part`、inner header、可选 consensus context 一起编码进 RLP。`TempoTxEnvelope` 增加 `AA` 类型，拒绝 EIP-4844，并提供 fee token、fee payer、2D nonce、payment classifier、subblock proposer、system tx signature 等语义。

   这类改动会影响区块 hash、transaction root、receipt root、network typed tx 解码和 RPC 展示，不能靠 wrap Ethereum primitive 解决。

2. chainspec / hardfork / base fee

   相关路径：

   - `/home/po/now/tempo/crates/chainspec/src/spec.rs`
   - `/home/po/now/tempo/crates/chainspec/src/hardfork.rs`

   `TempoChainSpec` 包住 Reth `ChainSpec<TempoHeader>`，但加入 T0/T1/T1A/T1B/T1C/T2/T3/T4 等 Tempo fork。`next_block_base_fee` 不是 Ethereum EIP-1559 动态公式，而是按 Tempo hardfork 返回固定 base fee。gas limit 也分 general/shared。

3. EVM / revm env / transaction execution

   相关路径：

   - `/home/po/now/tempo/crates/evm/src/lib.rs`
   - `/home/po/now/tempo/crates/revm`
   - `/home/po/now/tempo/crates/precompiles`

   `TempoEvmConfig` 可以复用 `EthEvmConfig` 的 scaffolding，但 `TempoTxEnv` 已经扩展出 fee token、fee payer、system tx、AA batch call、valid_after/before、nonce key、key auth、spending limit 等字段。`TempoEvm`、`TempoContext`、precompile 和 handler 是 Tempo 状态转移的一部分。

4. block executor

   相关路径：

   - `/home/po/now/tempo/crates/evm/src/block.rs`

   Tempo block 被分成 `StartOfBlock`、`NonShared`、`SubBlock`、`GasIncentive`、`System` 等阶段，并校验 subblock metadata/signature、shared gas、system tx 顺序、payment/general gas accounting。它还会在特定 fork 部署 marker bytecode 到 Tempo precompile 地址，并根据 subblock 切换 beneficiary。

   这已经是共识状态机，不能把 Reth `EthBlockExecutor` 当黑盒，只能把它作为内部可复用部件。

5. payload builder

   相关路径：

   - `/home/po/now/tempo/crates/payload/types`
   - `/home/po/now/tempo/crates/payload/builder`

   `TempoPayloadAttributes` 增加毫秒时间戳、interrupt flag、DKG extra_data、proposer public key、consensus context、subblocks provider。`TempoPayloadBuilder` 自己负责 subblock 获取、过期交易过滤、payment/general lane、stablecoin AMM fee scoring、system tx 追加、shared/general gas limit 和 block size 限制。

   payload 构造直接决定 canonical block 内容，是最不能靠 wrapper 解决的地方之一。

6. txpool

   相关路径：

   - `/home/po/now/tempo/crates/transaction-pool`

   `TempoTransactionPool` 包住标准 Reth pool，但额外维护 `AA2dPool`。AA 2D nonce 交易走单独 pool，普通交易走 Reth pool，再通过 merge iterator 组合 best transactions。它还需要处理 key revocation、spending limit、AMM liquidity、fee payer balance、TIP-403 等 invalidation。

   核心数据结构可 wrap，pool 的有效性和 best tx 选择不能只 wrap。

7. consensus validation

   相关路径：

   - `/home/po/now/tempo/crates/consensus/src/lib.rs`

   `TempoConsensus` wrap `EthBeaconConsensus`，但增加毫秒时间戳、future block time、shared/general gas limit、system tx 位置/字段等校验。header/body 可见规则变了，因此 consensus 层必须自有。

### Tempo 的取舍

Tempo 的好处是工程杠杆很高：provider、network、RPC、node-builder、payload service、trie/state root 等 Reth 基础设施都能继续吃上游红利。Commonware consensus 和 Tempo payment/AA 语义可以在 Reth 框架内落地，不需要重写 execution client。

代价是协议内核很深：primitives、EVM、payload、txpool、consensus 都是共识关键路径。每次 Reth 升级如果改动 `NodeTypes`、`ConfigureEvm`、payload builder、txpool trait 或 revm handler 边界，Tempo 都要跟着修。Tempo 的策略是“浅 fork client 壳，深 own 协议核”。

## optimism rust

### upstream 与分层

Optimism Rust 目录的直接工程基础是 Reth、Alloy、revm。`/home/po/now/optimism/rust/Cargo.toml` 里 workspace 分为几层：

- `op-alloy`: OP Stack consensus/RPC/network primitives。
- `op-revm`、`alloy-op-evm`: OP EVM env、handler、block executor、receipt builder。
- `op-reth`: 基于 Reth node-builder 的 execution client。
- `kona`: derivation、proof executor、interop proof provider、no_std proof 相关组件。

OP 的分层是三者里最清楚的：类型归 `op-alloy`，状态转移归 `alloy-op-evm` / `op-revm`，client 装配归 `op-reth`，rollup/proof 归 `kona`。

`op-reth/crates/node/src/node.rs` 和 Reth SDK 风格一致：

- `Primitives = OpPrimitives`
- `ChainSpec = OpChainSpec`
- `Storage = OpStorage`
- `Payload = OpEngineTypes`
- component 包括 `OpPoolBuilder`、`OpPayloadBuilder`、`OpNetworkBuilder`、`OpExecutorBuilder`、`OpConsensusBuilder`
- add-ons 增加 OP engine API、sequencer forwarding、historical RPC、tx conditional、miner/debug/witness、flashblocks 等。

### 可以 wrap 的模块

Optimism 可以 wrap 的部分：

- Reth node-builder、component builder、add-on 体系。
- provider/db/storage/trie/state root 基础设施。
- 网络和 RPC server 启动框架；OP 在其上换交易类型和 API。
- txpool 的基本数据结构和 task executor；OP 增加 validator、L1 data gas、interop supervisor。
- payload service 的调度框架；OP 自己实现 payload 内容。
- 通用 block executor / EVM 配置 trait；OP 自己给出 `OpEvmConfig` 和 `OpBlockExecutor`。

### 不能只 wrap 的模块

1. OP transaction / receipt primitives

   相关路径：

   - `/home/po/now/optimism/rust/op-alloy/crates/consensus/src`
   - `/home/po/now/optimism/rust/op-alloy/crates/consensus/src/receipts/envelope.rs`

   `OpTxEnvelope` 在 Ethereum typed tx 外增加 deposit tx；当前 OP receipt envelope 还包含 deposit/post-exec 相关变体。deposit receipt 带 `deposit_nonce`、`deposit_receipt_version`，并且不同 hardfork 下 receipt root 计算有历史兼容逻辑。

   receipt trie encoding 是共识根，不能 wrap Ethereum receipt。

2. OP EIP-1559 / extra_data 参数

   相关路径：

   - `/home/po/now/optimism/rust/op-alloy/crates/consensus/src/eip1559.rs`

   Holocene/Jovian 把 denominator、elasticity、min_base_fee 等参数编码进 `extra_data`，长度、version byte、字段含义都是 OP 规则。这改变 header 语义。

3. EVM pre/post block transition

   相关路径：

   - `/home/po/now/optimism/rust/alloy-op-evm/src`
   - `/home/po/now/optimism/rust/alloy-op-evm/src/block/receipt_builder.rs`

   `OpBlockExecutor` 需要执行 blockhash/beacon-root system contract call、Canyon create2 deployer、deposit tx gas/receipt 规则、Jovian DA footprint gas、post-block balance increment 等。`OpReceiptBuilder` 处理 deposit receipt 和 OP hardfork 差异。

   这些都是状态转移的一部分，不能靠 Reth Ethereum executor 外围 wrap。

4. block assembly / header 字段

   相关路径：

   - `/home/po/now/optimism/rust/alloy-op-evm/src/block`

   OP block assembler 需要处理：

   - `calculate_receipt_root_no_memo_optimism`
   - Isthmus 后 `withdrawals_root` 使用 L2ToL1MessagePasser storage root
   - Canyon 空 withdrawals root
   - pre-Canyon 没有 withdrawals root
   - Ecotone/Jovian 的 blob gas 字段语义
   - Isthmus 后 requests hash
   - Holocene/Jovian `extra_data`

   这些直接进入 block hash 或 execution payload，不能 wrap Ethereum assembler。

5. payload builder

   相关路径：

   - `/home/po/now/optimism/rust/op-reth/crates/payload/src`

   OP payload builder 的顺序是协议规则：system calls / pre-execution changes、forced create2 deployer、sequencer txs、可选 mempool txs、roots。它还要处理 `no_tx_pool`、DA limit、Jovian DA footprint scalar、禁止 pool 中的 blob/deposit tx、interop validity、priority-fee scoring。

6. Kona proof / derivation provider

   相关路径：

   - `/home/po/now/optimism/rust/kona/crates/proof/executor/src/builder/assemble.rs`
   - `/home/po/now/optimism/rust/kona/crates/proof/proof-interop/src/provider.rs`

   Kona 不是 op-reth 的简单 wrapper。proof executor 要在 stateless 场景下重建 OP header、state root、transaction root、receipt root、withdrawals/message-passer root、Holocene/Jovian extra_data、output root。interop provider 通过 preimage oracle 取 headers/receipts，解码 `OpReceiptEnvelope`，还有 multi-chain hint 和 Isthmus 后 EIP-2935 history lookup。

### Optimism 的取舍

Optimism Rust 的优点是分层最规整：OP-specific 类型、EVM、client、proof 各在独立 crate 中，边界清楚，适合多消费者复用。`op-alloy` 可以给 RPC、proof、client 共同使用；Kona 可以在 fault proof 场景使用同一套 OP primitives。

代价是协议升级的传播面大。一次 hardfork 往往要同时改 `op-alloy` encoding、`op-revm/alloy-op-evm` 状态转移、`op-reth` payload/consensus、`kona` proof/derivation。它牺牲了一些局部简单性，换来 OP Stack 生态内更好的共享和可验证性。

## base

### upstream 与分层

Base 的代码 lineage 是 OP Stack，但直接依赖关系更接近 Reth。`/home/po/now/base/Cargo.toml` 直接依赖 Reth `v1.11.3` 相关 crate，并大量使用本地 `base-*` crate；没有把 `op-reth`、`op-alloy` 当作普通上游 crate 直接套用。

Base workspace 里能看到完整本地栈：

- `crates/common/consensus`: Base/OP-like primitives。
- `crates/common/evm`、`crates/execution/revm`: Base EVM / revm / precompile。
- `crates/execution/{node,payload,chainspec,consensus,engine-tree}`: execution client。
- `crates/txpool`: Base txpool。
- `crates/builder/*`: builder / flashblocks。
- `crates/batcher/*`、`crates/proof/*`、`crates/consensus/*`: rollup、proof、consensus/builder 相关系统。

这就是为什么它“看起来是 Reth”：节点装配、provider、txpool、payload service 和 execution traits 都直接靠 Reth；OP 语义则被 port 到 Base 本地 crate，并继续加入 Base 自己的协议扩展。

### 节点装配方式

相关路径：

- `/home/po/now/base/crates/execution/node/src/node.rs`

Base node 和 op-reth 形状很像：

- `Primitives = OpPrimitives`
- `ChainSpec = OpChainSpec`
- `Storage = OpStorage`
- `Payload = OpEngineTypes`
- component 包括 `OpPoolBuilder`、`OpPayloadBuilder`、`OpNetworkBuilder`、`OpExecutorBuilder`、`OpConsensusBuilder`

但实现都来自 `base-*` crate。Base 还加入了自己的参数和策略：

- `RollupArgs`
- `TxpoolOrdering`，例如 coinbase tip / timestamp ordering
- verifier admission policy
- custom verifier gas cap
- EIP-8130 invalidation maintenance
- Base-specific Eth config handler、tx count override、sequencer forwarding、debug/witness/miner extensions

### 可以 wrap 的模块

Base 可以 wrap 或复用的部分：

- Reth node-builder、component builder、RPC/server 框架。
- Reth provider/db/storage/trie/state root 基础设施。
- Reth txpool 的基础数据结构、validation task executor、canonical state stream。
- Reth execution traits 和 payload service 调度。
- OP-like chain config / derivation 概念中未被 Base 改动的部分。
- infra service skeleton，例如 p2p、RPC、metrics、task orchestration。

### 不能只 wrap 的模块

1. Base transaction primitives / EIP-8130

   相关路径：

   - `/home/po/now/base/crates/common/consensus/src/transaction/envelope.rs`
   - `/home/po/now/base/crates/common/consensus/src/transaction/eip8130`

   Base 的 `OpTxEnvelope` 不只是 OP deposit tx。它还加入 `Eip8130`，类型值是 `0x7B`。EIP-8130 包含 account abstraction、phased call batches、account config changes、owner/payer authorization、nonce-free/2D nonce、native/custom verifier gas、CREATE2 account derivation、purity scanner、storage/predeploy 常量等。

   这改变了交易编码、签名/授权、validity、nonce 模型和执行输入，不能 wrap OP transaction。

2. Base revm / precompiles / handler

   相关路径：

   - `/home/po/now/base/crates/execution/revm/src/handler.rs`
   - `/home/po/now/base/crates/execution/revm/src/precompiles.rs`

   Base revm 添加 EIP-8130 transaction phases、ownership validation、nonce manager storage slots、authorizer validation、gas estimation overhead、Base V1 precompile set、TxContext/NonceManager precompile、custom system precompile 地址。

   这是状态转移核心，只能 own。

3. chainspec / hardfork

   相关路径：

   - `/home/po/now/base/crates/execution/chainspec`

   `OpChainSpec` wrap Reth `ChainSpec`，但 hardfork awareness 来自 Base upgrades。它兼容 OP 的 Holocene/Jovian base fee helpers，同时有 Base-specific fork 语义。

4. txpool

   相关路径：

   - `/home/po/now/base/crates/txpool`

   Base txpool 继承 Reth pool 结构，但 validation/order 变了：L1 data fee check、EIP-8130 verifier admission policy、BaseOrdering/TimestampOrdering、custom verifier gas cap、EIP-8130 invalidation。best transaction ordering 和 admission policy 会影响区块内容，因此不能只用 OP/Reth txpool 黑盒。

5. payload / engine tree / flashblocks

   相关路径：

   - `/home/po/now/base/crates/execution/payload`
   - `/home/po/now/base/crates/execution/engine-tree`
   - `/home/po/now/base/crates/builder/core`

   Base payload builder 处理 `OpPayloadAttributes`、pool tx、DA config 和 Base validation。engine-tree 进一步加入 cached execution provider、state root strategies、precompile caching、lazy trie overlays、deferred trie tasks，并和 flashblocks 集成。builder/core 负责 sub-second flashblocks progressive block chunks，再合并成完整 block。

   这些已经不是普通 OP payload builder 能 wrap 的范围，而是 Base product/protocol path。

6. proof / challenge / builder infra

   Base workspace 里有自己的 proposer、prover、challenger、batcher、builder、consensus、TEE/proof 相关 crate。这部分需要与 Base execution semantics 和 flashblocks/builder 设计同步，不能简单复用 OP Rust 的 Kona/op-reth 外壳。

### Base 的取舍

Base 的最大收益是自主性。它可以直接追 Reth 的模块化接口，同时拥有完整的 Base 协议和产品执行路径：EIP-8130、Base revm、custom txpool ordering、flashblocks、engine-tree、builder/proof infra 都能按自己的节奏推进。

成本也最大：Base 实际承担了一个 OP-like stack 的维护。OP hardfork 或 spec 行为变化不能自然通过 `op-reth` 升级吸收，需要同步到 `base-*` crate。相比 Optimism 的生态分层，Base 的本地改动更多；相比 Tempo，Base 的系统面积更大，因为它不仅改 execution inner loop，还维护 builder、batcher、proof、challenge、infra 等完整链路。

一句话概括：Base wrap 的是 Reth 的工程平台，own 的是 OP 语义在 Base 分支上的实现，以及 Base 自己的协议/产品增量。

## 对比：wrap 边界

| 模块 | tempo | optimism rust | base |
| --- | --- | --- | --- |
| node-builder / component assembly | wrap Reth，替换 typed components | wrap Reth，OP components | wrap Reth，Base components |
| provider / db / trie | 基本 wrap | 基本 wrap | 基本 wrap |
| network | 多数 wrap Ethereum network builder | wrap + OP tx types/options | wrap + Base tx types/options |
| RPC framework | wrap，增加 Tempo RPC | wrap，增加 OP RPC/engine extensions | wrap，增加 Base extensions |
| primitives | own: `TempoHeader` / `TempoTxEnvelope` | own: `OpTxEnvelope` / `OpReceiptEnvelope` | own: OP-like + EIP-8130 |
| chainspec / fork | own Tempo forks/base fee | own OP fork semantics | own Base upgrades + OP-like helpers |
| EVM env / handler | own Tempo revm/env/AA/stablecoin fee | own OP revm/env/deposit/DA/system calls | own Base revm/EIP-8130/precompiles |
| block executor | own stages/subblocks/system tx | own OP system calls/deposit/receipt | own Base execution and verifier semantics |
| payload builder | own lanes/subblocks/stablecoin scoring | own sequencer tx/no_tx_pool/DA rules | own DA/Base validation/flashblocks integration |
| txpool | wrap core pool + own AA2d/invalidation | wrap core pool + OP validation/supervisor | wrap core pool + EIP-8130/order/invalidation |
| proof/rollup | Commonware consensus side, not OP-like proof stack | Kona owns proof/derivation | Base owns proof/batcher/builder/challenge infra |

## 设计启发

如果要基于 Reth 做一条新链，可以按这个顺序判断：

1. 只改 RPC、启动参数、链配置、网络选项、pool 排序偏好：优先 wrap。
2. 改交易类型、receipt、header、hardfork 字段、base fee、gas accounting：必须 own primitives 和 chainspec。
3. 改 precompile、system call、transaction env、fee charging、nonce 模型、AA、deposit、DA gas：必须 own EVM/revm/block executor。
4. 改区块内交易来源和顺序，例如 sequencer tx、forced tx、subblocks、payment lane、flashblocks：必须 own payload builder。
5. 改 admission policy、best tx ordering、nonce/fee validity：可以复用 Reth txpool 数据结构，但 validator、ordering、maintenance 往往要 own。
6. 任何影响 trie root、block hash、receipt root、state root 的逻辑，都不要半 wrap。它应该有明确的本链 crate、测试和 fork-aware 实现。

三者共同的工程路线是：把 Reth 当可组合 execution-client 平台，而不是当一个只能 fork 的单体 client。差别在于协议 delta 的位置和规模：

- Tempo delta 深，但集中在一条 payment/AA 链的 execution 内核。
- Optimism delta 广，但按 OP Stack 层级拆得最清楚。
- Base delta 又深又广，直接基于 Reth 维护本地 OP-like stack，以换取更强的产品和协议自主性。

## 补充：原始 Optimism Rust 的 concrete type 边界

本节基于 `/home/po/now/optimism/rust` 的原始 Optimism Rust 代码，不基于 `deps/optimism` 里已经 fork 过、加入 8130 痕迹的版本。

核心问题是：如果要加 8130 这种新的 canonical transaction type，能否只在 `op-reth` / `op-revm` 外面包一层。结论是不能。OP Rust 里有一部分 trait seam 可以复用，但很多公共 API 和中间类型已经固定为 `OpTxEnvelope`、`OpReceiptEnvelope`、`OpPrimitives`、`OpPayloadAttributes`、`OpBlock`。这些地方就是改造边界。

### op-reth 的 concrete anchors

1. node type 层固定 OP primitives / payload / storage

   关键路径：

   - `/home/po/now/optimism/rust/op-reth/crates/node/src/node.rs`
   - `/home/po/now/optimism/rust/op-reth/crates/primitives/src/lib.rs`
   - `/home/po/now/optimism/rust/op-reth/crates/storage/src/chain.rs`

   `OpNodeTypes` 明确要求：

   - `Payload = OpEngineTypes`
   - `Primitives = OpPrimitives`
   - `ChainSpec: OpHardforks + Hardforks`

   `OpNode` 的 `NodeTypes` 实现固定为：

   - `Primitives = OpPrimitives`
   - `ChainSpec = OpChainSpec`
   - `Storage = OpStorage`
   - `Payload = OpEngineTypes`

   `OpPrimitives` 又固定：

   - `Block = alloy_consensus::Block<OpTransactionSigned>`
   - `SignedTx = OpTransactionSigned`
   - `Receipt = OpReceipt`

   `OpStorage` 默认也是 `EmptyBodyStorage<OpTransactionSigned, Header>`。

   影响：如果新交易类型不能塞进 `OpTransactionSigned` / `OpReceipt`，就不是外面包一层的问题，而是要换 `NodeTypes` 或改这些 OP type aliases / marker trait bounds。

2. op-alloy transaction / receipt enum 是封闭 enum

   关键路径：

   - `/home/po/now/optimism/rust/op-alloy/crates/consensus/src/transaction/envelope.rs`
   - `/home/po/now/optimism/rust/op-alloy/crates/consensus/src/receipts/envelope.rs`

   原始 `OpTxEnvelope` 只有：

   - Legacy
   - Eip2930
   - Eip1559
   - Eip7702
   - Deposit
   - PostExec

   原始 `OpReceiptEnvelope` 也只有对应 OP variants。虽然 `op-alloy` 里有 `Extended<B, T>` 的一些 trait impl，但 op-reth/Kona 主路径并没有端到端以 `Extended<OpTxEnvelope, YourTx>` 作为 primitive 类型运行。

   影响：新增 canonical tx type 必须改 tx type enum、typed tx decode/encode、sender recovery、pooled tx conversion、receipt envelope、serde/RPC 类型。否则交易 trie、receipt trie、engine payload decoding 都不会认识新 type id。

3. EVM config 有泛型 seam，但默认路径仍被 `OpTx`/OP receipt 锚住

   关键路径：

   - `/home/po/now/optimism/rust/op-reth/crates/evm/src/lib.rs`
   - `/home/po/now/optimism/rust/alloy-op-evm/src/tx.rs`
   - `/home/po/now/optimism/rust/op-revm/src/transaction/abstraction.rs`

   `OpEvmConfig<ChainSpec, N, R, EvmFactory>` 是泛型的，`ConfigureEvm` 约束也允许替换 `N`、`R`、`EvmFactory`。但默认 `new` 使用 `OpEvmFactory::<OpTx>`，并且要求：

   - `OpTx: FromRecoveredTx<N::SignedTx> + FromTxWithEncoded<N::SignedTx>`
   - `R: OpReceiptBuilder<Receipt: DepositReceipt, Transaction: SignedTransaction>`

   原始 `alloy-op-evm/src/tx.rs` 对 `OpTxEnvelope` 做 concrete match，把 Legacy/EIP2930/EIP1559/EIP7702/Deposit/PostExec 转成 `OpTx`。原始 `op-revm::OpTransaction` 只有 base `TxEnv`、enveloped bytes、deposit parts，没有扩展字段给 8130 这种 phase/auth/payer 数据。

   影响：如果新交易只是“新 envelope，但执行时等价普通 `TxEnv`”，可以多复用这里的泛型 seam。8130 这种要改变 execution env / handler / gas / precompile 的交易，必须改 `OpTx`、`OpTransaction`、`op-revm` handler，或者提供一套新的 EVM factory 和 tx env，并保证所有上层 bounds 都跟着换。

4. receipt builder 是 concrete match 点

   关键路径：

   - `/home/po/now/optimism/rust/op-reth/crates/evm/src/receipts.rs`
   - `/home/po/now/optimism/rust/alloy-op-evm/src/block/receipt_builder.rs`

   `OpRethReceiptBuilder` 固定：

   - `type Transaction = OpTransactionSigned`
   - `type Receipt = OpReceipt`

   并且按 `OpTxType` match 构造 `OpReceipt`。`OpAlloyReceiptBuilder` 也是按 `OpTxType` match 构造 `OpReceiptEnvelope`。

   影响：新 tx type 的 receipt 语义如果和普通 receipt 一样，可以扩展 match；如果有 payer、phase status、额外 system log、特殊 root encoding，就必须新增 receipt variant / receipt builder / root 计算兼容逻辑。

5. payload builder 半泛型，RPC attributes 固定 OP 类型

   关键路径：

   - `/home/po/now/optimism/rust/op-reth/crates/payload/src/traits.rs`
   - `/home/po/now/optimism/rust/op-reth/crates/payload/src/lib.rs`
   - `/home/po/now/optimism/rust/op-reth/crates/node/src/node.rs`

   `OpPayloadPrimitives` 是一个比较好的 seam：它要求 `SignedTx: OpTransaction`、`Receipt: DepositReceipt`，但不是完全写死 `OpTransactionSigned`。不过 `OpAttributes for OpPayloadBuilderAttributes<T>` 的 RPC attributes 是 `OpPayloadAttributes`，`OpPayloadTypes` 固定：

   - `ExecutionData = OpExecData`
   - `PayloadAttributes = OpPayloadAttrs`

   node builder 里也要求 `PayloadTypes<PayloadAttributes = OpPayloadAttrs>`。

   影响：如果新 tx type 仍然通过 OP engine payload 的 `transactions: Vec<Bytes>` 进入，payload 外壳能复用不少；一旦 payload attributes 自身要扩字段，或者 block building 要新 lane / system tx / ordering / gas accounting，就要 fork/own payload builder。

6. txpool 是最适合 wrapper 的边界，但只到 admission/order 层

   关键路径：

   - `/home/po/now/optimism/rust/op-reth/crates/txpool/src/transaction.rs`
   - `/home/po/now/optimism/rust/op-reth/crates/txpool/src/validator.rs`

   `OpPooledTransaction<Cons = OpTransactionSigned, Pooled = op_alloy_consensus::OpPooledTransaction>` 是泛型 wrapper，`OpTransactionValidator<Client, Tx, Evm>` 也主要依赖 `Tx: EthPoolTransaction + OpPooledTx`。

   影响：可以在这里组合普通 OP pool + side pool，做 8130 admission、nonce lane、best transaction merge、state invalidation。这个层适合 wrapper。但如果新 tx type 要进入 gossip/RPC/payload，仍然要求上面的 concrete primitives 能 decode/encode 它。

7. consensus 层相对更 trait 化，但 receipt root 仍是 OP 语义

   关键路径：

   - `/home/po/now/optimism/rust/op-reth/crates/consensus`

   `OpConsensusBuilder` 主要要求 `Receipt: DepositReceipt`，比 node/primitives 层松一些。但 OP post-execution validation、receipt root、deposit nonce Regolith/Canyon 兼容逻辑都是 OP-specific。

   影响：如果新 receipt 实现 `DepositReceipt` 且 root encoding 仍兼容 OP，可复用较多。只要新增 receipt type 进入 trie encoding，就要检查 proof/validation 里所有 `OpReceipt`/`OpReceiptEnvelope` match。

### Kona 的 concrete anchors

Kona 比 op-reth 更难外部 wrapper，因为它的公共 trait 本身经常直接使用 OP concrete types。

1. derivation attributes trait 固定 `OpPayloadAttributes`

   关键路径：

   - `/home/po/now/optimism/rust/kona/crates/protocol/derive/src/traits/attributes.rs`

   `AttributesBuilder::prepare_payload_attributes(...) -> PipelineResult<OpPayloadAttributes>`。这意味着 derivation pipeline 产出的执行输入就是 OP engine payload attributes。

   影响：如果你的链只是新增交易 type，但 payload attributes 仍是 OP 结构，可以 patch `OpTxEnvelope` 后继续走这里。若 attributes 要加字段，就要泛型化或 fork derivation pipeline。

2. proof driver 的 executor trait 固定 `OpPayloadAttributes`

   关键路径：

   - `/home/po/now/optimism/rust/kona/crates/proof/driver/src/executor.rs`

   `Executor::execute_payload(&mut self, attributes: OpPayloadAttributes)` 是 trait 方法签名。

   影响：所有 driver/executor 实现都被 OP payload attributes 锚住。要支持非 OP attributes，不是 executor 实现换一下就行，而是 trait 要改。

3. stateless proof executor 固定 `OpTxEnvelope` / `OpReceiptEnvelope`

   关键路径：

   - `/home/po/now/optimism/rust/kona/crates/proof/executor/src/builder/core.rs`
   - `/home/po/now/optimism/rust/kona/crates/proof/executor/src/builder/assemble.rs`

   `StatelessL2Builder` 约束 EVM tx：

   - `FromTxWithEncoded<OpTxEnvelope>`
   - `FromRecoveredTx<OpTxEnvelope>`
   - `OpTxEnv`

   `build_block` 接收 `OpPayloadAttributes`，执行结果是 `BlockExecutionResult<OpReceiptEnvelope>`。`seal_block` 也接收 `OpPayloadAttributes` 和 `BlockExecutionResult<OpReceiptEnvelope>`。

   `compute_receipts_root` 直接接收 `&[OpReceiptEnvelope]`，并 match `OpReceiptEnvelope::Deposit` 来处理 Regolith receipt root bug。

   影响：新增 tx type 至少要让 `OpTxEnvelope` 和 `OpReceiptEnvelope` 认识它；否则 proof executor 无法 decode、execute、seal、compute receipt root。要把它做成“链泛型 proof executor”，需要把 tx envelope、receipt envelope、payload attributes、receipt-root policy 都参数化。

4. proof driver / oracle provider 固定解码 `OpTxEnvelope`，构造 `OpBlock`

   关键路径：

   - `/home/po/now/optimism/rust/kona/crates/proof/driver/src/core.rs`
   - `/home/po/now/optimism/rust/kona/crates/proof/proof/src/l2/chain_provider.rs`

   proof driver 在执行失败后按 `OpTxType::Deposit` 过滤 deposit-only block，然后把 payload tx bytes decode 成 `Vec<OpTxEnvelope>`，构造 `OpBlock`。oracle L2 provider 从 transactions trie 读取 RLP 后也直接 `OpTxEnvelope::decode_2718`，再构造 `OpBlock`。

   影响：新 tx type 的 bytes 即使在 batch/payload 阶段只是 `Vec<Bytes>`，一旦进入 driver/provider 的 block construction 就会撞上 `OpTxEnvelope`。

5. protocol batch / system config 固定 `OpBlock` 和 `OpTxType`

   关键路径：

   - `/home/po/now/optimism/rust/kona/crates/protocol/protocol/src/batch/traits.rs`
   - `/home/po/now/optimism/rust/kona/crates/protocol/protocol/src/utils.rs`
   - `/home/po/now/optimism/rust/kona/crates/protocol/protocol/src/block.rs`
   - `/home/po/now/optimism/rust/kona/crates/protocol/protocol/src/batch/{single.rs,span.rs}`

   `BatchValidationProvider::block_by_number(...) -> Result<OpBlock, _>`。`to_system_config(block: &OpBlock, ...)` 依赖 `OpBlock` 第一笔交易必须是 deposit，并读取 `as_deposit()`。batch 编解码处直接比较 `OpTxType::Deposit`、`OpTxType::Eip7702` 的 type id。

   影响：Derivation 侧的 OP block model 是 concrete 的。新 sequencer tx 如果不改变第一笔 L1-info deposit 和 batch raw bytes 规则，冲击小一些；但最终 decode/validation 仍要 `OpTxEnvelope` 支持它。

6. interop 固定 `OpReceiptEnvelope`

   关键路径：

   - `/home/po/now/optimism/rust/kona/crates/protocol/interop/src/traits.rs`
   - `/home/po/now/optimism/rust/kona/crates/proof/proof-interop/src/provider.rs`
   - `/home/po/now/optimism/rust/kona/crates/protocol/interop/src/message.rs`

   `InteropProvider` 返回 `Vec<OpReceiptEnvelope>`；proof interop provider 从 receipt trie 直接 `OpReceiptEnvelope::decode_2718`；message extraction 接收 `&[OpReceiptEnvelope]`。

   影响：如果新增 receipt type 仍能作为 `OpReceiptEnvelope` variant 并暴露 logs，interop message extraction 可以继续用；否则 interop trait 本身也要泛型化。

7. node engine / gossip 固定 `OpTxEnvelope`

   关键路径：

   - `/home/po/now/optimism/rust/kona/crates/node/engine/src/attributes.rs`
   - `/home/po/now/optimism/rust/kona/crates/node/gossip/src/block_validity.rs`

   engine attributes 校验会把 attribute tx bytes decode 成 `OpTxEnvelope` 后和 block tx 对比。gossip block validity 把 payload 转成 `Block<OpTxEnvelope>` 再 hash 校验。

   影响：节点侧 validation 也要求新 type 进入 `OpTxEnvelope`，否则即使 execution client 接受，Kona node/engine 这边也会拒或无法验证。

### 改造边界结论

如果目标是“在原始 OP crate 外面套 wrapper，无侵入支持 8130”，边界会卡死在：

- `OpTxEnvelope` / `OpTxType` / `OpReceiptEnvelope`
- `OpPrimitives` / `OpTransactionSigned` / `OpReceipt`
- `OpPayloadAttributes` / `OpExecData` / `OpEngineTypes`
- Kona 的 `Executor`、`AttributesBuilder`、`BatchValidationProvider`、`InteropProvider` trait 方法签名
- proof executor 的 `FromTxWithEncoded<OpTxEnvelope>` / `BlockExecutionResult<OpReceiptEnvelope>` 约束

如果目标是“最少 fork 面支持新 canonical tx type”，更现实的路线是：

1. patch / fork `op-alloy-consensus`，把新 tx 和 receipt 作为 `OpTxEnvelope` / `OpReceiptEnvelope` 的一等 variant。
2. patch / fork `alloy-op-evm` 和必要的 `op-revm`，让 `OpTx` 能从新 tx 构造完整执行 env；如果只是普通 `TxEnv` 执行，改动较小；如果类似 8130，需要 handler/gas/precompile 级改动。
3. 在 `op-reth` 里替换或扩展 `OpRethReceiptBuilder`、txpool validator/pool、payload builder 的 best-tx/order/validation 逻辑。
4. 在 Kona 里同步更新所有 `OpTxEnvelope` / `OpReceiptEnvelope` decode、receipt-root、block construction、interop receipt path。

如果目标是“长期可插拔的 OP-like 框架”，需要更大的 upstream refactor：

- 把 `OpNodeTypes` 从 `Primitives = OpPrimitives` 改成 `Primitives: OpLikePrimitives`。
- 把 `OpEngineTypes` / `OpPayloadTypes` 参数化到 payload attributes 和 execution data。
- 把 `OpTxEnvelope` 依赖抽成 trait：可 decode 2718、可区分 deposit/post-exec、可返回 logs/receipt type、可计算 OP-compatible receipt root。
- 把 Kona 的 `Executor`、`AttributesBuilder`、`BatchValidationProvider`、`InteropProvider` 泛型化到 `PayloadAttributes`、`Block`、`TxEnvelope`、`ReceiptEnvelope`。

这条泛型化路线工程量大，而且会把 OP Stack 原本清晰的 concrete protocol model 抽象成框架。对于 8130 这种链特定协议扩展，现实上更像 Base 当前路线：维护一套 fork/patch 的 OP Rust 栈，用 wrapper 只处理 txpool、node assembly、payload service 这些外围组合点。
