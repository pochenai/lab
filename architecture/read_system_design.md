# 如何快速读懂一个系统的设计
核心: 先找 **spine**（贯穿全程的主干），再按 spine 的形式选切入方法。trait-first 不是普世规则，只在 capability-style 系统里成立。
spine 有两层：
1. semantic spine：世界模型、状态转移、不变量
2. execution spine：main loop、event flow、pipeline、trait dispatch
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

# 复杂系统设计

## 复杂性来源
复杂度≈实体*状态*并发*时间*外部事件
- 实体: 多个角色
- 状态转移维度过多:
    - 并发: 多读多写
    - 时间: 异步引起的超时/过期/重试/backoff等
    - 外部事件: 外部事件会触发状态变化

(new_state, output, effects) = f(old_state, input, time, external_world)
- 相对于无状态系统，多了几个维度：历史、顺序、失败、重试、并发观察者、旧 state 和新 state 的切换。

## 怎么理解并设计这样的系统？
建立世界模型: 实体+状态+关系+转移。
1. 实体：这个世界里有哪些东西？
2. 状态：每个实体可能处于什么状态？
3. 关系：实体之间有什么约束关系？
4. 转移：什么事件/命令能改变状态？
5. 不变量：哪些关系在所有状态下都必须成立？
6. 观察视图：外部如何查询/订阅这个世界？
7. 副作用：状态变化后要对外做什么？


# 读系统 vs 设计系统

## 读系统
- 先找执行 spine：main loop / event flow / dispatcher
- 再还原语义 spine：实体 / 状态 / 转移 / 不变量
- 最后看接口和数据结构：trait / storage / index / cache

## 设计系统
反过来更自然：
- 先建语义 spine：实体 + 状态 + 转移 + 不变量
- 再设计执行 spine：command/event 如何进入，main loop 如何调度
- 再设计边界：API / trait / storage / subscription
