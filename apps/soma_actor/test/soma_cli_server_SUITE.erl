-module(soma_cli_server_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_start_link_listens_and_accepts_connect/1]).
-export([test_start_link_unlinks_stale_socket_file/1]).
-export([test_second_start_link_on_live_path_errors/1]).
-export([test_first_server_survives_failed_second_start_link/1]).
-export([test_run_lisp_echo_returns_completed_result/1]).
-export([test_run_lisp_result_carries_correlation_id/1]).
-export([test_run_lisp_failed_returns_error_result/1]).
-export([test_server_serves_after_failed_lisp_run/1]).
-export([test_malformed_request_returns_error_sexpr/1]).
-export([test_server_serves_after_malformed_request/1]).
-export([test_run_cancelled_on_client_disconnect/1]).
-export([test_worker_dead_after_client_disconnect/1]).
-export([test_server_serves_after_client_disconnect/1]).
-export([test_ask_reply_returns_completed_result_with_text/1]).
-export([test_ask_reject_returns_rejected_result_with_reason/1]).
-export([test_ask_budget_llm_zero_returns_budget_exceeded/1]).
-export([test_trace_after_run_returns_ordered_chain_ending_completed/1]).

all() ->
    [test_start_link_listens_and_accepts_connect,
     test_start_link_unlinks_stale_socket_file,
     test_second_start_link_on_live_path_errors,
     test_first_server_survives_failed_second_start_link,
     test_run_lisp_echo_returns_completed_result,
     test_run_lisp_result_carries_correlation_id,
     test_run_lisp_failed_returns_error_result,
     test_server_serves_after_failed_lisp_run,
     test_malformed_request_returns_error_sexpr,
     test_server_serves_after_malformed_request,
     test_run_cancelled_on_client_disconnect,
     test_worker_dead_after_client_disconnect,
     test_server_serves_after_client_disconnect,
     test_ask_reply_returns_completed_result_with_text,
     test_ask_reject_returns_rejected_result_with_reason,
     test_ask_budget_llm_zero_returns_budget_exceeded,
     test_trace_after_run_returns_ordered_chain_ending_completed].

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
    ok = file:write_file(Path, <<"stale">>),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Client} = connect(Path),
    ok = gen_tcp:close(Client).

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
