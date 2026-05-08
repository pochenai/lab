# 如何快速读懂一个系统的设计
核心: 先找 **spine**（贯穿全程的主干），再按 spine 的形式选切入方法。trait-first 不是普世规则，只在 capability-style 系统里成立。
> 因为大多数代码没有大纲，需要自己从代码中先找出找大纲/主干。

## 系统的三种形态 → 三种 spine

| 系统形态 | spine 在哪 | 切入顺序 | 典型例子 |
|---|---|---|---|
| Library / capability | trait 就是 spine | trait → struct → 方法 | tokio, tower, serde, diesel |
| 算法 / 数据结构 | invariant 就是 spine | invariant → 操作 → 复杂度 | 排序、堆、k-way merge |
| 服务 / 状态机 / 事件驱动 | **main loop / event flow 是 spine** | loop → 阶段 → 接口 → 数据结构 | tx pool, scheduler, 共识引擎 |

## 判别方法
看代码里有没有显眼的 `tokio::select!` / `loop {}` / scheduler / dispatcher：
- **有** → 事件驱动，先找主循环。trait 先放一放。
- **没有** → capability-style，trait-first 合理。

## 反例 —— 为什么 interface-first 会迷路
事件驱动系统里，trait 描述的是"输入边界"（什么能进系统），不是"系统行为"（系统平时在做什么）。绝大部分变化是事件触发的、被动响应的，外部主动调用只是少数派。从 trait 入手 = 严重欠采样。

## 实现侧的对偶 —— Walking Skeleton
学习自顶向下，实现也自顶向下：
1. 先打通一条端到端的细线（每步可以是空壳）
2. 让 entry → core → assert 全链路 alive
3. 再往里加肉

不要从底层 primitive 往上堆 —— 容易为不知道形状的脚手架打地基。

## 一句话总结
**spine first。trait / invariant / event loop 只是 spine 在不同系统里的语法形式。**
