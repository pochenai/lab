## benchmark engine api rpc
benchmark 目标是模拟一个典型的 JSON-RPC 请求负载，来衡量服务器处理大请求时的性能表现。我们以 `engine_newPayloadV4` 方法为例。

简化模型为: Engine payload -> JSON-RPC marshal -> localhost HTTP + JWT auth -> EL auth -> JSON-RPC unmarshal -> typed engine payload。

普通 ERC20 transfer：
- 单笔tx gas 通常约 45k-65k
- 500M(区块gaslimit) / 50k ~= 10,000 tx
- signed raw tx 大概 170-250 bytes
- JSON 里 raw tx 是 hex string，所以大概翻倍：340-500 bytes/tx
所以10,000 tx * 400 bytes ~= 4,000,000 bytes ~= 3.8 MiB

### Commands
```
go run . -target-json-mib 2 -n 500 -warmup 20 -tx-bytes 256
go run . -target-json-mib 4 -n 500 -warmup 20 -tx-bytes 256

cargo run --release -- -target-json-mib 2 -n 500 -warmup 20 -tx-bytes 256
cargo run --release -- -target-json-mib 4 -n 500 -warmup 20 -tx-bytes 256
```

### Results

| Payload | Runtime | Avg | P95 | JSON codec / e2e Avg | JSON codec / e2e P95 |
|---|---:|---:|---:|---:|---:|
| 2 MiB | Go | 28.33 ms | 39.27 ms | 89.34% | 90.35% |
| 2 MiB | Rust | 5.12 ms | 6.41 ms | 83.71% | 77.59% |
| 4 MiB | Go | 53.11 ms | 75.83 ms | 91.26% | 90.04% |
| 4 MiB | Rust | 9.98 ms | 12.61 ms | 82.83% | 76.31% |

`JSON codec / e2e` = client request marshal + server request unmarshal + server response marshal + client response unmarshal，占 e2e 的比例。
