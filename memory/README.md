## Benchmarks
- 非并发读写的话，read+write的总带宽是30 GB/s左右
```
 cargo run --release -- 1 5

iteration 1: 0.120 s, copy throughput 8.96 GB/s, read+write traffic 17.92 GB/s
iteration 2: 0.064 s, copy throughput 16.87 GB/s, read+write traffic 33.74 GB/s
iteration 3: 0.061 s, copy throughput 17.60 GB/s, read+write traffic 35.19 GB/s
iteration 4: 0.063 s, copy throughput 17.05 GB/s, read+write traffic 34.10 GB/s
iteration 5: 0.067 s, copy throughput 15.94 GB/s, read+write traffic 31.88 GB/s
```

## Readings
- [What Every Programmer Should Know About Memory](https://people.freebsd.org/~lstewart/articles/cpumemory.pdf)