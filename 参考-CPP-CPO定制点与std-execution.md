---
title: 参考-C++CPO定制点与std-execution
aliases: [CPO学习, tag_invoke, std::execution, P2300, 定制点对象]
tags: [reference, reference/cpp]
created: 2026-08-26
updated: 2026-08-26
status: review
source: 基于 P2300/P1895 提案文本、cppreference、stdexec(NVIDIA) 公开资料整理；标准演进快，时效性条目以「待确认」标注
fetched_at: 2026-08-26
---

# 参考-C++ CPO 定制点与 tag_invoke 在 std::execution 下的使用

> [!abstract] 谱系一图
> **函数模板开放 ADL 劫持** →（修复）**CPO 定制点对象**：封装"成员优先/ADL 兜底 + 毒丸拦截"的可定制函数对象 → **`tag_invoke` 惯用法**：把所有定制收敛到一个 `tag_invoke(tag_t<CPO>, args...)` 入口（range-v3 发明，P1895 提案化）→ **`std::execution`（P2300 → C++26）**：sender/receiver/operation-state 三件套几乎全部以 CPO + tag_invoke 作为扩展缝。本文给出机制原理、在 stdexec 下的使用与自定义 sender 实操。

See also: [[lognet-rootcause-multiagent-architecture]] · [[log-analysis-agent-windows-architecture]] · [[opencode-pi-base-development-analysis]] · [[参考-COM组件框架-Windows集成]]

## 一、为什么需要 CPO

| 问题 | 裸 `swap(a,b)` 式 ADL 定制 | CPO 方案 |
|------|---------------------------|----------|
| 用户向 `std` 命名空间塞重载 = UB | 存在 | 不需要在 `std` 加代码 |
| 无限定调用可被最外层命名空间劫持 | 是 | CPO 内部先查成员/毒丸，再受限 ADL |
| 泛型库无法统一"有成员就用成员" | 手写 if constexpr 散落各处 | 定制逻辑集中一处 |

**CPO 三要素**（以 `std::ranges::begin` 为代表）：① 函数对象（全局 const 实例）② 定制查找顺序：成员 → ADL 自由函数（受概念约束）→ 缺省实现；③ **毒丸**（poison pill）：一个模板化的 deleted `begin(auto&&)` 在最内层命名空间兜底，阻断外层无限定重载继续参与重载决议。

> [!note] 两代技术路线
> - **ranges 家族**（C++20）：毒丸 + 约束式 ADL，**不用** tag_invoke
> - **execution / P2300 家族**（C++26 目标）：大规模采用 **`tag_invoke`** 统一定制入口
> - `tag_invoke` 本身源自 range-v3 实践、P1895 提案化；是否最终以 `std::tag_invoke` 名义进 IS 及所在版本归属 cppreference 页面口径**待确认**（随 execution 一起落地是当前主流表述）

## 二、tag_invoke 惯用法速览

```cpp
// 库侧：定义 CPO
inline constexpr struct my_size_fn {
    template <class T>
        requires requires(T& t) { t.my_size(); }          // 1) 成员优先
    constexpr auto operator()(T& t) const { return t.my_size(); }

    template <class T>
        requires (sizeof(my_size_fn) == 0)                // 毒丸变体之一
    friend constexpr auto my_size(T&) = delete;           // 阻断外部裸 ADL

    template <class T>
        requires requires(T& t) { tag_invoke(*this, t); } // 2) tag_invoke 兜底
    constexpr auto operator()(T& t) const { return tag_invoke(*this, t); }
} my_size{};

// 用户侧：非侵入定制 —— 一个友元即可
struct Blob { int n; 
  friend constexpr int tag_invoke(my_size_fn, Blob b) { return b.n; }
};
int s = my_size(Blob{42});   // 42
```

要点：`tag_t<CPO>` 取实例类型；定制点签名第一个参数永远是 tag；**禁止**用户直接调 `tag_invoke` 裸名（那是实现细节），永远经 CPO 调用。

## 三、std::execution 核心三件套（P2300）

```
sender  ──connect(rcvr)──▶ operation_state ──start()──▶ 异步执行
                                   │
                          receiver: set_value / set_error / set_stopped
```

| 概念 | 一句话 | 关键 CPO |
|------|--------|---------|
| sender | "一件将来的工作"的惰性描述（零开销组合子） | `connect(sndr, rcvr)`（定制缝=tag_invoke） |
| receiver | 结果的消费者（三种完成信号回调） | `get_env(rcvr)` 查询环境 |
| scheduler | "在哪跑"的句柄 | `schedule(sched)` 返回 sender（本身也是 tag_invoke 定制点） |
| operation_state | connect 产物，`start()` 触发执行，须保活至完成 | — |

高频工厂/适配器（全部是 CPO）：`just / just_error / just_stopped / then / upon_error / upon_stopped / let_value / let_error / on / bulk / when_all / split / ensure_started / stop_when`；消费端 `this_thread::sync_wait / sync_wait_with_dynamic`。

## 四、在 stdexec（NVIDIA 参考实现）下的实操

```cpp
#include <exec/static_thread_pool.hpp>
#include <stdexec/execution.hpp>
namespace ex = stdexec;

exec::static_thread_pool pool{4};                       // 4 工作线程
ex::scheduler sched = pool.get_scheduler();

auto work =
    ex::schedule(sched)                                 // sender: 在池上开始
  | ex::then([]{ return load_package_index(); })        // 纯变换
  | ex::let_value([](Index& idx){
        return ex::when_all(                            // 并行 fan-out
            ex::then(ex::just(&idx), parse_hilog),
            ex::then(ex::just(&idx), parse_kmsg));
    })
  | ex::upon_error([](std::exception_ptr e){ log(e); return 0; });

auto [result] = ex::sync_wait(std::move(work)).value(); // 阻塞收口（demo 用）
```

### 自定义 sender 的两条定制路

```cpp
struct retry_sender {
    using completion_signatures =
        ex::completion_signatures<ex::set_value_t(int),
                                  ex::set_error_t(std::exception_ptr)>;

    sender_of auto inner; int retries;

    // 路 A：成员 connect（P2300 认可）
    template <receiver_of Rcvr>
    friend auto tag_invoke(ex::connect_t, retry_sender&& s, Rcvr r);
    // 路 B：完全等价的外部形式
    // friend auto tag_invoke(ex::connect_t, retry_sender&&, Rcvr);
};
// 组合进管道后 ex::connect 会经 CPO 找到上面的 tag_invoke
```

> [!tip] 与本库 PoC 的映射
> LogNet PoC 的 P1 解析/P2 符号化/P3 建图流水线（[[lognet-rootcause-multiagent-architecture]] §8.1）天然是 `when_all + then` 结构：Sidecar 若选 C++ 实现，stdexec 提供结构化并发（取消传播 `stop_token` 贯穿 sender 链）替代手搓线程池——对应看门狗 T2 interrupt 的语言级支持。

## 五、取消与环境查询（生产化必读）

- **结构化取消**：`get_stop_token(get_env(rcvr))` 沿 sender 链自动传播；`stop_when(stop_src.token(), progress_sndr)` 可做超时/抢占——比裸线程 `interrupt()` 语义干净
- **forward progress 保证**：`get_forward_progress_guarantee` 查询调度器承诺（concurrent/parallel/weakly-sequential），影响 fan-out 设计下限
- **属性查询也是 CPO**：`get_scheduler/get_delegation_scheduler/...` 全部走 query 对象 + tag_invoke

## 六、采用现状与风险（2026-08 快照）

| 项 | 状态 |
|----|------|
| P2300 → IS 进度 | 目标 C++26；stdexec 库已可用于生产级实验（GCC 12+/Clang 15+/MSVC 19.35+ 区间为社区实测带，精确下限**待确认**） |
| 语言级竞争方案 | LEWG 有意让新 API 回归语言级定制点而非 tag_invoke（方向讨论进行中，具体提案号**待确认**）→ 新代码建议把业务逻辑包在自由函数里、tag_invoke 只留薄壳，降低未来迁移面 |
| 生态 | NVIDIA stdexec 最活跃；libunifex（Meta）为先驱但 API 早于 P2300 定稿 |

## 七、学习路径建议

1. 读 P2300 §3 motivation（半天）→ 2. 跑通 stdexec quick-start 十个例子（半天）→ 3. 手写一个 `retry_sender`（1 天，本文 §四骨架起步）→ 4. 给 LogNet PoC 写 stdexec 版 P1 流水线对照压测 → 5. 追踪 execution 进 IS 的措辞变化再定产线版本

## 待确认项汇总

> ① `std::tag_invoke` 是否随 execution 进入 IS 及版本号；② 各编译器对 P2300 的精确支持矩阵；③ LEWG 语言级定制点方向的提案编号；④ reg-free 场景外（见 COM 文档）无关项不列。

## 反向链接

- [[lognet-rootcause-multiagent-architecture]] — Sidecar 流水线的结构化并发候选
- [[log-analysis-agent-windows-architecture]] · [[opencode-pi-base-development-analysis]] — 服务端语言选型上下文
- [[参考-COM组件框架-Windows集成]] — 同期入库 Windows 侧框架知识
