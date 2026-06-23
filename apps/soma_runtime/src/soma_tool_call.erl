%% @doc Disposable per-tool-call worker. It runs exactly one tool invocation in
%% its own process, reports the result back to the run, then exits. v0.1 happy
%% path: it handles the `{ok, Output}' return and replies with
%% `{tool_result, ToolCallId, self(), {ok, Output}}', carrying its own pid so
%% the run can prove each invocation ran in a distinct process.
-module(soma_tool_call).

-export([start/1]).

%% Spawn the worker for one invocation. `Opts' carries the tool `module', the
%% resolved `input', the `ctx', the `tool_call_id', and the `reply_to' pid.
start(Opts) when is_map(Opts) ->
    Pid = spawn(fun() -> run(Opts) end),
    {ok, Pid}.

run(Opts) ->
    Module = maps:get(module, Opts),
    Input = maps:get(input, Opts),
    Ctx = maps:get(ctx, Opts),
    ToolCallId = maps:get(tool_call_id, Opts),
    ReplyTo = maps:get(reply_to, Opts),
    Result = Module:invoke(Input, Ctx),
    ReplyTo ! {tool_result, ToolCallId, self(), Result},
    ok.
