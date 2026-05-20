## benchmark engine api rpc
benchmark 目标是模拟一个典型的 JSON-RPC 请求负载，来衡量服务器处理大请求时的性能表现。我们以 `engine_newPayloadV4` 方法为例。
简化模型为: Engine payload -> JSON-RPC marshal -> localhost HTTP + JWT auth -> EL auth -> JSON-RPC unmarshal -> typed engine payload。

普通 ERC20 transfer：
- gas 通常约 45k-65k
- 500M / 50k ~= 10,000 tx
- signed raw tx 大概 170-250 bytes
- JSON 里 raw tx 是 hex string，所以大概翻倍：340-500 bytes/tx
所以10,000 tx * 400 bytes ~= 4,000,000 bytes ~= 3.8 MiB

### Commands
```
go run . -target-json-mib 2 -n 500 -warmup 20 -tx-bytes 256

cargo run --release -- -target-json-mib 2 -n 500 -warmup 20 -tx-bytes 256
```

### Results

| Payload | Runtime | Avg | P95 |
|---|---:|---:|---:|
| 2 MiB | Go | 28 ms | 40 ms |
| 2 MiB | Rust | 4.5 ms | 5 ms |
| 4 MiB | Go | 54 ms | 74 ms |
| 4 MiB | Rust | 9 ms | 10 ms |