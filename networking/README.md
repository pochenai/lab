## 一些基本的数据
| 通信方式                    | 单向延迟（大概）      |
| ----------------------- | ------------- |
| shared memory           | 几十 ns ~ 几百 ns |
| futex 唤醒                | ~100ns - 1μs  |
| Unix Domain Socket      | ~1-10 μs      |
| TCP loopback(127.0.0.1) | ~5-30 μs      |
| 网络 TCP                  | 100μs ~ ms    |

UDS: 
- sycall(sendmsg/recvmsg)/context switch(~0.5 - 3 μs)/kenerl-user copy; 
- 不走ip stack/congestion control所以比TCP快2-5倍。