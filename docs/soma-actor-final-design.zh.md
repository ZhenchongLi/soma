# `soma_actor` 最终设计

本文是当前阶段对 `soma_actor` 的收敛设计。它不替代 v0.1/v0.2 已经实现的 `soma_run` / `soma_tool_call` 执行内核，而是说明这个执行内核在最终 agent runtime 里的位置。

核心结论：

```text
Soma 使用 Erlang/OTP 的 actor model 构建 agent entity：soma_actor。

soma_actor 通过 message 被触发，拥有 state、memory/context、model config、
tool policy 和 active tasks。

soma_actor 发起 LLM call、soma_run、tool call 或 actor-to-actor message。

LLM/rules 只产生 proposal；状态转移、policy 校验和执行权属于 soma_actor。

结果通过 task_id / correlation_id 关联，并通过 reply、event stream 或 polling 获取。
```

当前 v0.1/v0.2 已经实现的是可靠 steps 执行路径：给定 steps，`soma_run` 顺序执行、隔离工具调用、处理 timeout/cancel/failure、发出 events。`soma_actor` 会使用这条路径执行自己的意图。

注：OTP 是 **Open Telecom Platform**，不是 “one time process”。Erlang/OTP
基础概念见 [erlang-otp-primer.zh.md](erlang-otp-primer.zh.md)。

## 目标

`soma_actor` 是 Soma 的 agent entity。它是一个长期存在的 Erlang/OTP process，具备 LLM call 能力，并用 message passing 与用户、系统和其他 `soma_actor` 交互。

它的目标不是把 prompt、memory、tool call 和状态变量塞进一个函数循环里，而是把 agent 的生命周期和每次动作都落在 OTP 语义上：

- message 触发工作；
- actor state machine 拥有控制权；
- LLM call 是受监督的推理操作；
- run 是受监督的 steps 执行 attempt；
- tool call 是 run 里的隔离调用；
- events 是事实来源；
- task/result 通过 correlation chain 串联。

## 总体结构

```text
soma_actor                    long-lived LLM-capable agent entity
  |
  +-- memory/context refs      actor-owned context and retrieval boundary
  |
  +-- soma_llm_call            supervised LLM call; returns proposal
  |
  +-- soma_run                 supervised execution attempt for known steps
  |     |
  |     +-- soma_tool_call     isolated per-step tool or llm_call tool
  |
  +-- actor message            message to another soma_actor
```

简化工作循环：

![soma_actor loop](diagrams/soma-actor-loop.svg)

更完整的 message-driven workflow：

![soma_actor message-driven workflow](diagrams/soma-actor-flow.svg)

## Erlang/OTP 映射

`soma_actor` 与 Erlang actor model 的映射应保持直接：

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

Agent 语义由 Soma 在这个基底上补齐：

```text
message envelope
task_id / correlation_id
memory/context loading
LLM provider/model config
tool policy and permissions
run ownership
result storage
event schema
budget and loop limits
backpressure and mailbox policy
actor-to-actor routing
```

推荐实现形态：

```text
soma_actor_sup
  └── soma_actor          gen_statem; long-lived agent entity

soma_llm_call_sup
  └── soma_llm_call       disposable worker; one model call

soma_run_sup
  └── soma_run            gen_statem; one execution attempt
        └── soma_tool_call
```

`soma_actor` 自身不阻塞在 LLM call 或 run 上。它启动并监控子操作，子操作结果作为 message 回到 actor mailbox。

## Message 是入口

`soma_actor` 的工作入口是 message。外部函数 API 只是 envelope 的包装，不绕过 actor mailbox。

最小 envelope：

```erlang
#{
  message_id => <<"msg-1">>,
  task_id => <<"task-1">>,
  correlation_id => <<"task-1">>,
  from => <<"user:liz">>,
  to => <<"actor:researcher">>,
  type => user_message,
  payload => #{text => <<"summarize this file">>},
  reply_to => undefined,
  timestamp => 123456789
}
```

触发来源：

- 用户消息；
- 另一个 `soma_actor` 的 message；
- system event，例如 timer、webhook、file change；
- run / llm / tool 的结果；
- control message，例如 cancel、pause、resume、shutdown、update_policy。

Actor 之间通信同样走 envelope：

```text
soma_actor A --actor_message/correlation_id--> soma_actor B
```

`correlation_id` 必须跨 actor 传播，用于追踪整条任务链。

## Actor Loop

`soma_actor` 的自主工作不是无限 while loop，而是 event-driven state machine：

```text
incoming message/event
  -> update actor/task state
  -> load memory/context
  -> build decision frame
  -> decide next action
  -> validate proposal
  -> execute action
  -> receive result event/message
  -> next loop or terminal result
```

可选状态：

```text
idle
  -- actor_message --> thinking

thinking
  -- proposal accepted --> running | waiting_llm | replying | waiting

waiting_llm
  -- llm_result --> thinking

running
  -- run_completed/run_failed/run_timeout/run_cancelled --> thinking

paused
  -- resume --> idle | thinking
```

状态名可以调整，但控制权必须在 `soma_actor`，不是 LLM。

## Decision Frame

`soma_actor` 每次决定下一步时，不应该只把原始用户消息丢给 LLM。它应构建一个 decision frame：

```erlang
#{
  actor_id => ActorId,
  task_id => TaskId,
  correlation_id => CorrelationId,
  actor_state => ActorState,
  task_state => TaskState,
  input_message => Envelope,
  memory_context => RetrievedMemory,
  active_runs => ActiveRuns,
  recent_events => RecentEvents,
  model_config => ModelConfig,
  tool_policy => ToolPolicy,
  budget => Budget,
  allowed_actions => AllowedActions
}
```

Decision frame 的作用：

- 给 rules / LLM 足够上下文；
- 限制可选 action；
- 让每次决策可审计；
- 让 policy gate 可以做确定性校验；
- 让 debug 可以复原 actor 为什么进入下一步。

## Rules 与 LLM 的关系

v0.1/v0.2 已经支持固定 steps 直接运行。这时不需要 LLM：

```text
given steps
  -> validate steps
  -> start soma_run
  -> execute sequentially
  -> emit events
  -> terminal result
```

`decide next action` 在这个场景里只是固定规则：

```text
Envelope has valid steps -> start_run
run completed -> create result
run failed/timeout/cancelled -> create failed result
```

后续 `soma_actor` 的动态流程才需要 LLM：

```text
message
  -> build context
  -> rules cannot decide
  -> soma_llm_call
  -> proposal
  -> policy validate
  -> execute
```

LLM 输出必须是结构化 proposal，而不是自由文本控制系统。

允许的 proposal action：

```text
reply
call_llm
start_run
send_actor_message
wait
request_user_input
complete_task
fail_task
```

示例：

```erlang
#{
  action => start_run,
  reason => <<"Need to read and summarize the file">>,
  steps => [...]
}
```

## Policy Gate

Policy gate 是 `soma_actor` 的核心安全边界。LLM/rules 给出的 proposal 必须先通过 policy，才能执行。

需要校验：

- action 是否允许；
- step schema 是否有效；
- tool 是否注册；
- tool 是否被该 actor 授权；
- timeout 是否明确；
- budget 是否足够；
- 是否触发 dangerous action；
- 是否需要用户确认；
- actor-to-actor message 是否允许；
- memory namespace 是否可读写；
- hop count / ttl 是否超过限制。

Policy gate 输出：

```text
allow
reject
ask_user
revise_with_constraints
fail_task
```

LLM 不拥有执行权。`soma_actor` 拥有执行权。

## LLM Call

`soma_llm_call` 是一次受监督的 model call。它由 `soma_actor` 发起，拿到 actor 提供的 context、instructions、allowed actions 和 tool surface，返回 proposal。

关系：

```text
soma_actor
  -> starts soma_llm_call
  -> gives context + allowed action schema
  <- receives llm_result / proposal
  -> validates policy
  -> executes or rejects
```

对 LLM call 来说，`soma_actor` 是 tool host / execution environment。Actor 可以把自己的部分能力包装成 tools 暴露给 LLM，例如：

```text
read_memory
write_memory
start_run
send_message_to_actor
request_user_input
```

这些是 actor 授权的 tool surface。LLM 只能请求调用；actor 决定是否执行。

LLM 也可以作为普通 step tool：

```erlang
[
  #{id => read, tool => file_read, args => #{path => <<"input.txt">>, root => Root}},
  #{id => summarize, tool => llm_call,
    args => #{prompt => {from_step, read}},
    timeout_ms => 30000},
  #{id => write, tool => file_write,
    args => #{path => <<"summary.txt">>, root => Root, bytes => {from_step, summarize}}}
]
```

Planner LLM 和 tool LLM 是两个位置：

- planner LLM 帮 `soma_actor` 产生 proposal；
- tool LLM 是 `soma_run` 中某一步的工具调用。

## Run Execution

`soma_run` 是 actor 执行确定 steps 的路径。它应该继续保持 v0.1/v0.2 的职责：

- 顺序执行 steps；
- 每个 tool invocation 跨进程边界；
- tool result 作为 message 返回 run；
- timeout 真实杀掉 active worker；
- cancel 真实停止 active worker；
- failure 进入 run terminal state；
- events 记录完整轨迹；
- session / actor 存活。

`soma_actor` 发起 run，并通过 run result message / event 观察结果：

```text
soma_actor
  -> start soma_run with validated steps
  -> state = running
  <- run_completed / run_failed / run_timeout / run_cancelled
  -> update task state
  -> next loop or final result
```

`soma_actor` 不直接执行工具逻辑。

## Result Model

每个 actor task 必须有：

```text
task_id
correlation_id
status
result or error
event trail
```

结果获取有三种方式。

### `ask/reply`

短任务便利 API：

```erlang
{ok, Result} = soma_actor:ask(ActorPid, Envelope, 30000).
```

底层仍然是 message：

```text
caller -> actor_message -> soma_actor -> work -> actor_reply -> caller
```

### `task_id + events`

长任务和 UI 主路径：

```erlang
{ok, TaskId} = soma_actor:send(ActorPid, Envelope).
Events = soma_event_store:by_correlation(StorePid, TaskId).
```

`by_correlation/2` 是 actor/event-store 层需要补的能力；当前 v0.1/v0.2 只有按 run 或 session 查询。

事件示例：

```text
actor.message.received
actor.task.accepted
actor.context.loaded
llm.started
llm.succeeded
actor.proposal.created
actor.policy.allowed
run.accepted
run.started
step.started
tool.started
tool.succeeded
step.succeeded
run.completed
actor.result.created
actor.task.completed
```

### `poll status/result`

简单集成 API：

```erlang
soma_actor:get_task_status(ActorPid, TaskId).
soma_actor:get_task_result(ActorPid, TaskId).
```

结果状态：

```erlang
#{
  task_id => <<"task-1">>,
  correlation_id => <<"task-1">>,
  status => running | completed | failed | timeout | cancelled,
  result => ResultOrUndefined,
  error => ReasonOrUndefined
}
```

Event stream 是事实来源；reply 和 polling 是便利接口。

## Event Contract

Actor 层应扩展现有 event model。每个事件仍应携带：

```text
event_id
timestamp
session_id
actor_id
task_id
correlation_id
run_id
step_id
tool_call_id
llm_call_id
event_type
payload
```

其中 `actor_id/task_id/correlation_id/llm_call_id` 是 actor 层新增字段。字段可以在 v0.3 里先通过 payload 兼容引入，之后再提升为事件规范字段。

Actor event 类型建议：

```text
actor.started
actor.message.received
actor.task.accepted
actor.context.loaded
actor.decision.started
actor.proposal.created
actor.policy.allowed
actor.policy.rejected
actor.action.started
actor.action.succeeded
actor.action.failed
actor.result.created
actor.message.sent
actor.task.completed
actor.task.failed
actor.task.cancelled
```

LLM event 类型建议：

```text
llm.started
llm.succeeded
llm.failed
llm.timeout
llm.cancelled
```

## Memory Model

`soma_actor` 的 memory 不应只是一个巨大 state map。建议分层：

```text
actor_state        small, hot, private process state
task_state         per task progress and active operations
short_context      constructed context for current decision frame
memory_refs        references to long-term memory backend
event_log          immutable trail
result_store       task final results and summaries
```

原则：

- actor process state 保持小而热；
- 长期 memory 放在后端或外部 store；
- context 每轮构建；
- event log 记录事实；
- result store 提供查询便利；
- memory namespace 受 policy 控制。

## Budget、Backpressure 与 Loop 限制

每个 task 必须有预算和终止条件：

```text
max_llm_calls
max_runs
max_tool_calls
max_actor_messages
max_actor_hops
max_wall_time_ms
max_tokens
max_event_count
```

Actor mailbox 需要 backpressure 策略：

```text
queue_limit
priority
deadline
dedupe_key
drop_or_reject_policy
pause/resume
```

Actor-to-actor message 必须带：

```text
correlation_id
hop_count
ttl
trace
```

这避免 actor 之间互相委托形成 runaway loop。

## Failure Semantics

失败必须分层记录：

```text
llm_call failed       -> 推理操作失败
tool_call failed      -> 某个工具调用失败
run failed            -> 一次 steps 执行失败
task failed           -> actor 的一个 task 失败
actor crashed         -> actor 进程崩溃，由 supervisor 处理
```

这些失败不能混成一个 `error`。

Actor 层处理原则：

- child operation crash 是 actor 收到的 data；
- actor 自己不直接执行长耗时操作；
- cancel task 要取消 active LLM call / run；
- timeout task 要停止 active operations；
- actor crash 后 supervisor 根据策略重启；
- task resume 是否支持取决于 persistence 层，不属于 v0.3 最小目标。

## soma_actor 最小切片

`soma_actor` 骨架应先实现核心能力，不急着做复杂 LLM planner。注：v0.3 已完成 LFE DSL 编译器层；`soma_actor` 是后续层的目标。

最小能力：

```text
1. start soma_actor with actor_id, model_config, tool_policy
2. receive Envelope through send/ask
3. create task_id / correlation_id
4. emit actor.message.received / actor.task.accepted
5. fixed-rule decision:
     - Envelope has steps -> validate and start soma_run
     - Envelope has reply payload -> create result
6. observe run terminal result
7. emit actor.result.created / actor.task.completed or failed
8. support ask/reply
9. support get_task_status / get_task_result
10. support event lookup by correlation_id
11. support cancel task -> cancel active run
```

初期暂不需要真实 LLM planner。可以先用 deterministic mock proposal worker 证明 actor loop。后续再加：

```text
soma_llm_call
structured proposal schema
policy gate over proposals
LLM -> validated steps
```

## soma_actor Test Contract

`soma_actor` 的测试必须继续遵守 Soma 的原则：证明进程行为，而不只是返回值。

必测项：

1. actor starts and emits `actor.started`;
2. actor receives message and creates task/correlation id;
3. actor can run fixed steps through `soma_run`;
4. run completion produces actor result;
5. `ask` receives final reply;
6. long task can be queried by `task_id`;
7. events can be queried by `correlation_id`;
8. actor survives run failure;
9. actor survives tool crash;
10. cancel task cancels active run;
11. actor can accept another message after failure/cancel/timeout;
12. actor-to-actor message preserves correlation id;
13. budget exhaustion fails task, not actor;
14. policy rejection fails or asks, not actor;
15. actor process remains responsive while LLM/run child is active.

## 非目标

soma_actor 最小切片不做完整 LLM planner。

不做 DAG。

不做 MCP。

不做持久 resume。

不做复杂 memory backend。

不让 `soma_run` 变成动态 agent loop。

## 不可变设计合同

`soma_actor` 是 agent entity。

`soma_actor` 通过 message 被触发。

`soma_actor` 之间通过 message 通信。

`soma_actor` 具备 LLM call 能力。

LLM/rules 产生 proposal。

`soma_actor` 校验 proposal，并拥有状态转移和执行权。

`soma_actor` 发起 `soma_run` 执行确定 steps。

`soma_run` 保持可靠执行路径：顺序 steps、process boundary、timeout、cancel、failure isolation、events。

结果通过 `task_id` / `correlation_id` 关联，并通过 reply、event stream 或 polling 获取。

Event stream 是事实来源。

这就是最终设计的主线：

```text
need
  -> actor_message
  -> soma_actor
  -> state + memory/context + policy
  -> rules or LLM proposal
  -> policy gate
  -> action
  -> message/event/result
  -> next loop
  -> final result
```
