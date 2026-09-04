# Indirection（间接引用）模式

> 核心一行：**`NodeId → Arena → Node`，引用方不持有 reference。**

SlotMap = arena-style O(1) indexed storage + O(1) slot reuse/delete + generational stable handle；在 Rust 中又顺便很好地把复杂对象图从引用/lifetime 问题转换成了 ID lookup 问题。

## 1. 解决什么问题

树/图结构里"引用一个节点"，默认把两件事焊在一起：

- **逻辑身份**：我要哪个节点
- **物理位置**：它在内存哪里

焊死的后果是这五件事做不到：

| 做不到的事 | 为什么 |
|---|---|
| 移动对象 | 一移动，所有指向它的引用全废 |
| 回收空间后重用 | 老引用会静默指到新对象 |
| 重排物理布局 | 布局一变引用就错，等于永远不能做 cache 优化 |
| 把子树整体交给别的线程 | 引用带 lifetime，跨线程搬 = 悬垂 |
| Rust 特有：无 lifetime 纠缠 | 直接引用 ⇒ `Rc<RefCell>` + `Weak` + 自引用地狱 |

**根源需求不是"更快"，是"让物理位置可变"。** 物理位置一旦可变，前四件同时解锁；性能只是随之而来的第二阶收益。

---

## 2. 定义

在引用方和对象之间插入一层 ID 查找：

```
引用方 ──(持有一个值)──► Handle ──(查表)──► 容器 ──► 对象
```

三个约束条件，缺一条就不算这个模式：

1. **引用方的引用类型是 `Copy` 的 handle**，不含被引用者的 lifetime
2. **对象所有权唯一集中在一个容器**（arena），别处只有 handle
3. **物理位置由容器单方面决定**，引用方无从知晓、也不该能推断

这一层的唯一职责：**吸收物理位置的变化。**

### 必要配套：handle 必须带版本

回收 slot ⇒ 裸 `usize` 必然有 ABA：

```
slot 7: 节点A ──remove──► 空闲 ──insert──► 节点B
            └── 手里还攥着 "7" 的旧引用 ──► 静默读到 B，不 panic
```

所以：

```
Handle = (slot: u32, generation: u32)
```

失效从"静默的错数据"变成显式的 `None`。

> **generational index 不是 indirection 的可选增强，是它的正确性配套。**
> 判据只有一条：slot 会不会被复用？会 ⇒ 必须带版本。

一个决定"安全是否免费"的细节：**version 与 value 存在同一个 slot** ⇒ 同一条 cache line ⇒ 校验不多付一次内存访问。version 与 value 分家（如 `SecondaryMap` 的双数组）就要拿 locality 换安全。

### 这条链是有序的

handle 层不是"一种可选风格"，它的每一步都是上一步的**必然后果**：

```
诉求：物理位置可变
   │
   ▼
① handle 层（引用方持值；对象所有权唯一集中在容器）
   │
   ├──► ② 子树可整体搬走  ⇒ 并行单位存在        （要求：容器是 owned 值）
   ├──► ③ 元数据可内联    ⇒ side map 消失       （要求：节点可寻址）
   └──► ④ 布局可重排      ⇒ cache              （要求：能改写全部 handle）
   │
   ▼
⑤ handle 会存活在容器之外吗？（遍历栈里、别的容器里）
   ├─ 会 ──► 必须带版本 generation              ← reth 是这种
   └─ 不会 ─► 裸下标即可，别多付 version
   │
   ▼
⑥ 但版本有边界：只在同一容器的生命周期内有效
   │      换新容器 ⇒ version 从 1 重启 ⇒ 旧 handle 数值相同、静默命中
   ▼
⑦ 于是债务必然落到遍历器：父链 + 绝对路径 + 可达性证明
                │
                └──► 接 batching-state-reuse-locality.md 的 ①②
```

> **② ③ ④ 是买到的东西，⑤ ⑥ ⑦ 是必须付的账。** 两边都要看见，才算理解这个模式。
>
> 两篇的**接点**在 ④：那篇第 4 步（压实重排）的动机从这里进来；而 ④ 能不能成立，取决于有没有人
> 先给你一个稳定的"逻辑访问顺序"去对齐——那是 [`batching-state-reuse-locality.md`](./batching-state-reuse-locality.md) 第 ①② 步的产物。
> **互为前提，但论证起点不同：那篇从"开销重复"起手，这篇从"位置可变"起手。**

---

## 3. 容器选型：`Vec` vs `SlotMap` vs `HashMap`

模式只要求"handle + 容器"，**容器选型是独立决策，且决定这个模式能不能落地**。

| 维度 | `Vec<Node>` + `usize` | `SlotMap<DefaultKey, Node>` | `HashMap<Path, Node>` |
|---|---|---|---|
| 访问已知节点 | 1 次地址计算 | 地址计算 + **同一 cache line 内**的 version 比较 | hash + probe |
| 删中间元素 | ⇒ **其后全部下标偏移，所有 handle 作废** | ⇒ 只标空洞，别的 handle 不动 | 只影响该 key |
| 空间复用 | 需自建 free list | 内建（侵入式 LIFO，存在空 slot 里） | 内建 |
| 旧 handle 的行为 | **静默指到新对象** | 显式 `None` | key 与位置无关，无此问题 |
| 物理布局可重排 | ✅ | ✅ | ❌（entry 顺序由 hash 决定） |
| "我在哪"（键/路径） | ❌ 派生 | ❌ 派生 | ✅ key 就是 |
| 可达性谁负责 | 自己 | 自己（版本兜底一半） | 存在即等于可达 |

### 关键推论：`Vec` 不是"更快那个选项"，是"会逼你重造 SlotMap 的那个选项"

trie 的节点**必须能在中途消失**（reveal → update leaf → branch collapse → prune）。要支持这个，`Vec` 只有两条路：

```
① remove            ⇒ O(n) 且作废全部下标 ⇒ 在带回指的图结构上直接不可用
② tombstone + free list ⇒ 你刚写完一个 slotmap，只是少了 version
```

而一旦有了 free list，就必须回答"旧 handle 怎么办"。**带版本就是那个答案，成本是 slot 里 4 字节 + 同 cache line 一次比较。**

> 所以 `Vec → SlotMap` 不是偏好，是**必然演化**。判据一句话：
> **只要 handle 会存活在它所属容器之外，generation 就从"可选增强"变成"必需"。**
>
> reth 正是这种情况：`ArenaCursor.stack` 里的 `Index` 活在 arena 之外，而 `pop()` 明确用 `arena.get() → Option` 处理"入栈后节点已被删除"（prune 路径）。这里**没有版本就只能读到错节点，而且是静默的**。

### 但别过度信任版本：两条边界

**① generation 只在同一个 arena 的生命周期内有效。**

`compact_arena` 是往一个**全新** `SlotMap` 里搬，`*arena = new_arena`（`mod.rs:45, 84`）。slotmap 每个新容器的第一个 key 恒为 `(slot 1, version 1)`（slot 0 是哨兵），所以旧 arena 的 root handle 和压实后新 arena 的 root handle **数值完全相同**。

⇒ "重排后旧 handle 必然失效"是错的。那一处靠的是**"每个操作开头必须 `reset()` 清空游标"**这条纪律（`reset` 里有 `stack.len() <= 1` 断言），不是版本。

**② reth 这里的 handle 其实并不 "typed"。**

```rust
type Index = DefaultKey;                        // 只是类型别名
type NodeArena = SlotMap<Index, ArenaSparseNode>;
// 上层一个 arena，每棵 subtrie 又一个 arena —— 类型完全相同
```

把某棵 subtrie 的 root `Index` 传给 `upper_arena[...]`，编译期不报错；而 `contains_key` **也拦不住**：两个新建容器的 root 都是 `(1, 1)`，key 数值相等，校验会成功通过。

⇒ 本模式宣称的"类型安全"这一半**没有兑现**，实际靠的是纪律："handle 绝不跨 arena 传递，要搬就 `migrate_nodes` 递归全量重映射"（`mod.rs:2052-2074`，它对每个 child 递归改写 `Revealed(idx)` 正是这条纪律的代价）。真要闭环需要 newtype-per-arena。

### 那相对 `HashMap` 到底赢在哪

表层答案是"少一次 hash"，真正的答案是：**节点可寻址 ⇒ 元数据可以内联**，于是两张 side map 消失：

```
旧：branch_node_masks: HashMap<Nibbles, BranchNodeMasks>  +  prefix_set: PrefixSetMut
新：ArenaSparseNodeBranch.branch_masks  +  ArenaSparseNodeState::{Revealed, Cached{epoch}, Dirty}
```

side map 从 2 张变 0 张，**跨表一致性不再需要人工维护**——这才是结构性收益，性能只是顺带的。

---

## 4. 收益与债务

> §2 那条链的 **②③④（买到）与 ⑦（欠的）** 摊开成账目，就是本节。

**买到的**（都来自"物理位置可变"这一条）：

- 移动 / 回收 / 重排对象 ⇒ 能做 cache 布局优化、能做 GC 式压缩
- 子树可整体搬走 ⇒ **并行的最小单位 = 一个 owned 容器 + 它的 handle**
- 对象可寻址 ⇒ 元数据能内联进对象本体，不必另立 side map
- 无 lifetime 传染

**欠的债**（indirection 的账单不会消失，只会转移）：

| 被间接层牺牲掉的性质 | 债务转移到哪 |
|---|---|
| 父指针（子只知道"我是谁"，不知道"谁指我"） | 遍历器必须自带父链 |
| 对象的"内容/路径"不再是 key | 遍历器必须自己携带路径 |
| 所有权不再自动保证可达性 | 需要显式的孤儿检查 |
| 结构变化后 handle 可能要同步换 | 需要"改对象同时改所有持有者"的收口函数 |

> **识别这个模式的方法 = 找到它的债务去处。**
> 看到 arena/handle 却没看到有人补父链和路径，说明设计还不完整，而不是"更简洁"。

---

## 5. 案例：reth `ArenaParallelSparseTrie`

```rust
type Index = DefaultKey;                       // (slot: u32, version: u32)
type NodeArena = SlotMap<Index, ArenaSparseNode>;
// 父指向子：ArenaSparseNodeBranchChild::Revealed(Index)   —— 只有 handle，没有引用
```

它替换掉的旧实现是另一极——**路径即身份**：

```rust
nodes: HashMap<Nibbles, SparseNode>            // key 就是节点在树里的路径
```

两极对照，这就是本模式的全部取舍：

| | 路径即身份（HashMap） | 引用即身份（arena） |
|---|---|---|
| "我在哪"（路径） | 免费，key 就是 | **派生量，必须自己算并携带** |
| "谁指着我"（父） | 免费，截 key 前缀 | **不存在** |
| 物理位置 | 不可控，永远不能重排 | 完全可控 ⇒ 可为 cache 重排 |
| 移动 / 搬走子树 | 做不到（key 就是位置） | 一个 `Box` 直接搬 |
| 元数据 | 只能放 side map | 可内联进节点 |
| 点查 by path | O(1) 一次 lookup | O(D) 从根逐步下降 |
| 访问一个已知节点 | hash + probe | 一次地址计算 |

关键取舍一句话：**arena 用"点查变慢、路径要自带、父链要自带"，换"布局可变、子树可搬、元数据可内联"。**

所以它适合**遍历密集、批量处理**的场景（sparse trie 每 block 要把同一批节点反复扫几遍），不适合**偶发点查**的场景。

### 债务在代码里长什么样

那条"父链 + 路径"的债，在 reth 里由 `ArenaCursor` 还：

```rust
struct ArenaCursor {
    stack: Vec<{ index, path, next_dense_idx }>,   // ← 父链 + 每层续读位置
    needs_pop: bool,
}
```

`stack` 就是被 arena 表示法丢掉的那两样东西：`stack[i]` 是 `stack[i+1]` 的父（父链），`entry.path` 是该节点的绝对路径。**cursor 不是性能优化，是这笔债的偿还。**

反证：只读点查 `find_leaf_in_arena` **不用 cursor**——它只需要一个 `Index` 加一个偏移计数器。所以 cursor 的定位是"**带可写上下文的遍历**"，不是"遍历的抽象"。

---

## 6. 同一形状在其他系统

| 系统 | Handle | 换来的核心能力 |
|---|---|---|
| Unix | `int fd` | 位置无关、可 dup、进程退出自动回收 |
| PostgreSQL | `ctid` | 页可分裂/移动、可 vacuum 重排 |
| ECS | `Entity(id, gen)` | 组件任意重排成 SoA |
| **JVM/GC** | 句柄表 | **对象可被压缩**（否则 GC 永远不能整理堆） |
| MDBX | cursor（页号 + slot） | 页可分裂合并 |
| reth trie | `slotmap::DefaultKey` | 见上 |

JVM 那行是这个模式最有力的存在性证明：**"允许 GC 压缩堆"这件事，本质就是靠一层 indirection 换来的。** 不引入 handle，你永远不能自由重排内存。

---

## 7. 什么时候用 / 不用

| 条件 | 判断 |
|---|---|
| 需要重排、压缩、搬移对象 | **必须用**（没有替代） |
| 需要并行单位是"一棵子树" | **该用**（handle + owned 容器） |
| 对象数量大、被反复遍历 | 该用（收益随访问次数放大） |
| 对象少、访问偶发、位置不变 | **不要用**（直接引用 + lifetime 更简单） |
| 主要操作是按 key 点查 | 不要用（路径即身份天然支持） |
| 没有预算再写一个带父链的遍历器 | **不要用**——债必须有人还 |

容器选型的两问：

| 问 | 答"是" | 答"否" |
|---|---|---|
| handle 会存活在容器之外吗（存在遍历栈里、别的容器里）？ | **必须** `SlotMap`（裸下标 = 静默 ABA） | `Vec` + `usize` 更简单，且同样可重排 |
| 对象有没有稳定的内容键（路径/ID）可当 key？ | `HashMap` 更省事：路径免费、父免费 | 需要"我在哪"→ 只能自带，那 `HashMap` 的优势就没了 |

---

## 参考

- `reth/crates/trie/sparse/src/arena/{mod.rs:31-33, cursor.rs}`
- 被替换的旧实现：`git show de7a103748^:crates/trie/sparse/src/parallel.rs`（`nodes: HashMap<Nibbles, SparseNode>`）
- 引入 / 删除：`792c8f2558 (#22381)` / `de7a103748 (#25453, C-debt)`
- slotmap 实现细节：`basic.rs:22-25`（`Slot{u:union{value,next_free}, version}`）、`129-134`（单一 `Vec<Slot<V>>`，version 与 value 同 slot）、`with_capacity_and_key`（**slot 0 是哨兵 ⇒ 新容器第一个 key 恒为 `(1,1)`**）、`try_insert_with_key`（insert 优先复用 `free_head`，LIFO）、`remove_from_slot`（version 递增 + 侵入式空闲链）
- 配套的性能侧：[`batching-state-reuse-locality.md`](./batching-state-reuse-locality.md) —— 它的 ④「压实重排」= 本篇的 ④「布局可重排」，同一个节点从另一个方向走
