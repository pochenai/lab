# p-token 为什么比 SPL Token 更省 CU

## TL;DR

- `p-token` 省 CU，核心不是“换了 token 语义”，而是把实现层的固定开销整体做薄了。
- 它保持和 SPL Token 相同的 instruction layout 与 account layout，目标是 drop-in replacement；所以省下来的 CU 主要来自执行路径工程化优化，而不是协议行为变化。
- 这些优化可以概括为 6 件事：`no_std` / 无 allocator、zero-copy 读写 account、按需解析 instruction、减少分发与分支开销、默认去掉 instruction name 日志、对高频路径和 CPI 做专项优化。

按 SIMD-0266 给出的数据，很多热点指令已经降到老 `spl-token` 的 `1.6% ~ 11.2%`。如果只看 proposal 里列出的前 `88.65%` token 指令流量，加权后平均 CU 大约从 `4555` 降到 `111`，约为原来的 `2.43%`，也就是约省 `97.57%`。

## 版本背景

- `febo/p-token` 是最早的 PoC 仓库，README 已说明代码后来迁到了 `solana-program/token`。
- SIMD-0266《Efficient Token program》已在 **2026-03-13** 合并到 `solana-improvement-documents`。
- 因此看这个主题时，最好把它拆成两层：
  - `febo/p-token`：最早的设计方向和早期实现。
  - `solana-program/token` 下的 `pinocchio/`：proposal 落地后的正式演进版本，加入了更激进的 fast path 和 `batch`。

这也解释了为什么 README 和 SIMD 里的 CU 数字不完全一致：

- `febo/p-token` README 写的是较早版本、且注明测试环境是 `Solana v2.1.0`。
- SIMD-0266 里还专门把“是否打印 instruction 日志”拆开测了；例如 `Transfer` 是 `76 CU`（无日志）vs `186 CU`（有日志）。
- 所以这里更应该把两份材料当成“同一条路线的不同阶段”，而不是要求数字逐项完全相同。

## 直观对比

SIMD-0266 里的部分热点指令数据：

| Instruction | SPL Token | p-token | p-token / SPL |
| --- | ---: | ---: | ---: |
| `Transfer` | 4645 | 76 | 1.6% |
| `TransferChecked` | 6200 | 105 | 1.6% |
| `MintTo` | 4538 | 119 | 2.6% |
| `Burn` | 4753 | 126 | 2.6% |
| `InitializeAccount` | 4527 | 154 | 3.4% |
| `InitializeMint` | 2967 | 105 | 3.5% |
| `CloseAccount` | 2916 | 120 | 4.1% |
| `InitializeMultisig2` | 2826 | 318 | 11.2% |

proposal 还给了 usage distribution，其中最热的两条就是：

- `TransferChecked`: `36.33%`
- `Transfer`: `13.22%`

也就是说，光是把这两条路径打磨到极致，就能吃到接近一半 token 流量的收益。

## 为什么省这么多 CU

### 1. 零拷贝读写 account data，直接消掉 `unpack/pack` 往返

老 `spl-token` 的典型路径是：

1. 从 `AccountInfo.data` 里 `unpack` 出 Rust struct。
2. 在栈上修改 struct。
3. 再 `pack` 回字节数组。

例如官方 `spl-token` 的 `process_transfer` 里，先 `Account::unpack(...)` 两次，最后再 `Account::pack(...)` 两次。

`p-token` 则是：

1. 只做长度检查。
2. 直接把 `&[u8]` / `&mut [u8]` cast 成 `&Account` / `&mut Account`。
3. 就地修改字段。

这一步是最大的结构性收益之一，因为它把每条指令里反复出现的序列化/反序列化成本基本拿掉了。

可对照的核心文件：

- SPL Token: `program/src/processor.rs` 里的 `Mint::unpack_unchecked` / `Mint::pack`、`Account::unpack` / `Account::pack`
- p-token: `interface/src/state/mod.rs` 里的 `load` / `load_mut` / `load_mut_unchecked`
- p-token: `program/src/processor/shared/transfer.rs` 里直接拿到 `&mut Account` 后原地改 `amount`

### 2. 指令解析是“按需解析”，不是先构造一个大 enum

老 `spl-token` 的入口先统一做：

```rust
instruction = TokenInstruction::unpack(input)
match instruction { ... }
```

这条路的特点是：先把整个 input 解成统一 enum，再进入每条指令自己的逻辑。

`febo/p-token` 的做法更细：

- 入口先只取 discriminator。
- 热门指令先走第一层 `match`。
- 每条指令自己只解析自己需要的那几个字节。

例如：

- `Transfer` 只把 `instruction_data` 直接转成一个 `u64 amount`
- `TransferChecked` 只读 `u64 + u8`
- `InitializeMint` 也是自己做最小长度校验，然后按偏移取 `decimals`、`mint_authority`、`freeze_authority`

这比“先解一个大而全的 enum”更省分支，也更少中间对象。

### 3. `no_std` + `no_allocator`，把运行时包袱压到最低

`febo/p-token` 的 `program/src/lib.rs` 顶部就是 `#![no_std]`，入口里还显式 `no_allocator!()`。

这意味着：

- 程序不依赖堆分配(no_std + no_allocator 组合)。
- 指令解析与状态访问尽量都在已有输入 buffer 上完成。
- 整个实现风格天然倾向于“定长、栈上、零拷贝、少抽象”。

单独看这件事未必解释全部收益，但它是后面那些 micro-optimization 能成立的前提。

### 4. 日志默认不打，直接省掉每条指令 100+ CU 的固定税

SIMD-0266 明确写了：仅仅打印 `Instruction: <name>` 这种日志，就要消耗 **100+ CU**。

proposal 里的样例：

- `InitializeMint`: `105` CU（无日志） -> `214` CU（有日志）
- `Transfer`: `76` CU（无日志） -> `186` CU（有日志）
- `TransferChecked`: `105` CU（无日志） -> `218` CU（有日志）

这件事非常关键，因为 token 指令本身已经被做到很薄了；日志在这种情况下反而会占掉非常可观的一部分。

`p-token` 在代码上把日志都包在：

```rust
#[cfg(feature = "logging")]
```

下面，所以默认可以把这块固定成本直接拿掉。

### 5. 分发层专门给高频路径做了优化

这条路线在两个版本里都能看到，但强度不同。

#### 5.1 `febo/p-token` 的第一版优化

在 `program/src/entrypoint.rs` 里，处理器被拆成“两段 match”：

- 第一段优先处理最常见指令：`InitializeMint`、`Transfer`、`MintTo`、`CloseAccount`、`InitializeAccount3`、`InitializeMint2`
- 其他指令再落到 `process_remaining_instruction`

源码注释写得很直白：这样做是为了减少大 `match` 的比较开销，尤其是给高频指令减少分发成本。

#### 5.2 proposal 落地版更进一步：直接给 `transfer` / `transfer_checked` 做 fast path

正式迁入 `solana-program/token` 的 `pinocchio` 版本，在 `pinocchio/program/src/entrypoint.rs` 里更激进：

- 不先走通用 `deserialize`
- 先直接检查 raw VM input 中 account 个数、account data length、instruction discriminator
- 如果能高置信度判断这是 `transfer` 或 `transfer_checked`，就直接调用对应 processor

这是一种很“硬核”的热路径工程化：把最热的两条指令从通用入口里剥出来单独走。

而 proposal 的 usage distribution 又告诉我们，`TransferChecked + Transfer` 合起来就是 `49.55%` 的 token 流量，所以这类 hot path 值得。

### 6. 热点指令内部也在做分支与 borrow 优化

以 `transfer` 为例，`p-token` 的实现不是追求“抽象最优雅”，而是追求“热点分支最便宜”：

- 用 slice destructuring 直接拆 accounts，而不是 `next_account_info` 一路迭代。
- `source_account_info == destination_account_info` 用内部指针比较来识别 self-transfer，比比较 pubkey 更便宜。
- self-transfer 和普通 transfer 分两条逻辑，避免平白去加载 destination account。
- 在已经验证过前提后使用 `load_mut_unchecked`，减少重复检查。
- 正式 `pinocchio` 版本还显式使用 `likely` / `unlikely`。

这些都是“单看很小、但在 36% + 13% 的高频指令上非常值钱”的优化。

### 7. `batch` 进一步压缩 CPI 成本

这点是 SIMD-0266 里的新增能力，不是最早 `febo/p-token` PoC 的重点，但对 DeFi/组合协议很重要。

`batch` 的核心思想是：

- 把多条 token instruction 打包到一次 `p-token` 调用里执行
- 这样一次 CPI 的基础 invoke 成本只付一次

proposal 里明确写到，当前基础 CPI invoke 成本大约是 `1000 CU`。如果一个协议在一次 instruction 里要做多次 token CPI（例如 swap 里的两次 transfer，或者 LP deposit 里的 transfer + mint），`batch` 会把这部分固定税明显摊薄。

所以：

- 基础版 `p-token` 省的是“单条 token instruction 自身更轻”
- `batch` 省的是“多条 token CPI 组合起来更轻”

## 核心代码路径

### 1. 老 SPL Token 的热点路径

可以把老 `spl-token` 的执行模型概括成：

```rust
instruction = TokenInstruction::unpack(input)
log("Instruction: ...")
src = Account::unpack(src_data)
dst = Account::unpack(dst_data)
check(...)
mutate(src, dst)
Account::pack(src, src_data)
Account::pack(dst, dst_data)
```

关键词是：`统一解码 -> 打日志 -> unpack -> mutate -> pack`。

### 2. `febo/p-token` 的热点路径

PoC 版可以概括成：

```rust
discriminator = instruction_data[0]
match discriminator {
  3 => process_transfer(accounts, rest),
  12 => process_transfer_checked(accounts, rest),
  ...
}

amount = u64::from_le_bytes(rest[..8])
src = load_mut(src_data)          // zero-copy
dst = load(dst_data)              // zero-copy
check(...)
dst = load_mut_unchecked(dst_data)
src.amount -= amount
dst.amount += amount
```

关键词是：`按需解码 -> zero-copy -> 原地写回`。

### 3. proposal 落地版 `pinocchio` 的更激进路径

正式版本在入口层又多了一层：

```rust
if raw_input_looks_like_transfer_checked() {
  return process_transfer_checked(...)
}
if raw_input_looks_like_transfer() {
  return process_transfer(...)
}
deserialize(...)
process_remaining(...)
```

也就是：

- 对最热的两条指令，连通用 deserialization 都尽量绕过去。
- 其他指令再走标准入口。

### 4. `batch` 的核心逻辑

`batch` 的主循环可以抽象成：

```rust
loop {
  account_count = data[0]
  ix_len = data[1]
  ix_accounts = accounts[..account_count]
  ix_data = data[2 .. 2 + ix_len]
  inner_process_instruction(ix_accounts, ix_data)
  accounts = accounts[account_count..]
  data = data[2 + ix_len..]
}
```

这件事非常像“同一个 program 内部的小型 dispatcher”，目的是避免外层程序多次 `invoke` token program。

## 我认为最本质的结论

如果只用一句话概括：

> `p-token` 的收益，本质上不是“把 token 逻辑变简单了”，而是“把 SPL Token 这种超高频基础设施的实现，按 CPU 热路径的标准重新写了一遍”。

更具体一点，收益来源可以按权重排序成：

1. zero-copy 取代 `pack/unpack`
2. 默认去掉 instruction 日志
3. 更轻的 instruction decode / dispatch
4. 对 `transfer` / `transfer_checked` 这种超高频路径做专门 fast path
5. `batch` 把多次 CPI 的固定 invoke 税摊薄

## 需要注意的点

- `p-token` 要成立，前提是必须和原 SPL Token **行为等价**。proposal 里也把测试、fuzz、audit、formal verification 都列成了重点。
- `febo/p-token` 和 proposal 落地版不是一份完全静态的代码；正式版本在 upstream 里继续演进了，所以分析时要分清“PoC 原理”和“正式实现细节”。
- `batch` 带来的收益主要发生在 **CPI-heavy** 场景；如果只是单条用户直调 token instruction，它不会像 zero-copy 那样直接影响每一条指令的 base cost。

## 追加细化（针对你提的 4 点）

### A. `zero-copy` 为什么依赖 `#[repr(C)]`，以及它具体保证了什么

你说得对，`#[repr(C)]` 是 zero-copy 能安全落地的核心之一，但它不是“唯一条件”。

`p-token` 的做法是把链上账户字节直接视为 Rust struct：

- `Account`/`Mint` 用 `#[repr(C)]`
- `load_unchecked` 里直接 `bytes.as_ptr() as *const T`
- 长度只校验 `bytes.len() == T::LEN`

这意味着必须同时满足：

1. 布局稳定：
- `#[repr(C)]` 把字段顺序和对齐固定下来，避免 Rust 默认布局重排。

2. 字段无歧义：
- 大量数值字段不是 `u64`，而是 `[u8; 8]`，读写都显式 `to_le_bytes/from_le_bytes`。
- 这样不会把“宿主 CPU 字节序”偷偷带进来，链上字节语义始终按 little-endian。

3. 尽量规避隐式 padding/ABI 陷阱：
- 比如 `is_initialized` 用 `u8`，`COption<T>` 也是手工 `(tag, value)`，而不是直接用 Rust `Option<T>` 做链上布局。
- `RawType`/`Transmutable` 的注释里也明确要求“无 padding、可安全 cast”。

所以更准确地说：`#[repr(C)]` 提供了“布局确定性”，`[u8;N] + 显式 LE 转换`提供了“字节序确定性”，两者加起来才是可用的 zero-copy。

### B. “按需解析”到底细到什么程度（代码级）

`spl-token` 标准路径是先 `TokenInstruction::unpack(input)`，把整条输入解析成 enum，再进入业务处理。  
`p-token` 则在每个 processor 里只取自己需要的最小字节：

1. `Transfer`:
- 仅接受 8 字节，直接 `u64::from_le_bytes(instruction_data[..8])`。

2. `TransferChecked` / `MintToChecked`:
- 仅接受 9 字节（`u64 + u8`），通过 `split_at(8)` 拆出 `amount` 和 `decimals`。

3. `InitializeAccount2`:
- 要求长度恰好 32（Pubkey），然后把 `instruction_data.as_ptr()` cast 成 `*const Pubkey`。

4. `InitializeMint`:
- 先做最小长度判断：`decimals(1) + mint_authority(32) + option(1) [+ freeze_authority(32)]`
- 后续按偏移读取：`raw+0`、`raw+1`、`raw+33`、`raw+34`。

5. `SetAuthority`:
- 同样是“最小长度 + 偏移解析”，`authority_type` 从第 0 字节取，`new_authority` tag 在第 1 字节，若存在则 pubkey 从第 2 字节起。

这类解析的共同点是：

- 不构造“全量 instruction enum 对象”
- 不解析本指令用不到的字段
- 多数路径只做常数次长度检查 + 常数次偏移读取

这就是它在 CU 上比“通用 unpack 再 match”更轻的根因。

### C. “双层/双端 dispatch”为啥更快

这里有两类 dispatch 优化，强度不同。

#### C.1 `febo/p-token` 的“双层 match”

入口先处理高频 discriminator（如 `0/3/7/9/18/20`），其余落到 `process_remaining_instruction`。  
它快的原因主要是：

1. 减少平均比较次数（高频指令提前命中）。
   设平均比较次数 `E = Σ p_i * c_i`，把高频指令放到第一层后，热点 `c_i` 会从“大 match 里的中后段”降到 `1~2` 次量级，`E` 会明显下降。
2. 热路径代码更集中，I-cache 更友好。
3. 热路径函数更短，分支预测更稳定。

可以把它理解成：把“主干流量”从大而全分发表里先摘出来。

#### C.2 upstream `pinocchio` 的“前置 fast-path + inner dispatch”

在正式版本里，入口比双层 match 更激进：

1. 先在 raw VM input 上做模式匹配：
- 账户数量是否是 `3/4`
- 关键账户 data_len 是否等于 `Account::LEN/Mint::LEN`
- discriminator 是否是 `3/12`

2. 若命中 `transfer/transfer_checked`，直接调用对应 processor，跳过通用 `deserialize`。
   这一步等价于把“每次都要付的固定成本”改成“只给未命中的指令付”。

3. 未命中再走常规 `deserialize + process_instruction + inner_process_instruction`。

它本质是在做“分层漏斗”：

- 第一层：极廉价特征过滤（只看少量字节）
- 第二层：只在需要时才进通用慢路径

因为 `TransferChecked + Transfer` 本身占接近一半 token 流量，这种“先便宜判定、再决定是否走重路径”非常值。

### D. `zero-copy` 不能直接用 COW 吗？为什么还要单独实现

短答案：可以“形式上”用 COW 包一层，但拿不到 `p-token` 这类收益，关键场景还会更慢。

具体原因：

1. COW 不能替代“字节 -> 结构体视图”这件事
- `Cow` 解决的是“借用还是拷贝拥有”，不解决链上字节布局解析问题。
- 你仍然需要定义布局（`repr(C)` + 字段编码）并做类型投影。

2. 发生写入时，COW 倾向触发复制
- token 指令大量是写路径（transfer/mint/burn/close）。
- COW 一旦进入 owned 分支，就要先 copy 再改，和 zero-copy 目标相反。

3. BPF 程序的约束不鼓励这类复制
- `p-token` 明确 `no_std + no_allocator`。
- 标准 `Cow<[u8]>` 的 owned 一般是 `Vec<u8>`，这条路径在这里本来就不理想。

4. Solana 账户更新语义是“原地改借来的 account data”
- runtime 需要看到对 `AccountInfo` 数据缓冲区的直接修改。
- “拷贝出去再改再回写”本质又回到了 pack/unpack 类模型，CU 会上去。

5. 这套手写 zero-copy 还能把检查位置做细粒度优化
- `load` / `load_mut` / `load_mut_unchecked` 分离后，可以把“长度校验、初始化校验、重复校验”放到最省 CU 的位置。
- COW 抽象通常做不到这么细的、面向热路径的检查编排。

所以不是“COW 完全不能用”，而是：  
在 Solana token 这种极致追 CU 的写密集路径里，COW 不是收益最优解；`p-token` 这种“布局可证明 + 手写 zero-copy + 就地写回”的方案才是。

## 关键源码

### SIMD / 提案

- SIMD-0266: <https://github.com/solana-foundation/solana-improvement-documents/blob/main/proposals/0266-efficient-token-program.md>

### 老 SPL Token

- `Processor::process` 与 instruction 日志: <https://github.com/solana-program/token/blob/main/program/src/processor.rs#L855-L970>
- `process_transfer`: <https://github.com/solana-program/token/blob/main/program/src/processor.rs#L226-L340>
- `TokenInstruction::unpack`: <https://github.com/solana-program/token/blob/main/interface/src/instruction.rs#L481-L585>

### `febo/p-token` PoC

- README: <https://github.com/febo/p-token/blob/main/README.md>
- `#![no_std]`: <https://github.com/febo/p-token/blob/main/program/src/lib.rs#L1-L5>
- 两段式入口分发: <https://github.com/febo/p-token/blob/main/program/src/entrypoint.rs#L14-L84>
- zero-copy state load: <https://github.com/febo/p-token/blob/main/interface/src/state/mod.rs#L28-L91>
- token account 内存布局: <https://github.com/febo/p-token/blob/main/interface/src/state/account.rs#L12-L151>
- `InitializeMint` 的按需解析: <https://github.com/febo/p-token/blob/main/program/src/processor/initialize_mint.rs#L14-L119>
- `Transfer` 的最小解析: <https://github.com/febo/p-token/blob/main/program/src/processor/transfer.rs#L5-L13>
- `TransferChecked` 的最小解析: <https://github.com/febo/p-token/blob/main/program/src/processor/transfer_checked.rs#L5-L26>
- `transfer` 热路径实现: <https://github.com/febo/p-token/blob/main/program/src/processor/shared/transfer.rs#L9-L172>

### proposal 落地后的 upstream `pinocchio` 版本

- 自定义 fast-path entrypoint: <https://github.com/solana-program/token/blob/main/pinocchio/program/src/entrypoint.rs#L28-L259>
- `batch`: <https://github.com/solana-program/token/blob/main/pinocchio/program/src/processor/batch.rs#L15-L109>
- 当前 `transfer` 热路径: <https://github.com/solana-program/token/blob/main/pinocchio/program/src/processor/shared/transfer.rs#L15-L191>
- 当前 zero-copy state helpers: <https://github.com/solana-program/token/blob/main/pinocchio/interface/src/state/mod.rs#L14-L100>
