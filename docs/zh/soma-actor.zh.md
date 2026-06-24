# `soma_actor` 工作模型

本文说明 Soma 最重要的抽象：`soma_actor` 如何作为 agent entity 工作，以及它和可靠执行 steps 的 runtime path 是什么关系。

当前仓库已经实现 v0.1/v0.2 的执行内核：session、run、tool call、tool manifest、CLI adapter、timeout、cancel、event store。`soma_actor` 是下一层设计目标，不是当前已完成的 API。

![soma_actor message-driven workflow](diagrams/soma-actor-flow.svg)

下面这张图用更简化的形式表达 actor loop：

![soma_actor loop](diagrams/soma-actor-loop.svg)

## 核心定义

`soma_actor` 是一个长期存在、具备 LLM call 能力的 actor 实体。它使用 Erlang/OTP 的 actor model 实现：

OTP 是 **Open Telecom Platform**，不是 “one time process”。Erlang/OTP
基础概念见 [erlang-otp-primer.zh.md](erlang-otp-primer.zh.md)。

```text
soma_actor
  = Erlang/OTP process
  = mailbox
  = private state
  = memory/context references
  = model configuration
  = tool policy
  = active tasks/runs
  = supervised lifecycle
```

`soma_actor` 的工作由 message 触发。它根据自己的 state、memory/context、model
configuration 和 tool policy 决定下一步：可以发起 LLM call，可以启动一次
`soma_run`，也可以向其他 `soma_actor` 发送 message。

结构上可以这样理解：

```text
soma_actor              长生命周期 agent entity
  ├── memory/context     actor 的上下文和记忆引用
  ├── soma_llm_call      一次受监督的 LLM 调用
  └── soma_run           一次受监督的 steps 执行 attempt
        └── soma_tool_call
```

一句话：**`soma_actor` 是 agent entity；LLM call 是它的能力；message passing 是它和其他 actor 的交互方式；`soma_run` 是它执行一段确定 steps 的运行路径。**

## 和 Erlang actor model 的关系

Erlang actor model 是 `soma_actor` 的实现基底：

```text
actor identity       -> actor_id + Erlang pid / registry entry
mailbox              -> Erlang process mailbox
private state        -> gen_server/gen_statem state
message passing      -> Erlang messages
supervision          -> OTP supervisor
failure isolation    -> links, monitors, restart policy
timeouts             -> timers / gen_statem state_timeout
cancellation         -> message + child process teardown
```

但 agent 语义不是 Erlang 自动提供的。Soma 需要在这层之上定义：

```text
message envelope
task_id / correlation_id
memory/context loading
LLM provider/model config
tool policy and permissions
run ownership
result storage
event schema
backpressure and mailbox policy
actor-to-actor routing
```

所以不是把一个 LLM call 包成 Erlang process 就结束了。`soma_actor` 应该是一个有身份、状态、上下文和策略的长期实体。

## 如何触发 `soma_actor` 工作

`soma_actor` 的工作入口是 message，而不是直接调用内部函数。

外部 API 可以有函数，但函数只是把请求包装成 message envelope，送进 actor mailbox：

```erlang
soma_actor:send(ActorPid, Envelope).
soma_actor:ask(ActorPid, Envelope, Timeout).
```

底层语义是：

```erlang
ActorPid ! {actor_message, Envelope}
```

一个 message envelope 应该至少包含：

```erlang
#{
  message_id => <<"msg-1">>,
  task_id => <<"task-1">>,
  correlation_id => <<"task-1">>,
  from => <<"user:liz">>,
  to => <<"actor:researcher">>,
  type => user_message,
  payload => #{
    text => <<"summarize this file">>
  },
  reply_to => undefined,
  timestamp => 123456789
}
```

`message_id` 标识这条消息本身。`task_id` 标识 actor 因这条消息启动的一次工作。`correlation_id` 把后续 LLM call、run、tool call、result、reply 和 events 串到同一条链上。

常见触发来源：

- 用户消息：用户请求 actor 做事。
- actor 消息：一个 `soma_actor` 委托、询问或通知另一个 `soma_actor`。
- 系统事件：scheduler、webhook、文件变化、外部事件。
- run 结果：`soma_run` 完成后，actor 观察结果并决定下一步。
- control message：pause、resume、cancel、shutdown、update_policy。

actor 之间通信也必须走 message：

```text
soma_actor A --message--> soma_actor B
```

这点很重要。`soma_actor` 之间不应该通过直接函数调用共享内部状态。

## `soma_actor` 如何处理一条 message

一条 message 进入 actor 后，典型流程是：

```text
receive message
  -> validate envelope
  -> check policy / permissions
  -> emit actor.message.received
  -> create or resume task
  -> load memory/context
  -> decide next action
       a) direct reply
       b) call LLM to produce reply
       c) call LLM to produce steps
       d) start soma_run with known steps
       e) send message to another actor
  -> observe LLM/run/tool events
  -> update memory/context
  -> emit actor.result.created
  -> send reply or downstream message
```

这个流程可以用 `gen_server` 实现；如果 actor 有清晰状态，例如 `idle | thinking | running | paused`，更适合用 `gen_statem`。

```text
idle
  -- actor_message --> thinking

thinking
  -- llm_result --> running | replying | idle

running
  -- run_completed --> thinking | replying | idle

paused
  -- resume --> idle
```

## LLM 在 `soma_actor` 里的两个位置

LLM 可以作为 planner：

```text
soma_actor receives message
  -> loads context
  -> soma_llm_call generates steps
  -> actor validates steps against schema/registry/policy
  -> actor starts soma_run
```

LLM 也可以作为普通 tool 出现在 steps 里：

```erlang
[
  #{id => read, tool => file_read,
    args => #{path => <<"input.txt">>, root => Root}},

  #{id => summarize, tool => llm_call,
    args => #{prompt => {from_step, read}},
    timeout_ms => 30000},

  #{id => write, tool => file_write,
    args => #{path => <<"summary.txt">>, root => Root,
              bytes => {from_step, summarize}}}
]
```

这两个角色不能混在一起：

- planner LLM 负责把 actor 的意图和 context 编译成 steps；
- tool LLM 是 steps 里的一个可超时、可取消、可审计的调用。

动态 agent loop 应该放在 `soma_actor` 层。`soma_run` 不应该变成“LLM 每一步都临时决定下一步”的大循环；它只负责可靠执行一段已经确定的 steps。

## 如何获取结果

结果获取也应该遵循 message/event 模型。不要把 `soma_actor` 设计成“调用函数然后同步返回最终结果”的普通函数。

推荐三种方式同时存在。

### 1. `ask/reply`：短任务便利 API

适合短任务。调用方发送 message，并等待 reply。

```erlang
{ok, Reply} = soma_actor:ask(ActorPid, #{
  type => user_message,
  payload => #{text => <<"summarize this">>}
}, 30000).
```

底层仍然是 message：

```text
caller
  -> actor_message
  -> soma_actor
  -> LLM/run/tool work
  -> actor_reply
  -> caller
```

actor 完成后发回：

```erlang
CallerPid ! {actor_reply, TaskId, Result}
```

`ask/3` 只是这个模式的同步封装，不应该绕过 mailbox、events、policy 或 cancellation。

### 2. `task_id + events`：长任务和 UI 的主路径

适合长任务、UI、CLI、debug、multi-actor workflow。

```erlang
{ok, TaskId} = soma_actor:send(ActorPid, Envelope).
Events = soma_event_store:by_correlation(StorePid, TaskId).
```

`by_correlation/2` 是 actor/event-store 层需要补上的查询能力；当前 v0.1/v0.2 事件存储只有按 run 或 session 查询。

event stream 是事实来源。一个完整任务可能产生：

```text
actor.message.received
actor.task.accepted
actor.context.loaded
llm.started
llm.succeeded
run.accepted
run.started
step.started
tool.started
tool.succeeded
step.succeeded
run.completed
actor.result.created
actor.message.sent
actor.task.completed
```

失败、超时和取消同样进入事件流：

```text
llm.failed
run.failed
run.timeout
run.cancelled
actor.task.failed
actor.task.cancelled
```

这让调用方可以看到中间状态，而不是只拿到一个最终值。

### 3. `poll status/result`：集成便利 API

适合简单系统集成。

```erlang
{ok, TaskId} = soma_actor:send(ActorPid, Envelope).
soma_actor:get_task_status(ActorPid, TaskId).
soma_actor:get_task_result(ActorPid, TaskId).
```

状态可以是：

```erlang
#{
  task_id => <<"task-1">>,
  status => running | completed | failed | timeout | cancelled,
  result => ResultOrUndefined,
  error => ReasonOrUndefined
}
```

这个 API 可以从 actor state 或 result store 读取，但最终事实仍然应该能从 event stream 复原。

## 结果模型的原则

所有 actor 工作都应该有 `task_id` / `correlation_id`。

所有 LLM call、run、tool call、message sent、result 都应该挂在同一个 correlation chain 下。

最终结果不仅要发给等待方，也要记录成事件：

```text
actor.result.created
actor.task.completed
```

这条规则保证了三件事：

- 短任务可以 `ask` 到结果。
- 长任务可以订阅 events。
- 系统崩溃或调试时，可以从 event log 还原发生过什么。

## 最小 API 草案

```erlang
soma_actor:start_link(Opts) -> {ok, ActorPid}.

soma_actor:send(ActorPid, Envelope) ->
    {ok, TaskId} | {error, Reason}.

soma_actor:ask(ActorPid, Envelope, TimeoutMs) ->
    {ok, Result} | {error, Reason} | timeout.

soma_actor:cancel(ActorPid, TaskId) ->
    ok | {error, Reason}.

soma_actor:get_status(ActorPid) ->
    #{actor_id := ActorId, status := Status, tasks := Tasks}.

soma_actor:get_task_status(ActorPid, TaskId) ->
    #{task_id := TaskId, status := Status}.

soma_actor:get_task_result(ActorPid, TaskId) ->
    {ok, Result} | {error, Reason} | not_ready.
```

这些 API 是 message 模型的外壳，不是绕过 actor mailbox 的直接函数调用。

## 非目标

`soma_actor` 不应该让 `soma_run` 变成动态大循环。

`soma_actor` 不应该直接执行工具逻辑。

`soma_actor` 不应该把所有 memory、LLM provider、tool policy、run state 都塞成一个不可拆的巨大状态 map。

`soma_actor` 不应该只返回最终字符串而丢掉中间事件。

## 不可变的设计合同

`soma_actor` 是 agent entity。

`soma_actor` 通过 message 被触发。

`soma_actor` 之间通过 message 通信。

`soma_actor` 具备 LLM call 能力。

`soma_actor` 发起 `soma_run` 来执行确定的 steps。

`soma_run` 保持可靠执行路径：顺序 steps、process boundary、timeout、cancel、failure isolation、events。

结果通过 `task_id` / `correlation_id` 关联，并通过 reply、event stream 或 polling 获取。

event stream 是事实来源。

这就是 Soma 的核心：用 Erlang/OTP 的 actor model 构建具备 LLM 能力的 agent entity，并让它发起的每个 LLM call、run、tool call 都保持可监督、可取消、可审计、失败可隔离。
