# Soma 是什么

Soma 是一个 Erlang/OTP 原生的 agent runtime。它使用 Erlang/OTP 的 actor
model 构建 agent entity：`soma_actor`；`soma_actor` 发起的工作，由一套可靠跑
steps 的执行机制承载。

这里的 OTP 是 **Open Telecom Platform**——Erlang 构建可靠并发系统的标准库、框架
和设计模式。Erlang/OTP 的基础概念见 [erlang-otp-primer.zh.md](erlang-otp-primer.zh.md)。

`soma_actor` 是更高层的 agent 抽象。它是一个长期存在、具备 LLM 能力的
entity，拥有 memory/context、model config、mailbox、tool policy，以及它启动
的 runs。它通过 message 被触发，并在处理 message 时发起 LLM call、`soma_run`
或对其他 `soma_actor` 的 message。

可靠跑 steps 是 `soma_actor` 执行意图、调用工具和调用 LLM 的运行路径。这条
execution path（session、run、tool call、event、timeout、cancel、failure
isolation）先建好并验证；`soma_actor` 这一层已经建在它之上（v0.4），v0.5 又加上
LLM call worker、proposal、policy、budget 和 actor-to-actor message。当前测试门禁
仍默认使用 mock LLM；真实 OpenAI-compatible provider 已经接在同一个 call seam 后面，
通过 actor 的 `model_config` 选择，live 调用是 opt-in。它要证明的观点是：

```text
一次 agent run 不是一个不断调用工具的函数循环，
而是一棵受监督的 OTP 进程树。
```

在 Soma 里，步骤列表只描述“要运行什么”。真正的运行语义，包括超时、取消、监控、崩溃隔离、进程生命周期和事件记录，都交给 Erlang/OTP 的运行时机制处理。`soma_actor` 已经把这条执行路径纳入自己的消息处理流程：接收消息（`send`/`ask`）、建任务、启动它自己拥有的 `soma_run`、观察终态消息、记录结果或在失败/超时/取消时作为数据存活。带 `llm` 的消息会先进入 LLM worker，得到 proposal，再经过 policy gate 和 budget 校验，允许后才执行。

## Soma 解决什么问题

Agent 系统的问题通常不是“能不能调到工具”，而是工具调用之后会发生什么：

- 模型调用或工具调用可能挂住。
- 外部程序可能崩溃、退出非 0，或输出过大。
- 用户会取消正在运行的任务。
- 一个 run 失败后，session 仍然应该继续可用。
- 每次运行都需要可审计的事件轨迹。
- 工具不能直接修改 run 状态，失败也不能污染整个 session。

很多 agent runtime 会把这些问题塞进一个主循环里，用状态变量、异常捕获和超时包装来补救。Soma 的选择相反：把 agent/entity 和它发起的操作都落在 OTP 进程模型上，用监督、监控、消息和状态机表达运行语义。

## `soma_actor` 与当前 runtime 的关系

更准确的分层是：

```text
soma_actor       谁在做事：长期存在的 agent entity
soma_run         这次要做什么：一次任务/消息的执行 attempt
soma_run         内部维护 step cursor：静态步骤列表按顺序执行
soma_tool_call   某一步如何隔离执行：一次性 worker
soma_llm_call    一种特殊操作：调用模型，可作为 planner 或 tool
```

所以 `LLM capability + memory/context + mailbox + policy` 构成 `soma_actor`
的核心。`llm_call` 是 `soma_actor` 处理 message 时可以发起的能力。

LLM 在 Soma 里可以有两种位置：

- 作为 planner：`soma_actor` 调用 LLM 生成 steps，校验后交给 `soma_run` 执行。
- 作为 tool：steps 里包含 `llm_call`，它和 `file_read`、`cli`、`file_write` 一样由 `soma_tool_call` 隔离执行。

动态 agent loop 应该放在 `soma_actor` 层：actor 观察一次 run 的事件和结果，再决定是否继续规划下一批 steps。`soma_run` 保持简单，只负责可靠执行一段已经确定的 steps。

## Soma 不是什么

Soma 不应该退化成一个把 prompt、工具调用和状态变量塞进主循环里的框架。当前明确还不应该提前塞进 execution core 的内容包括：

- DAG 并行执行。
- distributed Erlang。
- daemon 启动时的自动 resume。
- 非幂等 in-flight step 的 per-tool resume policy / compensation hook。

这些都在 roadmap 里。`soma_actor` 的 agent/entity 语义已经建好，v0.5 的 LLM worker、proposal、policy、budget 和 actor-to-actor message 也已经落地；v0.6 让事件流可读、可选持久化；v0.7.1-v0.7.4 已经实现了持久化 run journal、reconstruct、resume plan 和手动 resume executor。下一条 resume 主线是 v0.7.5 auto-resume on boot，之后才考虑 DAG / parallel execution。

## 如何继续阅读

- `../../README.md` 是当前实现状态和快速开始入口。
- `erlang-otp-primer.zh.md` 面向非 Erlang 读者解释 BEAM、process、mailbox、OTP、`gen_server`、`gen_statem`、supervisor、application、release 等概念。
- `soma-actor.zh.md` 是 `soma_actor` 的完整设计说明：actor entity、message 触发、actor loop、decision frame、policy gate、LLM call、结果模型、事件、预算和最小切片。
- `../design.md` 解释设计原则和 OTP 进程模型。
- `../usage.md` 是用户手册，记录 `soma` 命令、workflow、任务管理、trace、模型配置和排错。
- `../tool-manifest.md` 记录工具 manifest 和 CLI adapter 协议。
- `../contracts/` 下的 v0.2-v0.7、L.1-L.5、CLI 契约以及
  [`task-form-test-contract.md`](../contracts/task-form-test-contract.md) 把每个行为保证映射到具体测试。
- `../roadmap.md` 记录当前已完成层、v0.7.5 及之后的未来层，以及 node B / CLI / Lisp 轨道状态。

一句话概括：Soma 的价值不在于“能调用多少工具”，而在于用 Erlang/OTP
把 `soma_actor` 这种 LLM-capable agent entity，以及它发起的 run、LLM call、
tool call，都变成可监督、可取消、可审计、失败可隔离的运行时结构。
