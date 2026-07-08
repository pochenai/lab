# Native 代币标准的动机分析:TIP20(Tempo) vs B20(Base)

比较 Tempo 的 TIP20 和 Base 的 B20 —— 两者都把"ERC20 超集"下沉成协议级 native(Rust precompile),
而不是让发行方各自部署 ERC20 合约。核心问题:**为什么要 native?**

- TIP20 spec: https://tempo.xyz/developers/docs/protocol/tip20/spec
- B20 spec: https://docs.base.org/base-chain/specs/upgrades/beryl/b20
- B20 blog("Coming soon: frontier features and performance" 一节明确了 native 的动机是 node 控制权带来的能力)
- B20 参考实现(接口 + mock,Rust 实现在 `base/base` 主仓,本仓库须 slot-for-slot 对齐):`base-std` repo

## 动机分层框架(A / B / C)

判断"为什么 native"时,按"合约到底能不能做到"归类,比笼统说"性能好"更有区分度:

- **A 类 —— 合约根本做不到**:协议必须能自己操作代币的能力。这是唯一"非 native 不可"的理由。
- **B 类 —— 合约能做,但为了强制协调 / 审计一次才 native**:一致性、命名空间、可信合规。属于 curation / coordination 决策。
- **C 类 —— 锦上添花**:性能 / 成本。通常是搭便车,不是真正的驱动力。

## 主对比表

| 维度 | TIP20 (Tempo) | B20 (Base) |
|---|---|---|
| 链定位 | 稳定币支付专用链 | 通用高吞吐 L2 |
| **A 类:合约做不到的刚需** | ✅ **发布即有:用稳定币付 gas**。`transferFeePreTx / transferFeePostTx`(退费即使 paused 也执行)、`systemTransferFrom` 给 DEX/AMM,是协议在 EVM 执行之外调用代币的钩子,合约无法被干净调用 | ⏳ **发布时无,roadmap 上有**。今天全程 `nonpayable`(`src/interfaces/IB20.sol:29-33`、`IB20Factory.sol:67-68`);但 blog 明确 native 就是为解锁 node 级能力——roadmap 三条 A 类:①用自己的 token 付 gas(向 TIP20 收敛)②虚拟地址(唯一充值地址转发到共享账户,需 node 在 EVM 外改写)③原生索引(node 直接从 RPC 暴露聚合余额/历史,免外部 indexer) |
| **B 类:强制一致 / 合规** | 有:role、pause、supply cap、TIP-403 转账策略、reward 分发,协议级统一 | ✅ **全部主线**:freeze-and-seize(`burnBlocked`,仅对被 policy 拉黑账户生效)、allowlist/blocklist(单例 PolicyRegistry `0x8453...0002`,`uint64` policy ID 跨代币共享)、7 角色、granular pause(pause/unpause 分属不同角色)、"最后 admin 不能 renounce,只能 `renounceLastAdmin()`" |
| **B 类:地址命名空间** | `0x20C000...` 前缀,确定性部署,前 1000 地址保留给协议 | prefix `0xB2` + 9 字节 0 + **variant 编进 byte[10]** + `keccak(sender,salt)[0:9]`,off-chain 无需 RPC 即可识别是否 B20 及变体(`docs/B20/Factory.md:40-44`) |
| ERC20 兼容 | 超集 | 超集,声称 ERC20 selector 完全一致,drop-in |
| memo | 32-byte,transfer/mint/burn 均可带 | 32-byte,`*WithMemo` 后紧跟 `Memo` 事件,indexer 用 `(txHash, logIndex−1)` 关联 |
| 变体 | 以 currency 区分,仅 USD 计价可付 gas | Asset(6–18 decimals,rebase multiplier / 公告 / batchMint)、Stablecoin(固定 6 decimals + ISO currency 码) |
| **C 类:性能/成本** | 官方顺带提及;因 A 类才是决定性理由,性能是搭便车 | blog 列 `~50% cheaper / 2x TPS`,但仍是 "coming soon" 的 projection,无机制、无 benchmark(见下) |
| **native 的真正性质** | **被当下能力逼的**:付-gas 刚需发布即需要 → 不得不 native | **买未来能力的期权**:发布时 A 类一个没 ship,但先付 native 成本以预留 node 级能力空间(付-gas / 虚拟地址 / 原生索引);与 TIP20 的差别是"时间差"而非"哲学" |

## 性能:声称 vs 实证 vs 可行性

单独拎出来,因为这是最容易被营销话术误导的一栏。

| | 结论 |
|---|---|
| **声称** | B20 doc 列 performance / lower fees / chain integration;blog 给出具体数字 `~50% cheaper transfers / doubling TPS`,但归在 "coming soon" 一节,是 projection 而非已交付 |
| **实证** | `base-std` 全仓库 **零 benchmark、零 gas 对比、无 `.gas-snapshot`、foundry 未开 gas report**。blog 的 ~50%/2x 也未附机制或测量方法 |
| **可行性(为什么红利本就小)** | ① 该仓库只是接口 + mock,mock 本身就是普通合约,不比 ERC20 快;真正的 Rust 实现不在此仓,结构上无从 benchmark。② token transfer 是**存储密集型**:成本大头是 `SLOAD`/`SSTORE`,按 EVM gas schedule 收费,precompile 和合约一样贵;precompile 只省 opcode dispatch 开销,占比很低。precompile 真正碾压合约的是**计算密集型**(配对/哈希/椭圆曲线),不是转账。③ 唯一能"更便宜"的合法途径是协议给 precompile **自定义定价**——那是定价决策,不是执行更快 |

**推论**:性能不是被验证过的驱动力,更像事后的营销话术。这反而加强了"B20 native 是 curation/coordination 决策"的判断。

## 结论

- **TIP20 是被当下能力逼的**:稳定币付 gas 这个 A 类刚需发布即需要、合约又做不到,所以必须 native;性能、"ERC20 骨架安全"都是搭便车。
- **B20 是买未来能力的期权**:发布时 A 类一个没 ship(显式 `nonpayable`),靠 B 类(合规/一致/可离线识别)先立住标准;但 blog 挑明走 native 就是为了拿"合约够不到的 node 控制权",再逐步加付-gas、虚拟地址、原生索引三条 A 类能力。所以它和 TIP20 的差别是**时间差(现在 vs 以后),不是哲学差**——而且 roadmap 的付-gas 正在向 TIP20 收敛。
- **性能不是任一方的真实驱动力**:TIP20 靠 A 类、B20 靠 B 类+未来 A 类。B20 blog 虽给了 ~50%/2x 的数字,但仍是无机制、无 benchmark 的 projection,且被 Base 自己归为 native 的副产品而非动机。
- 通用规律:**"安全面照抄就好"只对 ERC20 骨架成立**;发行方要加的合规扩展逻辑(冻结、policy 门控、pause 交互)恰恰是没法照抄、最易出事的部分。B20 几乎全身都是这块,所以"协议级审计一次"对 B20 是真安全收益,对 TIP20 只是部分成立。
