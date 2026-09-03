## Overview
                 ① WHY
                  │
             What problem?
                  │
                  ↓
             ② BOUNDARY
                  │
          Who owns what?
                  │
                  ↓
             ③ DATA FLOW
                  │
       Producer → Consumer
                  │
                  ↓
             ④ CONCURRENCY
                  │
          What can run together?
                  │
                  ↓
             ⑤ RESOURCES
                  │
      CPU / Memory / IO / Buffer
                  │
                  ↓
             ⑥ BACKPRESSURE
                  │
        What if demand > capacity?
                  │
                  ↓
             ⑦ SCHEDULING
                  │
           Who gets resource?
                  │
                  ↓
             ⑧ FAILURE
                  │
          What if something dies?
                  │
                  ↓
             ⑨ LIFECYCLE
                  │
          Start → Run → Stop
                  │
                  ↓
             ⑩ OBSERVABILITY
                  │
         How do I know it's broken?
                  │
                  ↓
             ⑪ OPTIMIZATION
                  │
       Make it faster / cheaper
                  │
                  ↓
             ⑫ VALIDATION
                  │
      Does the whole system improve?


## 成长路径
局部性能优化
      ↓
并发设计
      ↓
Resource Management
      ↓
Scheduling / Backpressure
      ↓
Failure / Lifecycle
      ↓
Observability
      ↓
System-level Optimization