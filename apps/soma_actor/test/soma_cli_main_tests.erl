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

%% Criterion (#199): `soma daemon' must not crash when config selects a real
%% provider but the daemon environment lacks `SOMA_LLM_API_KEY'. It returns a
%% non-zero code and prints a stderr diagnostic naming the missing env var before
%% any foreground listener can block the CLI.
test_daemon_missing_api_key_prints_diagnostic_nonzero() ->
    ConfigPath = write_temp_config(
                   "[llm]\n"
                   "provider = \"openai_compat\"\n"
                   "base_url = \"api.example/v1\"\n"
                   "model = \"deepseek-v4\"\n"),
    SocketPath = temp_socket_path(),
    PrevConfig = os:getenv("SOMA_CONFIG"),
    PrevKey = os:getenv("SOMA_LLM_API_KEY"),
    os:putenv("SOMA_CONFIG", ConfigPath),
    os:unsetenv("SOMA_LLM_API_KEY"),
    try
        {Exit, Stdout, Stderr} =
            capture_dispatch(["daemon", "--socket", SocketPath]),
        ?assert(is_integer(Exit)),
        ?assert(Exit =/= 0),
        ?assertEqual(<<>>, Stdout),
        ?assertMatch({match, _},
                     re:run(Stderr, "SOMA_LLM_API_KEY", [{capture, first}]))
    after
        restore_env("SOMA_CONFIG", PrevConfig),
        restore_env("SOMA_LLM_API_KEY", PrevKey),
        file:delete(SocketPath),
        file:delete(ConfigPath)
    end.

daemon_missing_api_key_prints_diagnostic_nonzero_test() ->
    test_daemon_missing_api_key_prints_diagnostic_nonzero().

%% Issue #196 criterion 1: a socket path containing shell metacharacters must
%% not be interpreted by the daemon auto-start path. This exercises the real
%% `main_argv/0' auto-start entry in a child BEAM with `SOMA_SELF=/bin/true';
%% if the socket path is interpolated into a shell command, the embedded `touch'
%% creates `Marker'.
test_daemon_autostart_socket_metacharacters_do_not_execute_command() ->
    Marker = filename:join("/tmp",
                           "soma_cli_main_injected_"
                           ++ os:getpid() ++ "_"
                           ++ integer_to_list(erlang:unique_integer([positive]))),
    Socket = filename:join("/tmp",
                           "soma_cli_main_sock_"
                           ++ os:getpid() ++ "_"
                           ++ integer_to_list(erlang:unique_integer([positive]))
                           ++ "\"; touch " ++ Marker ++ "; #.sock"),
    PrevSelf = os:getenv("SOMA_SELF"),
    os:putenv("SOMA_SELF", "/bin/true"),
    file:delete(Marker),
    try
        _ = run_main_argv_subprocess(["status", "missing",
                                      "--socket", Socket]),
        timer:sleep(100),
        ?assertEqual({error, enoent}, file:read_file_info(Marker))
    after
        restore_env("SOMA_SELF", PrevSelf),
        file:delete(Marker),
        file:delete(Socket)
    end.

daemon_autostart_socket_metacharacters_do_not_execute_command_test_() ->
    {timeout, 15,
     fun test_daemon_autostart_socket_metacharacters_do_not_execute_command/0}.

%% Review finding (#237): every packaged tool-management verb is a client verb,
%% so it must take the same cold-start path as run/ask/status/cancel/trace. Build
%% a release-shaped tree from the exact `scripts/soma' overlay plus this test
%% profile's application libs, then drive the wrapper as an external executable.
%% Each command starts with no listener: list boots a daemon, register boots a
%% fresh daemon and persists a tool, and remove boots once more, reloads that
%% tool, and removes it. This catches omissions in `main_argv/0' that direct
%% `dispatch/1' and socket-client tests cannot see.
test_packaged_tool_verbs_autostart_daemon() ->
    Base = filename:join(
             tmp_dir(),
             "soma_cli_packaged_tools_" ++ os:getpid() ++ "_"
             ++ integer_to_list(erlang:unique_integer([positive]))),
    Release = filename:join(Base, "somad"),
    BinDir = filename:join(Release, "bin"),
    Wrapper = filename:join(BinDir, "soma"),
    LibLink = filename:join(Release, "lib"),
    Home = filename:join(Base, "home"),
    Runtime = filename:join(Base, "runtime"),
    Socket = filename:join(Runtime, "soma.sock"),
    Config = filename:join(Base, "soma.config"),
    Manifest = filename:join(Base, "cold_tool.lisp"),
    ToolsDir = filename:join([Home, ".soma", "tools"]),
    Persisted = filename:join(ToolsDir, "cold_tool.lisp"),
    RepoRoot = repo_root(),
    SourceWrapper = filename:join([RepoRoot, "scripts", "soma"]),
    TestLibRoot = filename:dirname(code:lib_dir(soma_actor)),
    ok = filelib:ensure_dir(filename:join(BinDir, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Home, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Runtime, "placeholder")),
    {ok, _} = file:copy(SourceWrapper, Wrapper),
    ok = file:change_mode(Wrapper, 8#755),
    ok = file:make_symlink(TestLibRoot, LibLink),
    ok = file:write_file(Config, <<"# hermetic: no llm config\n">>),
    ok = file:write_file(
           Manifest,
           <<"(tool\n"
             "  (name \"cold_tool\")\n"
             "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
             "  (adapter cli)\n"
             "  (executable \"/bin/echo\")\n"
             "  (argv \"hello\"))\n">>),
    Env = [{"HOME", Home},
           {"XDG_RUNTIME_DIR", Runtime},
           {"SOMA_CONFIG", Config},
           {"ERL_CRASH_DUMP", filename:join(Base, "erl_crash.dump")}],
    try
        ListPort = start_packaged_soma(
                     Wrapper, ["tool", "list", "--socket", Socket], Env),
        {ok, _ListOutput} =
            collect_port_until(ListPort, <<"(tool-list">>, []),
        ok = stop_daemon_over_socket(Socket),
        {0, _} = collect_port(ListPort, []),

        RegisterPort = start_packaged_soma(
                         Wrapper,
                         ["tool", "register", Manifest,
                          "--socket", Socket], Env),
        {ok, _RegisterOutput} =
            collect_port_until(RegisterPort, <<"(status registered)">>, []),
        true = filelib:is_regular(Persisted),
        ok = stop_daemon_over_socket(Socket),
        {0, _} = collect_port(RegisterPort, []),

        RemovePort = start_packaged_soma(
                       Wrapper,
                       ["tool", "remove", "cold_tool",
                        "--socket", Socket], Env),
        {ok, _RemoveOutput} =
            collect_port_until(RemovePort, <<"(status removed)">>, []),
        false = filelib:is_regular(Persisted),
        ok = stop_daemon_over_socket(Socket),
        {0, _} = collect_port(RemovePort, [])
    after
        _ = maybe_stop_daemon_over_socket(Socket),
        _ = file:delete(LibLink),
        _ = file:del_dir_r(Base)
    end.

packaged_tool_verbs_autostart_daemon_test_() ->
    {timeout, 90, fun test_packaged_tool_verbs_autostart_daemon/0}.

%% A self-contained relx tree carries its own ERTS but does not carry the OTP
%% installation's `bin/start.boot'.  The wrapper must therefore select relx's
%% release-local `bin/no_dot_erlang.boot' before starting the one-shot client.
%% A release-shaped tree with a recording `erl' executable proves the exact
%% argv without booting a VM or daemon.
test_packaged_wrapper_selects_release_boot() ->
    Base = filename:join(
             tmp_dir(),
             "soma_cli_packaged_boot_" ++ os:getpid() ++ "_"
             ++ integer_to_list(erlang:unique_integer([positive]))),
    Release = filename:join(Base, "somad"),
    BinDir = filename:join(Release, "bin"),
    ErtsBin = filename:join([Release, "erts-17.0.3", "bin"]),
    Wrapper = filename:join(BinDir, "soma"),
    RecordingErl = filename:join(ErtsBin, "erl"),
    Capture = filename:join(Base, "erl.argv"),
    Boot = filename:join(BinDir, "no_dot_erlang"),
    SourceWrapper = filename:join([repo_root(), "scripts", "soma"]),
    ok = filelib:ensure_dir(filename:join(BinDir, "placeholder")),
    ok = filelib:ensure_dir(filename:join(ErtsBin, "placeholder")),
    ok = filelib:ensure_dir(
           filename:join([Release, "lib", "placeholder", "ebin", "x"])),
    {ok, _} = file:copy(SourceWrapper, Wrapper),
    ok = file:change_mode(Wrapper, 8#755),
    ok = file:write_file(Boot ++ ".boot", <<"release boot fixture">>),
    ok = file:write_file(
           RecordingErl,
           <<"#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$SOMA_ARGV_CAPTURE\"\n">>),
    ok = file:change_mode(RecordingErl, 8#755),
    try
        Port = start_packaged_soma(
                 Wrapper, [], [{"SOMA_ARGV_CAPTURE", Capture}]),
        {0, <<>>} = collect_port(Port, []),
        {ok, Captured} = file:read_file(Capture),
        [<<"-boot">>, BootBin, <<"-noshell">> | _] =
            binary:split(Captured, <<"\n">>, [global, trim_all]),
        ?assertEqual(unicode:characters_to_binary(Boot), BootBin)
    after
        _ = file:del_dir_r(Base)
    end.

packaged_wrapper_selects_release_boot_test_() ->
    {timeout, 15, fun test_packaged_wrapper_selects_release_boot/0}.

%% Criterion #16: `soma_cli_main:main(Argv)' halts the OS process with the
%% `dispatch/1' integer as the exit status, and routes any diagnostics to
%% stderr. A real `halt/1' would kill the test runner, so this is a
%% source-structure assertion over `soma_cli_main.erl': `main/1' is exported,
%% a `main/1' clause exists, it threads `dispatch/1''s result straight into
%% `halt/1' (the whitespace-collapsed source contains `halt(dispatch('), and
%% the source's only diagnostic write target is `standard_error' -- there is no
%% `io:put_chars'/`io:format' to stdout or the bare group leader.
test_main_halts_with_dispatch_code() ->
    Src = read_main_source(),
    Collapsed = collapse_ws(Src),
    %% `main/1' is exported.
    ?assertMatch({match, _},
                 re:run(Collapsed, "-export\\(\\[[^\\]]*main/1", [{capture, first}])),
    %% A `main/1' clause is defined.
    ?assertMatch({match, _},
                 re:run(Collapsed, "main\\(", [{capture, first}])),
    %% `dispatch/1''s result is threaded straight into `halt/1'.
    ?assertMatch({match, _},
                 re:run(Collapsed, "halt\\(dispatch\\(", [{capture, first}])),
    %% Every diagnostic write goes to `standard_error': every `io:put_chars(' and
    %% every `io:format(' names `standard_error' as its first argument. (Count of
    %% bare put_chars/format calls must equal the count of standard_error ones.)
    AllPutChars = count_src(Src, <<"io:put_chars(">>),
    ErrPutChars = count_src(Src, <<"io:put_chars(standard_error">>),
    ?assertEqual({put_chars, AllPutChars}, {put_chars, ErrPutChars}),
    AllFormat = count_src(Src, <<"io:format(">>),
    ErrFormat = count_src(Src, <<"io:format(standard_error">>),
    ?assertEqual({format, AllFormat}, {format, ErrFormat}).

main_halts_with_dispatch_code_test() ->
    test_main_halts_with_dispatch_code().

%% Read the `soma_cli_main.erl' source under the app's `src/' directory. Under
%% EUnit `code:lib_dir(soma_actor)' points at `_build/test/lib/soma_actor',
%% whose `src/' subdir holds the copied module source.
read_main_source() ->
    Path = filename:join([code:lib_dir(soma_actor), "src", "soma_cli_main.erl"]),
    {ok, Src} = file:read_file(Path),
    Src.

%% Collapse every run of whitespace to nothing, so a structural match like
%% `halt(dispatch(' tolerates any inter-token spacing/newlines in the source.
collapse_ws(Src) ->
    re:replace(Src, "\\s+", "", [global, {return, binary}]).

count_src(Src, Needle) ->
    length(binary:matches(Src, Needle)).

write_temp_config(Contents) ->
    Path = filename:join(tmp_dir(),
                         "soma_cli_main_config_"
                         ++ os:getpid() ++ "_"
                         ++ integer_to_list(erlang:unique_integer([positive]))
                         ++ ".toml"),
    ok = file:write_file(Path, Contents),
    Path.

temp_socket_path() ->
    filename:join(tmp_dir(),
                  "soma_cli_main_"
                  ++ os:getpid() ++ "_"
                  ++ integer_to_list(erlang:unique_integer([positive]))
                  ++ ".sock").

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Dir -> Dir
    end.

restore_env(Key, false) ->
    os:unsetenv(Key);
restore_env(Key, Value) ->
    os:putenv(Key, Value).

run_main_argv_subprocess(PlainArgv) ->
    Erl = os:find_executable("erl"),
    ?assert(is_list(Erl)),
    CrashDump = filename:join(
                  tmp_dir(),
                  "soma_cli_main_child_crash_" ++ os:getpid() ++ "_"
                  ++ integer_to_list(erlang:unique_integer([positive]))
                  ++ ".dump"),
    Port = open_port({spawn_executable, Erl},
                     [binary, exit_status, stderr_to_stdout, use_stdio,
                      {args, erl_main_argv_args(PlainArgv)},
                      {env, [{"ERL_CRASH_DUMP", CrashDump}]}]),
    try collect_port(Port, [])
    after
        _ = file:delete(CrashDump)
    end.

start_packaged_soma(Wrapper, Argv, Env) ->
    open_port({spawn_executable, Wrapper},
              [binary, exit_status, stderr_to_stdout, use_stdio,
               {args, Argv}, {env, Env}]).

%% The detached daemon inherits the outer test port's output descriptor. Read
%% the client reply first, stop through the real socket, and only then wait for
%% the packaged client's exit status; stopping closes the inherited descriptor.
stop_daemon_over_socket(Socket) ->
    {ok, Sock} = gen_tcp:connect({local, Socket}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(stop)">>),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 10000),
    ok = gen_tcp:close(Sock),
    match = re:run(Reply, "\\(status stopped\\)", [{capture, none}]),
    wait_until_path_absent(Socket, 80).

maybe_stop_daemon_over_socket(Socket) ->
    case file:read_file_info(Socket) of
        {ok, _} ->
            try stop_daemon_over_socket(Socket)
            catch _:_ -> ok
            end;
        {error, enoent} ->
            ok;
        {error, _} ->
            ok
    end.

wait_until_path_absent(_Path, 0) ->
    {error, socket_not_removed};
wait_until_path_absent(Path, N) ->
    case file:read_file_info(Path) of
        {error, enoent} -> ok;
        _ ->
            timer:sleep(25),
            wait_until_path_absent(Path, N - 1)
    end.

repo_root() ->
    filename:dirname(
      filename:dirname(
        filename:dirname(
          filename:dirname(code:lib_dir(soma_actor))))).

collect_port_until(Port, Needle, Acc) ->
    receive
        {Port, {data, Data}} ->
            Acc1 = [Data | Acc],
            Output = iolist_to_binary(lists:reverse(Acc1)),
            case binary:match(Output, Needle) of
                nomatch -> collect_port_until(Port, Needle, Acc1);
                _ -> {ok, Output}
            end;
        {Port, {exit_status, Status}} ->
            {error, {early_exit, Status,
                     iolist_to_binary(lists:reverse(Acc))}}
    after 30000 ->
        erlang:error(cli_subprocess_reply_timeout)
    end.

erl_main_argv_args(PlainArgv) ->
    ["-noshell"] ++ code_path_args(code:get_path())
        ++ ["-s", "soma_cli_main", "main_argv", "-extra"] ++ PlainArgv.

code_path_args(Paths) ->
    lists:append([["-pa", Path] || Path <- Paths]).

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    after 30000 ->
        erlang:error(cli_subprocess_timeout)
    end.

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
