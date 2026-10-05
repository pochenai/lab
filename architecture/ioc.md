### IoC（Inversion of Control，控制反转）

**核心思想：**

> **IoC 关注控制关系（control flow）：把“控制逻辑”与“具体行为实现”分离。**

传统模式是业务代码主动控制整个流程：

```text
Business Code
    │
    ├── 创建对象
    ├── 选择实现
    ├── 决定调用顺序
    └── 主动调用其他模块
```

IoC 则把这些控制权交给更高层的 **framework / runtime / container / event loop**：

```text
Framework / Runtime
        │
        │  控制 when / order / lifecycle
        ↓
   Extension Point
        ↑
        │ 提供具体 behavior
        │
 Implementation
```

因此可以用一句话记忆：

> **Implementation defines WHAT to do; Framework controls WHEN / WHO / ORDER.**

或者经典的：

> **Library: you call it. Framework: it calls you.**

---

### IoC 可以发生在不同维度

```text
                         IoC
                          │
          ┌───────────────┼────────────────┐
          ↓               ↓                ↓
     Dependency      Execution Flow       Events
          │               │                │
      DI / Plugin      Callback         Observer
    Service Locator    Template         Event Bus
          │            Middleware          │
          │             Pre/Post           │
          ↓               ↓                ↓
      谁提供对象？       谁调用谁？        谁触发谁？
```

还可以扩展到 runtime / concurrency：

```text
                         IoC
                          │
      ┌───────────┬───────┼───────────┬────────────┐
      ↓           ↓       ↓           ↓            ↓
 Dependency    Execution Events    Lifecycle    Scheduling
      │           │       │           │            │
     DI        Callback Observer   Framework     Actor
   Plugin      Template EventBus    Hooks       Runtime
      │        Middleware            │            │
      ↓           ↓       ↓           ↓            ↓
  谁提供实现？  谁调用谁？ 谁触发谁？ 何时执行？   谁调度谁？
```

比如 Actor Model 里：

```text
Actor implementation:
    “收到 message 后做什么”

Actor runtime:
    “什么时候调度 actor”
    “什么时候投递 message”
    “哪个线程执行”
    “什么时候 restart”
```

所以它同样体现了 IoC：**actor 提供 behavior，runtime 掌握 scheduling/control flow。**

---

### 和“接口 / 实现分离”最重要的区别

这是最容易混淆的地方：

```text
接口 / 实现分离
================

Caller → Interface ← Implementation

关注：
“我依赖谁？”

解决：
模块依赖 / coupling

原则：
依赖 abstraction，而不是具体 implementation
```

而 IoC：

```text
IoC
================

Framework / Controller
          │
          │ control flow
          ↓
     Extension Point
          ↑
          │ behavior
    Implementation

关注：
“谁控制执行流程？”

解决：
控制逻辑与具体行为实现的耦合
```

因此最简单的**记忆模型**：

> **Interface / Implementation Separation → 关注 dependency relationship**  
> **IoC → 关注 control relationship / control flow**

两者是不同维度，但经常组合使用。

例如：

```rust
trait Hook {
    fn execute(&self);
}
```

这里只有：

> **接口 / 实现分离**

而：

```rust
fn framework(hook: &dyn Hook) {
    pre();
    hook.execute();
    post();
}
```

则进一步有：

```text
Framework
   │
   ├── pre()
   ├── hook.execute()
   └── post()
```

Framework 控制 `when/order`，Hook 只实现 behavior：

> **这才体现 IoC。**

---

### DI 为什么也是 IoC？

DI 是把 IoC 应用在 **dependency control** 上：

传统：

```text
Service
   │
   └── new RocksDB()
```

Service 自己控制依赖的创建和选择。

DI：

```text
Composition Root
      │
      ├── new RocksDB()
      │
      ↓
   Service(db)
```

变成：

> **Service 使用 dependency，但不控制 dependency 的创建/选择。**

所以：

```text
IoC                         ← 设计原则
 │
 ├── DI                     ← dependency control
 ├── Plugin / SPI           ← implementation selection
 ├── Callback               ← call control
 ├── Template Method        ← algorithm control
 ├── Pre/Post Hook          ← lifecycle control
 ├── Middleware             ← pipeline control
 ├── Observer / Event Bus   ← event control
 └── Actor Runtime          ← scheduling/message control
```

最终可以压缩成一句最值得记住的话：

> **IoC = 实现方提供 Behavior，控制方拥有 Control Flow。**  
> **接口/实现分离解决“依赖谁”，IoC 解决“谁控制谁”。**