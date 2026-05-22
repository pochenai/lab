## 完整的 rust tracing macro 家族
https://github.com/tokio-rs/tracing

```
// 事件（一次性日志）—— 五个级别一一对应
trace!(...)    debug!(...)    info!(...)    warn!(...)    error!(...)

// 块级 span（作用域开始到结束）—— 五个级别一一对应
trace_span!(...)    debug_span!(...)    info_span!(...)    warn_span!(...)    error_span!(...)

// 通用形式（要自己写 level 参数）
event!(Level::DEBUG, ...)
span!(Level::DEBUG, ...)

// 函数级 span（attribute macro，来自 tracing-attributes）
#[instrument(level = "debug", ...)]
全部来自 tracing crate（#[instrument] 由 tracing-attributes 实现，由 tracing re-export）
```

还有一个细节：tracing-log 桥接。reth 依赖的某些第三方库（比如 hyper、reqwest、某些老 crate）内部还在用 log crate。怎么把这些 log 也收进 tracing 体系？

```
答案是 tracing-log 这个桥接 crate：

// 程序启动时调一次
tracing_log::LogTracer::init().unwrap();
```