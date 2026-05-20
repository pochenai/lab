根据[benchmark结果](https://okg-block.sg.larksuite.com/wiki/Z0HrwC8q6iHktrkunYglDiDqgSd)来看, CL+EL的通讯成本很低，主要是线程调度的问题。

## 通信

### 通信方式
通过http json rpc通信:
```
HTTP Request
├── Header
│     └── JWT(签名iat: issued at timestamp)
│           └── “我是合法 CL”
│
└── Body
      └── JSON-RPC
            └── “我要调用 engine_newPayloadV3”
            └── body(大量JSON parse，大概几十~几百 μs):
                └──{
                    "jsonrpc":"2.0",
                    "method":"engine_newPayloadV3",
                    "params":[
                        {
                        "transactions":[ ... hundreds ... ],
                        "withdrawals":[ ... ],
                        ...
                        }
                    ],
                    "id":1
                  }
```

### RPC分类

- 查 EVM/交易/账户/receipt:  external -> EL(op-reth) eth_*
- 查 rollup/CL 状态:        external -> CL(op-node) optimism_*
- 控制 op-node/sequencer:   external -> CL(op-node) admin_* / opstack_*
- CL 推动 EL:               op-node -> op-reth engine_*

CL 与 EL 的核心通讯是 Engine API；eth_* / debug_* 不是共识控制协议，主要是 EL 的查询/调试/proof RPC，其中少量也会被 op-node 当辅助读接口使用。
```
op-node CL  -- engine_* -->  op-reth EL
          \-- eth_* 辅助读 --> op-reth EL
```

op-node也会用一部分 eth_* 去问 L2 EL 辅助信息，但是这个占比很少，比如：
- eth_getBlockByHash/Number：找 L2 block ref、初始化/重置 head
- eth_getProof：算 output root 时读 L2ToL1MessagePasser storage root
- receipts 相关 RPC：interop/indexing 或校验辅助路径
- debug_executePayload：更偏 proof/witness，不是主同步路径