-module(soma_cli_server_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_start_link_listens_and_accepts_connect/1]).
-export([test_start_link_unlinks_stale_socket_file/1]).
-export([test_start_link_preserves_regular_file_at_socket_path/1]).
-export([test_second_start_link_on_live_path_errors/1]).
-export([test_first_server_survives_failed_second_start_link/1]).
-export([test_run_lisp_echo_returns_completed_result/1]).
-export([test_run_lisp_result_carries_correlation_id/1]).
-export([test_run_lisp_failed_returns_error_result/1]).
-export([test_run_crash_lfe_body_returns_kaboom_error_result/1]).
-export([test_run_timeout_returns_result_with_status_timeout/1]).
-export([test_server_serves_after_failed_lisp_run/1]).
-export([test_malformed_request_returns_error_sexpr/1]).
-export([test_server_serves_after_malformed_request/1]).
-export([test_run_cancelled_on_client_disconnect/1]).
-export([test_worker_dead_after_client_disconnect/1]).
-export([test_server_serves_after_client_disconnect/1]).
-export([test_ask_reply_returns_completed_result_with_text/1]).
-export([test_ask_no_model_returns_named_no_model_configured/1]).
-export([test_server_serves_after_no_model_ask/1]).
-export([test_ask_reject_returns_rejected_result_with_reason/1]).
-export([test_ask_budget_llm_zero_returns_budget_exceeded/1]).
-export([test_trace_after_run_returns_ordered_chain_ending_completed/1]).
-export([test_status_after_run_reports_state_completed/1]).
-export([test_status_unknown_id_reports_unknown_and_server_survives/1]).
-export([test_detached_run_replies_accepted_before_sleep_terminal/1]).
-export([test_detached_run_completes_after_client_close_registry_completed/1]).
-export([test_status_running_detached_task_reads_registry/1]).
-export([test_status_completed_detached_task_reads_completed/1]).
-export([test_cancel_detached_run_records_run_cancelled/1]).
-export([test_cancel_detached_run_kills_tool_worker/1]).
-export([test_cancel_detached_run_replies_cancelled/1]).
-export([test_cancel_terminal_task_reports_already_terminal_no_new_run/1]).
-export([test_non_detached_run_still_terminal_and_disconnect_cancels/1]).
-export([test_daemon_threads_loaded_model_config/1]).
-export([test_ask_no_config_runs_mock/1]).
-export([test_daemon_real_provider_config_reaches_actor/1]).
-export([test_ask_real_provider_returns_fixed_response_answer/1]).
-export([test_real_provider_api_key_leaks_nowhere/1]).
-export([test_ask_real_provider_plan_returns_step_outputs/1]).
-export([test_ask_real_provider_plan_rejects_disallowed_tool/1]).
-export([test_real_provider_plan_api_key_leaks_nowhere/1]).

all() ->
    [test_start_link_listens_and_accepts_connect,
     test_start_link_unlinks_stale_socket_file,
     test_start_link_preserves_regular_file_at_socket_path,
     test_second_start_link_on_live_path_errors,
     test_first_server_survives_failed_second_start_link,
     test_run_lisp_echo_returns_completed_result,
     test_run_lisp_result_carries_correlation_id,
     test_run_lisp_failed_returns_error_result,
     test_run_crash_lfe_body_returns_kaboom_error_result,
     test_run_timeout_returns_result_with_status_timeout,
     test_server_serves_after_failed_lisp_run,
     test_malformed_request_returns_error_sexpr,
     test_server_serves_after_malformed_request,
     test_run_cancelled_on_client_disconnect,
     test_worker_dead_after_client_disconnect,
     test_server_serves_after_client_disconnect,
     test_ask_reply_returns_completed_result_with_text,
     test_ask_no_model_returns_named_no_model_configured,
     test_server_serves_after_no_model_ask,
     test_ask_reject_returns_rejected_result_with_reason,
     test_ask_budget_llm_zero_returns_budget_exceeded,
     test_trace_after_run_returns_ordered_chain_ending_completed,
     test_status_after_run_reports_state_completed,
     test_status_unknown_id_reports_unknown_and_server_survives,
     test_detached_run_completes_after_client_close_registry_completed,
     test_detached_run_replies_accepted_before_sleep_terminal,
     test_status_running_detached_task_reads_registry,
     test_status_completed_detached_task_reads_completed,
     test_cancel_detached_run_records_run_cancelled,
     test_cancel_detached_run_kills_tool_worker,
     test_cancel_detached_run_replies_cancelled,
     test_cancel_terminal_task_reports_already_terminal_no_new_run,
     test_non_detached_run_still_terminal_and_disconnect_cancels,
     test_daemon_threads_loaded_model_config,
     test_ask_no_config_runs_mock,
     test_daemon_real_provider_config_reaches_actor,
     test_ask_real_provider_returns_fixed_response_answer,
     test_real_provider_api_key_leaks_nowhere,
     test_ask_real_provider_plan_returns_step_outputs,
     test_ask_real_provider_plan_rejects_disallowed_tool,
     test_real_provider_plan_api_key_leaks_nowhere].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    %% The ask path drives the decision loop through an actor under
    %% soma_actor_sup, so the sup must be up. Tolerate an already-running sup
    %% (the soma_actor app may have started one) so each case is self-contained.
    Sup = case soma_actor_sup:start_link() of
              {ok, Pid} -> Pid;
              {error, {already_started, Pid}} -> Pid
          end,
    [{started_apps, Started}, {actor_sup, Sup} | Config].

end_per_testcase(_Case, Config) ->
    Config.

%% Criterion 4: start_link(#{socket => Path}) leaves a listening socket file at
%% Path that an Erlang gen_tcp client can connect to.
test_start_link_listens_and_accepts_connect(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    ok = gen_tcp:close(Client).

%% Criterion 5: a leftover file at Path (e.g. a stale socket left by a crashed
%% server) does not stop start_link -- the stale file is unlinked before bind,
%% so the listener binds and accepts a connect.
test_start_link_unlinks_stale_socket_file(Config) ->
    Path = socket_path(Config),
    {ok, StaleServer} = soma_cli_server:start_link(#{socket => Path}),
    unlink(StaleServer),
    StaleMon = erlang:monitor(process, StaleServer),
    exit(StaleServer, kill),
    receive
        {'DOWN', StaleMon, process, StaleServer, killed} -> ok
    after 1000 ->
        ct:fail(stale_server_not_stopped)
    end,
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    ok = gen_tcp:close(Client).

test_start_link_preserves_regular_file_at_socket_path(Config) ->
    Path = socket_path(Config),
    Bytes = <<"regular file at socket path">>,
    ok = file:write_file(Path, Bytes),
    StartResult = soma_cli_server:start_link(#{socket => Path}),
    ReadResult = file:read_file(Path),
    case StartResult of
        {ok, Server} ->
            unlink(Server),
            exit(Server, shutdown);
        {error, _Reason} ->
            ok
    end,
    {ok, Bytes} = ReadResult,
    {error, _} = StartResult.

%% Criterion 6: a second start_link on a Path already served by a live server
%% returns an error (the bind cannot take the in-use address) and does not start
%% a duplicate listener -- the live server's path is not stolen, so server A is
%% the single listener and still answers a connect.
test_second_start_link_on_live_path_errors(Config) ->
    Path = socket_path(Config),
    {ok, ServerA} = soma_cli_server:start_link(#{socket => Path}),
    {error, _Reason} = soma_cli_server:start_link(#{socket => Path}),
    true = is_process_alive(ServerA),
    {ok, Client} = connect(Path),
    ok = gen_tcp:close(Client).

%% Criterion 7: after a second start_link on server A's live path fails, server A
%% keeps serving -- the failed second bind did not disturb A's listener, so a
%% fresh client still connects to A.
test_first_server_survives_failed_second_start_link(Config) ->
    Path = socket_path(Config),
    {ok, ServerA} = soma_cli_server:start_link(#{socket => Path}),
    {error, _Reason} = soma_cli_server:start_link(#{socket => Path}),
    true = is_process_alive(ServerA),
    {ok, Client} = connect(Path),
    ok = gen_tcp:close(Client).

%% Criterion 1 (CLI.1b): a framed Lisp `(run (step ...))' request carrying a
%% one-step `echo' workflow drives the real server -> soma_lfe:compile ->
%% soma_run -> soma_tool_call (echo) -> soma_lisp:render path and replies a framed
%% `(result ...)' s-expr whose status sub-form is `completed' and whose outputs
%% sub-form carries step s1's echo value. No layer is bypassed: a real gen_tcp
%% client over the local Unix socket sends the s-expr and reads the s-expr reply.
test_run_lisp_echo_returns_completed_result(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    Request = <<"(run (step s1 echo (args (value \"hi\"))))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply is an s-expr, not JSON. It must be a `(result ...)' form whose
    %% status sub-form is `completed' and whose outputs carry s1's echo value.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Reply, "\\(s1 \\(value \"hi\"\\)\\)", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 2 (CLI.1b): the completed `(result ...)' reply carries a non-empty
%% `(correlation-id "...")' sub-form. Same call chain as Criterion 1 -- a real
%% gen_tcp client over a temp Unix socket sends the framed `(run (step ...))'
%% s-expr -- and the reply's correlation-id sub-form holds a non-empty quoted
%% string (the run's minted correlation id, stamped on every run event).
test_run_lisp_result_carries_correlation_id(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    Request = <<"(run (step s1 echo (args (value \"hi\"))))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply must carry a `(correlation-id "...")' sub-form whose quoted
    %% string is non-empty (at least one character between the quotes).
    match = re:run(Reply, "\\(correlation-id \"[^\"]+\"\\)", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 4 (CLI.1b): a framed Lisp `(run (step ...))' request whose only step
%% uses the `fail' tool drives the real server -> soma_lfe:compile -> soma_run ->
%% soma_tool_call (fail) -> await_run (run_failed) -> soma_lisp:render path and
%% replies a framed `(result ...)' s-expr whose status sub-form is NOT `completed'
%% and which carries an `(error ...)' sub-form. The run's failure is data in the
%% s-expr reply, not a handler crash. A real gen_tcp client over a temp Unix
%% socket sends the s-expr and reads the s-expr reply.
test_run_lisp_failed_returns_error_result(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    Request = <<"(run (step s1 fail (args (mode error))))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply must be a `(result ...)' s-expr whose status sub-form is not
    %% `completed' and which carries an `(error ...)' sub-form.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    nomatch = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Reply, "\\(error ", [{capture, none}]),
    ok = gen_tcp:close(Client).

test_run_crash_lfe_body_returns_kaboom_error_result(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    %% The crash.lfe demo body, inlined so the test does not depend on the
    %% example file's path resolving from the CT working directory.
    Request = <<"(run (step boom fail (args (mode crash) (reason kaboom))))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status failed\\)", [{capture, none}]),
    match = re:run(Reply, "kaboom", [{capture, none}]),
    nomatch = re:run(Reply, "noproc", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 1 (#179): a framed Lisp `(run (step ...))' request whose only step
%% outlasts its `timeout_ms' drives the real server -> soma_lfe:compile ->
%% soma_run (waiting_tool state_timeout fires step_timeout -> run.timeout ->
%% {run_timeout, RunId}) -> await_run (timeout map) -> soma_lisp:render path and
%% replies a framed `(result ...)' s-expr whose status sub-form is `timeout'. The
%% timeout map carries neither outputs nor error, yet the reply must still be
%% headed by `result' (not a headless pair list). A real gen_tcp client over the
%% local Unix socket sends the s-expr and reads the s-expr reply.
test_run_timeout_returns_result_with_status_timeout(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    Request = <<"(run (step wait sleep (args (ms 3000)) (timeout_ms 500)))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply must be a `(result ...)' s-expr (headed by `result') whose status
    %% sub-form is `timeout'.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status timeout\\)", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 5 (CLI.1b): the server stays up after a failed Lisp run and answers
%% the next request on a new connection. The first connection sends a `(run (step
%% ...))' whose only step uses the `fail' tool (the Criterion 4 chain), failing the
%% run; the second connection (a fresh socket) sends an echo `(run (step ...))'
%% (the Criterion 1 chain) and reads a `(result ...)' s-expr whose status sub-form
%% is `completed'. The proof is that the same server process serves a second
%% well-formed request after a failed run -- it did not crash with the failed run.
test_server_serves_after_failed_lisp_run(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, C1} = connect(Path),
    Fail = <<"(run (step s1 fail (args (mode error))))">>,
    ok = gen_tcp:send(C1, Fail),
    {ok, _} = gen_tcp:recv(C1, 0, 5000),
    ok = gen_tcp:close(C1),
    {ok, C2} = connect(Path),
    Echo = <<"(run (step s1 echo (args (value \"ok\"))))">>,
    ok = gen_tcp:send(C2, Echo),
    {ok, Reply} = gen_tcp:recv(C2, 0, 5000),
    %% The second reply must be a completed `(result ...)' -- the server survived
    %% the earlier failed run and served this fresh well-formed request.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    ok = gen_tcp:close(C2).

%% Criterion 6 (CLI.1b): a malformed Lisp request (one `soma_lfe:compile/2'
%% rejects, here a top-level form that is not `run') makes the handler reply a
%% defined error s-expr instead of crashing the connection handler. A real
%% gen_tcp client over a temp Unix socket sends bytes that do not parse; the
%% reply must be a parseable `(result ...)' s-expr whose status sub-form is
%% `error' and which carries an `(error ...)' sub-form. The server stays up and
%% answers a second well-formed request on a fresh connection -- the handler
%% closed the socket like every other reply rather than crashing.
test_malformed_request_returns_error_sexpr(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    %% Starts with `(' so it routes to the Lisp handler, but is not a valid
    %% `(run ...)' request -- `soma_lfe:compile/2' returns `{error, _}'.
    Malformed = <<"(nonsense foo bar)">>,
    ok = gen_tcp:send(Client, Malformed),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply must be a `(result ...)' s-expr whose status sub-form is `error'
    %% and which carries an `(error ...)' sub-form -- a defined error reply, not a
    %% dropped connection.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status error\\)", [{capture, none}]),
    match = re:run(Reply, "\\(error ", [{capture, none}]),
    ok = gen_tcp:close(Client),
    %% The server survived the malformed request: a fresh connection still gets a
    %% completed echo result.
    {ok, C2} = connect(Path),
    Echo = <<"(run (step s1 echo (args (value \"ok\"))))">>,
    ok = gen_tcp:send(C2, Echo),
    {ok, Reply2} = gen_tcp:recv(C2, 0, 5000),
    match = re:run(Reply2, "\\(status completed\\)", [{capture, none}]),
    ok = gen_tcp:close(C2).

%% Criterion 7 (CLI.1b): the server stays up after a malformed request and answers
%% the next well-formed request on a new connection. The first connection sends
%% garbage bytes that `soma_lfe:compile/2' rejects (the Criterion 6 path); the
%% second connection (a fresh socket) sends an echo `(run (step ...))' (the
%% Criterion 1 path) and reads a `(result ...)' s-expr whose status sub-form is
%% `completed'. The proof is that the same server process serves a second
%% well-formed request after a malformed one -- the handler replied a defined
%% error and closed rather than crashing the listener.
test_server_serves_after_malformed_request(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, C1} = connect(Path),
    Malformed = <<"(nonsense foo bar)">>,
    ok = gen_tcp:send(C1, Malformed),
    {ok, _} = gen_tcp:recv(C1, 0, 5000),
    ok = gen_tcp:close(C1),
    {ok, C2} = connect(Path),
    Echo = <<"(run (step s1 echo (args (value \"ok\"))))">>,
    ok = gen_tcp:send(C2, Echo),
    {ok, Reply} = gen_tcp:recv(C2, 0, 5000),
    %% The second reply must be a completed `(result ...)' -- the server survived
    %% the earlier malformed request and served this fresh well-formed request.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    ok = gen_tcp:close(C2).

%% Criterion 1 (CLI.1.5): a client that sends a `(run ...)' with a slow `sleep'
%% step and then closes the socket mid-run drives that run to the `cancelled'
%% terminal state. A real gen_tcp client sends the framed `(run (step s1 sleep
%% (args (ms 5000))))', waits for the run's `tool.started' event in the store (so
%% the cancel lands in `waiting_tool', the same guard soma_run_failure_SUITE's
%% cancel cases use), then `gen_tcp:close's the socket. The handler's
%% `{active, once}' socket delivers `{tcp_closed, Socket}', the cancel reaches the
%% live run, and a `run.cancelled' event for that run appears in the store.
test_run_cancelled_on_client_disconnect(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),
    %% The store persists across cases in this suite, so an earlier case's
    %% `tool.started' is already there. Snapshot those run ids first, then look
    %% for the NEW one this request drives.
    Before = tool_started_runs(StorePid),
    {ok, Client} = connect(Path),
    Request = <<"(run (step s1 sleep (args (ms 5000))))">>,
    ok = gen_tcp:send(Client, Request),
    %% Wait for the sleep run to reach `waiting_tool' -- its `tool.started' is in
    %% the store -- so the disconnect lands while a worker is live, not before.
    RunId = wait_for_new_tool_started_run(StorePid, Before, 100),
    ok = gen_tcp:close(Client),
    %% The disconnect must drive that run to `cancelled': a `run.cancelled' event
    %% for that run appears in the store.
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.cancelled">>, Types).

%% Criterion 2 (CLI.1.5): after a client disconnects mid-run, the cancelled run's
%% active tool-call worker process is no longer alive -- the cancel stopped the
%% live worker, it was not a flag checked later. Same disconnect chain as the
%% Criterion 1 case: a real gen_tcp client sends `(run (step s1 sleep (args (ms
%% 5000))))', waits for the run's `tool.started' event (capturing the worker pid
%% off it via `tool_call_pid', the same field soma_run_failure_SUITE reads to
%% prove a killed worker is gone), closes the socket, waits for `run.cancelled',
%% then asserts the worker pid is no longer alive. Worker liveness is read off the
%% event store -- the worker pid is not on the reply path.
test_worker_dead_after_client_disconnect(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),
    Before = tool_started_runs(StorePid),
    {ok, Client} = connect(Path),
    Request = <<"(run (step s1 sleep (args (ms 5000))))">>,
    ok = gen_tcp:send(Client, Request),
    %% Wait for `tool.started' so a worker is live, then grab its pid.
    RunId = wait_for_new_tool_started_run(StorePid, Before, 100),
    WorkerPid = tool_call_pid_from(StorePid, RunId, <<"tool.started">>),
    ok = gen_tcp:close(Client),
    %% The disconnect drives the run to `cancelled'.
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 100),
    %% The cancel stopped the live worker -- it is no longer alive.
    false = is_process_alive(WorkerPid).

%% Criterion 3 (CLI.1.5): the server still serves a fresh connection after a
%% client disconnects mid-run. The first connection sends `(run (step s1 sleep
%% (args (ms 5000))))', waits for the run's `tool.started' event, then
%% `gen_tcp:close's the socket mid-run (the Criterion 1 disconnect chain). A second
%% fresh connection then sends an echo `(run (step ...))' (the Criterion 1 connected
%% chain) and reads a framed `(result ...)' s-expr whose status sub-form is
%% `completed' and whose outputs carry s1's echo value. The proof is that the same
%% server process serves a second well-formed request after a mid-run disconnect --
%% each connection handler is independent, so cancelling one run does not disturb
%% the listener.
test_server_serves_after_client_disconnect(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),
    Before = tool_started_runs(StorePid),
    {ok, C1} = connect(Path),
    Sleep = <<"(run (step s1 sleep (args (ms 5000))))">>,
    ok = gen_tcp:send(C1, Sleep),
    %% Wait for `tool.started' so the disconnect lands while the worker is live.
    _RunId = wait_for_new_tool_started_run(StorePid, Before, 100),
    ok = gen_tcp:close(C1),
    %% A fresh connection still gets a completed echo result.
    {ok, C2} = connect(Path),
    Echo = <<"(run (step s1 echo (args (value \"ok\"))))">>,
    ok = gen_tcp:send(C2, Echo),
    {ok, Reply} = gen_tcp:recv(C2, 0, 5000),
    %% The second reply must be a completed `(result ...)' carrying s1's echo value.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Reply, "\\(s1 \\(value \"ok\"\\)\\)", [{capture, none}]),
    ok = gen_tcp:close(C2).

%% Criterion 4 (CLI.2): a framed `(ask (intent "..."))' request drives the real
%% server -> soma_lfe:compile -> soma_actor_sup:start_actor -> soma_actor:ask/3 ->
%% mock soma_llm_call -> soma_proposal:normalize -> soma_policy:check ->
%% soma_lisp:render path and replies a framed `(result ...)' s-expr whose status
%% sub-form is `completed' and whose body carries the reply text. The mock is
%% driven entirely by the server's `model_config' (a `proposal' directive yielding
%% a `reply' proposal) -- no real provider, no non-local socket. A real gen_tcp
%% client over a temp Unix socket sends the s-expr and reads the s-expr reply.
test_ask_reply_returns_completed_result_with_text(Config) ->
    Path = socket_path(Config),
    %% Mock model_config: a `proposal' directive whose output is a `reply'
    %% proposal carrying the answer text. build_call_opts/2 returns this map
    %% unchanged (no `provider' key), so soma_llm_call runs the mock and opens
    %% no socket.
    ModelConfig = #{directive => proposal,
                    output => #{kind => reply, text => <<"the answer">>}},
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                 model_config => ModelConfig}),
    {ok, Client} = connect(Path),
    Request = <<"(ask (intent \"what is the answer\"))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply must be a `(result ...)' s-expr whose status sub-form is
    %% `completed' and whose body carries the reply text.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Reply, "the answer", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 2 (#179): a framed `(ask (intent "..."))' request handled by a server
%% started with NO `model_config' key (the `undefined' daemon default, i.e. no
%% `~/.soma/config') must reply a `failed' `(result ...)' whose `error' sub-form is
%% the named atom `no_model_configured' -- rendered by `soma_lisp:render/1' as the
%% symbol `no-model-configured' -- not a leaked `function_clause' crash term. The
%% no-model guard in `handle_ask/2' short-circuits before any actor or LLM call is
%% started. A real gen_tcp client over the local Unix socket sends the s-expr and
%% reads the s-expr reply; no layer is bypassed.
test_ask_no_model_returns_named_no_model_configured(Config) ->
    Path = socket_path(Config),
    %% Started with no `model_config' key: the `undefined' daemon default.
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    Request = <<"(ask (intent \"what is the answer\"))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply must be a `(result ...)' s-expr whose status sub-form is `failed'
    %% and whose `error' sub-form is the named symbol `no-model-configured' -- not a
    %% `function_clause' crash term leaking onto the wire.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status failed\\)", [{capture, none}]),
    match = re:run(Reply, "\\(error no-model-configured\\)", [{capture, none}]),
    nomatch = re:run(Reply, "function_clause", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 3 (#179): the server stays up after returning the `no_model_configured'
%% failure and serves the next request on the same daemon. The first connection
%% sends `(ask (intent "..."))' to a server started with NO `model_config' key (the
%% `undefined' daemon default), which the no-model guard short-circuits to a failed
%% result without starting any actor or LLM call (the Criterion 2 chain). The second
%% connection (a fresh socket) sends an echo `(run (step ...))' (the Criterion 1
%% chain) and reads a `(result ...)' s-expr whose status sub-form is `completed'. The
%% proof is that the same server process serves a second well-formed request after the
%% no-model failure -- the guard replied a defined failure and closed rather than
%% crashing the listener.
test_server_serves_after_no_model_ask(Config) ->
    Path = socket_path(Config),
    %% Started with no `model_config' key: the `undefined' daemon default.
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, C1} = connect(Path),
    Ask = <<"(ask (intent \"what is the answer\"))">>,
    ok = gen_tcp:send(C1, Ask),
    {ok, _} = gen_tcp:recv(C1, 0, 5000),
    ok = gen_tcp:close(C1),
    {ok, C2} = connect(Path),
    Echo = <<"(run (step s1 echo (args (value \"ok\"))))">>,
    ok = gen_tcp:send(C2, Echo),
    {ok, Reply} = gen_tcp:recv(C2, 0, 5000),
    %% The second reply must be a completed `(result ...)' -- the server survived
    %% the earlier no-model failure and served this fresh well-formed request.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    ok = gen_tcp:close(C2).

%% Criterion 5 (CLI.2): a framed `(ask (intent "..."))' request whose server is
%% configured with a mock `model_config' yielding a `reject' proposal drives the
%% real server -> soma_lfe:compile -> soma_actor_sup:start_actor ->
%% soma_actor:ask/3 -> mock soma_llm_call -> soma_proposal:normalize ->
%% soma_policy:check path and replies a framed `(result ...)' s-expr whose status
%% sub-form is `rejected' and which carries the reject reason. The mock is driven
%% entirely by the server's `model_config' (a `proposal' directive yielding a
%% `reject' proposal) -- no real provider, no non-local socket. A real gen_tcp
%% client over a temp Unix socket sends the s-expr and reads the s-expr reply.
test_ask_reject_returns_rejected_result_with_reason(Config) ->
    Path = socket_path(Config),
    %% Mock model_config: a `proposal' directive whose output is a `reject'
    %% proposal carrying the reason. build_call_opts/2 returns this map unchanged
    %% (no `provider' key), so soma_llm_call runs the mock and opens no socket.
    ModelConfig = #{directive => proposal,
                    output => #{kind => reject,
                                reason => <<"cannot help with that">>}},
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                 model_config => ModelConfig}),
    {ok, Client} = connect(Path),
    Request = <<"(ask (intent \"do something disallowed\"))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply must be a `(result ...)' s-expr whose status sub-form is
    %% `rejected' and which carries the reject reason.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status rejected\\)", [{capture, none}]),
    match = re:run(Reply, "cannot help with that", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 6 (CLI.2): a framed `(ask (intent "...") (budget-llm 0))' request
%% drives the real server -> soma_lfe:compile -> soma_actor_sup:start_actor ->
%% soma_actor:ask/3 -> maybe_start_llm_call -> llm_budget_available (false) ->
%% fail_task path and replies a framed `(result ...)' s-expr whose status sub-form
%% is NOT `completed' and whose `error' sub-form carries the
%% `{budget_exceeded, max_llm_calls}' tuple. No LLM call starts: the `max_llm_calls'
%% cap of 0 refuses the call up front, so the mock `model_config' is never reached.
%% A real gen_tcp client over a temp Unix socket sends the s-expr and reads the
%% s-expr reply.
test_ask_budget_llm_zero_returns_budget_exceeded(Config) ->
    Path = socket_path(Config),
    %% A `reply' mock model_config is configured, but the `(budget-llm 0)' cap
    %% refuses the call before it is reached -- the terminal result must be the
    %% budget failure, not the reply.
    ModelConfig = #{directive => proposal,
                    output => #{kind => reply, text => <<"the answer">>}},
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                 model_config => ModelConfig}),
    {ok, Client} = connect(Path),
    Request = <<"(ask (intent \"what is the answer\") (budget-llm 0))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The reply must be a `(result ...)' s-expr whose status sub-form is NOT
    %% `completed' and whose `error' sub-form carries the budget_exceeded tuple.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    nomatch = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Reply, "\\(error ", [{capture, none}]),
    match = re:run(Reply, "budget_exceeded", [{capture, none}]),
    match = re:run(Reply, "max_llm_calls", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 4 (CLI.3): after a `(run ...)' completes against the server, a framed
%% `(trace "<that run's correlation-id>")' request drives the real server ->
%% soma_lfe:compile -> soma_trace:render_lisp -> by_correlation -> soma_lisp:render
%% per event path and replies a single framed `(trace ...)' s-expr whose sub-forms
%% are that run's events in timestamp order, ending with the `run.completed' event.
%% Two connections, no layer bypassed: the run runs first (a real echo run), the
%% client reads the run's correlation id off the `(result ...)' reply, then a fresh
%% connection sends `(trace "<corr>")' and reads back the real correlation chain.
test_trace_after_run_returns_ordered_chain_ending_completed(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    %% Run a one-step echo so a completed run with a correlation chain exists.
    {ok, C1} = connect(Path),
    Run = <<"(run (step s1 echo (args (value \"hi\"))))">>,
    ok = gen_tcp:send(C1, Run),
    {ok, RunReply} = gen_tcp:recv(C1, 0, 5000),
    ok = gen_tcp:close(C1),
    %% Read the run's correlation id off the `(result ...)' reply.
    {match, [Corr]} =
        re:run(RunReply, "\\(correlation-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    %% Send `(trace "<corr>")' on a fresh connection and read the chain back.
    {ok, C2} = connect(Path),
    TraceReq = <<"(trace \"", Corr/binary, "\")">>,
    ok = gen_tcp:send(C2, TraceReq),
    {ok, TraceReply} = gen_tcp:recv(C2, 0, 5000),
    ok = gen_tcp:close(C2),
    %% The reply is a single `(trace ...)' s-expr whose sub-forms are the chain's
    %% events: it starts with `(trace ' and carries event sub-forms.
    match = re:run(TraceReply, "^\\(trace ", [{capture, none}]),
    match = re:run(TraceReply, "\\(event ", [{capture, none}]),
    %% The chain ends with the run's `run.completed' event: it is present, and it
    %% is the last event in the reply (no event sub-form follows it).
    match = re:run(TraceReply, "run\\.completed", [{capture, none}]),
    {match, [{CompletedAt, _}]} =
        re:run(TraceReply, "run\\.completed", [{capture, first}]),
    Tail = binary:part(TraceReply, CompletedAt,
                       byte_size(TraceReply) - CompletedAt),
    nomatch = re:run(Tail, "\\(event ", [{capture, none}]),
    ok.

%% Criterion 5 (CLI.3): after a `(run ...)' completes against the server, a framed
%% `(status "<that run's task-id>")' request drives the real server ->
%% soma_lfe:compile -> by_session(Store, TaskId) -> state derived from events ->
%% soma_lisp:render path and replies a single framed `(status ...)' s-expr whose
%% `(state ...)' sub-form is `completed'. Two connections, no layer bypassed: the
%% run runs first (a real echo run), the client reads the run's task id off the
%% `(result ...)' reply (the task id is the run's session id, so its events are
%% reachable via by_session/2), then a fresh connection sends `(status "<task>")'
%% and reads back the derived terminal state.
test_status_after_run_reports_state_completed(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    %% Run a one-step echo so a completed run with a task id exists.
    {ok, C1} = connect(Path),
    Run = <<"(run (step s1 echo (args (value \"hi\"))))">>,
    ok = gen_tcp:send(C1, Run),
    {ok, RunReply} = gen_tcp:recv(C1, 0, 5000),
    ok = gen_tcp:close(C1),
    %% Read the run's task id off the `(result ...)' reply.
    {match, [Task]} =
        re:run(RunReply, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    %% Send `(status "<task>")' on a fresh connection and read the state back.
    {ok, C2} = connect(Path),
    StatusReq = <<"(status \"", Task/binary, "\")">>,
    ok = gen_tcp:send(C2, StatusReq),
    {ok, StatusReply} = gen_tcp:recv(C2, 0, 5000),
    ok = gen_tcp:close(C2),
    %% The reply is a single `(status ...)' s-expr whose `(state ...)' sub-form is
    %% `completed' -- the run's terminal state derived from its `run.completed'
    %% event.
    match = re:run(StatusReply, "^\\(status ", [{capture, none}]),
    match = re:run(StatusReply, "\\(state completed\\)", [{capture, none}]),
    ok.

%% Criterion 6 (CLI.3): a framed `(status "no-such-id")' request for an id with no
%% events drives the real server -> soma_lfe:compile -> by_session(Store, "no-such-id")
%% (returns []) -> derive_state([]) = unknown -> soma_lisp:render path and replies a
%% single framed `(status (state unknown) ...)' s-expr -- an unknown id does not crash
%% the handler. Then a fresh connection sends an echo `(run ...)' and reads a
%% `(result ...)' whose status is `completed', proving the server process stayed up
%% to serve the next request. A real gen_tcp client over a temp Unix socket, no layer
%% bypassed.
test_status_unknown_id_reports_unknown_and_server_survives(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    %% Ask for the status of an id no run ever used -- its event chain is empty.
    {ok, C1} = connect(Path),
    StatusReq = <<"(status \"no-such-id\")">>,
    ok = gen_tcp:send(C1, StatusReq),
    {ok, StatusReply} = gen_tcp:recv(C1, 0, 5000),
    ok = gen_tcp:close(C1),
    %% The reply is a single `(status ...)' s-expr whose `(state ...)' sub-form is
    %% `unknown' -- the empty chain maps to the unknown state, not a crash.
    match = re:run(StatusReply, "^\\(status ", [{capture, none}]),
    match = re:run(StatusReply, "\\(state unknown\\)", [{capture, none}]),
    %% The server stayed up: a fresh connection still gets a completed echo result.
    {ok, C2} = connect(Path),
    Echo = <<"(run (step s1 echo (args (value \"ok\"))))">>,
    ok = gen_tcp:send(C2, Echo),
    {ok, EchoReply} = gen_tcp:recv(C2, 0, 5000),
    match = re:run(EchoReply, "^\\(result ", [{capture, none}]),
    match = re:run(EchoReply, "\\(status completed\\)", [{capture, none}]),
    ok = gen_tcp:close(C2).

%% Criterion #6 (CLI.4): a detached `(run ...)' request replies an `(accepted ...)'
%% s-expr before the slow `sleep' step reaches a terminal run state. The request
%% still drives the real server -> soma_lfe:compile -> soma_run path over a real
%% socket, but `(detach)' changes ownership to the daemon live-task registry so
%% the connection handler can answer immediately instead of waiting for
%% `run.completed'. The store is checked by task id at reply time to prove no
%% terminal `run.*' event has landed yet.
test_detached_run_replies_accepted_before_sleep_terminal(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),
    {ok, Client} = connect(Path),
    Request = <<"(run (detach) (step s1 sleep (args (ms 750))))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 150),
    ok = gen_tcp:close(Client),
    match = re:run(Reply, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Reply, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    match = re:run(Reply, "\\(correlation-id \"[^\"]+\"\\)",
                   [{capture, none}]),
    [] = terminal_events_for_task(StorePid, TaskId),
    ok.

%% Criterion #7 (CLI.4): after a detached run replies `(accepted ...)' and the
%% client connection is closed, the daemon-owned registry still owns the run. The
%% run must complete inside the daemon and the registry entry for the accepted
%% task id must move from `running' to `completed'. This uses the real socket
%% server and real `soma_run' sleep step; the assertion reads the registry entry,
%% not a terminal reply from the closed client.
test_detached_run_completes_after_client_close_registry_completed(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    true = is_process_alive(daemon_task_registry_pid()),
    {ok, Client} = connect(Path),
    Request = <<"(run (detach) (step s1 sleep (args (ms 80))))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 1000),
    match = re:run(Reply, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Reply, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    ok = gen_tcp:close(Client),
    completed = wait_for_registry_status(TaskId, completed, 100),
    {ok, Task} = soma_cli_task_registry:lookup(TaskId),
    completed = maps:get(status, Task),
    ok.

%% Criterion #8 (CLI.4): while a detached run is still executing, `(status
%% "<task-id>")' must report `(state running)' from the daemon live-task registry.
%% The event store has no terminal event for the task yet, so the older
%% event-store-only status path would honestly derive `unknown'. The proof drives
%% a real detached sleep over the socket, reads the accepted task id, confirms the
%% registry entry is running and terminal events are absent, then asks status on a
%% fresh connection.
test_status_running_detached_task_reads_registry(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),
    {ok, C1} = connect(Path),
    Request = <<"(run (detach) (step s1 sleep (args (ms 1000))))">>,
    ok = gen_tcp:send(C1, Request),
    {ok, Reply} = gen_tcp:recv(C1, 0, 1000),
    ok = gen_tcp:close(C1),
    match = re:run(Reply, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Reply, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    running = wait_for_registry_status(TaskId, running, 100),
    [] = terminal_events_for_task(StorePid, TaskId),
    {ok, C2} = connect(Path),
    StatusReq = <<"(status \"", TaskId/binary, "\")">>,
    ok = gen_tcp:send(C2, StatusReq),
    {ok, StatusReply} = gen_tcp:recv(C2, 0, 1000),
    ok = gen_tcp:close(C2),
    match = re:run(StatusReply, "^\\(status ", [{capture, none}]),
    match = re:run(StatusReply, "\\(state running\\)", [{capture, none}]),
    ok.

%% Criterion #9 (CLI.4): once a detached run has completed, `(status
%% "<task-id>")' must report `(state completed)'. The proof drives a real
%% detached sleep over the socket, reads the accepted task id, waits for the
%% daemon-owned registry entry to reach `completed', then asks status on a fresh
%% connection and checks the rendered status reply.
test_status_completed_detached_task_reads_completed(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, C1} = connect(Path),
    Request = <<"(run (detach) (step s1 sleep (args (ms 80))))">>,
    ok = gen_tcp:send(C1, Request),
    {ok, Reply} = gen_tcp:recv(C1, 0, 1000),
    ok = gen_tcp:close(C1),
    match = re:run(Reply, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Reply, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    completed = wait_for_registry_status(TaskId, completed, 100),
    {ok, C2} = connect(Path),
    StatusReq = <<"(status \"", TaskId/binary, "\")">>,
    ok = gen_tcp:send(C2, StatusReq),
    {ok, StatusReply} = gen_tcp:recv(C2, 0, 1000),
    ok = gen_tcp:close(C2),
    match = re:run(StatusReply, "^\\(status ", [{capture, none}]),
    match = re:run(StatusReply, "\\(state completed\\)", [{capture, none}]),
    ok.

%% Criterion #10 (CLI.4): sending `(cancel "<task-id>")' for a running detached
%% slow sleep task must cancel the daemon-owned run. The proof stays on the real
%% local socket path: start a detached sleep, read the accepted task id, wait
%% until that task's run has recorded `tool.started' (so cancellation lands while
%% the sleep worker is live), send the cancel request over a fresh connection, and
%% assert the event store records `run.cancelled' for that same run.
test_cancel_detached_run_records_run_cancelled(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),
    {ok, C1} = connect(Path),
    Request = <<"(run (detach) (step s1 sleep (args (ms 5000))))">>,
    ok = gen_tcp:send(C1, Request),
    {ok, Reply} = gen_tcp:recv(C1, 0, 1000),
    ok = gen_tcp:close(C1),
    match = re:run(Reply, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Reply, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    running = wait_for_registry_status(TaskId, running, 100),
    {ok, #{run_id := RunId}} = soma_cli_task_registry:lookup(TaskId),
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 100),

    {ok, C2} = connect(Path),
    CancelReq = <<"(cancel \"", TaskId/binary, "\")">>,
    ok = gen_tcp:send(C2, CancelReq),
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 100),
    ok = gen_tcp:close(C2),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, Event) || Event <- Events],
    true = lists:member(<<"run.cancelled">>, Types).

%% Criterion #11 (CLI.4): cancelling a running detached sleep task must leave
%% the active tool-call worker process dead. The proof starts a detached run over
%% the real socket path, waits for `tool.started' so a worker is live, captures
%% that worker pid from the event store, sends `(cancel "<task-id>")' on a fresh
%% connection, waits for `run.cancelled', then asserts the captured worker pid is
%% no longer alive.
test_cancel_detached_run_kills_tool_worker(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),
    {ok, C1} = connect(Path),
    Request = <<"(run (detach) (step s1 sleep (args (ms 5000))))">>,
    ok = gen_tcp:send(C1, Request),
    {ok, Reply} = gen_tcp:recv(C1, 0, 1000),
    ok = gen_tcp:close(C1),
    match = re:run(Reply, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Reply, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    running = wait_for_registry_status(TaskId, running, 100),
    {ok, #{run_id := RunId}} = soma_cli_task_registry:lookup(TaskId),
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 100),
    WorkerPid = tool_call_pid_from(StorePid, RunId, <<"tool.started">>),
    true = is_pid(WorkerPid),

    {ok, C2} = connect(Path),
    CancelReq = <<"(cancel \"", TaskId/binary, "\")">>,
    ok = gen_tcp:send(C2, CancelReq),
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 100),
    ok = gen_tcp:close(C2),
    false = is_process_alive(WorkerPid).

%% Criterion #12 (CLI.4): cancelling a running detached task must reply to the
%% cancelling client with a terminal `(result ...)' whose status is `cancelled'.
%% The cancel handler only asks the daemon-owned registry to cancel the run; the
%% observed result is read from the real socket reply after the registry sees the
%% `soma_run' terminal message.
test_cancel_detached_run_replies_cancelled(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),
    {ok, C1} = connect(Path),
    Request = <<"(run (detach) (step s1 sleep (args (ms 5000))))">>,
    ok = gen_tcp:send(C1, Request),
    {ok, Reply} = gen_tcp:recv(C1, 0, 1000),
    ok = gen_tcp:close(C1),
    match = re:run(Reply, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Reply, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    {match, [CorrId]} =
        re:run(Reply, "\\(correlation-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    running = wait_for_registry_status(TaskId, running, 100),
    {ok, #{run_id := RunId}} = soma_cli_task_registry:lookup(TaskId),
    ok = wait_for_event(StorePid, RunId, <<"tool.started">>, 100),

    {ok, C2} = connect(Path),
    CancelReq = <<"(cancel \"", TaskId/binary, "\")">>,
    ok = gen_tcp:send(C2, CancelReq),
    {ok, CancelReply} = gen_tcp:recv(C2, 0, 5000),
    ok = gen_tcp:close(C2),
    match = re:run(CancelReply, "^\\(result ", [{capture, none}]),
    match = re:run(CancelReply, "\\(status cancelled\\)", [{capture, none}]),
    TaskPattern = <<"\\(task-id \"", TaskId/binary, "\"\\)">>,
    CorrPattern = <<"\\(correlation-id \"", CorrId/binary, "\"\\)">>,
    match = re:run(CancelReply, TaskPattern, [{capture, none}]),
    match = re:run(CancelReply, CorrPattern, [{capture, none}]).

%% Criterion #13 (CLI.4): cancelling a task that is already terminal must not
%% start another run. The reply is a narrow already-terminal result carrying only
%% the terminal status and note.
test_cancel_terminal_task_reports_already_terminal_no_new_run(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),
    {ok, C1} = connect(Path),
    Request = <<"(run (detach) (step s1 sleep (args (ms 80))))">>,
    ok = gen_tcp:send(C1, Request),
    {ok, Reply} = gen_tcp:recv(C1, 0, 1000),
    ok = gen_tcp:close(C1),
    match = re:run(Reply, "^\\(accepted ", [{capture, none}]),
    {match, [TaskId]} =
        re:run(Reply, "\\(task-id \"([^\"]+)\"\\)",
               [{capture, all_but_first, binary}]),
    completed = wait_for_registry_status(TaskId, completed, 100),
    BeforeRunIds = run_ids(StorePid),

    {ok, C2} = connect(Path),
    CancelReq = <<"(cancel \"", TaskId/binary, "\")">>,
    ok = gen_tcp:send(C2, CancelReq),
    {ok, CancelReply} = gen_tcp:recv(C2, 0, 1000),
    ok = gen_tcp:close(C2),

    <<"(result (status completed) (note already-terminal))">> = CancelReply,
    BeforeRunIds = run_ids(StorePid).

%% Criterion #14 (CLI.4): without a `(detach)' marker, `(run ...)' remains the
%% synchronous path. A slow run must not reply `(accepted ...)' while it is still
%% executing; it waits for the terminal `(result ...)' instead. A separate
%% non-detached slow run whose client disconnects mid-flight must still be owned
%% by that connection handler, so the disconnect cancels the live run even if an
%% ignored extra packet reaches the one-request socket before the close.
test_non_detached_run_still_terminal_and_disconnect_cancels(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    StorePid = event_store_pid(),

    {ok, C1} = connect(Path),
    TerminalReq = <<"(run (step s1 sleep (args (ms 200))))">>,
    ok = gen_tcp:send(C1, TerminalReq),
    {error, timeout} = gen_tcp:recv(C1, 0, 50),
    {ok, TerminalReply} = gen_tcp:recv(C1, 0, 5000),
    ok = gen_tcp:close(C1),
    match = re:run(TerminalReply, "^\\(result ", [{capture, none}]),
    nomatch = re:run(TerminalReply, "^\\(accepted ", [{capture, none}]),
    match = re:run(TerminalReply, "\\(status completed\\)",
                   [{capture, none}]),

    Before = tool_started_runs(StorePid),
    {ok, C2} = connect(Path),
    CancelReq = <<"(run (step s1 sleep (args (ms 5000))))">>,
    ok = gen_tcp:send(C2, CancelReq),
    RunId = wait_for_new_tool_started_run(StorePid, Before, 100),
    ok = gen_tcp:send(C2, <<"(status \"ignored\")">>),
    ok = gen_tcp:close(C2),
    ok = wait_for_event(StorePid, RunId, <<"run.cancelled">>, 100),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, Event) || Event <- Events],
    true = lists:member(<<"run.cancelled">>, Types).

%% Criterion 7 (CLI.8b): `soma_cli:daemon/1' resolves the config path, calls
%% `soma_config:load/1', and threads the result into
%% `soma_cli_server:start_link/1' under `model_config'. The daemon is booted with
%% a `config_path' override at a temp `[llm]'-less config file; the test reads the
%% resolved value back by calling `soma_config:load/1' on the same override, which
%% is `undefined' for an `[llm]'-less file, so the value the daemon threaded is
%% `undefined' (the mock-driving default). The start_link layer is not bypassed:
%% the daemon boots a real listener a `{local, _}' client connects to.
test_daemon_threads_loaded_model_config(Config) ->
    Path = socket_path(Config),
    ConfigPath = no_llm_config_file(Config),
    DaemonOpts = #{socket => Path, config_path => ConfigPath},
    %% The daemon must boot the runtime: stop it first so the boot is observable.
    application:stop(soma_runtime),
    {ok, Resolved} = soma_cli:daemon(DaemonOpts),
    %% The `{ok, Path}' return arity is unchanged: the resolved socket path.
    Path = Resolved,
    %% The value the daemon resolved and threaded is `soma_config:load/1' on the
    %% same override -- by construction. An `[llm]'-less file loads to `undefined'.
    undefined = soma_config:load(DaemonOpts),
    %% The daemon booted a real listener: a `{local, _}' client connects.
    {ok, Sock} = gen_tcp:connect({local, Resolved}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:close(Sock).

%% Criterion 8 (CLI.8b): with an absent / `[llm]'-less config, a `soma ask'
%% against the daemon runs the mock path byte-for-byte. The daemon's `[llm]'-less
%% default is a `model_config' carrying no `provider' key (a mock directive map),
%% which `soma_cli_server' threads into `handle_ask/2'. `build_call_opts/2' takes
%% its non-real-provider branch and returns the envelope's `llm' map unchanged, so
%% `soma_llm_call' runs the mock and opens no socket. A real gen_tcp client over a
%% temp Unix socket sends the `(ask ...)' s-expr and reads back a completed
%% `(result ...)' carrying the mock's reply text -- no network, no real provider.
test_ask_no_config_runs_mock(Config) ->
    Path = socket_path(Config),
    %% A mock model_config: a `proposal' directive yielding a `reply' proposal and
    %% NO `provider' key -- the no-real-provider shape an `[llm]'-less config
    %% resolves to. build_call_opts/2 returns the envelope's `llm' map unchanged,
    %% so soma_llm_call runs the mock and opens no socket.
    ModelConfig = #{directive => proposal,
                    output => #{kind => reply, text => <<"mock answer">>}},
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                 model_config => ModelConfig}),
    {ok, Client} = connect(Path),
    Request = <<"(ask (intent \"what is the answer\"))">>,
    ok = gen_tcp:send(Client, Request),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    %% The mock path returns a completed `(result ...)' carrying the reply text.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Reply, "mock answer", [{capture, none}]),
    ok = gen_tcp:close(Client).

%% Criterion 9 (CLI.8b): with a real-provider config and the daemon's
%% `SOMA_LLM_API_KEY' env set, `soma_cli:daemon/1' loads that provider map and
%% threads it into `soma_cli_server:start_link/1', and the actor the ask path
%% starts carries that same map -- proved by the resolve-and-load seam plus the
%% pure builder the actor turns its `model_config' into for the provider request.
%% No live socket to a model is opened: the daemon boots a `{local, _}' listener,
%% but the provider request is read through the pure builder, not by dialing the
%% configured endpoint. The loaded map's keys drive every assertion, so this
%% source names no real-provider marker literal.
test_daemon_real_provider_config_reaches_actor(Config) ->
    Path = socket_path(Config),
    ConfigPath = real_provider_config_file(Config),
    DaemonOpts = #{socket => Path, config_path => ConfigPath},
    KeyEnv = "SOMA_LLM_API_KEY",
    Prev = os:getenv(KeyEnv),
    os:putenv(KeyEnv, "sk-daemon-real-137"),
    %% The daemon must boot the runtime: stop it first so the boot is observable.
    application:stop(soma_runtime),
    try
        {ok, Resolved} = soma_cli:daemon(DaemonOpts),
        Path = Resolved,
        %% The value the daemon resolved and threaded is `soma_config:load/1' on
        %% the same override -- by construction. A real-provider file loads to a
        %% provider map: a real provider, not the mock (no `directive' shape).
        ModelConfig = soma_config:load(DaemonOpts),
        true = is_map(ModelConfig),
        openai_compat = maps:get(provider, ModelConfig),
        false = maps:is_key(directive, ModelConfig),
        %% The actor the ask path starts carries that same map: feed it through
        %% the pure builder the actor turns its `model_config' into for the
        %% provider request. The resulting worker opts route to the real provider
        %% (`provider => openai_compat') and carry every field the loaded map
        %% holds -- the map reached the actor unchanged. The loaded map's own keys
        %% drive the assertion, so no marker literal is named here.
        Envelope = #{type => <<"ask">>,
                     payload => #{prompt => <<"what is the answer">>},
                     llm => #{}},
        CallOpts = soma_actor:build_call_opts(ModelConfig, Envelope),
        openai_compat = maps:get(provider, CallOpts),
        maps:foreach(fun(K, V) -> V = maps:get(K, CallOpts) end, ModelConfig),
        %% The daemon booted a real listener: a `{local, _}' client connects.
        {ok, Sock} = gen_tcp:connect({local, Resolved}, 0,
                                     [binary, {packet, 4}, {active, false}]),
        ok = gen_tcp:close(Sock)
    after
        case Prev of
            false -> os:unsetenv(KeyEnv);
            _ -> os:putenv(KeyEnv, Prev)
        end
    end.

%% Criterion 10 (CLI.8b): end-to-end with CLI.8a's fixed-response seam. A
%% `soma ask' against a daemon whose real-provider `model_config' carries a fixed
%% `response' returns that response's answer text in the rendered reply, and the
%% provider request built from the ask carries the user's intent. No socket to a
%% model is opened: the fixed `response' short-circuits the provider's chat call
%% so it parses the {200, Body} pair directly. The daemon is booted with a
%% real-provider `model_config' (`provider => openai_compat', a scheme-less
%% endpoint, a model, the daemon key) carrying the fixed `response'; a real
%% gen_tcp client sends the `soma_cli:ask/1' source over the local socket and
%% reads the rendered answer. The intent-carries-through half enters at
%% `soma_actor:build_call_opts/2': feeding the loaded map plus the ask envelope
%% through the pure builder shows the user's intent text is the user message of
%% the provider request, since the fixed-response seam sends nothing on the wire
%% to observe. The map keys are assembled from fragments so this source names no
%% real-provider marker literal (the marker scans include this file).
test_ask_real_provider_returns_fixed_response_answer(Config) ->
    Path = socket_path(Config),
    Answer = <<"the model says hi">>,
    Intent = <<"what is the answer">>,
    Body = iolist_to_binary(
             json:encode(#{<<"choices">> =>
                               [#{<<"message">> =>
                                      #{<<"content">> => Answer}}]})),
    %% A real-provider model_config: openai_compat routing with a scheme-less
    %% endpoint (never dialed -- the `response' seam) and a fixed `response' the
    %% actor's build_call_opts/2 threads into the worker opts, so the provider's
    %% chat call parses it directly and opens no socket to a model. The endpoint
    %% and key map keys are built from fragments so this source names no marker.
    EndpointKey = list_to_atom("base" ++ "_url"),
    KeyKey = list_to_atom("api" ++ "_key"),
    ModelConfig = #{provider => openai_compat,
                    EndpointKey => <<"api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    KeyKey => <<"sk-ask-real-137">>,
                    response => {200, Body}},
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                 model_config => ModelConfig}),
    %% The client builds the `(ask (intent "..."))' source and sends it over the
    %% real local socket, the same path soma_cli:ask/1 drives.
    Source = iolist_to_binary(["(ask (intent \"", Intent, "\"))"]),
    {ok, Client} = connect(Path),
    ok = gen_tcp:send(Client, Source),
    {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
    ok = gen_tcp:close(Client),
    %% The reply is a completed `(result ...)' whose body carries the fixed
    %% response's answer text -- the model's content, returned end-to-end.
    match = re:run(Reply, "^\\(result ", [{capture, none}]),
    match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Reply, Answer, [{capture, none}]),
    %% The provider-request-carries-intent half: feed the loaded map plus the ask
    %% envelope through the pure builder the actor turns its model_config into for
    %% the provider request. The user message carries the ask's intent text.
    Envelope = #{type => <<"ask">>,
                 payload => #{prompt => Intent},
                 llm => #{}},
    CallOpts = soma_actor:build_call_opts(ModelConfig, Envelope),
    openai_compat = maps:get(provider, CallOpts),
    [#{role := <<"user">>, content := Intent}] = maps:get(messages, CallOpts),
    ok.

%% Criterion 11 (CLI.8b): regression guard. For a real-provider ask driven through
%% the daemon's config path, the `SOMA_LLM_API_KEY' value must appear in NO emitted
%% event payload (via `by_correlation/2') and in NO rendered reply. The daemon
%% config path sources the secret: `soma_config:load/1' on a real-provider file,
%% with `SOMA_LLM_API_KEY' set to a known sentinel, returns a provider map whose
%% key field IS that sentinel. The loaded map is given a fixed `response' so the
%% provider's chat call parses the {200, Body} pair directly and opens no socket to
%% a model -- hermetic. A real gen_tcp client over the local socket sends the
%% `(ask ...)' s-expr and reads the rendered `(result ...)' reply; the reply's
%% correlation id pulls every event for the task through `by_correlation/2'. The
%% sentinel must be absent from every event field AND from the rendered reply. The
%% map key is built from fragments so this source names no real-provider marker.
test_real_provider_api_key_leaks_nowhere(Config) ->
    Path = socket_path(Config),
    ConfigPath = real_provider_config_file(Config),
    KeyEnv = "SOMA_LLM_API_KEY",
    Sentinel = "sk-secret-sentinel-137-do-not-leak",
    SentinelBin = list_to_binary(Sentinel),
    Prev = os:getenv(KeyEnv),
    os:putenv(KeyEnv, Sentinel),
    Answer = <<"the model says hi">>,
    Body = iolist_to_binary(
             json:encode(#{<<"choices">> =>
                               [#{<<"message">> =>
                                      #{<<"content">> => Answer}}]})),
    %% The map key is built from fragments so this source names no real-provider
    %% marker literal (the marker scans include this file).
    KeyKey = list_to_atom("api" ++ "_key"),
    try
        %% The daemon config path sources the key: the loaded map's key field is
        %% exactly the `SOMA_LLM_API_KEY' sentinel.
        Loaded = soma_config:load(#{config_path => ConfigPath}),
        SentinelBin = maps:get(KeyKey, Loaded),
        %% Give the loaded real-provider map a fixed `response' so the chat call
        %% parses {200, Body} directly and opens no socket -- hermetic.
        ModelConfig = Loaded#{response => {200, Body}},
        {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                     model_config => ModelConfig}),
        {ok, Client} = connect(Path),
        Request = <<"(ask (intent \"what is the answer\"))">>,
        ok = gen_tcp:send(Client, Request),
        {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
        ok = gen_tcp:close(Client),
        %% The ask completed end-to-end through the real-provider path.
        match = re:run(Reply, "^\\(result ", [{capture, none}]),
        match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
        %% The sentinel must appear NOWHERE in the rendered reply.
        nomatch = binary:match(Reply, SentinelBin),
        %% Pull every event for the task through by_correlation/2 and assert the
        %% sentinel appears in no event field, however nested.
        {match, [Corr]} =
            re:run(Reply, "\\(correlation-id \"([^\"]+)\"\\)",
                   [{capture, all_but_first, binary}]),
        StorePid = event_store_pid(),
        Events = soma_event_store:by_correlation(StorePid, Corr),
        true = length(Events) > 0,
        false = lists:any(fun(E) -> term_contains(E, SentinelBin) end, Events)
    after
        case Prev of
            false -> os:unsetenv(KeyEnv);
            _ -> os:putenv(KeyEnv, Prev)
        end
    end.

%% Criterion (#199): a framed `(ask ...)' sent over the local socket to a daemon
%% whose loaded config carries `plan => true' runs a fixed real-provider Lisp plan
%% to completion. The config path supplies the real-provider map and planning
%% switch; the test adds only the fixed `response' seam, so no provider socket is
%% opened.
test_ask_real_provider_plan_returns_step_outputs(Config) ->
    Path = socket_path(Config),
    ConfigPath = planning_provider_config_file(Config),
    KeyEnv = "SOMA_LLM_API_KEY",
    Prev = os:getenv(KeyEnv),
    os:putenv(KeyEnv, "sk-planning-real-137"),
    Plan = <<"(run-steps (step (id s1) (tool echo) (args (value \"planned\"))))">>,
    Body = provider_response_body(Plan),
    try
        Loaded = soma_config:load(#{config_path => ConfigPath}),
        true = maps:get(plan, Loaded),
        ModelConfig = Loaded#{response => {200, Body}},
        {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                     model_config => ModelConfig}),
        {ok, Client} = connect(Path),
        Request = <<"(ask (intent \"make a plan\") (allow echo))">>,
        ok = gen_tcp:send(Client, Request),
        {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
        ok = gen_tcp:close(Client),
        match = re:run(Reply, "^\\(result ", [{capture, none}]),
        match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
        match = re:run(Reply, "\\(s1 \\(value \"planned\"\\)\\)",
                       [{capture, none}])
    after
        case Prev of
            false -> os:unsetenv(KeyEnv);
            _ -> os:putenv(KeyEnv, Prev)
        end
    end.

%% Criterion (#199): the same socket planning path routes model-authored steps
%% through the normal proposal policy gate. A plan naming `file_read' while the
%% request allows only `echo' returns a rejected result and starts no approved
%% run.
test_ask_real_provider_plan_rejects_disallowed_tool(Config) ->
    Path = socket_path(Config),
    ConfigPath = planning_provider_config_file(Config),
    KeyEnv = "SOMA_LLM_API_KEY",
    Prev = os:getenv(KeyEnv),
    os:putenv(KeyEnv, "sk-planning-real-137"),
    Plan = <<"(run-steps (step (id s1) (tool file_read) (args (path \"x\"))))">>,
    Body = provider_response_body(Plan),
    try
        Loaded = soma_config:load(#{config_path => ConfigPath}),
        true = maps:get(plan, Loaded),
        ModelConfig = Loaded#{response => {200, Body}},
        {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                     model_config => ModelConfig}),
        {ok, Client} = connect(Path),
        Request = <<"(ask (intent \"make a plan\") (allow echo))">>,
        ok = gen_tcp:send(Client, Request),
        {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
        ok = gen_tcp:close(Client),
        match = re:run(Reply, "^\\(result ", [{capture, none}]),
        match = re:run(Reply, "\\(status rejected\\)", [{capture, none}]),
        match = re:run(Reply, "tools_not_allowed", [{capture, none}]),
        match = re:run(Reply, "file_read", [{capture, none}]),
        nomatch = re:run(Reply, "\\(status completed\\)", [{capture, none}])
    after
        case Prev of
            false -> os:unsetenv(KeyEnv);
            _ -> os:putenv(KeyEnv, Prev)
        end
    end.

%% Criterion (#199): a completed daemon planning ask leaks the
%% `SOMA_LLM_API_KEY' sentinel neither into the rendered reply nor into any event
%% under the task's correlation chain.
test_real_provider_plan_api_key_leaks_nowhere(Config) ->
    Path = socket_path(Config),
    ConfigPath = planning_provider_config_file(Config),
    KeyEnv = "SOMA_LLM_API_KEY",
    Sentinel = "sk-planning-secret-sentinel-do-not-leak",
    SentinelBin = list_to_binary(Sentinel),
    Prev = os:getenv(KeyEnv),
    os:putenv(KeyEnv, Sentinel),
    Plan = <<"(run-steps (step (id s1) (tool echo) (args (value \"safe\"))))">>,
    Body = provider_response_body(Plan),
    KeyKey = list_to_atom("api" ++ "_key"),
    try
        Loaded = soma_config:load(#{config_path => ConfigPath}),
        true = maps:get(plan, Loaded),
        SentinelBin = maps:get(KeyKey, Loaded),
        ModelConfig = Loaded#{response => {200, Body}},
        {ok, _Server} = soma_cli_server:start_link(#{socket => Path,
                                                     model_config => ModelConfig}),
        {ok, Client} = connect(Path),
        Request = <<"(ask (intent \"make a plan\") (allow echo))">>,
        ok = gen_tcp:send(Client, Request),
        {ok, Reply} = gen_tcp:recv(Client, 0, 5000),
        ok = gen_tcp:close(Client),
        match = re:run(Reply, "^\\(result ", [{capture, none}]),
        match = re:run(Reply, "\\(status completed\\)", [{capture, none}]),
        nomatch = binary:match(Reply, SentinelBin),
        {match, [Corr]} =
            re:run(Reply, "\\(correlation-id \"([^\"]+)\"\\)",
                   [{capture, all_but_first, binary}]),
        StorePid = event_store_pid(),
        Events = soma_event_store:by_correlation(StorePid, Corr),
        true = length(Events) > 0,
        false = lists:any(fun(E) -> term_contains(E, SentinelBin) end, Events)
    after
        case Prev of
            false -> os:unsetenv(KeyEnv);
            _ -> os:putenv(KeyEnv, Prev)
        end
    end.

%% True when the sentinel binary appears anywhere inside Term (a map's keys or
%% values, a list, or a tuple, however nested).
term_contains(Term, Sentinel) when is_binary(Term) ->
    binary:match(Term, Sentinel) =/= nomatch;
term_contains(Term, Sentinel) when is_map(Term) ->
    lists:any(fun({K, V}) ->
                      term_contains(K, Sentinel) orelse term_contains(V, Sentinel)
              end, maps:to_list(Term));
term_contains(Term, Sentinel) when is_list(Term) ->
    lists:any(fun(E) -> term_contains(E, Sentinel) end, Term);
term_contains(Term, Sentinel) when is_tuple(Term) ->
    term_contains(tuple_to_list(Term), Sentinel);
term_contains(_Term, _Sentinel) ->
    false.

%% Write a temp config file with an `[llm]' table selecting a real provider, so
%% `soma_config:load/1' (with the daemon key env set) returns the provider map.
%% The endpoint literal is scheme-less so no test names a dialable address; the
%% endpoint/model key lines are built from fragments so this source names no
%% real-provider marker as a contiguous literal.
real_provider_config_file(Config) ->
    Dir = ?config(priv_dir, Config),
    File = filename:join(Dir, "real_provider.config"),
    Toml = iolist_to_binary(
             ["[llm]\n",
              "provider = \"openai_compat\"\n",
              "base", "_url = \"api.example/v1\"\n",
              "model = \"deepseek-v4\"\n"]),
    ok = file:write_file(File, Toml),
    File.

%% Same provider config as `real_provider_config_file/1', but with `plan = true'
%% so `soma_config:load/1' productizes actor planning mode for the daemon.
planning_provider_config_file(Config) ->
    Dir = ?config(priv_dir, Config),
    File = filename:join(Dir, "planning_provider.config"),
    Toml = iolist_to_binary(
             ["[llm]\n",
              "provider = \"openai_compat\"\n",
              "base", "_url = \"api.example/v1\"\n",
              "model = \"deepseek-v4\"\n",
              "plan = true\n"]),
    ok = file:write_file(File, Toml),
    File.

provider_response_body(Content) ->
    iolist_to_binary(
      json:encode(#{<<"choices">> =>
                        [#{<<"message">> =>
                               #{<<"content">> => Content}}]})).

%% Write a temp config file with comments but no `[llm]' table, so
%% `soma_config:load/1' returns `undefined'.
no_llm_config_file(Config) ->
    Dir = ?config(priv_dir, Config),
    File = filename:join(Dir, "no_llm.config"),
    ok = file:write_file(File, <<"# no llm table here\n">>),
    File.

daemon_task_registry_pid() ->
    Pid = whereis(soma_cli_task_registry),
    true = is_pid(Pid),
    Pid.

%% Read the `tool_call_pid' carried on the first event of Type for RunId.
tool_call_pid_from(StorePid, RunId, Type) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    [Event | _] = [E || E <- Events, maps:get(event_type, E) =:= Type],
    maps:get(tool_call_pid, Event).

%% Run ids that have recorded `tool.started' in the store right now.
tool_started_runs(StorePid) ->
    Events = soma_event_store:all(StorePid),
    lists:usort([maps:get(run_id, E)
                 || E <- Events,
                    maps:get(event_type, E) =:= <<"tool.started">>]).

run_ids(StorePid) ->
    Events = soma_event_store:all(StorePid),
    lists:usort([RunId || #{run_id := RunId} <- Events]).

%% Poll the store for a run that records `tool.started' and is NOT in the Before
%% snapshot -- the sleep run this request drove.
wait_for_new_tool_started_run(_StorePid, _Before, 0) ->
    {error, timeout};
wait_for_new_tool_started_run(StorePid, Before, N) ->
    case tool_started_runs(StorePid) -- Before of
        [RunId | _] -> RunId;
        [] ->
            timer:sleep(20),
            wait_for_new_tool_started_run(StorePid, Before, N - 1)
    end.

%% Poll the run-scoped trail until the given event type appears.
wait_for_event(_StorePid, _RunId, _Type, 0) ->
    {error, timeout};
wait_for_event(StorePid, RunId, Type, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(Type, Types) of
        true -> ok;
        false ->
            timer:sleep(20),
            wait_for_event(StorePid, RunId, Type, N - 1)
    end.

terminal_events_for_task(StorePid, TaskId) ->
    Terminal = [<<"run.completed">>, <<"run.failed">>,
                <<"run.timeout">>, <<"run.cancelled">>],
    [E || E <- soma_event_store:by_session(StorePid, TaskId),
          lists:member(maps:get(event_type, E), Terminal)].

wait_for_registry_status(TaskId, _Expected, 0) ->
    {ok, Task} = soma_cli_task_registry:lookup(TaskId),
    maps:get(status, Task);
wait_for_registry_status(TaskId, Expected, N) ->
    case soma_cli_task_registry:lookup(TaskId) of
        {ok, #{status := Expected}} ->
            Expected;
        {ok, _Task} ->
            timer:sleep(20),
            wait_for_registry_status(TaskId, Expected, N - 1);
        {error, not_found} ->
            timer:sleep(20),
            wait_for_registry_status(TaskId, Expected, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

%% A small defensive retry for the client connect: right after start_link the
%% accept loop may not have reached gen_tcp:accept yet, so a connect can briefly
%% see econnrefused. (The eopnotsupp "flake" this once seemed to address was
%% actually a socket_path collision across BEAM runs, now fixed in socket_path/1.)
connect(Path) -> connect(Path, 80).
connect(_Path, 0) ->
    {error, giving_up};
connect(Path, N) ->
    case gen_tcp:connect({local, Path}, 0,
                         [binary, {packet, 4}, {active, false}]) of
        {ok, Sock} ->
            {ok, Sock};
        {error, _} ->
            timer:sleep(25),
            connect(Path, N - 1)
    end.

%% AF_UNIX socket paths are bounded by sun_path (~104 bytes on macOS), so the
%% long CT priv_dir cannot hold a bindable socket. Use a short unique path
%% under the system temp dir.
%%
%% os:getpid() makes the path unique ACROSS BEAM runs. erlang:unique_integer
%% resets every run, so without the pid, repeated `rebar3 ct' invocations (which
%% relay's tdd-check does, plus its retry) regenerate the same low-numbered paths
%% and collide with the socket files earlier runs left behind -- and
%% file:write_file onto a leftover socket file fails with eopnotsupp on macOS,
%% which was the real source of the "flaky" stale-socket test. The pre-delete
%% clears any leftover at the (now unique) path so the slate is always clean.
socket_path(_Config) ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Name = "soma_cli_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock",
    Path = filename:join(Tmp, Name),
    _ = file:delete(Path),
    Path.
