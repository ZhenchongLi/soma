# Soma Agent Shell 设计草案

> 状态：已实现(2026-07-16)。对应 GitHub issue #225(伞形,AS.1–AS.4 探索层),
> 及其后续 #236(RS.1 运行时服务)与 #233/#234(soma.delegate)。
> 各切片的行为保证见 `docs/contracts/` 下的 AS.*、RS.1* 契约文档;
> 服务面兼容性契约见 `docs/service-contract.md`。以下为原设计草案。
> 本文描述一个用户态 agent shell 层：外部 agent 只知道 `soma` 一个工具，
> 在 Soma 内部探索工具、阅读 help、过滤信息、试跑、生成 Soma Lisp、编译、
> 执行和监控。

## 核心场景

目标不是把 Soma 里每个底层工具都直接暴露给外部模型。目标是让外部 agent
只看到一个高层工具：

```text
soma
```

外部 agent 把目标交给 Soma。Soma 在内部提供一个 agent OS / shell 环境：

```text
explore tools
  -> read help
  -> search/filter help
  -> probe safely
  -> write Soma Lisp
  -> compile
  -> run
  -> monitor status/trace/cancel
```

因此，`docmod`、`file_read`、`file_write`、未来的 `text_grep`、`memory_search`
等能力不是外部 agent 必须逐个学习的顶层工具，而是 Soma 内部 catalog 里的
capabilities。外部 agent 学的是 Soma 这个操作系统入口。

## 为什么需要这一层

当前 Soma 已经适合作为 agent runtime kernel：

- `soma_run` 执行一段已经确定的顺序 steps。
- 每次 tool call 都经过 `soma_tool_call` process boundary。
- timeout、cancel、crash isolation、event trail、trace、durable resume 已经在
  runtime 层成立。
- CLI adapter 使用 executable + argv，不走 shell command string。

但这还不是完整的 agent shell。很多真实任务不是一开始就知道精确工具参数：

```text
我只知道有 docmod，我需要先看 docmod help edit，
再搜索 range / changes / examples，
再在临时文件上试一下，
最后写出可重复运行的 Soma Lisp task。
```

这类流程需要一个探索循环。这个循环不应该放进 `soma_run`，否则 runtime 会从
可靠执行器变成通用工作流/agent loop。更合适的位置是 `soma_actor` 或其上方的
agent shell 用户态。

## 分层

建议分层如下：

```text
外部 agent
  只知道 soma 一个工具/接口

Soma agent shell
  探索 catalog/help
  搜索/过滤文本
  安全 probe
  生成 Soma Lisp
  编译、运行、监控

soma_actor / planner
  LLM call、proposal、policy、budget、任务状态

soma_run runtime kernel
  顺序 step list
  soma_tool_call worker
  timeout/cancel/event/resume

tools/capabilities
  BEAM tools
  CLI tools
  actor tools
  future memory/MCP/client callback tools
```

边界原则：

- `soma_run` 不增加 ReAct loop、DAG、shell pipeline 或任意循环。
- agent shell 可以多轮探索，但每次实际 tool execution 仍然通过现有
  `soma_run -> soma_tool_call` 路径。
- 最终可执行产物是 Soma Lisp `(task ...)`，再由 `soma_lfe:compile/2` 编译成
  canonical step list。

## Agent 看到的动作空间

外部 agent 不应该直接面对任意 Unix shell。它应该面对一组稳定、有限的 Soma
动作。一个可能的高层 API 是：

```text
soma.explore(objective)
soma.help(tool, topic?)
soma.search(source, query)
soma.probe(call, safety)
soma.draft_lisp(notes)
soma.compile_lisp(source)
soma.run_lisp(source)
soma.status(task_id)
soma.trace(correlation_id)
soma.cancel(task_id)
```

这些动作可以是一个 `soma` 工具下的子动作，也可以是本地 CLI/daemon wire 上的
命令族。关键不是外形，而是外部 agent 的认知负担：它只学习 Soma，不学习所有底
层工具的进程、argv、quoting 和 pipeline 规则。

## Unix 风格工具如何进入 Soma

以 `docmod` 为例，Unix CLI 自己已经有自然的结构：

```bash
docmod help
docmod help edit
docmod read ...
docmod edit ...
```

Soma 不需要发明另一套 nested command language 来替代它。Soma 应该保留这个
心智模型，但不默认开放 shell：

```bash
docmod help edit | grep range
```

上面这类 shell pipeline 不应作为 Soma 的执行协议，因为它需要 `sh -c`、quoting、
环境继承和 shell expansion，容易扩大注入面。

Soma 应该提供结构化等价物：

```text
docmod help edit
  -> text_grep(pattern = "range")
```

或者在 Soma Lisp 里表达为类似：

```lisp
(task
  (let* ((help (tool docmod
                 (command "help")
                 (topic "edit")))
         (hits (tool text_grep
                 (pattern "range")
                 (text (from help)))))
    (return hits)))
```

这样保留 Unix 可组合性，但每个动作仍是受监管的 Soma tool call。

## 粗粒度工具与细粒度工具

第一版可以把 `docmod` 粗粒度注册成一个工具：

```lisp
(tool
  (name "docmod")
  (description "Run docmod CLI commands such as help, read, edit, and export.")
  (effect state)
  (idempotent false)
  (timeout-ms 30000)
  (adapter cli)
  (executable "/path/to/wrapper")
  (argv))
```

这很符合 Unix 心智：一个 binary，多个 subcommands。但它有治理代价：

- `docmod help`、`docmod read`、`docmod edit` 共享同一个 Soma descriptor。
- descriptor 只能保守标成 `state` / non-idempotent。
- read-only policy 不能允许 `docmod read` 同时禁止 `docmod edit`。
- persistent resume 遇到 in-flight `docmod help/read` 也会按更危险的 state 工具
  处理。
- catalog 参数会更泛，模型更容易传错。

长期更精确的形态是一个物理 CLI，对应多个 Soma descriptors：

```text
docmod_help -> docmod help ...
docmod_read -> docmod read ...
docmod_edit -> docmod edit ...
```

或者在 manifest 层支持 command metadata，再 normalize 成 flat descriptors。无论
哪种，`soma_run` 看到的仍然应是 flat canonical tools。

## Help 的位置

Help 应该由工具自己拥有，随工具版本一起发布。

CLI 工具优先使用自己的 Unix help：

```bash
docmod help
docmod help edit
docmod --help
```

BEAM 工具可以提供等价的 help surface，例如 callback 或 manifest metadata。

短期不一定需要一个独立 `tool_help` runtime tool。因为当前 Soma 不是 ReAct loop，
如果 step 1 调 help，模型不会自动在同一个 `soma_run` 里读完 help 再重新规划。

更自然的是：

- agent shell / planner 在规划阶段按需读取 help。
- 如果需要把 help 读取作为可审计 tool execution，也可以启动一个小 run 调对应
  CLI help。
- 将来如果 Soma 引入完整 tool-calling planning loop，同一套 help 能力可以再包成
 普通 reader tool。

## 探索循环

一个典型流程：

```text
用户目标：
  用 docmod 修改这个文档。

Soma agent shell：
  1. 读取 catalog，发现 docmod。
  2. 获取 docmod help。
  3. 获取 docmod help edit。
  4. 搜索 help 中的 changes/range/path/example。
  5. 必要时在临时副本上 probe。
  6. 生成 Soma Lisp task。
  7. 编译 Soma Lisp。
  8. 如果编译失败，把诊断作为 task data，让 agent 修正。
  9. 编译通过后正式运行。
  10. 监控 status/trace，支持 cancel。
```

这个循环应该有明确预算：

- 最大探索步数。
- 最大 help 输出字节数。
- 最大 probe 次数。
- state 工具默认只能在临时副本或 dry-run 模式下 probe。
- 失败 observation 必须短、结构化、可行动。

## 最终产物：Soma Lisp

探索不是最终目的。探索完成后，Soma 应该产出一段可复用、可审计、可编译的
Soma Lisp：

```lisp
(task
  (let* ((read (tool docmod_read
                 (path "input.docx")))
         (edit (tool docmod_edit
                 (path "input.docx")
                 (changes "<changes>"))))
    (return edit)))
```

如果第一版使用粗粒度 `docmod`，则可能是：

```lisp
(task
  (let* ((edit (tool docmod
                 (command "edit")
                 (path "input.docx")
                 (changes "<changes>"))))
    (return edit)))
```

无论哪种，正式执行前必须经过：

```text
soma_lfe:compile(Source, #{})
```

编译成功后才交给 runtime。编译失败是 task data，不应导致 actor 崩溃。

## 监控与审计

Soma agent shell 不是黑盒自动化。它应该暴露：

- 当前 task id。
- correlation id。
- 探索步骤摘要。
- 最终生成的 Soma Lisp。
- compile 诊断。
- run status。
- trace。
- cancel 入口。

事件 payload 必须 bounded/scrubbed：

- 不泄漏 API keys 或 provider secrets。
- 不泄漏不必要的 executable path / argv internals。
- 不泄漏 pids、ports、refs。
- 不写入无界 help 文档或工具输出。

## 最小实现切片

一个务实的第一版可以是：

1. 新增设计文档和 test contract 草案。
2. 增加 `text_grep` / `text_head` / `text_slice` 中最小的一两个原生 reader/identity 工具。
3. 支持一个 bounded exploration mode：help、search、probe、draft、compile、run。
4. 先允许粗粒度 CLI 工具，例如 `docmod` wrapper。
5. 生成 Soma Lisp 后必须 compile，再执行。
6. 所有正式执行仍走 `soma_run -> soma_tool_call`。
7. 失败路径证明 actor/session 存活。

第一版不要求：

- 完整 command-level manifest。
- 任意 shell pipeline。
- DAG/loop 进入 `soma_run`。
- 完整 Unix shell 兼容。
- 独立 skill 概念。

## 风险

主要风险不是技术可行性，而是边界滑动：

- 如果外部 agent 直接看到所有内部工具，复杂度会上升。
- 如果允许 `sh -c`，安全边界会变差。
- 如果把探索循环塞进 `soma_run`，runtime 会失去简单性。
- 如果粗粒度工具长期不拆，policy/resume/audit 会过于保守。
- 如果 help 输出不受限，事件和上下文都会膨胀。

对应约束：

- 外部 agent 只知道 `soma`。
- Soma 内部工具通过 catalog/help 暴露。
- Unix pipeline 用 Soma tools 表达，不用 shell。
- 探索循环在 actor/planner 用户态。
- 最终产物是 Soma Lisp，runtime 只跑 canonical steps。

## 待定问题

- `soma` 这个单一外部工具的具体 API 是 CLI 子命令、daemon wire action，还是
  未来 MCP/HTTP 边界？
- help 规范是 callback、manifest metadata、`help_argv`，还是 CLI convention 优先？
- 第一版是否接受粗粒度 `docmod`，还是直接注册 `docmod_help/read/edit`？
- text tools 的最小集合是什么？
- probe 如何表达 temp copy / dry-run / state 工具保护？
- exploration budget 是否复用现有 actor budget，还是单独建 shell budget？
- 探索过程的事件类型是否需要新增 `shell.*` / `explore.*`，还是先复用 task/run 事件？

## 一句话

Soma 已经有 agent runtime kernel。这个设计要补的是 agent shell user space：
外部 agent 只学会 `soma`，Soma 在内部像 Unix shell 一样探索工具、阅读 help、
组合安全 pipeline、生成 Soma Lisp、编译、运行和监控，同时保持 OTP runtime 的
进程边界、取消、审计和失败隔离。
