## MPP tutorial
```
tempo wallet login
tempo request https://openai.mpp.tempo.xyz/v1/chat/completions \
  -X POST \
  --json '{
    "model":"gpt-4o",
    "messages":[{"role":"user","content":"hello"}]
}'
tempo wallet sessions list
```


## References
- [Tempo wallet 相关](https://github.com/tempoxyz/wallet)
- [Sessio相关](https://mpp.dev/payment-methods/tempo/session)
    - [ref impl](https://github.com/tempoxyz/tempo/blob/main/tips/ref-impls/src/TempoStreamChannel.sol)
- [Solana MPP](https://github.com/tempoxyz/mpp-specs/pull/201)