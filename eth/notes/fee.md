## OpStack Fee Formula

$$
\text{total\_fee} = \underbrace{\text{gas\_used} \times (\text{base\_fee} + \text{priority\_fee})}_{\text{L2 执行费}} + \underbrace{\text{l1\_data\_fee}}_{\text{L1 数据费}} + \underbrace{\text{operator\_fee}}_{\text{Isthmus hardfork}}
$$

## L2 basefee计算公式
L2 执行费:在 XLayer 上 base_fee ≈ 0,所以约等于 gas_used × priority_fee。如果 sequencer 接受 priority_fee = 0,这一项归零。

gas_target = gas_limit / elasticity_multiplier

情况 1:parent_gas_used == gas_target — 用量正好,base_fee 不变
$$
\text{base\_fee} = \text{parent\_base\_fee}
$$

情况 2:parent_gas_used > gas_target — 用多了,涨
$$
\text{base\_fee} = \text{parent\_base\_fee} + \max\Big(1,\; \text{parent\_base\_fee} \times \frac{\text{parent\_gas\_used} - \text{gas\_target}}{\text{gas\_target} \times \text{max\_change\_denominator}}\Big)
$$

情况 3:parent_gas_used < gas_target — 用少了,跌(不会跌到负)
$$
\text{base\_fee} = \text{parent\_base\_fee} - \text{parent\_base\_fee} \times \frac{\text{gas\_target} - \text{parent\_gas\_used}}{\text{gas\_target} \times \text{max\_change\_denominator}}
$$

合并写法
$$
\text{base\_fee} = \text{parent\_base\_fee} \times \Big(1 + \frac{\text{parent\_gas\_used} - \text{gas\_target}}{\text{gas\_target} \times \text{max\_change\_denominator}}\Big)
$$

代入gasused:
$$
\text{base\_fee} = \text{parent\_base\_fee} \times \Big(1 + \frac{\text{parent\_gas\_used} \times \text{elasticity} - \text{gas\_limit}}{\text{gas\_limit} \times \text{max\_change\_denominator}}\Big)
$$


### base fee设置为0的方式:
- Elasticity=1, Denominator = 1，出一个空块儿之后，parent_base_fee就等于0
- Elasticity=0， Denominator = 1不行，因为SystemConfig.sol要求Elasticity和Denominator>=1 
- 其他的交易设置一个最小的priority_fee
- feehistory

### L1 数据费
L1 数据费(Ecotone/Fjord 公式) — 计算在 deps/optimism/rust/op-revm/src/l1block.rs:334-368:

$$
\text{l1\_data\_fee} = \frac{\text{data\_gas} \times \big(16 \times \text{l1\_base\_fee} \times \text{base\_fee\_scalar} + \text{blob\_base\_fee} \times \text{blob\_scalar}\big)}{16 \times 10^6}
$$

### Operator fee
$operator\_fee = gas\_used × operator\_fee\_scalar / 1e6 + operator\_fee\_constant$

## X Layer mainnet fee config
- Elasticity = 1, Denominator = 100,000,000 (代码中设置)
- base_fee += base_fee × (used - target) / target / denominator接近于0
- l1_base_fee在SystemConfig合约中setGasConfigEcotone(scalar, blob_scalar)配置
    - 0: cast call 0x4200000000000000000000000000000000000015 "baseFeeScalar()(uint32)" --rpc-url https://rpc.xlayer.tech
    - 0: cast call 0x4200000000000000000000000000000000000015 "blobBaseFeeScalar()(uint32)" --rpc-url https://rpc.xlayer.tech
- operator_fee
    - operator_fee_scalar: 0 
        - cast call 0x4200000000000000000000000000000000000015 "operatorFeeScalar()(uint32)" --rpc-url https://rpc.xlayer.tech
    - operator_fee_constant
        - cast call 0x4200000000000000000000000000000000000015 "operatorFeeConstant()(uint64)" --rpc-url https://rpc.xlayer.tech

## OP mainnet fee config
- EIP-1559 参数:Holocene 后在 L1 SystemConfig.sol (function setEIP1559Params(uint32 _denominator, uint32 _elasticity)) 通过 setEIP1559Params(denominator, elasticity) 配置;经 derivation pipeline 编码到 L2 block header 的 extraData,执行层解码(decode_holocene_base_fee in deps/optimism/rust/op-reth/crates/chainspec/src/basefee.rs:16-33),若都为 0 则 fallback 到 chain spec 默认值
    - Denominator = 250: cast call 0x229047fed2591dbec1eF1118d64F7aF3dB9EB290 "eip1559Denominator()(uint32)" --rpc-url <ETH_L1_RPC>
    - Elasticity = 2: cast call 0x229047fed2591dbec1eF1118d64F7aF3dB9EB290 "eip1559Elasticity()(uint32)" --rpc-url <ETH_L1_RPC>
- l1_base_fee在SystemConfig合约中setGasConfigEcotone(scalar, blob_scalar)配置
    - 5227: cast call 0x4200000000000000000000000000000000000015 "baseFeeScalar()(uint32)" --rpc-url https://mainnet.optimism.io
    - 1014213: cast call 0x4200000000000000000000000000000000000015 "blobBaseFeeScalar()(uint32)" --rpc-url https://mainnet.optimism.io
- operator_fee
    - operator_fee_scalar: 0
        - cast call 0x4200000000000000000000000000000000000015 "operatorFeeScalar()(uint32)" --rpc-url https://mainnet.optimism.io
    - operator_fee_constant: 0
        - cast call 0x4200000000000000000000000000000000000015 "operatorFeeConstant()(uint64)" --rpc-url https://mainnet.optimism.io


## 配置变更
```
┌────────────────────────────────────────────────────────────────┐
│ L1 (Ethereum mainnet)                                          │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ SystemConfig.sol  ← 唯一的 source of truth              │  │
│  │   - eip1559Denominator / Elasticity                      │  │
│  │   - scalar (packed: base + blob)                         │  │
│  │   - operatorFeeScalar / Constant                         │  │
│  │   - batcherHash / gasLimit                               │  │
│  │   写入:owner 调 setEIP1559Params/setGasConfigEcotone... │  │
│  │   读取:op-node 监听 ConfigUpdate 事件                  │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
                        │
                        │ op-node 把 SystemConfig 值打包到
                        │ 每个 L2 block 的第一笔 deposit tx
                        ▼
┌────────────────────────────────────────────────────────────────┐
│ L2 链上 (运行时状态,每个 L2 block 更新)                       │
│                                                                │
│  ┌──────────────────────────────┐   ┌──────────────────────┐  │
│  │ L1Block.sol 预编译           │   │ L2 block.extraData   │  │
│  │ (0x4200...0015)              │   │ (8 bytes Holocene)   │  │
│  │   - baseFeeScalar            │   │   - denominator      │  │
│  │   - blobBaseFeeScalar        │   │   - elasticity       │  │
│  │   - operatorFeeScalar/Const  │   │                      │  │
│  │   - l1BaseFee / blobBaseFee  │   │                      │  │
│  │   - basefee / number / hash  │   │                      │  │
│  │                              │   │                      │  │
│  │ 写:仅 depositor account     │   │ 写:builder 构造块时 │  │
│  │   通过 setL1BlockValuesXxx() │   │ 读:执行层算下一块  │  │
│  │ 读:L2 合约用 cast / getter │   │   的 base_fee       │  │
│  │     op-revm 直接读 storage  │   │                      │  │
│  └──────────────────────────────┘   └──────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
                        │
                        │ EVM 执行交易时
                        ▼
┌────────────────────────────────────────────────────────────────┐
│ 执行层 (Rust 进程内,每个 tx 计算时使用)                       │
│                                                                │
│  ┌──────────────────────────────┐   ┌──────────────────────┐  │
│  │ l1block.rs (op-revm)         │   │ RollupConfig         │  │
│  │ struct L1BlockInfo           │   │ (kona/genesis)       │  │
│  │                              │   │                      │  │
│  │ 作用:L1Block 存储槽的       │   │ 作用:启动时加载的   │  │
│  │   in-memory 缓存            │   │   静态链配置        │  │
│  │ 写:try_fetch_ecotone/       │   │   - hardfork 时间戳 │  │
│  │   isthmus/jovian — 直接     │   │   - chain_op_config │  │
│  │   sload(L1_BLOCK_CONTRACT,  │   │     (BaseFee fallback)│ │
│  │   SLOT) 拷到结构体          │   │   - genesis info    │  │
│  │ 读:计算 l1_data_fee /      │   │ 写:从 JSON 加载,   │  │
│  │   operator_fee 时用         │   │   运行时不变        │  │
│  └──────────────────────────────┘   └──────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

### 谁写谁读
写入只有一个权威路径:L1 owner → SystemConfig → (op-node + 内置 deposit tx) → L2 状态。L2 上 L1Block 的写权限只给 DEPOSITOR_ACCOUNT(系统地址),用户合约写不了。

读取有多个消费者,但不算「写重合」:

- L2 上的 Solidity 合约(比如 GasPriceOracle 预编译)用 getter 读 L1Block
- op-revm 的 L1BlockInfo 用 db.storage(L1_BLOCK_CONTRACT, SLOT) 直接读同一个槽 — 不走 getter,但读的是同一份数据
- 这是两个读者,共享一个写者(depositor),所以一致性靠协议保证

**为什么 RollupConfig 里 也有 BaseFee 配置(chain_op_config)**:

- Holocene 之前没有 SystemConfig.eip1559Params — 那时 chain_op_config 就是唯一来源
- Fallback:Holocene 之后如果 SystemConfig 值是 0,执行层走 chain_op_config(见 basefee.rs:26-30)
- Genesis 启动:首块还没 extraData 可读时,只能用 RollupConfig 兜底


> 为什么base_fee放到Header里，而l1 fee这些放到L1 block里？因为EIP-1559 在 L1 spec 里就把 base_fee 定义成了 header-only 的 stateless 函数(basefee opcode),所有围绕它的检查(maxFeePerGas 准入、BASEFEE opcode、header pre-validation)都假设这个性质。OP 想在不动这个契约的前提下加可配置参数,只能塞进 header 的某个字段 — 自然落到 extraData。L1Block 那一类参数没这个约束,因为它们的消费者(L1 cost 计算、operator fee)本来就发生在 tx 执行中,跟 state 同层,放 storage 顺理成章。