## OpStack Fee Formula

$$
\text{total\_fee} = \underbrace{\text{gas\_used} \times (\text{base\_fee} + \text{priority\_fee})}_{\text{L2 execution fee}} + \underbrace{\text{l1\_data\_fee}}_{\text{L1 data fee}} + \underbrace{\text{operator\_fee}}_{\text{Isthmus hardfork}}
$$

## L2 basefee formula
L2 execution fee: on XLayer, base_fee ≈ 0, so it's approximately gas_used × priority_fee. If the sequencer accepts priority_fee = 0, this term goes to zero.

gas_target = gas_limit / elasticity_multiplier

Case 1: parent_gas_used == gas_target — usage is exactly on target, base_fee unchanged
$$
\text{base\_fee} = \text{parent\_base\_fee}
$$

Case 2: parent_gas_used > gas_target — overused, increases
$$
\text{base\_fee} = \text{parent\_base\_fee} + \max\Big(1,\; \text{parent\_base\_fee} \times \frac{\text{parent\_gas\_used} - \text{gas\_target}}{\text{gas\_target} \times \text{max\_change\_denominator}}\Big)
$$

Case 3: parent_gas_used < gas_target — underused, decreases (won't go negative)
$$
\text{base\_fee} = \text{parent\_base\_fee} - \text{parent\_base\_fee} \times \frac{\text{gas\_target} - \text{parent\_gas\_used}}{\text{gas\_target} \times \text{max\_change\_denominator}}
$$

Combined form
$$
\text{base\_fee} = \text{parent\_base\_fee} \times \Big(1 + \frac{\text{parent\_gas\_used} - \text{gas\_target}}{\text{gas\_target} \times \text{max\_change\_denominator}}\Big)
$$

Substituting gas_used:
$$
\text{base\_fee} = \text{parent\_base\_fee} \times \Big(1 + \frac{\text{parent\_gas\_used} \times \text{elasticity} - \text{gas\_limit}}{\text{gas\_limit} \times \text{max\_change\_denominator}}\Big)
$$


### Ways to set base fee to 0:
- Elasticity=1, Denominator = 1: after producing one empty block, parent_base_fee becomes 0
- Elasticity=0, Denominator = 1 doesn't work, because SystemConfig.sol requires Elasticity and Denominator >= 1
- Set a minimum priority_fee for other transactions
- feehistory

### L1 data fee
L1 data fee (Ecotone/Fjord formula) — computed in deps/optimism/rust/op-revm/src/l1block.rs:334-368:

$$
\text{l1\_data\_fee} = \frac{\text{data\_gas} \times \big(16 \times \text{l1\_base\_fee} \times \text{base\_fee\_scalar} + \text{blob\_base\_fee} \times \text{blob\_scalar}\big)}{16 \times 10^6}
$$

### Operator fee
$operator\_fee = gas\_used × operator\_fee\_scalar / 1e6 + operator\_fee\_constant$

## X Layer mainnet fee config
- Elasticity = 1, Denominator = 100,000,000 (set in code)
- base_fee += base_fee × (used - target) / target / denominator is close to 0
- l1_base_fee is configured in the SystemConfig contract via setGasConfigEcotone(scalar, blob_scalar)
    - 0: cast call 0x4200000000000000000000000000000000000015 "baseFeeScalar()(uint32)" --rpc-url https://rpc.xlayer.tech
    - 0: cast call 0x4200000000000000000000000000000000000015 "blobBaseFeeScalar()(uint32)" --rpc-url https://rpc.xlayer.tech
- operator_fee
    - operator_fee_scalar: 0
        - cast call 0x4200000000000000000000000000000000000015 "operatorFeeScalar()(uint32)" --rpc-url https://rpc.xlayer.tech
    - operator_fee_constant
        - cast call 0x4200000000000000000000000000000000000015 "operatorFeeConstant()(uint64)" --rpc-url https://rpc.xlayer.tech

## OP mainnet fee config
- EIP-1559 params: after Holocene, configured on L1 in SystemConfig.sol (function setEIP1559Params(uint32 _denominator, uint32 _elasticity)) via setEIP1559Params(denominator, elasticity); encoded by the derivation pipeline into the L2 block header's extraData, and decoded by the execution layer (decode_holocene_base_fee in deps/optimism/rust/op-reth/crates/chainspec/src/basefee.rs:16-33); if both are 0, it falls back to the chain spec default
    - Denominator = 250: cast call 0x229047fed2591dbec1eF1118d64F7aF3dB9EB290 "eip1559Denominator()(uint32)" --rpc-url <ETH_L1_RPC>
    - Elasticity = 2: cast call 0x229047fed2591dbec1eF1118d64F7aF3dB9EB290 "eip1559Elasticity()(uint32)" --rpc-url <ETH_L1_RPC>
- l1_base_fee is configured in the SystemConfig contract via setGasConfigEcotone(scalar, blob_scalar)
    - 5227: cast call 0x4200000000000000000000000000000000000015 "baseFeeScalar()(uint32)" --rpc-url https://mainnet.optimism.io
    - 1014213: cast call 0x4200000000000000000000000000000000000015 "blobBaseFeeScalar()(uint32)" --rpc-url https://mainnet.optimism.io
- operator_fee
    - operator_fee_scalar: 0
        - cast call 0x4200000000000000000000000000000000000015 "operatorFeeScalar()(uint32)" --rpc-url https://mainnet.optimism.io
    - operator_fee_constant: 0
        - cast call 0x4200000000000000000000000000000000000015 "operatorFeeConstant()(uint64)" --rpc-url https://mainnet.optimism.io


## Config changes
```
┌────────────────────────────────────────────────────────────────┐
│ L1 (Ethereum mainnet)                                          │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ SystemConfig.sol  ← the only source of truth             │  │
│  │   - eip1559Denominator / Elasticity                      │  │
│  │   - scalar (packed: base + blob)                         │  │
│  │   - operatorFeeScalar / Constant                         │  │
│  │   - batcherHash / gasLimit                               │  │
│  │   write: owner calls setEIP1559Params/setGasConfig...    │  │
│  │   read:  op-node watches ConfigUpdate events            │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
                        │
                        │ op-node packs the SystemConfig values into
                        │ the first deposit tx of each L2 block
                        ▼
┌────────────────────────────────────────────────────────────────┐
│ On L2 (runtime state, updated every L2 block)                  │
│                                                                │
│  ┌──────────────────────────────┐   ┌──────────────────────┐  │
│  │ L1Block.sol precompile       │   │ L2 block.extraData   │  │
│  │ (0x4200...0015)              │   │ (8 bytes Holocene)   │  │
│  │   - baseFeeScalar            │   │   - denominator      │  │
│  │   - blobBaseFeeScalar        │   │   - elasticity       │  │
│  │   - operatorFeeScalar/Const  │   │                      │  │
│  │   - l1BaseFee / blobBaseFee  │   │                      │  │
│  │   - basefee / number / hash  │   │                      │  │
│  │                              │   │                      │  │
│  │ write: only depositor account│   │ write: builder when  │  │
│  │   via setL1BlockValuesXxx()  │   │   constructing block │  │
│  │ read: L2 contracts use cast  │   │ read: exec layer     │  │
│  │   / getter                   │   │   computes next      │  │
│  │   op-revm reads storage      │   │   block's base_fee   │  │
│  │   directly                   │   │                      │  │
│  └──────────────────────────────┘   └──────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
                        │
                        │ when the EVM executes transactions
                        ▼
┌────────────────────────────────────────────────────────────────┐
│ Execution layer (in the Rust process, used per-tx computation) │
│                                                                │
│  ┌──────────────────────────────┐   ┌──────────────────────┐  │
│  │ l1block.rs (op-revm)         │   │ RollupConfig         │  │
│  │ struct L1BlockInfo           │   │ (kona/genesis)       │  │
│  │                              │   │                      │  │
│  │ role: in-memory cache of     │   │ role: static chain   │  │
│  │   L1Block storage slots      │   │   config loaded at   │  │
│  │ write: try_fetch_ecotone/    │   │   startup            │  │
│  │   isthmus/jovian — directly  │   │   - hardfork times   │  │
│  │   sload(L1_BLOCK_CONTRACT,   │   │   - chain_op_config  │  │
│  │   SLOT) copied into struct   │   │     (BaseFee fallback)│ │
│  │ read: when computing         │   │   - genesis info     │  │
│  │   l1_data_fee / operator_fee │   │ write: loaded from   │  │
│  │                              │   │   JSON, immutable at │  │
│  │                              │   │   runtime            │  │
│  └──────────────────────────────┘   └──────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

### Who writes, who reads
There is only one authoritative write path: L1 owner → SystemConfig → (op-node + built-in deposit tx) → L2 state. On L2, write access to L1Block is granted only to the DEPOSITOR_ACCOUNT (a system address); user contracts cannot write to it.

There are multiple readers, but they don't count as "overlapping writes":

- Solidity contracts on L2 (e.g. the GasPriceOracle precompile) read L1Block via getters
- op-revm's L1BlockInfo reads the same slots directly via db.storage(L1_BLOCK_CONTRACT, SLOT) — bypassing the getters, but reading the same data
- These are two readers sharing one writer (the depositor), so consistency is guaranteed by the protocol

**Why RollupConfig also carries a BaseFee config (chain_op_config)**:

- Before Holocene there was no SystemConfig.eip1559Params — back then chain_op_config was the only source
- Fallback: after Holocene, if the SystemConfig values are 0, the execution layer uses chain_op_config (see basefee.rs:26-30)
- Genesis startup: when the first block has no extraData to read yet, RollupConfig is the only fallback


> Why is base_fee placed in the Header, while the L1 fee params go into the L1Block? Because EIP-1559 in the L1 spec defines base_fee as a header-only stateless function (the BASEFEE opcode), and all the checks around it (maxFeePerGas admission, the BASEFEE opcode, header pre-validation) assume this property. OP wanted to add configurable params without breaking that contract, so it could only stuff them into some field of the header — naturally landing in extraData. The L1Block-class params don't have this constraint, because their consumers (L1 cost computation, operator fee) already happen during tx execution, at the same layer as state, so putting them in storage is the natural fit.
