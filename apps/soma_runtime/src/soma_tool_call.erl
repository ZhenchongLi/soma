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

%% Branch on which adapter opts the worker received. With a `module' it runs the
%% in-BEAM tool. With an `executable' and `argv' it runs an external program
%% through a port. Both replies carry the same shape the run waits on, so the run
%% does not tell a cli success from an erlang_module one.
run(#{module := Module} = Opts) ->
    Input = maps:get(input, Opts),
    Ctx = maps:get(ctx, Opts),
    ToolCallId = maps:get(tool_call_id, Opts),
    ReplyTo = maps:get(reply_to, Opts),
    Result = Module:invoke(Input, Ctx),
    ReplyTo ! {tool_result, ToolCallId, self(), Result},
    ok;
run(#{executable := Executable, argv := Argv} = Opts) ->
    Input = maps:get(input, Opts),
    ToolCallId = maps:get(tool_call_id, Opts),
    ReplyTo = maps:get(reply_to, Opts),
    Result = run_cli(Executable, Argv, Input),
    ReplyTo ! {tool_result, ToolCallId, self(), Result},
    ok.

%% Launch the external program with `argv ++ [InputArg]' through a port -- no
%% shell, so each argv element reaches the program as one literal argument. The
%% step's resolved input travels as the final argument (the port cannot half-close
%% the child's stdin, so a stdin-reading helper would hang). Collect the program's
%% stdout and reply `{ok, Stdout}' on exit status 0.
run_cli(Executable, Argv, Input) ->
    Args = [render_arg(A) || A <- Argv] ++ [render_input(Input)],
    Port = open_port({spawn_executable, Executable},
                     [{args, Args}, exit_status, binary, use_stdio,
                      stderr_to_stdout]),
    collect_cli(Port, []).

collect_cli(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_cli(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))}
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
