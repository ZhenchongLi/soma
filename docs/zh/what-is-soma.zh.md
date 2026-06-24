# Soma 是什么

Soma 是一个 Erlang/OTP 原生的 agent runtime。它使用 Erlang/OTP 的 actor
model 构建 agent entity：`soma_actor`；`soma_actor` 发起的工作，由一套可靠跑
steps 的执行机制承载。

这里的 OTP 是 **Open Telecom Platform**，不是 “one time process”。Erlang/OTP
的基础概念见 [erlang-otp-primer.zh.md](erlang-otp-primer.zh.md)。

`soma_actor` 是更高层的 agent 抽象。它是一个长期存在、具备 LLM 能力的
entity，拥有 memory/context、model config、mailbox、tool policy，以及它启动
的 runs。它通过 message 被触发，并在处理 message 时发起 LLM call、`soma_run`
或对其他 `soma_actor` 的 message。

可靠跑 steps 是 `soma_actor` 执行意图、调用工具和调用 LLM 的运行路径。当前仓库
先实现了这条 execution path：session、run、tool call、event、timeout、cancel
和 failure isolation。它要证明的观点是：

```text
一次 agent run 不是一个不断调用工具的函数循环，
而是一棵受监督的 OTP 进程树。
```

在 Soma 里，步骤列表只描述“要运行什么”。真正的运行语义，包括超时、取消、监控、崩溃隔离、进程生命周期和事件记录，都交给 Erlang/OTP 的运行时机制处理。未来 `soma_actor` 会把这条执行路径纳入自己的消息处理流程：接收消息，构建 context，调用 LLM 规划或响应，启动 `soma_run`，观察事件和结果，再更新 memory/context。

## Soma 解决什么问题

Agent 系统的问题通常不是“能不能调到工具”，而是工具调用之后会发生什么：

- 模型调用或工具调用可能挂住。
- 外部程序可能崩溃、退出非 0，或输出过大。
- 用户会取消正在运行的任务。
- 一个 run 失败后，session 仍然应该继续可用。
- 每次运行都需要可审计的事件轨迹。
- 工具不能直接修改 run 状态，失败也不能污染整个 session。

很多 agent runtime 会把这些问题塞进一个主循环里，用状态变量、异常捕获和超时包装来补救。Soma 的选择相反：把 agent/entity 和它发起的操作都落在 OTP 进程模型上，用监督、监控、消息和状态机表达运行语义。

## 核心模型

当前仓库已经是一个 rebar3 umbrella，主要包含四个 OTP application：

- `soma_runtime`：session、run、监督树和工具调用 worker。
- `soma_tools`：工具 behaviour、工具注册表、内置工具、manifest 校验和 CLI adapter 相关逻辑。
- `soma_event_store`：内存事件存储。
- `soma_lfe`：LFE DSL 编译器，把受限的 LFE 语法编译成 runtime 已接受的步骤列表格式；compile-only 层，不依赖 `soma_runtime`。

运行时的主结构是：

```text
soma_sup
  ├── soma_event_store
  ├── soma_tool_registry
  ├── soma_session_sup
  └── soma_run_sup
```

其中最重要的进程角色是：

- `soma_agent_session` 是长生命周期的 `gen_server`。它拥有 `session_id`，接受 run 请求，启动 `soma_run`，追踪 run 状态，但不执行工具逻辑。
- `soma_run` 是每次运行对应的 `gen_statem`。它拥有步骤游标、步骤输出、当前 tool call、超时、取消和事件发射。它的终态是 `completed`、`failed`、`timeout`、`cancelled`。
- `soma_tool_call` 是一次性 worker。它只执行一次工具调用，把结果作为消息发回 `soma_run`，然后退出。

这个边界是 Soma 的关键：每个工具调用都必须跨越进程边界。工具崩溃时，`soma_run` 通过 monitor 收到 `'DOWN'` 消息，把它记录成 run 的失败数据，而不是让 session 或未来的 `soma_actor` 一起崩掉。

## `soma_actor` 与当前 runtime 的关系

更准确的分层是：

```text
soma_actor       谁在做事：长期存在的 agent entity
soma_run         这次要做什么：一次任务/消息的执行 attempt
soma_step        按什么顺序做：静态步骤列表中的一个步骤
soma_tool_call   某一步如何隔离执行：一次性 worker
soma_llm_call    一种特殊操作：调用模型，可作为 planner 或 tool
```

所以 `LLM capability + memory/context + mailbox + policy` 构成 `soma_actor`
的核心。`llm_call` 是 `soma_actor` 处理 message 时可以发起的能力。

LLM 在 Soma 里可以有两种位置：

- 作为 planner：`soma_actor` 调用 LLM 生成 steps，校验后交给 `soma_run` 执行。
- 作为 tool：steps 里包含 `llm_call`，它和 `file_read`、`cli`、`file_write` 一样由 `soma_tool_call` 隔离执行。

动态 agent loop 应该放在 `soma_actor` 层：actor 观察一次 run 的事件和结果，再决定是否继续规划下一批 steps。`soma_run` 保持简单，只负责可靠执行一段已经确定的 steps。

## 一次 run 如何执行

Soma 的步骤格式刻意保持很小。一个 run 接收一组顺序步骤：

```erlang
[
  #{id => read, tool => file_read, args => #{path => <<"in.txt">>, root => "/tmp/soma"}},
  #{id => echo, tool => echo, args => #{from_step => read}},
  #{id => write, tool => file_write,
    args => #{path => <<"out.txt">>, root => "/tmp/soma", bytes => {from_step, echo}}}
]
```

执行过程是严格顺序的：

```text
解析步骤参数
解析工具 descriptor
启动 soma_tool_call worker
等待工具结果、崩溃、超时或取消
记录事件
进入下一步或进入终态
```

步骤之间只有简单的 `from_step` 引用。v0.3 新增了 LFE DSL 编译器（`soma_lfe:compile/2`），可以把 LFE 语法编译成这种步骤列表。未来无论步骤来自 `soma_actor` 的 LLM planning、JSON、LLM structured output 还是 UI，它们都应该先编译成这个小步骤列表，通过 schema/registry/policy 校验后，再交给 runtime 执行。

## 工具系统

Soma 的工具是 Erlang behaviour：

```erlang
-callback describe() -> soma_tool:spec().
-callback invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
```

工具通过 manifest 注册。manifest 至少声明：

- `name`：步骤里引用的工具名。
- `effect`：`identity`、`reader` 或 `state`。
- `idempotent`：是否幂等。
- `timeout_ms`：默认调用超时。
- `adapter`：运行方式。

当前有两类 adapter：

- `erlang_module`：在 BEAM 内调用实现了 `soma_tool` behaviour 的模块。
- `cli`：通过 Erlang port 启动一次性外部可执行程序。

内置工具包括 `echo`、`sleep`、`fail`、`file_read`、`file_write`。其中 `fail` 用于证明错误和崩溃路径，文件工具在指定 `root` 下读写。

CLI 工具遵守一个重要规则：只接受 `executable + argv`，不接受 shell 命令字符串。Soma 不走 `/bin/sh -c`，也不让管道、重定向、glob 或 shell interpolation 进入核心路径。步骤输入会被追加为最后一个 argv 参数，外部程序的输出被收集为步骤输出，非 0 退出、不可执行、找不到文件、输出过大都会被规范化成 `{error, Reason}` 数据。

## 超时、取消和失败隔离

Soma 把取消和超时当成运行时语义，而不是最后检查的标志位。

当一个步骤超时时，`soma_run` 会杀掉当前 `soma_tool_call` worker。如果这是 CLI 工具，run 还会记录外部 OS 进程 pid，并在超时或取消时杀掉外部进程。run 随后进入 `timeout` 或 `cancelled` 终态，并发出对应事件。

当工具返回 `{error, Reason}` 或 worker 崩溃时，`soma_run` 进入 `failed`，记录 `tool.failed`、`step.failed` 和 `run.failed`。`soma_agent_session` 只收到运行结果消息并更新状态，它本身继续存活，可以继续启动新的 run。

这也是 Soma 使用 Erlang/OTP 的根本原因：失败隔离不是外围补丁，而是进程模型的一部分。

## 事件日志

事件是 Soma 从第一天起就要求具备的能力。每条事件都会被规范化为包含以下字段：

```text
event_id
timestamp
session_id
run_id
step_id
tool_call_id
event_type
payload
```

成功 run 的典型事件轨迹是：

```text
session.started
run.accepted
run.started
step.started
tool.started
tool.succeeded
step.succeeded
run.completed
```

失败、超时、取消会走向 `run.failed`、`run.timeout` 或 `run.cancelled`。这让测试和调试可以直接查看“发生了什么”，而不是只看最终返回值。

## 当前状态

按照当前 `README.md`，Soma 的 v0.1 runtime core、v0.2 tool manifest + CLI/port adapter 和 v0.3 LFE DSL 编译器层已经实现并在 `main` 上通过测试（EUnit 95，Common Test 70）。仓库里已经有：

- rebar3 umbrella 和四个 app（`soma_runtime`、`soma_tools`、`soma_event_store`、`soma_lfe`）。
- `soma_agent_session`、`soma_run`、`soma_tool_call` 的运行时骨架与实现。
- 内存事件存储。
- 内置工具和工具注册表。
- manifest 校验。
- in-BEAM 工具和外部 CLI 工具路径。
- `soma_lfe:compile/2`：把 LFE DSL 源码编译成 runtime 步骤列表，compile-only，不依赖 `soma_runtime`，返回 `{ok, #{run => #{steps => Steps}}}` 或 `{error, [Diagnostic]}`。
- Common Test 和 EUnit，用来证明进程存活、顺序执行、事件发射、失败隔离、超时、取消和 CLI 子进程清理；DSL 层合约测试覆盖编译、校验、以及通过真实 session/run/tool-call 路径执行的 end-to-end 验证。
- macOS arm64 自包含 release；Linux x86_64 和 Linux arm64 release 仍是剩余打包任务。

还没有实现的是 `soma_actor` 这一层：长期存在的 agent entity、mailbox、memory/context、model config、tool policy，以及 actor-driven planning。

## Soma 不是什么

Soma 不应该退化成一个把 prompt、工具调用和状态变量塞进主循环里的框架。当前明确还不应该提前塞进 execution core 的内容包括：

- MCP client adapter。
- DAG 并行执行。
- distributed Erlang。
- 持久化 resume。

这些都在 roadmap 里。`soma_actor` 是下一个重要层：先有 agent/entity 语义，再在它上面加 MCP、actor-driven planning 和持久化 resume。

## 如何继续阅读

- `../../README.md` 是当前实现状态和快速开始入口。
- `erlang-otp-primer.zh.md` 面向非 Erlang 读者解释 BEAM、process、mailbox、OTP、`gen_server`、`gen_statem`、supervisor、application、release 等概念。
- `soma-actor-final-design.zh.md` 是 `soma_actor` 的最终设计说明：actor 语义、message loop、decision pipeline、policy gate、预算、结果、事件和最小切片。
- `soma-actor.zh.md` 解释最核心的 `soma_actor` 工作模型：如何通过 message 触发、如何调用 LLM/run/tool、如何通过 reply/events/correlation_id 获取结果。
- `../design.md` 解释设计原则和 OTP 进程模型。
- `../usage.md` 记录实际 API、步骤格式、事件读取和取消方式。
- `../tool-manifest.md` 记录工具 manifest 和 CLI adapter 协议。
- `../contracts/v0.2-test-contract.md` 把每个行为保证映射到具体测试。
- `../roadmap.md` 记录 v0.3 之后才应该进入的未来层。

一句话概括：Soma 的价值不在于“能调用多少工具”，而在于用 Erlang/OTP
把 `soma_actor` 这种 LLM-capable agent entity，以及它发起的 run、LLM call、
tool call，都变成可监督、可取消、可审计、失败可隔离的运行时结构。
