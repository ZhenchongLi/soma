-module(soma_cli_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_run_echo_file_prints_result_exit_zero/1]).
-export([test_run_failed_workflow_exit_nonzero/1]).
-export([test_run_reads_workflow_from_stdin_dash/1]).
-export([test_daemon_boots_listener_client_connects/1]).
-export([test_ask_prints_reply_result_exit_zero/1]).
-export([test_trace_prints_reply_exit_zero/1]).
-export([test_status_prints_reply_exit_zero/1]).
-export([test_cancel_sends_cancel_request_prints_reply_exit_zero/1]).
-export([test_cancel_error_reply_exits_nonzero/1]).
-export([test_run_detach_sends_detach_marker/1]).
-export([test_run_task_file_detach_returns_accepted/1]).
-export([test_ask_detach_sends_detach_marker/1]).
-export([test_ask_non_ascii_intent_round_trips_reply/1]).

all() ->
    [test_run_echo_file_prints_result_exit_zero,
     test_run_failed_workflow_exit_nonzero,
     test_run_reads_workflow_from_stdin_dash,
     test_daemon_boots_listener_client_connects,
     test_ask_prints_reply_result_exit_zero,
     test_trace_prints_reply_exit_zero,
     test_status_prints_reply_exit_zero,
     test_cancel_sends_cancel_request_prints_reply_exit_zero,
     test_cancel_error_reply_exits_nonzero,
     test_run_detach_sends_detach_marker,
     test_run_task_file_detach_returns_accepted,
     test_ask_detach_sends_detach_marker,
     test_ask_non_ascii_intent_round_trips_reply].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    %% The ask path drives the decision loop through an actor under
    %% soma_actor_sup, so the sup must be up. Tolerate an already-running sup so
    %% each case is self-contained.
    Sup = case soma_actor_sup:start_link() of
              {ok, Pid} -> Pid;
              {error, {already_started, Pid}} -> Pid
          end,
    [{started_apps, Started}, {actor_sup, Sup} | Config].

end_per_testcase(_Case, _Config) ->
    ok.

%% Criterion 8 (CLI.1b): `soma_cli:run/1', pointed at a server on a temp socket,
%% reads a one-step echo `.lfe' file, prints the `(result ...)' reply, and returns
%% exit code 0. The client reads the file's s-expr, connects to the temp socket
%% served by a real `soma_cli_server', frames + sends the bytes, reads the framed
%% `(result ...)' reply, prints it, and returns 0 when the reply's status sub-form
%% is `completed'.
test_run_echo_file_prints_result_exit_zero(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    File = filename:join(?config(priv_dir, Config), "echo_flow.lfe"),
    ok = file:write_file(File, <<"(run (step s1 echo (args (value \"hi\"))))">>),
    ct:capture_start(),
    Exit = soma_cli:run(#{file => File, socket => Path}),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),
    %% The printed reply must be the `(result ...)' s-expr whose status sub-form is
    %% `completed' and whose outputs carry s1's echo value.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Printed, "\\(s1 \\(value \"hi\"\\)\\)", [{capture, none}]),
    %% A completed run returns exit code 0.
    0 = Exit.

%% Criterion 9 (CLI.1b): `soma_cli:run/1' returns a non-zero exit code when the
%% workflow's run does not reach `completed'. The client reads a one-step `.lfe'
%% file whose only step uses the `fail' tool, connects to the temp socket served
%% by a real `soma_cli_server', frames + sends the bytes, and reads the framed
%% `(result ...)' reply whose status sub-form is not `completed'. The behavior
%% under test is the exit code: a non-completed run returns non-zero.
test_run_failed_workflow_exit_nonzero(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    File = filename:join(?config(priv_dir, Config), "fail_flow.lfe"),
    ok = file:write_file(File, <<"(run (step s1 fail (args (mode error))))">>),
    ct:capture_start(),
    Exit = soma_cli:run(#{file => File, socket => Path}),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),
    %% The printed reply is a `(result ...)' s-expr whose status is not `completed'.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    nomatch = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    %% A run that does not reach `completed' returns a non-zero exit code.
    true = (Exit =/= 0).

%% Criterion 10 (CLI.1b): `soma_cli:run/1' reads the workflow from stdin when the
%% path arg is `-'. The workflow bytes are fed on a redirected stdin (the group
%% leader of the process that calls `run/1'); the client must read those bytes,
%% not a file, send them through the same server chain as a file run, print the
%% `(result ...)' reply, and return exit 0 for the completed echo run. A fake IO
%% server stands in for stdin: it answers the IO protocol with the workflow bytes,
%% then EOF, so the byte source under test is the redirected stdin -- not a file.
test_run_reads_workflow_from_stdin_dash(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    Workflow = <<"(run (step s1 echo (args (value \"hi\"))))">>,
    Parent = self(),
    %% A fake IO server stands in for the child's group leader: it feeds `Workflow'
    %% on `get_chars' (stdin) and records `put_chars' (stdout). Running `run/1' with
    %% the path arg `-' must therefore read the workflow from this stdin, not a file.
    IO = stdin_io_server(Workflow),
    Child = spawn(fun() ->
        group_leader(IO, self()),
        Exit = soma_cli:run(#{file => "-", socket => Path}),
        Parent ! {result, Exit}
    end),
    Exit =
        receive
            {result, E} -> E
        after 60000 ->
            exit(Child, kill),
            ct:fail(stdin_run_timed_out)
        end,
    Printed = iolist_to_binary(io_server_output(IO)),
    %% The reply printed must be the completed echo `(result ...)' s-expr, proving
    %% the workflow read from stdin reached the server and ran.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Printed, "\\(s1 \\(value \"hi\"\\)\\)", [{capture, none}]),
    0 = Exit.

%% Criterion 11 (CLI.1b): `soma_cli:daemon/1', given a temp socket override, boots
%% the runtime and a listener on that resolved path; a real `gen_tcp' client can
%% then connect to the path the daemon resolved. The behavior under test is that
%% `daemon/1' both started the runtime (a runtime-owned process is registered) and
%% bound a listener a client reaches -- so we read the resolved path back from
%% `daemon/1' and prove a `{local, _}' connect to it succeeds.
test_daemon_boots_listener_client_connects(Config) ->
    Path = socket_path(Config),
    %% The daemon must boot the runtime: stop it first so the boot is observable.
    application:stop(soma_runtime),
    %% This test only asserts the listener boots -- it does not exercise LLM
    %% config resolution, so it must not accidentally read a real developer
    %% machine's `~/.soma/config' (a real `[llm]' section without
    %% `SOMA_LLM_API_KEY' set fails boot with `{missing_env, _}', an unrelated
    %% failure this test should never surface). Point `config_path' at a
    %% scratch path that is guaranteed absent instead of relying on default
    %% resolution.
    {ok, Resolved} = soma_cli:daemon(#{socket => Path,
                                       config_path => scratch_config_path(Config)}),
    %% The daemon resolved the override path and started the runtime.
    Path = Resolved,
    true = is_pid(whereis(soma_sup)),
    %% A real client connects to the path the daemon's listener bound.
    {ok, Sock} = gen_tcp:connect({local, Resolved}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:close(Sock).

%% Criterion 7 (CLI.2): `soma_cli:ask/1', pointed at a `soma_cli_server' on a temp
%% socket whose mock `model_config' yields a `reply' proposal, sends an intent,
%% prints the `(result ...)' reply, and returns exit code 0. The client builds the
%% `(ask (intent "..."))' source from the intent string, connects to the temp
%% socket served by a real `soma_cli_server', frames + sends the bytes, reads the
%% framed `(result ...)' reply, prints it, and returns 0 when the reply's status
%% sub-form is `completed'. The mock is driven entirely by the server's
%% `model_config' -- no real provider, no non-local socket.
test_ask_prints_reply_result_exit_zero(Config) ->
    Path = socket_path(Config),
    %% Mock model_config: a `proposal' directive whose output is a `reply'
    %% proposal carrying the answer text -- the criterion-4 server config shape.
    ModelConfig = #{directive => proposal,
                    output => #{kind => reply, text => <<"the answer">>}},
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                 model_config => ModelConfig}),
    ct:capture_start(),
    Exit = soma_cli:ask(#{intent => "what is the answer", socket => Path}),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),
    %% The printed reply must be the `(result ...)' s-expr whose status sub-form is
    %% `completed' and whose body carries the reply text.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Printed, "the answer", [{capture, none}]),
    %% A completed ask returns exit code 0.
    0 = Exit.

%% Dogfooding regression (docmod integration, 2026-07-02): a non-ASCII intent
%% (e.g. Chinese, as `soma_cli_main:dispatch/1' hands `soma_cli:ask/1' after
%% escript argv decoding + `soma_cli_intent:escape/1') must round-trip intact
%% through the wire AND through the client's own printed reply. Two bugs this
%% pins: (1) `ask_source/1,2' used to splice the intent codepoint list directly
%% into an iolist, crashing `iolist_to_binary/1' on any codepoint above 255;
%% (2) the reply was printed with `io:format("~s~n", ...)', which treats a
%% UTF-8 reply binary as raw latin1 bytes and double-encodes it on a unicode
%% device. The intent here is passed as a plain Erlang string (a list of
%% Unicode codepoints), matching what escript argv actually looks like for
%% non-ASCII input -- not a binary, which would not have reproduced either bug.
test_ask_non_ascii_intent_round_trips_reply(Config) ->
    Path = socket_path(Config),
    ReplyText = <<"你好，很高兴认识你"/utf8>>,
    ModelConfig = #{directive => proposal,
                    output => #{kind => reply, text => ReplyText}},
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                 model_config => ModelConfig}),
    Intent = unicode:characters_to_list(<<"用一句话回复:你好"/utf8>>),
    EscapedIntent = soma_cli_intent:escape(Intent),
    ct:capture_start(),
    Exit = soma_cli:ask(#{intent => EscapedIntent, socket => Path}),
    ct:capture_stop(),
    Printed = unicode:characters_to_binary(ct:capture_get()),
    %% The reply text must appear byte-for-byte, not double-encoded: the
    %% captured output binary must literally contain the original UTF-8 bytes.
    match = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    true = binary:match(Printed, ReplyText) =/= nomatch,
    0 = Exit.

%% Criterion 7 (CLI.3): `soma_cli:trace/1', pointed at a `soma_cli_server' on a temp
%% socket, prints the `(trace ...)' reply and returns exit code 0. The test seeds a
%% correlation chain first by running a one-step echo `(run ...)' through
%% `soma_cli:run/1' and reading its correlation id off the printed `(result ...)'
%% reply; it then calls `soma_cli:trace/1' with that correlation id against the same
%% server. The client builds `(trace "<corr>")' source-side, connects to the temp
%% socket, frames + sends the bytes, reads the framed `(trace ...)' reply, prints it,
%% and returns exit 0 -- a successful read is not gated on `(status completed)'.
test_trace_prints_reply_exit_zero(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    %% Seed a real correlation chain: run a one-step echo and read its correlation
    %% id off the `(result ...)' reply `run/1' printed.
    File = filename:join(?config(priv_dir, Config), "trace_seed.lfe"),
    ok = file:write_file(File, <<"(run (step s1 echo (args (value \"hi\"))))">>),
    ct:capture_start(),
    0 = soma_cli:run(#{file => File, socket => Path}),
    ct:capture_stop(),
    RunPrinted = iolist_to_binary(ct:capture_get()),
    {match, [Corr]} =
        re:run(RunPrinted, "\\(correlation-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    %% Now trace that correlation id against the same server.
    ct:capture_start(),
    Exit = soma_cli:trace(#{correlation_id => Corr, socket => Path}),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),
    %% The printed reply must be the `(trace ...)' s-expr carrying event sub-forms.
    match = re:run(Printed, "^\\(trace ", [{capture, none}]),
    match = re:run(Printed, "\\(event ", [{capture, none}]),
    %% A successful read returns exit code 0.
    0 = Exit.

%% Criterion 8 (CLI.3): `soma_cli:status/1', pointed at a `soma_cli_server' on a temp
%% socket, prints the `(status ...)' reply and returns exit code 0. The test seeds a
%% task first by running a one-step echo `(run ...)' through `soma_cli:run/1' and
%% reading its task id off the printed `(result ...)' reply's `(task-id ...)'
%% sub-form; it then calls `soma_cli:status/1' with that task id against the same
%% server. The client builds `(status "<task>")' source-side, connects to the temp
%% socket, frames + sends the bytes, reads the framed `(status ...)' reply, prints it,
%% and returns exit 0 -- a successful read is not gated on `(status completed)'.
test_status_prints_reply_exit_zero(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    %% Seed a real task: run a one-step echo and read its task id off the
    %% `(result ...)' reply `run/1' printed.
    File = filename:join(?config(priv_dir, Config), "status_seed.lfe"),
    ok = file:write_file(File, <<"(run (step s1 echo (args (value \"hi\"))))">>),
    ct:capture_start(),
    0 = soma_cli:run(#{file => File, socket => Path}),
    ct:capture_stop(),
    RunPrinted = iolist_to_binary(ct:capture_get()),
    {match, [TaskId]} =
        re:run(RunPrinted, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    %% Now ask the status of that task id against the same server.
    ct:capture_start(),
    Exit = soma_cli:status(#{task_id => TaskId, socket => Path}),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),
    %% The printed reply must be the `(status ...)' s-expr carrying a `(state ...)'.
    match = re:run(Printed, "^\\(status ", [{capture, none}]),
    match = re:run(Printed, "\\(state ", [{capture, none}]),
    %% A successful read returns exit code 0.
    0 = Exit.

%% Criterion #15 (CLI.4): `soma_cli:cancel/1', pointed at a `soma_cli_server' on a
%% temp socket, sends `(cancel "task-id")', prints the `(result ...)' reply, and
%% returns exit code 0. The test first seeds a running detached sleep task through
%% the real socket daemon, then invokes the thin client cancel path against that
%% accepted task id. A cancelled result proves the client sent the cancel request
%% to the daemon rather than handling it locally.
test_cancel_sends_cancel_request_prints_reply_exit_zero(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),

    {ok, Seed} = connect(Path),
    Request = <<"(run (detach) (step s1 sleep (args (ms 5000))))">>,
    ok = gen_tcp:send(Seed, Request),
    {ok, Accepted} = gen_tcp:recv(Seed, 0, 1000),
    ok = gen_tcp:close(Seed),
    match = re:run(Accepted, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Accepted, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    {match, [CorrId]} =
        re:run(Accepted, "\\(correlation-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    {ok, #{run_id := RunId}} = soma_cli_task_registry:lookup(TaskId),
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 100),

    ct:capture_start(),
    Exit = try soma_cli:cancel(#{task_id => TaskId, socket => Path})
           after ct:capture_stop()
           end,
    Printed = iolist_to_binary(ct:capture_get()),
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status cancelled\\)", [{capture, none}]),
    TaskPattern = <<"\\(task-id \"", TaskId/binary, "\"\\)">>,
    CorrPattern = <<"\\(correlation-id \"", CorrId/binary, "\"\\)">>,
    match = re:run(Printed, TaskPattern, [{capture, none}]),
    match = re:run(Printed, CorrPattern, [{capture, none}]),
    0 = Exit.

test_cancel_error_reply_exits_nonzero(Config) ->
    Path = socket_path(Config),
    Capture = soma_cli_request_capture:start(
                Path,
                <<"(result (status error) "
                  "(error cancel-intent-not-persisted))">>),
    ct:capture_start(),
    Exit = try soma_cli:cancel(
                 #{task_id => <<"task-unconfirmed">>, socket => Path})
           after ct:capture_stop()
           end,
    Printed = iolist_to_binary(ct:capture_get()),
    Request = soma_cli_request_capture:request(Capture),
    1 = Exit,
    match = re:run(Printed, "cancel-intent-not-persisted",
                   [{capture, none}]),
    <<"(cancel \"task-unconfirmed\")">> = Request.

%% Criterion #16 (CLI.4): `soma_cli:run/1' with `detach => true' sends a request
%% carrying the literal `(detach)' marker. The capture helper records only the
%% client wire payload so the proof stays scoped to request
%% construction, not daemon-side detached execution.
test_run_detach_sends_detach_marker(Config) ->
    Path = socket_path(Config),
    File = filename:join(?config(priv_dir, Config), "detach_flow.lfe"),
    ok = file:write_file(File, <<"(run (step s1 echo (args (value \"hi\"))))">>),
    Capture = soma_cli_request_capture:start(
                Path, <<"(result (status completed))">>),

    ct:capture_start(),
    Exit = try soma_cli:run(#{file => File, socket => Path, detach => true})
           after ct:capture_stop()
           end,
    _ = ct:capture_get(),
    Request = soma_cli_request_capture:request(Capture),

    0 = Exit,
    match = re:run(Request, "^\\(run ", [{capture, none}]),
    match = re:run(Request, "\\(detach\\)", [{capture, none}]).

%% `soma run TASK_FILE --detach' must also detach when TASK_FILE is the public
%% `(task ...)' form. The CLI rewrites only the source marker; the daemon proves
%% the marker by returning `(accepted ...)' instead of blocking for a terminal
%% `(result ...)'.
test_run_task_file_detach_returns_accepted(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    File = filename:join(?config(priv_dir, Config), "detach_task.lfe"),
    ok = file:write_file(
           File,
           <<"(task (let* ((wait (tool sleep (ms 25)))) (return wait)))">>),

    ct:capture_start(),
    _Exit = try soma_cli:run(#{file => File, socket => Path, detach => true})
            after ct:capture_stop()
            end,
    Printed = iolist_to_binary(ct:capture_get()),

    match = re:run(Printed, "^\\(accepted ", [{capture, none}]),
    match = re:run(Printed, "\\(task-id \"[^\"]+\"\\)", [{capture, none}]),
    match = re:run(Printed, "\\(correlation-id \"[^\"]+\"\\)",
                   [{capture, none}]).

%% Criterion #16 (CLI.4): `soma_cli:ask/1' with `detach => true' sends a request
%% carrying the literal `(detach)' marker. The capture helper records only the
%% client wire payload and leaves request parsing / execution to the daemon.
test_ask_detach_sends_detach_marker(Config) ->
    Path = socket_path(Config),
    Capture = soma_cli_request_capture:start(
                Path, <<"(result (status completed))">>),

    ct:capture_start(),
    Exit = try soma_cli:ask(#{intent => "what is the answer",
                              socket => Path,
                              detach => true})
           after ct:capture_stop()
           end,
    _ = ct:capture_get(),
    Request = soma_cli_request_capture:request(Capture),

    0 = Exit,
    match = re:run(Request, "^\\(ask ", [{capture, none}]),
    match = re:run(Request, "\\(intent \"what is the answer\"\\)",
                   [{capture, none}]),
    match = re:run(Request, "\\(detach\\)", [{capture, none}]).

%% A minimal IO server usable as a group leader: it answers `get_chars' / `get_line'
%% / `get_until' read requests by delivering `Bytes' once then EOF (so a reader
%% sees exactly `Bytes' as stdin), and accumulates `put_chars' writes so the test
%% can read back what `run/1' printed. `output' returns the accumulated stdout.
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

%% A `put_chars' request is an output write: record it, reply `ok'. Any read
%% request delivers the remaining stdin bytes once, then EOF.
stdin_io_answer({put_chars, _Enc, Chars}, Bytes, Out) ->
    {ok, Bytes, [Chars | Out]};
stdin_io_answer({put_chars, _Enc, M, F, A}, Bytes, Out) ->
    {ok, Bytes, [apply(M, F, A) | Out]};
stdin_io_answer(_Read, <<>>, Out) ->
    {eof, <<>>, Out};
stdin_io_answer(_Read, Bytes, Out) ->
    {binary_to_list(Bytes), <<>>, Out}.

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

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

connect(Path) ->
    gen_tcp:connect({local, Path}, 0,
                    [binary, {packet, 4}, {active, false}]).

%% AF_UNIX socket paths are bounded by sun_path (~104 bytes on macOS), so the long
%% CT priv_dir cannot hold a bindable socket. Use a short unique path under the
%% system temp dir; os:getpid() makes it unique across BEAM runs (see
%% soma_cli_server_SUITE for the full rationale), and the pre-delete clears any
%% leftover at the unique path.
socket_path(_Config) ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Name = "soma_cli_c_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock",
    Path = filename:join(Tmp, Name),
    _ = file:delete(Path),
    Path.

%% A guaranteed-absent config path, isolating a test from whatever
%% `~/.soma/config' a real developer machine may carry.
scratch_config_path(Config) ->
    filename:join(?config(priv_dir, Config), "no_such_soma_config").
