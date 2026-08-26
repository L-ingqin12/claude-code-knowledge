---
title: C++核心知识
aliases: [现代C++, CPP基础, cpp-core]
tags: [cs/cpp, cs]
created: 2026-08-26
updated: 2026-08-26
status: review
source: 教科书级标准事实整理（ISO C++11/17/20/23 口径）；机制类论断以 cppreference/cpdishes 社区共识为准，存疑处标待确认
fetched_at: 2026-08-26
---

# C++ 核心知识

> [!abstract] 定位
> 现代 C++（11→23）主干知识地图：资源管理、移动语义、模板与泛型、并发内存模型、工程实践坑位。深度专题见姊妹篇 [[参考-CPP-CPO定制点与std-execution]]；Windows COM 场景见 [[参考-COM组件框架-Windows集成]]。

See also: [[CS-KB-Home]] · [[参考-CPP-CPO定制点与std-execution]] · [[数据结构与算法]] · [[高并发系统设计]]

## 一、资源管理（RAII 是一切的地基）

| 设施 | 要点 | 口诀 |
|------|------|------|
| 构造/析构 | 资源获取即初始化；析构默认不抛（`noexcept` 违约即 terminate） | 谁拥有谁释放 |
| `unique_ptr` | 独占所有权，零开销；`make_unique` 异常安全 | 默认选择 |
| `shared_ptr` | 引用计数原子操作（有开销）；**循环引用**靠 `weak_ptr` 破 | 共享才用 |
| `weak_ptr` | 不持计数，`lock()` 临时提升 | 观察者/缓存 |
| 自定义删除器 | FILE/socket/句柄包成 RAII 类或 unique_ptr + deleter | 句柄必包 |

> [!danger] 高频坑
> ① `shared_ptr` 的计数线程安全 ≠ 对象本身线程安全；② `get()` 裸指针逃逸后 delete 双释放；③ 构造函数中调用虚函数不具多态性（派生层未构造）。

## 二、值语义与移动语义

- 左值/右值/将亡值：`T&&` 绑定右值；移动构造"偷资源后置空源"
- `std::move` 只是转 rvalue 强制转换（不移动任何东西）；被移动对象=有效但未定状态
- 完美转发：万能引用 `template<class T> f(T&&)` + `std::forward<T>` 保值类别传递
- RVO/NRVO 与 C++17 强制拷贝消除：返回临时值不再调用移动构造
- 五法则/零法则：写了自定义析构/拷贝/移动之一 → 考虑全五个；能用成员 RAII 就一个都不写（零法则）

## 三、模板与泛型

| 主题 | 关键点 |
|------|--------|
| 类型萃取 | `<type_traits>`：`decay/remove_reference/conditional` 编译期计算 |
| SFINAE→concepts | C++20 `requires` 子句取代 enable_if 黑魔法，报错可读 |
| 变参模板 | 参数包展开；折叠表达式 `(args + ...)` |
| CTAD | `std::lock_guard lg(m);` 类模板实参推导 |
| 两阶段查找 | 依赖名须 `this->`/限定，否则二期查找不到（经典编译错） |

## 四、并发与内存模型（对接 [[高并发系统设计]]）

- `std::thread/jthread`（jthread 自动 join+stop_token 协作取消）
- **内存序**六档：relaxed / acquire-release 配对 / seq_cst 默认；acquire 读、release 写构成同步于 happens-before
- 锁族：`mutex/recursive/shared(shared_mutex 读写锁)/scoped_lock 多锁防死锁`
- 条件变量三件套：`unique_lock<mutex>` + `cv.wait(lk, pred)` **谓词版必带**（防虚假唤醒）
- async/future/promise；`launch::deferred vs async` 执行策略差异；future 析构不 join 的 async 特例（**经典陷阱**）

## 五、工程实践速查

| 主题 | 结论 |
|------|------|
| 初始化 | 用 `{}` 防 narrowing；类内成员默认初始化防 UB |
| 字符串 | `string_view` 免拷贝传参（注意悬垂：不存临时）；SSO 小串栈上分配 |
| 容器选型 | 连续优先（vector/string）cache 友好；`reserve` 预扩容；map vs unordered_map 按有序需求与哈希攻击面取舍 |
| ABI/编译 | `-O2` 起步；sanitizers：ASan(内存)/TSan(数据竞争)/UBSan 全套进 CI |
| 标准 | 项目锁定单一标准版本；C++23 主要件：`expected/print/mdspan` |

## 六、待确认项

> ① 各编译器对 C++20 modules 的生产可用度差异；② coroutine TS→C++20 无栈协程在主流库（asio/cppcoro）的封装成熟度；③ 硬件内存模型（TSO/ARM 弱序）与 C++ 序映射的逐平台对照表。

## Related

[[CS-KB-Home]] · [[参考-CPP-CPO定制点与std-execution]] · [[参考-COM组件框架-Windows集成]] · [[操作系统八股]] · [[高并发系统设计]] · [[lognet-rootcause-multiagent-architecture]]
