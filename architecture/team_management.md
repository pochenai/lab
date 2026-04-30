# 团队如何合理分工
核心: 按照capability划分，而不是模块儿, 不要求先想清所有设计而是在做的工程中不断完善底层的capability和接口。

## Capability如何建模并细化
**Capability = Entry Function + Test Fixture + Assertion**
- 其实细化后也能知道如何正交划分capability和模块儿了。

### Execution (8130)
Capability = 执行交易

- Entry: execute()
- Fixture: tx + mock db + executor
- Assertion: receipt 正确

→ tx → execute → receipt


### Mempool (8130)
Capability = 接收交易

- Entry: add_transaction()
- Fixture: tx
- Assertion: accepted / rejected

→ tx → add_transaction → result

## 纵向切分capability基本流程
1. v0 capability matrix（不完整也没关系）
2. v0 interface / contract（关键，需要考虑failure路径）
3. 切 vertical slices（按能力链，不按模块）
4. 并行开发（允许 stub / fake）
5. 集成时发现缺口 → 回补 capability
6. 收敛接口（v1 → v2）

```
               ┌──────────────┐
               │ capability v0│
               └──────┬───────┘
                      ↓
               ┌──────────────┐
               │ contract v0  │ ←（你要重点盯）
               └──────┬───────┘
                      ↓
        ┌─────────────┼─────────────┐
        ↓             ↓             ↓
   slice A        slice B       slice C
        ↓             ↓             ↓
        └──────→ 集成 / 冲突 ←──────┘
                      ↓
               ┌──────────────┐
               │ contract v1  │（收敛）
               └──────────────┘

```

### 核心要求
1. contract 要硬（可执行）
2. slice 要真 vertical（跨模块）
3. 必须有人做收敛（你）


