-module(soma_cli_dispatch_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_dispatch_run_file_completed_exit_zero/1]).
-export([test_dispatch_run_dash_reads_stdin/1]).
-export([test_dispatch_ask_completed_exit_zero/1]).
-export([test_dispatch_status_read_exit_zero/1]).
-export([test_dispatch_trace_read_exit_zero/1]).
-export([test_dispatch_cancel_running_task_exit_zero/1]).
-export([test_dispatch_run_detach_marks_request/1]).
-export([test_dispatch_ask_detach_marks_request/1]).
-export([test_dispatch_socket_override_wins/1]).
-export([test_dispatch_ask_intent_with_quotes_round_trips/1]).
-export([test_dispatch_stop_running_daemon_exit_zero/1]).

all() ->
    [test_dispatch_run_file_completed_exit_zero,
     test_dispatch_run_dash_reads_stdin,
     test_dispatch_ask_completed_exit_zero,
     test_dispatch_status_read_exit_zero,
     test_dispatch_trace_read_exit_zero,
     test_dispatch_cancel_running_task_exit_zero,
     test_dispatch_run_detach_marks_request,
     test_dispatch_ask_detach_marks_request,
     test_dispatch_socket_override_wins,
     test_dispatch_ask_intent_with_quotes_round_trips,
     test_dispatch_stop_running_daemon_exit_zero].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    %% The ask path drives the decision loop through an actor under
    %% soma_actor_sup; keep the sup up so every dispatch case is self-contained
    %% even though criterion 1 only exercises `run'. Tolerate an already-running
    %% sup.
    Sup = case soma_actor_sup:start_link() of
              {ok, Pid} -> Pid;
              {error, {already_started, Pid}} -> Pid
          end,
    %% Point the resolver at a unique per-run XDG_RUNTIME_DIR so a separately
    %% resolved client and the server we boot land on the same socket without a
    %% `--socket' override. The dir name is uniquified by os:getpid() (stable
    %% within a BEAM run, distinct across runs -- see the cross-BEAM path
    %% collision note) plus a per-call unique integer; we restore the prior env
    %% in teardown.
    PrevXdg = os:getenv("XDG_RUNTIME_DIR"),
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    XdgDir = filename:join(Tmp,
                           "soma_cli_dispatch_" ++ os:getpid() ++ "_"
                           ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(XdgDir, "x")),
    Path = filename:join(XdgDir, "soma.sock"),
    _ = file:delete(Path),
    os:putenv("XDG_RUNTIME_DIR", XdgDir),
    [{started_apps, Started}, {actor_sup, Sup},
     {prev_xdg, PrevXdg}, {xdg_dir, XdgDir}, {socket_path, Path} | Config].

end_per_testcase(_Case, Config) ->
    case ?config(prev_xdg, Config) of
        false -> os:unsetenv("XDG_RUNTIME_DIR");
        Prev -> os:putenv("XDG_RUNTIME_DIR", Prev)
    end,
    _ = file:delete(?config(socket_path, Config)),
    ok.

%% Criterion 1 (CLI.5): `soma_cli_main:dispatch(["run", File])' runs the workflow
%% file through the daemon on the resolved socket, prints the `(result ...)' reply
%% to stdout, and returns the same exit code as `soma_cli:run/1' -- 0 only when
%% the reply carries `(status completed)'. The full chain runs against a real
%% `soma_cli_server' on a unique per-run socket; the dispatcher resolves that
%% socket itself (no `--socket' override). Process survival is asserted: after the
%% dispatch returns, the same server still serves a fresh client request.
test_dispatch_run_file_completed_exit_zero(Config) ->
    Path = ?config(socket_path, Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    File = filename:join(?config(priv_dir, Config), "dispatch_echo.lfe"),
    ok = file:write_file(File, <<"(run (step s1 echo (args (value \"hi\"))))">>),

    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["run", File]),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),

    %% The printed reply is the completed echo `(result ...)' s-expr, proving the
    %% dispatcher resolved the socket and drove the full run through the daemon.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    %% A completed run returns exit code 0 (mirroring `soma_cli:run/1').
    0 = Exit,

    %% Process survival: the server still serves a subsequent request after the
    %% dispatch returned.
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(run (step s2 echo (args (value \"again\"))))">>),
    {ok, Reply2} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    match = re:run(Reply2, "\\(status completed\\)", [{capture, none}]).

%% Criterion 2 (CLI.5): `soma_cli_main:dispatch(["run", "-"])' reads the workflow
%% from stdin instead of a file, drives it through the daemon on the resolved
%% socket, prints the `(result ...)' reply to stdout, and returns 0 for a
%% completed echo run. The `-' positional reaches `soma_cli:run/1''s
%% `read_source("-")' stdin path. A fake IO server stands in for the child's
%% group leader so the workflow bytes are the redirected stdin, not a file. The
%% dispatcher resolves the socket itself (no `--socket' override). Process
%% survival is asserted: the same server still serves a fresh request afterward.
test_dispatch_run_dash_reads_stdin(Config) ->
    Path = ?config(socket_path, Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    Workflow = <<"(run (step s1 echo (args (value \"hi\"))))">>,
    Parent = self(),
    %% A fake IO server feeds `Workflow' on `get_chars' (stdin) and records
    %% `put_chars' (stdout). Running dispatch(["run", "-"]) with this IO as group
    %% leader must read the workflow from stdin, not a file.
    IO = stdin_io_server(Workflow),
    Child = spawn(fun() ->
        group_leader(IO, self()),
        Exit = soma_cli_main:dispatch(["run", "-"]),
        Parent ! {result, Exit}
    end),
    Exit =
        receive
            {result, E} -> E
        after 60000 ->
            exit(Child, kill),
            ct:fail(stdin_dispatch_timed_out)
        end,
    Printed = iolist_to_binary(io_server_output(IO)),
    %% The reply printed must be the completed echo `(result ...)' s-expr, proving
    %% the workflow read from stdin reached the daemon and ran.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Printed, "\\(s1 \\(value \"hi\"\\)\\)", [{capture, none}]),
    %% A completed stdin run returns exit code 0 (mirroring `soma_cli:run/1').
    0 = Exit,

    %% Process survival: the server still serves a subsequent request.
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(run (step s2 echo (args (value \"again\"))))">>),
    {ok, Reply2} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    match = re:run(Reply2, "\\(status completed\\)", [{capture, none}]).

%% Criterion 3 (CLI.5): `soma_cli_main:dispatch(["ask", Intent])' drives
%% `soma_cli:ask/1' on the resolved socket and returns its exit code. The server is
%% booted with a mock `model_config' whose `proposal' directive yields a `reply'
%% proposal, so the daemon's decision loop completes and replies with a `(result
%% ...)' s-expr carrying `(status completed)'. The dispatcher resolves the socket
%% itself (no `--socket' override). The printed reply proves the intent reached the
%% daemon and ran, and the exit code mirrors `ask/1' (0 for a completed ask).
%% Process survival is asserted: the same server still serves a fresh request after
%% the dispatch returns.
test_dispatch_ask_completed_exit_zero(Config) ->
    Path = ?config(socket_path, Config),
    %% Mock model_config: a `proposal' directive whose output is a `reply'
    %% proposal carrying the answer text -- the server config shape the daemon ask
    %% suites use so the decision loop completes without a real provider.
    ModelConfig = #{directive => proposal,
                    output => #{kind => reply, text => <<"the answer">>}},
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                 model_config => ModelConfig}),

    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["ask", "what is the answer"]),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),

    %% The printed reply is the completed `(result ...)' s-expr carrying the reply
    %% text, proving the dispatcher resolved the socket and drove the full ask
    %% through the daemon.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Printed, "the answer", [{capture, none}]),
    %% A completed ask returns exit code 0 (mirroring `soma_cli:ask/1').
    0 = Exit,

    %% Process survival: the server still serves a subsequent request after the
    %% dispatch returned.
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(run (step s2 echo (args (value \"again\"))))">>),
    {ok, Reply2} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    match = re:run(Reply2, "\\(status completed\\)", [{capture, none}]).

%% Criterion 4 (CLI.5): `soma_cli_main:dispatch(["status", TaskId])' drives
%% `soma_cli:status/1' on the resolved socket and returns 0 on a successful read.
%% The test seeds a real task first by dispatching a one-step echo `run' through
%% the daemon and reading its task id off the printed `(result ...)' reply's
%% `(task-id ...)' sub-form; it then dispatches `["status", TaskId]' against the
%% same server. The dispatcher resolves the socket itself (no `--socket'
%% override). The printed reply is the `(status ...)' s-expr carrying a
%% `(state ...)', and the exit code mirrors `soma_cli:status/1' (0 for a
%% successful read, not gated on `(status completed)'). Process survival is
%% asserted: the same server still serves a fresh request after dispatch returns.
test_dispatch_status_read_exit_zero(Config) ->
    Path = ?config(socket_path, Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    %% Seed a real task: dispatch a one-step echo run and read its task id off the
    %% `(result ...)' reply the dispatcher printed.
    File = filename:join(?config(priv_dir, Config), "status_dispatch_seed.lfe"),
    ok = file:write_file(File, <<"(run (step s1 echo (args (value \"hi\"))))">>),
    ct:capture_start(),
    0 = soma_cli_main:dispatch(["run", File]),
    ct:capture_stop(),
    RunPrinted = iolist_to_binary(ct:capture_get()),
    {match, [TaskId]} =
        re:run(RunPrinted, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, list}]),

    %% Now dispatch the status of that task id against the same server.
    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["status", TaskId]),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),

    %% The printed reply must be the `(status ...)' s-expr carrying a `(state ...)',
    %% proving the dispatcher resolved the socket and drove the read through the
    %% daemon.
    match = re:run(Printed, "^\\(status ", [{capture, none}]),
    match = re:run(Printed, "\\(state ", [{capture, none}]),
    %% A successful read returns exit code 0 (mirroring `soma_cli:status/1').
    0 = Exit,

    %% Process survival: the server still serves a subsequent request after the
    %% dispatch returned.
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(run (step s2 echo (args (value \"again\"))))">>),
    {ok, Reply2} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    match = re:run(Reply2, "\\(status completed\\)", [{capture, none}]).

%% Criterion 5 (CLI.5): `soma_cli_main:dispatch(["trace", CorrId])' drives
%% `soma_cli:trace/1' on the resolved socket and returns 0 on a successful read.
%% The test seeds a real correlation chain first by dispatching a one-step echo
%% `run' through the daemon and reading its correlation id off the printed
%% `(result ...)' reply's `(correlation-id ...)' sub-form; it then dispatches
%% `["trace", CorrId]' against the same server. The dispatcher resolves the socket
%% itself (no `--socket' override). The printed reply is the `(trace ...)' s-expr
%% carrying the chain's event sub-forms, and the exit code mirrors
%% `soma_cli:trace/1' (0 for a successful read, not gated on `(status
%% completed)'). Process survival is asserted: the same server still serves a
%% fresh request after dispatch returns.
test_dispatch_trace_read_exit_zero(Config) ->
    Path = ?config(socket_path, Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    %% Seed a real correlation chain: dispatch a one-step echo run and read its
    %% correlation id off the `(result ...)' reply the dispatcher printed.
    File = filename:join(?config(priv_dir, Config), "trace_dispatch_seed.lfe"),
    ok = file:write_file(File, <<"(run (step s1 echo (args (value \"hi\"))))">>),
    ct:capture_start(),
    0 = soma_cli_main:dispatch(["run", File]),
    ct:capture_stop(),
    RunPrinted = iolist_to_binary(ct:capture_get()),
    {match, [CorrId]} =
        re:run(RunPrinted, "\\(correlation-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, list}]),

    %% Now dispatch the trace of that correlation id against the same server.
    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["trace", CorrId]),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),

    %% The printed reply must be the `(trace ...)' s-expr carrying event
    %% sub-forms, proving the dispatcher resolved the socket and drove the read
    %% through the daemon.
    match = re:run(Printed, "^\\(trace ", [{capture, none}]),
    %% A successful read returns exit code 0 (mirroring `soma_cli:trace/1').
    0 = Exit,

    %% Process survival: the server still serves a subsequent request after the
    %% dispatch returned.
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(run (step s2 echo (args (value \"again\"))))">>),
    {ok, Reply2} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    match = re:run(Reply2, "\\(status completed\\)", [{capture, none}]).

%% Criterion 6 (CLI.5): `soma_cli_main:dispatch(["cancel", TaskId])' drives
%% `soma_cli:cancel/1' on the resolved socket and returns 0 on a successful cancel.
%% The test seeds a real running task first by sending a detached long sleep run
%% over the daemon socket, reading the accepted task id off the `(accepted ...)'
%% reply, and waiting (bounded) for its `tool.started' event so the run is actually
%% in flight; it then dispatches `["cancel", TaskId]' against the same server. The
%% dispatcher resolves the socket itself (no `--socket' override). The printed reply
%% is the `(result ...)' s-expr carrying `(status cancelled)', proving the cancel
%% reached the daemon and stopped the run, and the exit code mirrors
%% `soma_cli:cancel/1' (0 on a successful cancel). Process survival is asserted: the
%% same server still serves a fresh request after dispatch returns.
test_dispatch_cancel_running_task_exit_zero(Config) ->
    Path = ?config(socket_path, Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),

    %% Seed a real running task: a detached long sleep run accepted by the daemon.
    {ok, Seed} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Seed, <<"(run (detach) (step s1 sleep (args (ms 5000))))">>),
    {ok, Accepted} = gen_tcp:recv(Seed, 0, 60000),
    ok = gen_tcp:close(Seed),
    match = re:run(Accepted, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Accepted, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    {ok, #{run_id := RunId}} = soma_cli_task_registry:lookup(TaskId),
    %% Bounded poll until the run is actually in flight before we cancel.
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 100),

    %% Now dispatch the cancel of that task id against the same server. The
    %% dispatch argv is a list of strings, matching how a real CLI hands the
    %% positional through.
    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["cancel", binary_to_list(TaskId)]),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),

    %% The printed reply must be the `(result ...)' s-expr carrying `(status
    %% cancelled)', proving the dispatcher resolved the socket and drove the cancel
    %% through the daemon.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status cancelled\\)", [{capture, none}]),
    %% A successful cancel returns exit code 0 (mirroring `soma_cli:cancel/1').
    0 = Exit,

    %% Process survival: the server still serves a subsequent request after the
    %% dispatch returned.
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(run (step s2 echo (args (value \"again\"))))">>),
    {ok, Reply2} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    match = re:run(Reply2, "\\(status completed\\)", [{capture, none}]).

%% Criterion 7 (CLI.5): `--detach' after `run File' sets `detach => true' in the
%% dispatched args, so the request the client emits carries the literal `(detach)'
%% marker. A `soma_cli_request_capture' stands in for the server on the resolved
%% socket (the same capture pattern `soma_cli_SUITE' uses), so the test reads the
%% actual wire bytes the dispatcher's client sent. The dispatcher resolves the
%% socket itself (no `--socket' override) and lands on the capture's path.
test_dispatch_run_detach_marks_request(Config) ->
    Path = ?config(socket_path, Config),
    File = filename:join(?config(priv_dir, Config), "detach_dispatch_run.lfe"),
    ok = file:write_file(File, <<"(run (step s1 echo (args (value \"hi\"))))">>),
    Capture = soma_cli_request_capture:start(
                Path, <<"(result (status completed))">>),

    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["run", File, "--detach"]),
    ct:capture_stop(),
    _ = ct:capture_get(),
    Request = soma_cli_request_capture:request(Capture),

    %% The emitted request is a `(run ...)' that carries the `(detach)' marker,
    %% proving `--detach' set `detach => true' in the dispatched args.
    match = re:run(Request, "^\\(run ", [{capture, none}]),
    match = re:run(Request, "\\(detach\\)", [{capture, none}]),
    0 = Exit.

%% Criterion 7 (CLI.5): `--detach' after `ask Intent' sets `detach => true' in the
%% dispatched args, so the request the client emits carries the literal `(detach)'
%% marker. A `soma_cli_request_capture' stands in for the server on the resolved
%% socket so the test reads the actual wire bytes. The dispatcher resolves the
%% socket itself (no `--socket' override).
test_dispatch_ask_detach_marks_request(Config) ->
    Path = ?config(socket_path, Config),
    Capture = soma_cli_request_capture:start(
                Path, <<"(result (status completed))">>),

    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["ask", "what is the answer", "--detach"]),
    ct:capture_stop(),
    _ = ct:capture_get(),
    Request = soma_cli_request_capture:request(Capture),

    %% The emitted request is an `(ask ...)' carrying the intent and the `(detach)'
    %% marker, proving `--detach' set `detach => true' in the dispatched args.
    match = re:run(Request, "^\\(ask ", [{capture, none}]),
    match = re:run(Request, "\\(intent \"what is the answer\"\\)",
                   [{capture, none}]),
    match = re:run(Request, "\\(detach\\)", [{capture, none}]),
    0 = Exit.

%% Criterion 8 (CLI.5): `--socket <path>' overrides the resolved socket path for any
%% subcommand. The server is booted on `OverridePath' -- a second unique per-run
%% socket -- while `XDG_RUNTIME_DIR' (set in `init_per_testcase') still points the
%% resolver at a *different* directory whose `soma.sock' has no listener. A
%% `["status", TaskId, "--socket", OverridePath]' dispatch reads a real seeded task
%% successfully, which can only happen if the override path won over the resolver:
%% had the dispatcher used the resolved `XDG_RUNTIME_DIR/soma.sock', the connect would
%% have failed (no server there). Process survival is asserted on the override server.
test_dispatch_socket_override_wins(Config) ->
    %% A second per-run socket, distinct from the resolver's `XDG_RUNTIME_DIR'
    %% `soma.sock', so reaching it proves the `--socket' override beat the resolver.
    XdgDir = ?config(xdg_dir, Config),
    OverridePath = filename:join(XdgDir, "override.sock"),
    _ = file:delete(OverridePath),
    {ok, _Server} = soma_cli_server:start_link(#{socket => OverridePath}),

    %% The resolver's path (XDG/soma.sock) deliberately has no listener; if the
    %% override is ignored the status connect lands here and fails.
    ResolvedPath = ?config(socket_path, Config),
    false = (OverridePath =:= ResolvedPath),

    %% Seed a real task on the override server and read its task id.
    File = filename:join(?config(priv_dir, Config), "override_seed.lfe"),
    ok = file:write_file(File, <<"(run (step s1 echo (args (value \"hi\"))))">>),
    ct:capture_start(),
    0 = soma_cli_main:dispatch(["run", File, "--socket", OverridePath]),
    ct:capture_stop(),
    RunPrinted = iolist_to_binary(ct:capture_get()),
    {match, [TaskId]} =
        re:run(RunPrinted, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, list}]),

    %% Status of that task, with `--socket' overriding the resolver.
    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["status", TaskId, "--socket", OverridePath]),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),

    %% A successful `(status (state ...))' read proves the override path was used --
    %% the resolved path has no server, so this read could only land via `--socket'.
    match = re:run(Printed, "^\\(status ", [{capture, none}]),
    match = re:run(Printed, "\\(state ", [{capture, none}]),
    0 = Exit,

    %% Process survival: the override server still serves a subsequent request.
    {ok, Sock} = gen_tcp:connect({local, OverridePath}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(run (step s2 echo (args (value \"again\"))))">>),
    {ok, Reply2} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    match = re:run(Reply2, "\\(status completed\\)", [{capture, none}]),
    _ = file:delete(OverridePath).

%% Criterion 13 (CLI.5): an `ask' intent that itself contains a `"' (or `\\')
%% must be escaped so the request the dispatcher emits is a valid s-expr the
%% daemon parses, and the original string reaches the daemon intact. Without the
%% escaper the intent `say "hi"' renders as `(ask (intent "say "hi""))', which
%% `soma_lfe' rejects -- the daemon would reply `(status error)' instead of
%% completing the ask. The server is booted with the same mock `model_config' the
%% other ask case uses, so a parseable request drives the decision loop to a
%% completed `(result ...)'. The dispatcher resolves the socket itself (no
%% `--socket' override). Process survival is asserted: the same server still
%% serves a fresh request after the dispatch returns.
test_dispatch_ask_intent_with_quotes_round_trips(Config) ->
    Path = ?config(socket_path, Config),
    ModelConfig = #{directive => proposal,
                    output => #{kind => reply, text => <<"the answer">>}},
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                 model_config => ModelConfig}),

    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["ask", "say \"hi\""]),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),

    %% The intent contained a `"'; the escaper made the emitted request a valid
    %% s-expr, so the daemon parsed the intent (the bytes between the quotes
    %% reaching it as the original `say "hi"') and the decision loop completed.
    %% Without escaping the request is malformed and the reply carries
    %% `(status error)', failing this assertion.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    nomatch = re:run(Printed, "\\(status error\\)", [{capture, none}]),
    0 = Exit,

    %% Round-trip proof that the original string reached the daemon intact: a
    %% `completed' reply (not `error') can only happen if the dispatcher's emitted
    %% request was a valid s-expr whose `(intent "...")' the daemon parsed back to
    %% the literal `say "hi"'. The only escaping applied is the reversible `\\"'
    %% that `soma_lfe' reads back to `"', so the daemon completing the ask means
    %% the original bytes survived the wire intact -- an unescaped intent renders
    %% `(ask (intent "say "hi""))', which `soma_lfe' rejects (the daemon would
    %% reply `(status error)' and this case would fail above).

    %% Process survival: the server still serves a subsequent request after the
    %% dispatch returned.
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(run (step s2 echo (args (value \"again\"))))">>),
    {ok, Reply2} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    match = re:run(Reply2, "\\(status completed\\)", [{capture, none}]).

%% Criterion 8 (CLI.9): `soma_cli_main:dispatch(["stop"])' resolves the socket and
%% drives `soma_cli:stop/1' over it, returning exit code 0 on a successful stop. A
%% real `soma_cli_server' is booted on the unique per-run socket; the dispatcher
%% resolves that socket itself (no `--socket' override). The printed reply is the
%% terminal `(result (status stopped))' s-expr, proving the stop reached the daemon
%% over the resolved socket, and the exit code mirrors `soma_cli:stop/1' (0 on a
%% successful stop). The stop is observed off-chain: after the dispatch returns, the
%% listener has torn down, so the socket file is gone and a fresh connect to the
%% same path fails -- the same teardown observations the sibling stop cases use.
test_dispatch_stop_running_daemon_exit_zero(Config) ->
    Path = ?config(socket_path, Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),

    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["stop"]),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),

    %% The printed reply is the terminal `(result (status stopped))' s-expr,
    %% proving the dispatcher resolved the socket and drove the stop through the
    %% daemon.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status stopped\\)", [{capture, none}]),
    %% A successful stop returns exit code 0 (mirroring `soma_cli:stop/1').
    0 = Exit,

    %% Teardown observation: after the stop, the listener has closed the listen
    %% socket and unlinked the file, so a fresh connect to the same path must fail.
    ok = wait_for_connect_refused(Path, 100).

%% Bounded poll: returns ok once a `{local, Path}' connect is refused (the listener
%% has torn down), retrying up to `N' times with a short sleep between tries.
wait_for_connect_refused(_Path, 0) ->
    {error, still_listening};
wait_for_connect_refused(Path, N) ->
    case gen_tcp:connect({local, Path}, 0,
                         [binary, {packet, 4}, {active, false}]) of
        {ok, Sock} ->
            ok = gen_tcp:close(Sock),
            timer:sleep(20),
            wait_for_connect_refused(Path, N - 1);
        {error, _} ->
            ok
    end.

%% Bounded poll: returns ok once an event of `Type' is recorded against `RunId' in
%% the event store, retrying up to `N' times with a short sleep between tries.
wait_for_event(_StorePid, _RunId, _Type, 0) ->
    {error, timeout};
wait_for_event(StorePid, RunId, Type, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(Type, Types) of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_for_event(StorePid, RunId, Type, N - 1)
    end.

%% The runtime's event store pid, dug out of `soma_sup''s children so the bounded
%% poll can read run events directly.
event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

%% A minimal IO server usable as a group leader: it answers read requests by
%% delivering `Bytes' once then EOF (so a reader sees exactly `Bytes' as stdin),
%% and accumulates `put_chars' writes so the test can read back what dispatch
%% printed. `output' returns the accumulated stdout.
stdin_io_server(Bytes) ->
    spawn(fun() -> stdin_io_loop(Bytes, []) end).

io_server_output(IO) ->
    IO ! {output, self()},
    receive {output, Out} -> Out after 5000 -> ct:fail(io_server_no_output) end.

stdin_io_loop(Bytes, Out) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, Rest, Out1} = stdin_io_answer(Request, Bytes, Out),
            From ! {io_reply, ReplyAs, Reply},
            stdin_io_loop(Rest, Out1);
        {output, From} ->
            From ! {output, lists:reverse(Out)},
            stdin_io_loop(Bytes, Out);
        _Other ->
            stdin_io_loop(Bytes, Out)
    end.

stdin_io_answer({put_chars, _Enc, Chars}, Bytes, Out) ->
    {ok, Bytes, [Chars | Out]};
stdin_io_answer({put_chars, _Enc, M, F, A}, Bytes, Out) ->
    {ok, Bytes, [apply(M, F, A) | Out]};
stdin_io_answer(_Read, <<>>, Out) ->
    {eof, <<>>, Out};
stdin_io_answer(_Read, Bytes, Out) ->
    {binary_to_list(Bytes), <<>>, Out}.
