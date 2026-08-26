---
title: Python高级核心
aliases: [python进阶, python对象模型]
tags: [cs/cpp, cs, cs/toolchain]
created: 2026-08-26
updated: 2026-08-26
status: review
source: CPython 实现口径（《Fluent Python》/官方语言参考共识）；版本敏感处以 CPython 3.10+ 为准，标待确认处须实测
fetched_at: 2026-08-26
---

# Python 高级核心：对象模型到 asyncio

> [!abstract] 定位
> 从"会写"到"懂运行时"：一切皆对象的类型系统、协议驱动的魔法函数、引用计数+分代 GC、描述符与元类、生成器帧机制、GIL 与三套并发模型的选型矩阵。按机制级深度标准走读，版本口径 CPython 3.10+。本库 Python 落地锚点：LogNet PoC（[[lognet-rootcause-multiagent-architecture]]）。

See also: [[CS-KB-Home]] · [[CPP-核心知识]] · [[LibC运行时排查-TLS与锁]] · [[LLM推理部署与量化]]

## 一、对象模型：type/object/class 三角

```
type 是所有类的类型; object 是所有类的基类 —— 二者互为对方实例:
  type(object) == type      # type 的类型是它自己
  object.__class__ is type  # object 是 type 的实例
  isinstance(int, type)==True; isinstance(int, object)==True
```

- 变量是**名字贴到对象上的标签**（PyObject* 指针语义），赋值永不拷贝数据——`a = b` 后两者同一对象（`is` 判身份，`==` 删 `__eq__` 值）
- 可变默认参数事故的根因即此：`def f(x=[])` 的 list 在函数定义时创建一次，跨调用共享——修法 `x=None + 函数体内新建`
- 小整数缓存 [-5,256]/字符串驻留是解释器优化不是语言承诺——**身份判断永远用 is 只用于 None/哨兵**

## 二、魔法函数=协议（鸭子类型的正式化）

| 协议 | 魔法函数 | 解锁能力 |
|------|---------|---------|
| 序列 | `__len__/__getitem__/__setitem__` | for 迭代/切片/`in`；切片对象是 `slice(start,stop,step)`——自定义可切片类要处理 slice 分支 |
| 迭代 | `__iter__/__next__` | for 循环本质=iter()+循环 next() 直到 StopIteration |
| 上下文 | `__enter__/__exit__` | with 资源管理；`contextlib.contextmanager` 用生成器免写类 |
| 数值 | `__add__` 与反射版 `__radd__` | 左侧不支持时调右侧反射版 |
| hash/eq | `__hash__/__eq__` 成对实现 | 定义 eq 后默认 hash=None → 对象不可入 set/dict key |

**bisect 维护已排序序列**：插入 O(log n) 查位+O(n) 挪动——比"append 后 sort"(O(n log n)) 快且保持有序不变量；何时不用 list：频繁头部插删用 deque、 membership 大量 `in` 用 set(O(1))。

## 三、dict/set 实现：开放寻址哈希

- CPython dict 用**开放寻址**（探测序列 perturb 扰动，非链地址法）——所以键必须可哈希（tuple 可以，list 不行）
- 紧凑 dict（3.6+）：entries 数组按插入序存 [hash,key,value]，indices 稀疏表指槽位——既保插入序又省内存
- **为什么 set 查找 O(1)**：hash(key) 定桶 → 探测比较；哈希碰撞退化 O(n) 但均匀哈希下期望 O(1)
- 推论：dict 键的 `__hash__` 必须在生命周期内不变——自定义可变对象做键=自埋雷

## 四、GC：引用计数为主，分代为辅

```
主回收器 = 引用计数: ob_refcnt 归零立即析构 —— 确定性强、代价平摊在每条语句
辅回收器 = 分代 gc 模块: 只解决【循环引用】(refcnt 到不了 0)
  三代(0新→2老), 0 代扫描最频; 触发阈值 (700,10,10) 分配计数差
弱引用 weakref: 不增 refcnt 的观测指针 —— 缓存/观察者模式防泄漏的标准解
```

**经典泄漏排查**：对象不释放 → 先查循环引用（A 引 B、B 引 A，常伴回调/父指针），`gc.get_referrers()` 定位引用链；再查全局容器累积（注册表只加不减）。对照 [[设计模式实战]] 观察者 RAII 句柄方案的 Python 版：订阅返回 `weakref.finalize` 句柄。

## 五、属性查找与描述符（ORM 的原理地基）

```
obj.attr 查找序(数据描述符优先):
  type(obj).__mro__ 上的【数据描述符】(__get__+__set__)   ← 最高
  → obj.__dict__
  → 类上的非数据描述符(__get__ only, 如 function/property 无 setter)
  → __getattr__ 兜底
```

- **property 就是数据描述符**；@staticmethod/@classmethod/classmethod 都是描述符糖
- **元类 ORM 原理**：`Model` 的元类 `__new__` 扫描类属性把 `Field()` 描述符收进 `fields` 字典 → 实例化后 `user.name=value` 触发 Field 描述符校验 → `save()` 遍历 fields 拼 SQL。Django/Tortoise ORM 同构
- `__new__(cls)` 造实例（单例在此拦）、`__init__` 只初始化——`__init__` 忘 return 不是错，`__new__` 忘调 super 才造不出对象

## 六、生成器：挂起的栈帧

```python
def read_large(path):
    with open(path) as f:
        for line in f:            # 文件迭代器本身惰性 → 全程 O(1) 内存
            yield line.strip()
```

- 生成器函数调用**不执行**，返回 generator；每次 next() 跑到 yield **冻结帧**（局部变量/IP/求值栈都存在 frame 对象里），下次从冻结点恢复——这就是"用户态可暂停函数"
- 该机制向上长出：协程(`async def`=生成器的语法进化)、惰性管道(`map/filter` 组合)、流式大文件处理（LogNet PoC 解析器对 GB 包体必须走此路，逐行产出而非整包入内存）
- `yield from`/`await` = 双向通道+委托子生成器

## 七、并发选型矩阵（GIL 之下）

| 手段 | 适用 | 本质 |
|------|------|------|
| threading | IO 密集（等待时释放 GIL） | 同一进程多线程，GIL 保证字节码级互斥但**不保护复合操作**——仍需锁保护 check-then-act |
| multiprocessing | CPU 密集 | 多进程绕开 GIL；IPC 成本(pickle)是税 |
| asyncio | 高并发 IO（万级连接） | 单线程事件循环+协程切换(~µs)；**一处阻塞全循环卡死**——IO 库必须异步版(aiofiles/httpx) |
| concurrent.futures | 统一池抽象 | ThreadPoolExecutor/ProcessPoolExecutor 换一行切型号 |

- **GIL 边界事实**：C 扩展在进入纯 C 计算时可主动放 GIL（NumPy 大矩阵乘实际并行）；3.13 free-threaded 实验构建去 GIL 中（生产采用度**待确认**）
- asyncio 心智图：协程是"可暂停任务"，事件循环是"调度器"，Task 是"已排期"；`gather` 并发扇出——与本库 agent fan-out 模式同构（[[fan-out-subagent-pattern]]）

## 八、待确认项

> ① free-threading(PEP 703) 构建下第三方 C 扩展兼容面；② 解释器自适应特化指令(3.11+)对各 workload 的实测增益分布；③ subinterpreters 跨进程通信 API 稳定化进度。

## Related

[[CS-KB-Home]] · [[CPP-核心知识]] · [[数据库原理与调优]] · [[lognet-rootcause-multiagent-architecture]] · [[LLM推理部署与量化]] · [[高并发系统设计]]
