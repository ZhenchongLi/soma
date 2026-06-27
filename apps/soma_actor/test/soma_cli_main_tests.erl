%% @doc CLI.5 `soma_cli_main:dispatch/1' malformed-argv proofs. No subcommand at
%% all, an unknown subcommand, or a subcommand missing its required positional
%% must print a usage message to stderr, leave stdout clean, and return a
%% non-zero exit code. Hermetic: no daemon, no socket, no network -- the malformed
%% argv never reaches a `soma_cli:*' client, so dispatch returns from the usage
%% path alone. stdout and stderr are captured separately by swapping in recording
%% IO servers for the group leader (stdout) and the `standard_error' process.
-module(soma_cli_main_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion #14: an unknown subcommand, a missing required argument, or no
%% subcommand at all prints a usage message to stderr and returns a non-zero exit
%% code, with stdout free of diagnostics. Each malformed argv is dispatched with
%% stdout and stderr captured separately: the return must be a non-zero integer,
%% stderr must carry a "usage" line, and stdout must stay empty.
test_dispatch_malformed_prints_usage_nonzero() ->
    Cases = [[], ["bogus"], ["run"]],
    lists:foreach(fun(Argv) ->
        {Exit, Stdout, Stderr} = capture_dispatch(Argv),
        %% Non-zero integer exit code.
        ?assert(is_integer(Exit)),
        ?assert(Exit =/= 0),
        %% stdout stays free of diagnostics.
        ?assertEqual(<<>>, Stdout),
        %% stderr carries a usage message.
        ?assertMatch({match, _},
                     re:run(Stderr, "usage", [caseless, {capture, first}]))
    end, Cases).

dispatch_malformed_prints_usage_nonzero_test() ->
    test_dispatch_malformed_prints_usage_nonzero().

%% Criterion #15: `dispatch/1' returns an integer rather than crashing or
%% badmatching on any malformed input -- the criterion-14 set (no subcommand,
%% an unknown subcommand, a known subcommand missing its required positional)
%% plus an unknown flag and a `--socket' with no following value. Each is
%% dispatched with stdout/stderr captured so the usage write cannot leak into
%% the runner; the return must be an integer for every case.
test_dispatch_malformed_returns_integer() ->
    Cases = [[],
             ["bogus"],
             ["run"],
             ["run", "f", "--bogus"],
             ["run", "f", "--socket"]],
    lists:foreach(fun(Argv) ->
        {Exit, _Stdout, _Stderr} = capture_dispatch(Argv),
        ?assert(is_integer(Exit))
    end, Cases).

dispatch_malformed_returns_integer_test() ->
    test_dispatch_malformed_returns_integer().

%% Run `soma_cli_main:dispatch(Argv)' with stdout and stderr each routed to a
%% recording IO server, returning `{Exit, StdoutBin, StderrBin}'. The group
%% leader stands in for stdout; the `standard_error' registered process is
%% temporarily swapped for a recorder so `io:*(standard_error, ...)' is captured
%% and restored afterward.
capture_dispatch(Argv) ->
    Out = start_recorder(),
    Err = start_recorder(),
    PrevGl = group_leader(),
    PrevErr = whereis(standard_error),
    group_leader(Out, self()),
    swap_standard_error(Err),
    try
        Exit = soma_cli_main:dispatch(Argv),
        {Exit, recorder_bytes(Out), recorder_bytes(Err)}
    after
        group_leader(PrevGl, self()),
        swap_standard_error(PrevErr),
        stop_recorder(Out),
        stop_recorder(Err)
    end.

%% Re-register `standard_error' to point at `Pid', tolerating it not being
%% registered yet. Returns ok.
swap_standard_error(Pid) ->
    try unregister(standard_error) catch error:badarg -> true end,
    case Pid of
        undefined -> ok;
        _ -> register(standard_error, Pid), ok
    end.

%% A minimal IO server that accumulates `put_chars' writes so the test can read
%% back what was printed to it.
start_recorder() ->
    spawn(fun() -> recorder_loop([]) end).

recorder_bytes(Pid) ->
    Pid ! {bytes, self()},
    receive {bytes, B} -> B after 5000 -> erlang:error(recorder_no_reply) end.

stop_recorder(Pid) ->
    Pid ! stop,
    ok.

recorder_loop(Acc) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, Acc1} = recorder_answer(Request, Acc),
            From ! {io_reply, ReplyAs, Reply},
            recorder_loop(Acc1);
        {bytes, From} ->
            From ! {bytes, iolist_to_binary(lists:reverse(Acc))},
            recorder_loop(Acc);
        stop ->
            ok;
        _Other ->
            recorder_loop(Acc)
    end.

recorder_answer({put_chars, _Enc, Chars}, Acc) ->
    {ok, [Chars | Acc]};
recorder_answer({put_chars, _Enc, M, F, A}, Acc) ->
    {ok, [apply(M, F, A) | Acc]};
recorder_answer({put_chars, Chars}, Acc) ->
    {ok, [Chars | Acc]};
recorder_answer({put_chars, M, F, A}, Acc) ->
    {ok, [apply(M, F, A) | Acc]};
recorder_answer(_Other, Acc) ->
    {ok, Acc}.
