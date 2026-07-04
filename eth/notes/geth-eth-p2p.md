# geth eth/p2p 交易中继丢弃问题（egress fan-out 队列截断）

## 现象

拓扑为 `reth → geth → reth`，geth 承担交易**中继（relay）**角色。上游 reth 突发转发大量交易，
下游 reth 收到的交易数明显少于上游发出的——即 geth 在中继过程中静默丢弃了大量交易。

排查后确认：丢弃发生在 geth 的**出站（egress）广播路径**，不是入站接收，也不是下游 TCP 背压
（下游 reth 读取很快，`reth → reth` 直连无此问题）。

## 交易传播（egress）路径

1. txpool 接受新交易后，通过事件 feed 发出 `NewTxsEvent`，进入 handler 的 `txsCh`（缓冲 4096）。
   - `eth/handler.go` 中 `txChanSize = 4096`、`txsCh` 定义与订阅。
2. **全局唯一**的广播 goroutine `txBroadcastLoop` 逐个取事件，**同步**调用 `BroadcastTransactions`。
   - `eth/handler.go:548` `txBroadcastLoop`
3. `BroadcastTransactions` 对事件里的每笔交易、每个 peer 决定投递方式：
   - `ceil(sqrt(len(peers)))` 个 peer 走**直发完整交易**（`Transactions`）；其余 peer 走**哈希公告**
     （`NewPooledTransactionHashes`，下游需再发 `GetPooledTransactions` 回程拉取）。
   - 对每个 peer，把该事件里发给它的所有 hash **累积成一个 slice**，然后**一次性**调用
     `AsyncSendTransactions` / `AsyncSendPooledTransactionHashes`。
   - `eth/handler.go:491` `BroadcastTransactions`；`choosePeers` 在 `eth/handler.go:733`（`sqrt` 逻辑在 `:752`）。
4. `AsyncSend*` 把这一批 hash 通过无缓冲 channel 交给该 peer 的发送 goroutine。
   - `eth/protocols/eth/peer.go:145` `AsyncSendTransactions`、`:171` `AsyncSendPooledTransactionHashes`。
5. 每个 peer 有独立的发送 goroutine `broadcastTransactions` / `announceTransactions`，
   维护一个待发 `queue`。
   - `eth/protocols/eth/peer.go:83-84` 启动这两个 goroutine。

## 发送 goroutine 内部的两个独立机制

以 `broadcastTransactions` 为例（`eth/protocols/eth/broadcast.go`），队列有两个互不相干的机制：

### 机制 A：渐进排空（不丢数据）

`eth/protocols/eth/broadcast.go:42-59`

```go
if done == nil && len(queue) > 0 {              // 上一批发完(done)才开下一批 —— 同一时刻只有一批在途
    for i := 0; i < len(queue) && size < maxTxPacketSize; i++ { // 从队头取，累计 ≤ 100KB
        ...
    }
    queue = queue[:copy(queue, queue[hashesCount:])]            // 把已取走的从队头移除
}
```

- `maxTxPacketSize = 100 * 1024`（`eth/protocols/eth/broadcast.go:27`）。
- 一次发不完，剩余部分留在 `queue`，后续循环继续发。**此机制从不丢弃**，只是分批、串行地发。

### 机制 B：入队截断（唯一丢弃点）

`eth/protocols/eth/broadcast.go:82-86`

```go
case hashes := <-p.txBroadcast:
    queue = append(queue, hashes...)
    if len(queue) > maxQueuedTxs {                                       // 判断的是积压总量
        queue = queue[:copy(queue, queue[len(queue)-maxQueuedTxs:])]     // 只保留最新的 maxQueuedTxs 个
    }
```

- `maxQueuedTxs = 4096`、`maxQueuedTxAnns = 4096`（`eth/protocols/eth/peer.go:37,41`），**硬编码**。
- 截断保留的是**最新的 4096 个**，丢弃的是**队头（最老）的**。
- 公告路径 `announceTransactions` 有完全相同的逻辑（`eth/protocols/eth/broadcast.go:151-156`，用 `maxQueuedTxAnns`）。

## 根因

丢弃 = 队列积压 `len(queue)` 越过上限 4096。这只在两种情况发生：

1. **单次 append 就 > 4096**：`BroadcastTransactions` 对每个 peer 是**一次** `AsyncSend*` 把该事件里
   所有 hash 一起塞入的。当**单个 `NewTxsEvent` 里发往同一 peer 的交易数 > 4096** 时，这一次 append
   之后立即触发截断。
2. **持续 append 速率 > 排空速率**：多个事件累加使积压缓慢涨过 4096。排空速率由 `done`（`SendTransactions`
   写完 socket 后关闭）触发频率决定；下游读取快、socket 不堵时排空很快，积压涨不起来，此情况基本不成立。

**本次实测命中情况 1**：单个事件发往同一 peer 的交易数约 **1 万笔**，一次 append 后队列被截断到 4096，
**最老的约 5900 笔从未发出即被丢弃**。丢弃依据是"在事件里的位置"，与 gas / 优先级无关，近似随机截断。

深层原因：上游注释指出 `maxQueuedTxs` 本应 "referenced from the size of tx pool"——即该队列上限本应随
txpool 容量缩放。当 txpool 的 `GlobalSlots` 被调得很大、单次可 promote 上万笔时，队列上限仍停在默认 4096，
二者不匹配，突发批量必然被截断。

与"下游快慢无关"的原因：`SendTransactions` 走 `p2p.Send` 写 socket，下游读得快时几乎立即返回、排空很快；
但机制 B 是在**入队瞬间**按积压总量截断的，与下游读取速度无关。

## 丢弃是静默的：无日志、无 metric

`eth/protocols/eth/broadcast.go:82-86` 与 `:151-156` 两处截断**既不打日志、也不计数**，是完全静默的丢弃。
这是排查困难的直接原因——监控上看不到任何"drop"指标。唯一能间接观察的：

- `BroadcastTransactions` 结尾的 `"Distributed transactions"` debug 日志（`eth/handler.go:543`），
  其 `bcastcount` / `anncount` 与上游实际入站交易速率对比，出现大缺口即在丢。
- 对比 geth 的 p2p ingress 与 egress 交易数/字节数曲线。

## 相关代码位置速查

| 位置 | 说明 |
|------|------|
| `eth/handler.go:51` `txChanSize = 4096` | `NewTxsEvent` 订阅 channel 缓冲 |
| `eth/handler.go:548` `txBroadcastLoop` | 全局唯一广播 goroutine（串行） |
| `eth/handler.go:491` `BroadcastTransactions` | 每事件×每 peer 决定投递方式并 `AsyncSend*` |
| `eth/handler.go:733` `choosePeers`（`:752` sqrt） | 直发 peer 选取，`ceil(sqrt(N))` |
| `eth/handler.go:512,61` `txMaxBroadcastSize = 4096` | 超过此大小的交易只公告不直发 |
| `eth/protocols/eth/peer.go:37,41` `maxQueuedTxs / maxQueuedTxAnns = 4096` | 每 peer 待发队列上限（硬编码） |
| `eth/protocols/eth/peer.go:145,171` `AsyncSend*` | 把一批 hash 交给发送 goroutine |
| `eth/protocols/eth/broadcast.go:27` `maxTxPacketSize = 100KB` | 单批发送累计大小上限 |
| `eth/protocols/eth/broadcast.go:42-59` | 机制 A：渐进排空（不丢） |
| `eth/protocols/eth/broadcast.go:82-86` | 机制 B：直发队列入队截断（静默丢弃） |
| `eth/protocols/eth/broadcast.go:151-156` | 机制 B：公告队列入队截断（静默丢弃） |
