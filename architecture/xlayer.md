## 架构
                ┌────────────────────────────────────────────┐
                │   bin/node/src/main.rs                    │
                │   （组装 / 编排）                          │
                └────────────────────────────────────────────┘
                          │
        ┌─────────────────┼──────────────────┐
        ▼                 ▼                  ▼
┌────────────────┐ ┌─────────────────┐ ┌──────────────────┐
│ xlayer_*       │ │ reth_optimism_* │ │ reth / reth_*    │
│ (crates/*)     │─│ (deps/optimism) │─│ (git: okx fork)  │
│                │ │                 │ │                  │
│ flashblocks    │ │ OpNode          │ │ NodeBuilder      │
│ legacy_rpc     │ │ OpEvmConfig     │ │ EngineNodeLauncher│
│ monitor        │ │ RollupArgs      │ │ BlockchainProvider│
│ rpc            │ │ Cli             │ │ EthApi traits    │
│ chainspec      │ │ OpEngineValidator│ │ ...              │
│ builder        │ │ ...             │ │                  │
└────────────────┘ └─────────────────┘ └──────────────────┘
        │                 │                  │
        │ 装饰 / 替换       │ 路径依赖（可改）   │ git 依赖（不可本地改）
        │                 │                  │
主语其实是 NodeBuilder（reth 核心层的）。它定义了一套统一的拼装协议（types / components / add-ons / launcher），任何符合这套协议的实现都能被装进来。


NodeBuilder (reth 提供的"组装机")
    │
    ├── types         ← OpNode 提供（决定 block/tx/receipt 等类型族）
    ├── components    ← op_node.components() 提供 OP 默认组件
    │                   其中 payload 被 XLayer 替换为 XLayerPayloadServiceBuilder
    ├── add-ons       ← OP 提供基础 RPC，XLayer 用 middleware/extend_rpc_modules 叠加
    ├── engine        ← OpEngineValidatorBuilder 被 XLayerEngineValidatorBuilder 装饰
    ├── evm           ← OpEvmConfig（XLayer 直接复用）
    └── launcher      ← EngineNodeLauncher（reth 提供，原样使用）

所以三句话总结：
- OP 层是"OP-stack 一台完整可用的节点" —— OpNode / OpEngineValidatorBuilder / OpEvmConfig 单独就能跑出一个 op-reth。
- reth 层是"通用拼装协议 + 不挑链的基础设施" —— builder、launcher、provider、rpc 框架。
- XLayer 层做的是"在 builder 拼装阶段做手脚" —— 替换 payload、装饰 engine validator、叠 RPC 中间件、加自家 RPC 命名空间，几乎不碰 OP 默认实现，遇到必须改的就直接改 deps/optimism 里的源码。

一个直观的反向理解：如果你把 main.rs 里所有 xlayer_* 相关的行删掉，剩下的代码其实就是一个标准的 op-reth 节点启动流程——XLayer 是组装阶段的注入，不是 fork。


## Flashblock (XLayer vs OP)

┌─────────────────────────────────────────────────────────────────┐
│              共享类型（op-alloy）                                │
│   OpFlashblockPayload / OpFlashblockPayloadBase / ...           │
└─────────────────────────────────────────────────────────────────┘
              ▲                                  ▲
              │ use                              │ use（含 XLayer 包装）
              │                                  │
┌─────────────────────────┐         ┌─────────────────────────────┐
│ reth-optimism-flashblocks│         │ xlayer-flashblocks          │
│ (OP 通用消费侧)          │         │ (XLayer 集成 + 生产 + 消费) │
│                          │  无     │                              │
│  FlashBlockService       │  实质   │  XLayerEngineValidator       │
│  WsFlashBlockStream      │  代码   │  WsFlashBlockStream(自家)    │
│  validation::*           │  依赖   │  FlashblocksRpcService       │
│  PendingStateRegistry    │ ──×──→  │  FlashblockStateCache        │
│  ...                     │         │  FlashblocksPubSub           │
│                          │         │  ...                         │
└──────────────────────────┘         └─────────────────────────────┘
                                            │
                                            │ uses
                                            ▼
                                     ┌──────────────────┐
                                     │ xlayer-builder   │
                                     │ 定义 XLayerFlash-│
                                     │ blockMessage     │
                                     └──────────────────┘

- 区别：消息格式 XLayer 多了 target_index 和显式 PayloadEnd；集成层级 XLayer 是节点深度集成（engine validator + RPC + 出块），OP 是纯消费侧服务；两边各有一套独立实现，没有互相复用。

- 依赖关系：Cargo.toml 上写了，但源码没用上 —— 实质上独立。它们都依赖更底层的 op-alloy-rpc-types-engine，那才是真正的共享接口。

> 一个推论：做 8130 时如果只是改 OP 上游的 reth-optimism-flashblocks，xlayer-flashblocks 那边可能根本感知不到 —— 因为它没真的 use 那边的代码。但如果 8130 改的是 OpFlashblockPayload 字段或 op-alloy-rpc-types-engine 那一层（比如新加 metadata 字段），XLayer 这边一定会受影响，必须同步改 XLayerFlashblockPayload 以及 builder 里的序列化测试。