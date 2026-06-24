# Erlang/OTP 背景说明

这篇文档面向不熟悉 Erlang 的读者，解释 Soma 文档里频繁出现的 Erlang、BEAM、process、mailbox、OTP、supervisor、`gen_server`、`gen_statem`、application、release 等概念。

一句话先说清楚：

```text
Erlang 提供轻量进程、mailbox 和 message passing。
OTP 提供构建可靠并发系统的框架、behaviours 和监督模式。
Soma 用 Erlang/OTP 来实现 agent entity 和它发起的 run/tool/LLM 调用。
```

## Erlang 是什么

Erlang 是一门为高并发、高可用系统设计的语言。它最早服务于电信系统，核心能力是让大量独立任务长期运行、互相通信，并在局部失败时不拖垮整个系统。

Soma 关心 Erlang 的几个特性：

- 轻量进程；
- 每个进程有自己的 mailbox；
- 进程之间通过 message passing 通信；
- 进程状态默认不共享；
- 进程可以被监控、链接和监督；
- 一个进程崩溃可以被当成系统正常语义处理。

这些特性很适合 agent runtime，因为 agent 系统天然会遇到：

- LLM call 卡住；
- tool call 超时；
- 外部进程崩溃；
- 用户取消任务；
- 一个任务失败但 actor/session 要继续活着；
- 每次动作都要可审计。

## BEAM 是什么

BEAM 是 Erlang 的虚拟机。Erlang 代码运行在 BEAM 上。

可以把它理解为：

```text
Erlang 源码
  -> 编译
  -> BEAM bytecode
  -> BEAM VM 运行
```

BEAM 提供：

- 大量轻量进程；
- 抢占式调度；
- process mailbox；
- message passing；
- fault isolation；
- timers；
- ports；
- hot code loading 等底层能力。

Soma 里说 “in-BEAM tool” 时，意思是这个工具作为 Erlang 模块直接在 BEAM 里运行，比如 `echo`、`sleep`、`file_read`、`file_write`。

## Erlang process 是什么

Erlang process 不是 OS process。它是 BEAM VM 内部的轻量进程。

区别：

```text
OS process
  - 操作系统级进程
  - 创建成本较高
  - 独立地址空间

Erlang process
  - BEAM VM 内部轻量进程
  - 创建成本低
  - 有自己的 mailbox 和 state
  - 通过 message 与其他 Erlang process 通信
```

在 Soma 里：

```text
soma_actor      可以是一个长期存在的 Erlang process
soma_run        是一次 run 对应的 Erlang process
soma_tool_call  是一次工具调用对应的短生命周期 Erlang process
```

## Actor Model 是什么

Actor model 的核心是：

```text
actor 拥有自己的状态；
actor 有自己的 mailbox；
actor 通过 message 通信；
actor 不直接共享内部状态。
```

Erlang 的 process 很自然地实现了 actor model：

```text
Erlang process = actor
mailbox        = actor inbox
Pid ! Message  = send message
receive        = process message handling
```

Soma 的设计里有两层 actor 语义：

```text
Erlang actor model
  -> 实现基底：process、mailbox、message、monitor、supervisor

soma_actor
  -> 领域抽象：长期存在、具备 LLM call 能力的 agent entity
```

所以 `soma_actor` 不是简单“把一次 LLM call 包成进程”。它是一个有身份、状态、memory/context、model config、tool policy 和 active tasks 的长期 agent entity。

## Mailbox 和 Message Passing

每个 Erlang process 都有 mailbox。其他 process 可以向它发送 message。

示意：

```erlang
ActorPid ! {actor_message, Envelope}
```

这不是函数调用。发送者把 message 放进目标 process 的 mailbox；目标 process 什么时候处理，由它自己的 event loop/state machine 决定。

这对 Soma 很重要：

- `soma_actor` 通过 message 被触发；
- `soma_actor` 之间通过 message 通信；
- `soma_llm_call` 的结果通过 message 回到 `soma_actor`；
- `soma_run` 的结果通过 message 回到 session/actor；
- `soma_tool_call` 的结果通过 message 回到 `soma_run`。

这个边界保证了：子操作不能直接修改父进程状态，只能发送结果；父进程收到 message 后自己决定状态转移。

## OTP 是什么

OTP 是 **Open Telecom Platform** 的缩写，不是 “one time process”。

今天的 OTP 通常指 Erlang 生态里构建可靠并发系统的一套标准库、框架和设计模式。

可以这样理解：

```text
Erlang = 语言 + VM + 轻量进程 + mailbox + message passing
OTP    = supervisor + gen_server + gen_statem + application + release 等工程化框架
```

OTP 的作用是把 Erlang 的并发能力组织成可维护、可重启、可发布的生产系统。

## Behaviour 是什么

Behaviour 是 Erlang/OTP 里的一种“回调协议”。

一个 behaviour 定义：

```text
你要实现哪些 callback；
OTP runtime 会在什么时候调用这些 callback；
这个模块如何被标准框架运行。
```

常见 OTP behaviour：

- `gen_server`
- `gen_statem`
- `supervisor`
- `application`

Soma 也定义了自己的工具 behaviour：

```erlang
-callback describe() -> soma_tool:spec().
-callback invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
```

这让所有工具都有统一形状。

## `gen_server` 是什么

`gen_server` 是 OTP 提供的通用 server process 模式。

它适合长期存在、维护内部状态、处理请求的进程。

典型能力：

- 初始化 state；
- 同步请求；
- 异步消息；
- 普通 process message；
- terminate / code change 等生命周期 callback。

Soma 里适合用 `gen_server` 的对象：

```text
soma_agent_session  长生命周期 session process
soma_event_store    内存事件存储
soma_tool_registry  工具注册表
```

未来简单版 `soma_actor` 也可以先用 `gen_server` 起步，但如果 actor 状态转换变复杂，更适合 `gen_statem`。

## `gen_statem` 是什么

`gen_statem` 是 OTP 提供的状态机 process 模式。

它适合有明确状态转换的进程。

例如 `soma_run`：

```text
executing
  -> waiting_tool
  -> completed | failed | timeout | cancelled
```

未来 `soma_actor` 也很适合用 `gen_statem`：

```text
idle
  -> thinking
  -> waiting_llm
  -> running
  -> replying
  -> idle
```

`gen_statem` 的优势是：状态名就是设计的一部分，timeout/cancel/result 都可以明确落在状态转换上。

## Supervisor 是什么

Supervisor 是 OTP 的监督进程。

它不负责业务逻辑，而是负责启动、监控和重启子进程。

典型监督树：

```text
top_sup
  ├── event_store
  ├── registry
  ├── actor_sup
  └── run_sup
```

Supervisor 让系统把失败当成正常事件处理：

```text
child process crashed
  -> supervisor observes exit
  -> restart or leave stopped according to policy
```

在 Soma 里：

- `soma_sup` 是顶层 supervisor；
- `soma_session_sup` 管 session；
- `soma_run_sup` 管 run；
- 未来可以有 `soma_actor_sup` 管 actor；
- 未来可以有 `soma_llm_call_sup` 管一次性 LLM call worker。

## Link 和 Monitor

Link 和 monitor 都是 Erlang 里观察进程生命周期的机制。

简化理解：

```text
link
  - 进程之间建立失败传播关系
  - 一个 linked process 崩溃，另一个通常会收到 exit signal

monitor
  - 单向观察
  - 被监控进程退出时，监控者收到 'DOWN' message
  - 不自动把监控者拖垮
```

Soma 大量需要 monitor：

```text
soma_run monitors soma_tool_call
soma_actor monitors soma_run / soma_llm_call
```

这样子操作崩溃时，父进程收到的是数据：

```erlang
{'DOWN', MRef, process, Pid, Reason}
```

父进程可以把它记录成 `run.failed`、`task.failed` 或 `llm.failed`，而不是自己一起崩溃。

## Application 是什么

OTP application 是 Erlang 系统里的一个可启动单元。

它通常包含：

- `.app.src` 元数据；
- 一个 application callback module；
- 一个 supervision tree；
- 依赖声明；
- 源码、测试、priv 文件等。

当前 Soma 是 rebar3 umbrella，包含多个 OTP application：

```text
apps/soma_runtime
apps/soma_tools
apps/soma_event_store
```

`application:ensure_all_started(soma_runtime)` 会启动 `soma_runtime` 及其依赖应用。

## Release 是什么

Release 是一个可发布、可运行的 Erlang 系统包。

它把需要的应用、依赖、配置和可选的 ERTS 打包在一起。

Soma 的 release 目标是：

```text
用户不需要本机安装 Erlang；
解压 release tarball 就能运行 soma。
```

文档里说的 self-contained release，就是包含 Erlang runtime 的发布包。

## Port 是什么

Port 是 BEAM 与外部 OS process 通信的机制。

Soma 的 CLI tool adapter 使用 port 启动外部可执行程序：

```text
soma_tool_call
  -> open_port({spawn_executable, Executable}, Args)
  -> external OS process
```

这和 Erlang process 不同：

```text
Erlang process
  - BEAM 内部轻量进程

External OS process
  - 操作系统进程
  - 通过 port 由 BEAM 管理和通信
```

Soma 对 CLI tool 的约束是：

- 使用 executable + argv；
- 不使用 shell command string；
- timeout/cancel 时杀掉 worker 和外部 OS process；
- stdout/stderr 有输出大小限制；
- 非 0 exit 被规范化成 `{error, Reason}`。

## Rebar3 Umbrella 是什么

rebar3 是 Erlang 的构建工具。

Umbrella repo 是一个包含多个 OTP application 的工程结构：

```text
soma/
  rebar.config
  apps/
    soma_runtime/
    soma_tools/
    soma_event_store/
```

这适合 Soma，因为 runtime、tools、event store 是不同边界，但需要作为一个系统一起构建和测试。

## Soma 里的概念映射

| Soma 概念 | Erlang/OTP 对应 |
|---|---|
| `soma_actor` | 长生命周期 Erlang process，建议 `gen_statem` |
| actor mailbox | Erlang process mailbox |
| actor message | Erlang message envelope |
| actor state | `gen_server` / `gen_statem` state |
| actor policy | actor state + validation module |
| `soma_llm_call` | 一次性 worker process |
| `soma_run` | per-run `gen_statem` |
| `soma_tool_call` | 一次性 worker process |
| tool crash | monitor `'DOWN'` message |
| timeout | timer / `state_timeout` |
| cancellation | message + child teardown |
| event store | `gen_server` |
| tool registry | `gen_server` |
| external CLI tool | OS process via port |
| release | OTP release tarball |

## 为什么这适合 Soma

Agent runtime 的核心难点不是“调用一次 LLM”或“调用一个工具”，而是：

- 长生命周期 entity；
- 多个并发 task；
- 子操作超时；
- 用户取消；
- 局部失败隔离；
- 事件审计；
- actor-to-actor message；
- 不让 LLM 直接拥有执行权。

Erlang/OTP 正好提供这套底层语义：

```text
process       -> entity / run / call 的隔离边界
mailbox       -> message 入口
supervisor    -> 生命周期和恢复
monitor       -> 子操作结果和崩溃观察
gen_statem    -> 明确状态转换
timer         -> timeout
event store   -> 可审计轨迹
port          -> 外部程序边界
```

Soma 的设计就是把这些机制用于 agent runtime：

```text
soma_actor 是 agent entity；
soma_run 是执行确定 steps 的路径；
soma_tool_call / soma_llm_call 是受监督的子操作；
events 是事实来源。
```

## 术语速查

| 术语 | 简短解释 |
|---|---|
| Erlang | 为高并发、高可用系统设计的语言 |
| BEAM | Erlang 虚拟机 |
| Erlang process | BEAM 内部轻量进程，不是 OS process |
| mailbox | 每个 Erlang process 的消息队列 |
| message passing | 进程之间通过发送消息通信 |
| actor model | 独立实体通过 message 通信的并发模型 |
| OTP | Open Telecom Platform，可靠 Erlang 系统框架和模式 |
| behaviour | 回调协议，例如 `gen_server`、`gen_statem` |
| `gen_server` | 长生命周期 server process 模式 |
| `gen_statem` | 状态机 process 模式 |
| supervisor | 启动、监控、重启子进程的监督者 |
| monitor | 单向观察进程退出，收到 `'DOWN'` message |
| link | 进程之间的失败传播关系 |
| application | OTP 可启动应用单元 |
| release | 可发布、可运行的 Erlang 系统包 |
| port | BEAM 与外部 OS process 通信的机制 |
| rebar3 | Erlang 构建工具 |
| umbrella | 一个 repo 中包含多个 OTP application 的结构 |
