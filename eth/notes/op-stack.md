## Key Design Questions
### How to prove withdraw?
- 首先计算出withdrawHash
- 然后计算该storage key对应的slot，通过eth_getProof RPC生成证明
```typescript
const proof = getProof(client, {
    address: contracts.l2ToL1MessagePasser.address,
    storageKeys: [slot],
    blockNumber: l2BlockNumber,
})
```
https://github.com/wevm/viem/blob/a59b5630311249031c7bbfdbcc093dd52586a5bf/src/op-stack/actions/buildProveWithdrawal.ts#L103


- 然后再提供outputroof的proof(hash preimage)，以及其中storage root对应的storag proof, [代码](https://github.com/QuarkChain/optimism/blob/876b6bd8649869a2e00903471821e5a6c9aa69f1/packages/contracts-bedrock/src/L1/OptimismPortal2.sol#L373)

```solidity
    function hashOutputRootProof(Types.OutputRootProof memory _outputRootProof) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _outputRootProof.version,
                _outputRootProof.stateRoot,
                _outputRootProof.messagePasserStorageRoot,
                _outputRootProof.latestBlockhash
            )
        );
    }

    function proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        uint256 _disputeGameIndex,
        Types.OutputRootProof calldata _outputRootProof,
        bytes[] calldata _withdrawalProof
    )
    {
        ...
        // Verify that the output root can be generated with the elements in the proof.
        if (disputeGameProxy.rootClaim().raw() != Hashing.hashOutputRootProof(_outputRootProof)) {
            revert OptimismPortal_InvalidOutputRootProof();
        }
        ...
        if (
            SecureMerkleTrie.verifyInclusionProof({
                _key: abi.encode(storageKey),
                _value: hex"01",
                _proof: _withdrawalProof,
                _root: _outputRootProof.messagePasserStorageRoot
            }) == false
        ) {
            revert OptimismPortal_InvalidMerkleProof();
        }
    }

- disable withdraw solution: https://github.com/QuarkChain/optimism/pull/49
```

> So, [archive node](https://docs.optimism.io/chain-operators/guides/management/best-practices#op-proposer-assumes-archive-mode) must be used for L2 withdraw.

### If Deposit transaction revert when _value > msg.value, will the fund be locked in L1 forever?
No.
- [code](https://github.com/ethereum-optimism/optimism/blob/d48b45954c381f75a13e61312da68d84e9b41418/packages/contracts-bedrock/src/L1/OptimismPortal.sol#L369C1-L380C6)
- [doc](https://specs.optimism.io/protocol/deposits.html#execution)

```solidity
    /// @param _to         Target address on L2.
    /// @param _value      ETH value to send to the recipient.
    /// @param _gasLimit   Amount of L2 gas to purchase by burning gas on L1.
    /// @param _isCreation Whether or not the transaction is a contract creation.
    /// @param _data       Data to trigger the recipient with.
    function depositTransaction(
        address _to,
        uint256 _value,
        uint64 _gasLimit,
        bool _isCreation,
        bytes memory _data
    )
```
- The balance of the from account MUST be increased by the amount of mint (msg.value). This is unconditional, and does not revert on deposit failure.
- address alias is used to prevent l1假冒L2地址的情况，即L1合约地址与L2某个地址一致但是实际上部署的代码完全不一样，这导致如果有其他L2合约需要依赖msg.sender判断就会导致被攻击
    - 通过控制create2的salt来枚举是有可能伪造出地址相同但代码不同的合约

### How to filter invalid msg sent to Batch Inbox Address
- Through batcher address

### Sequencer, Batcher, Proposer, Challenger
- Sequencer: receives L2 transactions from L2 users, creates L2 blocks using them, which it then submits to data availability provider (via a batcher). The sequencer’s address is not recorded on-chain; only the batcher’s address is. Users and node operators typically obtain the sequencer’s RPC endpoint from the chain operator.
    - run op-node with `--sequencer.enabled --rpc.port=8547`
- Batcher(BatchSubmitter): submits batches of transactions to L1 (可以控制99%的L2交易，还有1%可以通过L1 deposit tx来到L2)
    - run op-batcher with `--rollup.rpc=http://localhost:8547` to **pull** unsafe blocks and publish these to L1
- Proposer: 
    - [legency](https://github.com/ethereum-optimism/optimism/pull/13489/changes#diff-54cffe8f94a25ed0cfb98c27cc49d91713dfe2312cd62f2d5f567142687be81c): submit l2 output root
    - with fault proof: creates a dispute game for batch of blocks:
    `create(uint32 _gameType,bytes32 _rootClaim,bytes _extraData)`
- Challenger
    - run op-challenger with a funded private key and submitting attack tx when false outputroots are found.

### Can finalized L2 blocks be reorged?
No.
What is reorg? Local node accept two or more difference forked chains.
What is L2 finalized block? The L1 block that includes the L2 block is finalized.
- 如果首先sequencer在L2 finalized之前广播了错误的区块，其他nodes不会接受（即不会添加到本地的链上），所以不涉及reorg
- 如果sequencer广播了正确的L2区块儿，其所属的L1区块finalize之后又再次提交了L2区块号相同但内容不同的区块儿，也不会被其他节点接受（在derivation的时候就发现了）

### Sequencer采用EL Sync导致出现sequencer重启后RPC node无法sunc的坑
假设A是当前sequencer，B采用EL sync
- 此时A收到了交易并打包为unsafe block提交给B，此时B采用EL sync会把[finalized区块号设置为该unsafe block number N](https://github.com/ethereum-optimism/optimism/blob/c0d1ce8a27e5349c04d258dc3d4619b73cca7685/op-node/rollup/engine/engine_controller.go#L547-L556);
- A宕机(unsafe blocks还没被L1 finalize)，然后B上线切换为sequencer，此时B会从N+1开始提交span batch，但是其他节点此时finalized可能还是n (N>n)，导致B的交易被drop掉

[issue](https://github.com/QuarkChain/pm/issues/110), [alan's note](https://github.com/zhiqiangxu/private_notes/blob/main/misc/elsync_safe_head_drift.md)


### Deployment: genesis.json, rollup.json, systemconfig
- SystemConfig: The SystemConfig contract helps manage configuration of an OP Stack network. Much of the network’s configuration is stored on L1 and picked up by L2 as part of the derivation of the L2 chain. The contract also contains references to all other contract addresses for the chain.
- genesis.json: 用来初始化L2的chain_id，链初始化的EOA和合约等初始状态
- rollup.json: 用来确定L2共识依赖的DA层合约的source of truth，包括batcher地址、systemconfig、区块儿时间等


```json
# rollup.json
{
  "genesis": {
    "l1": {
      "hash": "0xf39446e09aeca67452545d06a6e6a6a11184575ecf421f9306cf3602febf93ba",
      "number": 1
    },
    "l2": {
      "hash": "0x2a92ff72dad302d39fa80ef81522f0ccb27dc903255b618dfc4feddb22a8f80d",
      "number": 0
    },
    "l2_time": 1728358574,
    "system_config": {
      "batcherAddr": "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc",
      "overhead": "0x0000000000000000000000000000000000000000000000000000000000000834",
      "scalar": "0x00000000000000000000000000000000000000000000000000000000000f4240",
      "gasLimit": 30000000
    }
  },
  "block_time": 2,
  "max_sequencer_drift": 300,
  "seq_window_size": 200,
  "channel_timeout": 120,
  "l1_chain_id": 900,
  "l2_chain_id": 901,
  "regolith_time": 0,
  "canyon_time": 0,
  "delta_time": 0,
  "ecotone_time": 0,
  "fjord_time": 0,
  "batch_inbox_address": "0xff00000000000000000000000000000000000901",
  "deposit_contract_address": "0x55bdfb0bfef1070c457124920546359426153833",
  "l1_system_config_address": "0x3649f526889a918af0a5498706db29e81bc91e0c",
  "protocol_versions_address": "0x0000000000000000000000000000000000000000"
}
```

- op's devnet deployment guide(流程正确，但是部署细节没有): https://docs.optimism.io/index#deployment
    - 部署的时候要先部署[L1 contracts](https://docs.optimism.io/op-stack/protocol/smart-contracts#l1-contract-details)作为source of truth才能启动L2,
- devnet depolyment guide: https://github.com/QuarkChain/pm/blob/6509512378503de6cb4570603bd97743eba22a21/L2/devnet_fault_proof.md
- quarkchain mainnet deployment guide: https://github.com/QuarkChain/pm/pull/101/changes#diff-829716c3dc993a798d256f3be34bbe3c900b545c7b9a9022c05dd444db9b2e94
    - awesome mainnet launch todo list: https://github.com/QuarkChain/pm/issues/31
    - bootnode setup: https://github.com/QuarkChain/pm/blob/main/L2/mainnet_bootnode.md
    - test hardfork: https://github.com/QuarkChain/pm/blob/main/L2/hardfork_devnet_test.md
    - basic tests after launching a new node: https://github.com/QuarkChain/pm/issues/35



## TX data types
- 跨进程一定是 RLP（RPC ↔ p2p ↔ Engine API ↔ batcher ↔ L1）—— 这是协议层规定，互操作性的底线
- 进程内内存里是 OpTxEnvelope —— 只要要"算"什么（执行、签名校验、gas 估算），就得反序列化成它
- MDBX 落盘是 Compact:Size trait类型 —— reth 的私有优化，只在 op-reth 进程的 DB 里出现，节省 ~20-40% 空间
    - impl Compact for TxDeposit 
```
impl Compact for TxDeposit {
    fn to_compact<B>(&self, buf: &mut B) -> usize
    where
        B: bytes::BufMut + AsMut<[u8]>,
    {
        CompactTxDeposit::from(self).to_compact(buf)
    }

    fn from_compact(buf: &[u8], len: usize) -> (Self, &[u8]) {
        let (compact, buf) = CompactTxDeposit::from_compact(buf, len);
        (compact.into(), buf)
    }
}
```


进程内TxEnvelop相关转换:
```
                    ┌─ TxLegacy   ──Signed─→  Signed<TxLegacy>   ─┐
                    ├─ TxEip2930  ──Signed─→  Signed<TxEip2930>  ─┤
原始字段 struct ────┼─ TxEip1559  ──Signed─→  Signed<TxEip1559>  ─┤
   (无 type byte,   ├─ TxEip7702  ──Signed─→  Signed<TxEip7702>  ─┼─→ OpTxEnvelope
    无 hash)        ├─ TxEip8130  ──Sealed─→  Sealed<TxEip8130>  ─┤   (enum, 带 type byte)
                    ├─ TxDeposit  ──Sealed─→  Sealed<TxDeposit>  ─┤
                    └─ TxPostExec ──Sealed─→  Sealed<TxPostExec> ─┘
                                  ↑
                       Signed = T + ECDSA Signature + hash
                       Sealed = T + hash         (验签信息内嵌在 T 里)
```
一句话：TxEip8130 是"光秃秃的字段"，OpTxEnvelope::Eip8130 是"打好 hash 又贴上 type 标签的成品"，可以丢进通用容器、走 2718 编解码、被 executor/RPC/pool 一视同仁地处理。转换就是给这笔交易"上车"——上 OP Stack 通用执行流水线的车。


## 一些特殊的地址区分

EVM 体系下的"特殊地址 / 特殊合约"容易混在一起，按两个**独立**维度可以彻底拆开：

1. **部署机制**：客户端 native（不进状态树）/ 普通 CREATE / 创世预埋 / 硬分叉 irregular state transition
2. **写入 ACL**：合约自己代码里的 `msg.sender` 检查 —— 是限定为某个 system address，还是开放给任何人

这两维**正交**，所以用第二维（写入 ACL）去切"非 CREATE 部署"那一类，能干净分出 System Contract 和 Predeploy。

### 四类对比

| 类别 | 典型地址 | 部署机制 | 有 bytecode? | 谁能 read（CALL） | 谁能 write（合约 ACL） | 典型用途 |
|---|---|---|---|---|---|---|
| **Precompile** | `0x01` ecrecover / `0x02` sha256 / `0x06` bn256add / `0x0a` kzg / `0x100` p256verify (OP) | 客户端 native code 实现，**不进状态树** | ❌ 无 EVM bytecode | 任何人 CALL | 无状态可写（无意义） | 密码学 / 数学原语 |
| **System Address** | `0xfffffffffffffffffffffffffffffffffffffffe` (ETH) / `0xdeaddeaddeaddeaddeaddeaddeaddeaddead0001` (OP depositor) | **不是合约**，无私钥的 sender 标识 | N/A | N/A | N/A（自己当 `from` 调别人） | 给协议自动发起的内部调用提供"假身份" |
| **System Contract** | `0x000...0002` BEACON_ROOTS (EIP-4788) / `0x4200...0015` OP L1Block / `0x000...0935` History Storage (EIP-2935) | 创世预埋 或 硬分叉 irregular state transition | ✅ Solidity 字节码 | 任何人（read 路径开放） | **仅 system address**（合约内 `if msg.sender == SYSTEM_ADDR { ...write... }`） | 协议级元数据 —— beacon root / L1 区块信息 / history hashes |
| **Predeploy / Preinstalled** | `0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2` CREATE2_DEPLOYER (OP, Canyon 硬分叉注入) | 硬分叉 irregular state transition | ✅ Solidity 字节码 | 任何人 | **任何人**（合约自身无 sender ACL） | 公共工具合约 —— CREATE2 工厂 / MultiCall 等 |

### 两维独立、不要混淆

部署机制和写入 ACL 完全正交，交叉分类：

|  | 写入开放 | 写入 protocol-only |
|---|---|---|
| 客户端 native | Precompile（无状态，ACL 无意义） | — |
| 创世 / 硬分叉强插 | **Predeploy / Preinstalled** | **System Contract** |
| 普通 CREATE | 普通用户合约 | 用户合约里自己加 ACL（罕见） |

System Contract 和 Predeploy 在"部署机制"维度上**完全一样**（都是非 CREATE 路径"凭空出现"），区别**只在合约自己代码里加不加 sender ACL 检查**。所以"是不是 predeploy" 跟 "谁能写" 没有蕴含关系，不能互相推。

`0x4200...XXXX` 这一整段地址在 OP 里是 predeploy 命名空间，但其中**两类都有**：`L1Block`（写路径 protocol-only）属 System Contract，`MultiCall3` 这种属 Predeploy / Preinstalled。光看地址前缀分不出来，得看合约里的 ACL。

### ETH 主网 vs OP Stack

| 类别 | ETH 主网 | OP Stack |
|---|---|---|
| Precompile | ✅ 一堆 | ✅ 多了 P256VERIFY / BLS 等 |
| System Address | ✅ `0xfff...fffe` | ✅ `0xdead...0001` (depositor) |
| System Contract | ✅ BEACON_ROOTS / History Storage / Withdrawal Queue 等 | ✅ L1Block / Withdrawal / GasPriceOracle 等 |
| **Predeploy（开放写入的公共工具）** | ❌ **基本没有** | ✅ CREATE2_DEPLOYER / MultiCall3 等 |

ETH 主网上类似 CREATE2 工厂的公共合约是社区个人用普通 tx 部署的（典型如 `0x4e59b44847b379578588920ca78fbf26c0b4956c`，是 Arachnid 自己 deploy 的），**不走 predeploy 路径**。OP 真正比 ETH 多出来的，就是 **Predeploy / Preinstalled** 这一类 —— L2 用硬分叉 irregular state transition 把高频公共工具直接预埋到状态里，让用户开箱即用。

### 速记口诀

- **Precompile** = 协议给的"魔法函数"（无字节码、无状态）
- **System Address** = 协议自己的"假身份"（不是合约，是 sender）
- **System Contract** = 协议自己的"私有黑板"（任何人能看，只有协议能写）
- **Predeploy** = 协议帮大家预埋的"公共工具"（部署特殊，调用普通）
