%% @doc Disposable per-tool-call worker. It runs exactly one tool invocation in
%% its own process, reports the result back to the run, then exits. v0.1 happy
%% path: it handles the `{ok, Output}' return and replies with
%% `{tool_result, ToolCallId, self(), {ok, Output}}', carrying its own pid so
%% the run can prove each invocation ran in a distinct process.
-module(soma_tool_call).

-export([start/1]).

%% Configured upper bound on the bytes the cli adapter buffers from a program's
%% merged stdout/stderr. A program that emits more than this is stopped rather
%% than buffered whole, and the run fails with a reason naming this limit. A
%% module constant is enough for v0.1: there is no per-tool override.
-define(CLI_OUTPUT_LIMIT, 65536).

%% Spawn the worker for one invocation. `Opts' carries the tool `module', the
%% resolved `input', the `ctx', the `tool_call_id', and the `reply_to' pid.
start(Opts) when is_map(Opts) ->
    {Pid, MRef} = spawn_monitor(fun() -> run(Opts) end),
    {ok, Pid, MRef}.

%% Branch on which adapter opts the worker received. With a `module' it runs the
%% in-BEAM tool. With an `executable' and `argv' it runs an external program
%% through a port. Both replies carry the same shape the run waits on, so the run
%% does not tell a cli success from an erlang_module one.
run(#{module := Module} = Opts) ->
    Input = maps:get(input, Opts),
    Ctx = maps:get(ctx, Opts),
    ToolCallId = maps:get(tool_call_id, Opts),
    ReplyTo = maps:get(reply_to, Opts),
    Result = normalize_erlang_module_result(Module:invoke(Input, Ctx)),
    ReplyTo ! {tool_result, ToolCallId, self(), Result},
    ok;
run(#{executable := Executable, argv := Argv} = Opts) ->
    Input = maps:get(input, Opts),
    ToolCallId = maps:get(tool_call_id, Opts),
    ReplyTo = maps:get(reply_to, Opts),
    AppendInput = maps:get(append_input, Opts, true),
    Result = run_cli(Executable, Argv, Input, AppendInput, ToolCallId, ReplyTo),
    ReplyTo ! {tool_result, ToolCallId, self(), Result},
    ok.

%% Launch the external program through a port -- no shell, so each argv element
%% reaches the program as one literal argument. No-placeholder cli descriptors
%% keep the original `argv ++ [InputArg]' protocol. Descriptors whose argv was
%% fully prepared from placeholders skip that trailing compatibility argument.
%% Collect the program's stdout and reply `{ok, Stdout}' on exit status 0.
%%
%% Before blocking in `collect_cli/2', report the spawned child's OS pid up to the
%% run. `exit(WorkerPid, kill)' is untrappable, so this worker gets no chance to
%% reap its child on teardown; the run -- which outlives the worker -- holds the
%% OS pid and kills it when the run times out or is cancelled. Reporting the OS
%% pid as the worker's first act keeps the run holding it for the whole step.
run_cli(Executable, Argv, Input, AppendInput, ToolCallId, ReplyTo) ->
    Args = [render_arg(A) || A <- Argv] ++ input_args(AppendInput, Input),
    case open_cli_port(Executable, Args) of
        {ok, Port} ->
            await_cli(Port, ToolCallId, ReplyTo);
        {error, Reason} ->
            {error, Reason}
    end.

input_args(false, _Input) ->
    [];
input_args(true, Input) ->
    [render_input(Input)].

%% Open the port for the external program, catching the raise `open_port' makes
%% when the executable cannot be spawned. The raise kills the worker and is
%% reported to the run as a raw port exception through the monitor's `'DOWN''
%% path; catching it lets the worker return a named `{error, Reason}' instead.
%% `open_port' does not expose a stable, distinct error term for the
%% missing-path versus not-executable cases, so the failure path stats the file
%% to tell them apart (the happy path never stats): a path that is not a file is
%% the missing case; a path that is a file but still failed to spawn is the
%% permission / not-executable case.
open_cli_port(Executable, Args) ->
    try
        Port = open_port({spawn_executable, Executable},
                         [{args, Args}, {env, minimal_env()},
                          {cd, adapter_cwd()}, exit_status,
                          binary, use_stdio, stderr_to_stdout]),
        {ok, Port}
    catch
        error:_ ->
            case filelib:is_file(Executable) of
                false ->
                    {error, {cli_executable_not_found, Executable}};
                true ->
                    {error, {cli_executable_not_executable, Executable}}
            end
    end.

%% Build the minimal environment for a cli child. `open_port''s `{env, _}' is
%% additive over the inherited environment, so a minimal env means unsetting
%% every inherited variable (each cleared with the `false' value) except the
%% small allowed set the adapter keeps. For v0.1 the allowed set is just `PATH',
%% taken from the runtime's own `PATH' so `#!/bin/sh' helpers can still find
%% `printf', `tr', `sleep', and `touch'. A runtime variable not on this list is
%% absent in the child.
minimal_env() ->
    Cleared = [{Name, false} || {Name, _Value} <- os:env(),
                                Name =/= "PATH"],
    case os:getenv("PATH") of
        false -> Cleared;
        Path -> [{"PATH", Path} | Cleared]
    end.

%% The fixed working directory the adapter sets for every cli child. It is a
%% stable, adapter-chosen directory that is not the runtime process cwd, so the
%% child never inherits the directory the BEAM happens to sit in. The system
%% temp directory satisfies this for v0.1: it exists, is writable, and is not
%% where the runtime was started. Per-tool cwd is out of scope for this issue.
adapter_cwd() ->
    Dir = filename:basedir(user_cache, "soma_cli"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

await_cli(Port, ToolCallId, ReplyTo) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} ->
            ReplyTo ! {tool_started_os_pid, ToolCallId, self(), OsPid};
        undefined ->
            ok
    end,
    collect_cli(Port, [], 0).

%% Collect the program's merged stdout/stderr until it exits. A clean exit
%% (status 0) returns the full captured output as `{ok, Output}'. A non-zero exit
%% returns `{error, {cli_exit_status, N, Excerpt}}' so the run fails with the exit
%% status in the payload instead of blocking forever (the old code matched only
%% status 0, so a non-zero exit fell through to the per-step timeout). `Excerpt'
%% is the captured merged output.
%%
%% The loop carries a running byte count alongside the accumulator. When the
%% bytes seen exceed `?CLI_OUTPUT_LIMIT' before the program exits, the worker
%% stops collecting, kills the port, and returns
%% `{error, {cli_output_limit_exceeded, Limit}}' -- it does not keep buffering
%% past the limit, so a program that floods output cannot make the worker buffer
%% the whole stream in memory.
collect_cli(Port, Acc, Bytes) ->
    receive
        {Port, {data, Data}} ->
            Bytes1 = Bytes + byte_size(Data),
            case Bytes1 > ?CLI_OUTPUT_LIMIT of
                true ->
                    try erlang:port_close(Port) catch _:_ -> ok end,
                    {error, {cli_output_limit_exceeded, ?CLI_OUTPUT_LIMIT}};
                false ->
                    collect_cli(Port, [Data | Acc], Bytes1)
            end;
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, N}} ->
            Excerpt = iolist_to_binary(lists:reverse(Acc)),
            {error, {cli_exit_status, N, Excerpt}}
    end.

%% Render one argv element as a flat string for the port. argv elements are
%% authored as strings or binaries; both pass through as the literal argument the
%% program receives.
render_arg(Arg) when is_binary(Arg) ->
    binary_to_list(Arg);
render_arg(Arg) when is_list(Arg) ->
    Arg.

%% Render the step's resolved input as the single trailing argv argument. A
%% binary or string is the input bytes verbatim; any other resolved term is
%% rendered to a printable form so the program always receives one argument.
render_input(Input) when is_binary(Input) ->
    binary_to_list(Input);
render_input(Input) when is_list(Input) ->
    Input;
render_input(Input) ->
    lists:flatten(io_lib:format("~p", [Input])).

normalize_erlang_module_result({ok, _Output} = Result) ->
    Result;
normalize_erlang_module_result({error, _Reason} = Result) ->
    Result;
normalize_erlang_module_result(_Other) ->
    {error, invalid_tool_return}.
