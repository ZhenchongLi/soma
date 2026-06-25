%% @doc Actor-facing proofs for the soma_llm_call worker, set up like
%% soma_actor_SUITE: boot the soma_runtime app (so soma_run_sup and the event
%% store are alive), start an actor through soma_actor_sup:start_actor/1 with the
%% booted runtime's event store, and drive it through the real soma_actor:send/2
%% with an `llm' envelope.
-module(soma_llm_call_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([llm_worker_runs_in_distinct_pid/1]).
-export([get_task_result_holds_llm_output/1]).
-export([slow_call_times_out_worker_dead_actor_alive/1]).
-export([cancel_in_flight_call_worker_dead_actor_alive/1]).
-export([crash_reaches_actor_as_failed_via_down/1]).
-export([crash_with_timeout_ms_stays_failed_no_spurious_timeout/1]).
-export([status_promptly_while_llm_call_in_flight/1]).
-export([completed_call_appends_llm_event_with_correlation_id/1]).
-export([by_correlation_returns_llm_and_actor_events/1]).
-export([both_steps_and_llm_rejected_no_child_started/1]).
-export([pins_v0_5_test_contract_maps_each_proof/1]).

all() ->
    [llm_worker_runs_in_distinct_pid,
     get_task_result_holds_llm_output,
     slow_call_times_out_worker_dead_actor_alive,
     cancel_in_flight_call_worker_dead_actor_alive,
     crash_reaches_actor_as_failed_via_down,
     crash_with_timeout_ms_stays_failed_no_spurious_timeout,
     status_promptly_while_llm_call_in_flight,
     completed_call_appends_llm_event_with_correlation_id,
     by_correlation_returns_llm_and_actor_events,
     both_steps_and_llm_rejected_no_child_started,
     pins_v0_5_test_contract_maps_each_proof].

init_per_testcase(_TestCase, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    {ok, Sup} = soma_actor_sup:start_link(),
    [{sup, Sup}, {started_apps, Started} | Config].

end_per_testcase(_TestCase, Config) ->
    case ?config(sup, Config) of
        undefined -> ok;
        Sup ->
            unlink(Sup),
            exit(Sup, shutdown)
    end,
    application:stop(soma_runtime),
    ok.

%% Criterion 2: when the actor starts an LLM call for a task, the soma_llm_call
%% worker runs in a process whose pid is distinct from the actor pid. The runtime
%% is booted so the event store is alive; the actor is started through
%% soma_actor_sup:start_actor/1 with the booted runtime's event store so the actor
%% and the worker share one store. Enters through the real soma_actor:send/2 call
%% with an `llm' envelope, no layer bypassed. The worker pid is read back from the
%% llm.started event the actor emits and asserted distinct from the actor pid.
llm_worker_runs_in_distinct_pid(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-llm-distinct-pid">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => success, output => <<"hi from the mock">>},
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => <<"task-llm-distinct-pid">>,
                 llm => Llm},
    {ok, <<"task-llm-distinct-pid">>} = soma_actor:send(ActorPid, Envelope),
    Started = wait_for_actor_event(Store, <<"llm.started">>, 100),
    WorkerPid = maps:get(llm_call_pid, Started),
    true = is_pid(WorkerPid),
    true = WorkerPid =/= ActorPid,
    ok.

%% Criterion 3: after a successful mock LLM call, get_task_result returns the
%% call's output for that task. Enters through the real soma_actor:send/2 with a
%% `success' llm envelope carrying a known output, waits for the {llm_result, ...}
%% success message to land (the task reaching `completed'), then asserts
%% get_task_result/2 returns {ok, Output} carrying that configured output.
get_task_result_holds_llm_output(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-llm-result">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Output = <<"the mock reply">>,
    %% A `timeout_ms' arms a real call-timeout timer, so the success result path
    %% runs through clear_llm_timer/2's actual erlang:cancel_timer branch (the
    %% line dialyzer's unmatched_returns flags). clear_llm_timer/2 must still
    %% return Data carrying the output and cancel the timer so no stale timer
    %% later fires a spurious `llm.timeout' against the finished task.
    Llm = #{directive => success, output => Output, timeout_ms => 50},
    TaskId = <<"task-llm-result">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    {ok, Output} = soma_actor:get_task_result(ActorPid, TaskId),
    %% Sleep past the 50ms window so a stale (uncancelled) timer would have fired.
    timer:sleep(200),
    completed = maps:get(status, soma_actor:get_task_status(ActorPid, TaskId)),
    Events = soma_event_store:all(Store),
    [] = [E || E <- Events,
               maps:get(event_type, E, undefined) =:= <<"llm.timeout">>],
    ok.

%% Criterion 4: an LLM call whose mock runs past the call timeout leaves the
%% worker process dead, records the task as `timeout', and keeps the actor pid
%% alive. Enters through the real soma_actor:send/2 with a `slow' directive and a
%% short call timeout. The actor arms a call-timeout timer when it starts the
%% call; the `slow' mock ignores it; the timer firing makes the actor kill the
%% worker (exit(WorkerPid, kill)) and record the task `timeout'. Reads the worker
%% pid from the llm.started event, then asserts: the worker pid is dead, the task
%% status reads `timeout', and the actor pid is still alive.
slow_call_times_out_worker_dead_actor_alive(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-llm-timeout">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => slow, timeout_ms => 50},
    TaskId = <<"task-llm-timeout">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    Started = wait_for_actor_event(Store, <<"llm.started">>, 100),
    WorkerPid = maps:get(llm_call_pid, Started),
    true = is_pid(WorkerPid),
    ok = wait_for_status(ActorPid, TaskId, timeout, 100),
    false = is_process_alive(WorkerPid),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 5: cancelling an in-flight LLM call leaves the worker process dead,
%% records the task as `cancelled', and keeps the actor pid alive. Enters through
%% the real soma_actor:send/2 with a `hang' directive (the worker blocks until
%% killed), reads the worker pid from the llm.started event, then calls
%% soma_actor:cancel/2. The actor kills the worker (exit(WorkerPid, kill)) and
%% records the task `cancelled' -- the actor does the kill itself because the bare
%% worker has no state machine to drive its own teardown. Asserts: the worker pid
%% is dead, the task status reads `cancelled', and the actor pid is still alive.
cancel_in_flight_call_worker_dead_actor_alive(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-llm-cancel">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => hang},
    TaskId = <<"task-llm-cancel">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    Started = wait_for_actor_event(Store, <<"llm.started">>, 100),
    WorkerPid = maps:get(llm_call_pid, Started),
    true = is_pid(WorkerPid),
    ok = soma_actor:cancel(ActorPid, TaskId),
    ok = wait_for_status(ActorPid, TaskId, cancelled, 100),
    false = is_process_alive(WorkerPid),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 6: a mock that crashes reaches the actor as data through the monitor
%% `'DOWN'', records the task as `failed', and keeps the actor pid alive and
%% distinct from the dead worker pid. Enters through the real soma_actor:send/2
%% with a `crash' directive (the worker dies abnormally). Reads the worker pid
%% from the llm.started event, then asserts: the task status reaches `failed', the
%% worker pid is dead, the actor pid is still alive, and the actor pid is distinct
%% from the dead worker pid.
crash_reaches_actor_as_failed_via_down(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-llm-crash">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => crash},
    TaskId = <<"task-llm-crash">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    Started = wait_for_actor_event(Store, <<"llm.started">>, 100),
    WorkerPid = maps:get(llm_call_pid, Started),
    true = is_pid(WorkerPid),
    ok = wait_for_status(ActorPid, TaskId, failed, 100),
    false = is_process_alive(WorkerPid),
    true = is_process_alive(ActorPid),
    true = ActorPid =/= WorkerPid,
    %% Criterion 1: the crash backstop appends an `llm.failed' event carrying the
    %% task's correlation_id (defaulting to the task_id here, no explicit one in
    %% the envelope) and a non-`undefined' llm_call_id.
    Failed = wait_for_actor_event(Store, <<"llm.failed">>, 100),
    TaskId = maps:get(task_id, Failed),
    TaskId = maps:get(correlation_id, Failed),
    LlmCallId = maps:get(llm_call_id, Failed),
    true = LlmCallId =/= undefined,
    %% Criterion 2: a direct by_correlation/2 read for the task's correlation id
    %% (defaulting to the task_id) surfaces BOTH the `llm.failed' event and the
    %% task-level `actor.task.failed' event under the one correlation id.
    Correlated = soma_event_store:by_correlation(Store, TaskId),
    CorrLlmFailed = [E || E <- Correlated,
                          maps:get(event_type, E, undefined) =:= <<"llm.failed">>],
    CorrTaskFailed = [E || E <- Correlated,
                           maps:get(event_type, E, undefined) =:= <<"actor.task.failed">>],
    true = length(CorrLlmFailed) >= 1,
    true = length(CorrTaskFailed) >= 1,
    ok.

%% Regression (review #77): a crashing LLM call whose envelope ALSO carried a
%% `timeout_ms' must reach `failed' and STAY `failed'. The crash arrives through
%% the monitor `'DOWN'' and records `failed', but unless that path also clears the
%% armed call-timeout timer and drops the `llm_calls' entry, the still-live timer
%% later fires `{timeout, _, {llm_timeout, LlmCallId}}', finds the task still in
%% `llm_calls', and flips the status `failed' -> `timeout' while emitting a
%% spurious `llm.timeout' event against the already-dead worker. Enters through
%% the real soma_actor:send/2 with a `crash' directive AND a short `timeout_ms'.
%% Asserts the task reaches `failed', then -- after sleeping well past the timeout
%% window so any stale timer would have fired -- the status is STILL `failed' and
%% no `llm.timeout' event exists in the store. The actor stays alive.
crash_with_timeout_ms_stays_failed_no_spurious_timeout(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-llm-crash-tmo">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => crash, timeout_ms => 50},
    TaskId = <<"task-llm-crash-tmo">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, failed, 100),
    %% Sleep well past the 50ms call-timeout window so any stale armed timer
    %% would have fired by now.
    timer:sleep(200),
    failed = maps:get(status, soma_actor:get_task_status(ActorPid, TaskId)),
    Events = soma_event_store:all(Store),
    [] = [E || E <- Events,
               maps:get(event_type, E, undefined) =:= <<"llm.timeout">>],
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 7: while an LLM call is in flight, get_task_status returns promptly
%% with a non-terminal status, proving the actor is not blocked on the worker.
%% Enters through the real soma_actor:send/2 with a `hang' directive (the worker
%% blocks until killed, so the call never completes on its own). The status read
%% is timed: it must return well within a bound far below any worker completion,
%% and must read the non-terminal `running' -- if the actor were blocked on the
%% worker, the gen_statem:call would not return at all. The worker is then killed
%% so the suite leaves no live hang behind.
status_promptly_while_llm_call_in_flight(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-llm-prompt">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => hang},
    TaskId = <<"task-llm-prompt">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    Started = wait_for_actor_event(Store, <<"llm.started">>, 100),
    WorkerPid = maps:get(llm_call_pid, Started),
    true = is_pid(WorkerPid),
    true = is_process_alive(WorkerPid),
    %% Time the status read. The actor must answer promptly -- well within 200ms,
    %% far below any worker completion (the hang never completes) -- proving its
    %% mailbox is not blocked on the in-flight worker.
    Start = erlang:monotonic_time(millisecond),
    Status = soma_actor:get_task_status(ActorPid, TaskId),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    true = Elapsed < 200,
    running = maps:get(status, Status),
    true = is_process_alive(ActorPid),
    exit(WorkerPid, kill),
    ok.

%% Criterion 8: a completed LLM call appends at least one `llm.*' event to the
%% event store carrying the task's `correlation_id'. Enters through the real
%% soma_actor:send/2 with a `success' llm envelope and an explicit
%% `correlation_id' in the envelope, waits for the task to reach `completed',
%% then queries soma_event_store:by_correlation/2 for that correlation_id and
%% asserts at least one event whose type starts with `llm.' is present (each such
%% event carries the correlation_id by virtue of by_correlation/2's filter).
completed_call_appends_llm_event_with_correlation_id(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-llm-corr">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => success, output => <<"hi from the mock">>},
    TaskId = <<"task-llm-corr">>,
    CorrelationId = <<"corr-llm-corr">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    LlmEvents = [E || E <- Events,
                      is_llm_event_type(maps:get(event_type, E, undefined))],
    true = length(LlmEvents) >= 1,
    ok.

%% Criterion 9: by_correlation/2 returns the call's `llm.*' events alongside the
%% task's `actor.*' events under one `correlation_id'. The stronger sibling of
%% criterion 8: it is not enough that some `llm.*' event carries the id -- the
%% same query must surface BOTH event families for the one task. Enters through
%% the real soma_actor:send/2 with a `success' llm envelope and an explicit
%% `correlation_id', waits for `completed', then queries
%% soma_event_store:by_correlation/2 and asserts at least one `actor.*'-type event
%% AND at least one `llm.*'-type event are present (every returned event carries
%% the correlation_id by virtue of by_correlation/2's filter).
by_correlation_returns_llm_and_actor_events(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-llm-both">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Llm = #{directive => success, output => <<"hi from the mock">>},
    TaskId = <<"task-llm-both">>,
    CorrelationId = <<"corr-llm-both">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    ActorEvents = [E || E <- Events,
                        is_actor_event_type(maps:get(event_type, E, undefined))],
    LlmEvents = [E || E <- Events,
                      is_llm_event_type(maps:get(event_type, E, undefined))],
    true = length(ActorEvents) >= 1,
    true = length(LlmEvents) >= 1,
    ok.

%% Bonus coverage (decision 1, mutual exclusion): an envelope carrying BOTH a
%% valid `steps' list AND an `llm' map is malformed and rejected up front by
%% validate_envelope/1 with `{error, _}', before any child starts. Enters through
%% the real soma_actor:send/2. Asserts: the call returns `{error, _}'; no run and
%% no llm call were started (no `actor.task.accepted', no `run.*', no `llm.*'
%% event ever appears, and the task is `not_found'); and the actor pid stays
%% alive. This proves the dispatch never reaches maybe_start_run /
%% maybe_start_llm_call for a both-present envelope.
both_steps_and_llm_rejected_no_child_started(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-llm-mutex">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    Steps = [#{id => <<"s1">>, tool => echo,
               args => #{}, timeout_ms => 1000}],
    Llm = #{directive => success, output => <<"hi from the mock">>},
    TaskId = <<"task-llm-mutex">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 steps => Steps,
                 llm => Llm},
    {error, _} = soma_actor:send(ActorPid, Envelope),
    %% No child started: the malformed envelope never reached dispatch, so the
    %% task was never accepted and neither a run nor an llm call event exists.
    #{status := not_found} = soma_actor:get_task_status(ActorPid, TaskId),
    Events = soma_event_store:all(Store),
    [] = [E || E <- Events,
               started_child_event(maps:get(event_type, E, undefined))],
    true = is_process_alive(ActorPid),
    ok.

started_child_event(<<"actor.task.accepted">>) -> true;
started_child_event(<<"run.", _/binary>>) -> true;
started_child_event(<<"llm.", _/binary>>) -> true;
started_child_event(_) -> false.

%% Criterion 10: `docs/contracts/v0.5-test-contract.md' exists and maps each
%% process proof in this slice to the suite and case that proves it. Mirrors how
%% earlier slices pinned their contract docs (see v0.4-test-contract.md and its
%% pin test). This reads the file off the call chain -- a documentation
%% deliverable, not runtime behaviour -- and asserts it exists and references the
%% two proving suites plus every case named in design-77's criteria 1-9 and the
%% mutual-exclusion bonus case.
pins_v0_5_test_contract_maps_each_proof(_Config) ->
    Doc = read_contract_doc(),
    %% Both proving suites.
    true = doc_contains(Doc, <<"soma_llm_call_tests">>),
    true = doc_contains(Doc, <<"soma_llm_call_SUITE">>),
    %% The v0.5.2 proposal-normalize section and its proving suites.
    true = doc_contains(Doc, <<"v0.5.2">>),
    true = doc_contains(Doc, <<"soma_proposal_tests">>),
    true = doc_contains(Doc, <<"soma_proposal_SUITE">>),
    %% The v0.5.3 policy-gate section and its proving suites.
    true = doc_contains(Doc, <<"v0.5.3">>),
    true = doc_contains(Doc, <<"soma_policy_tests">>),
    true = doc_contains(Doc, <<"soma_policy_SUITE">>),
    %% Every case that proves a process proof in this slice.
    Cases =
        [<<"test_mock_success_returns_configured_output">>,
         <<"llm_worker_runs_in_distinct_pid">>,
         <<"get_task_result_holds_llm_output">>,
         <<"slow_call_times_out_worker_dead_actor_alive">>,
         <<"cancel_in_flight_call_worker_dead_actor_alive">>,
         <<"crash_reaches_actor_as_failed_via_down">>,
         <<"status_promptly_while_llm_call_in_flight">>,
         <<"completed_call_appends_llm_event_with_correlation_id">>,
         <<"by_correlation_returns_llm_and_actor_events">>,
         <<"both_steps_and_llm_rejected_no_child_started">>,
         %% v0.5.2 pure-normalize proofs (soma_proposal_tests).
         <<"test_reply_normalizes_ok">>,
         <<"test_run_steps_normalizes_ok">>,
         <<"test_reject_normalizes_ok">>,
         <<"test_ask_normalizes_ok">>,
         <<"test_unknown_kind_errors">>,
         <<"test_actor_message_kind_errors">>,
         <<"test_reply_missing_text_errors">>,
         <<"test_run_steps_bad_step_errors">>,
         %% v0.5.2 actor-side proofs (soma_proposal_SUITE).
         <<"reply_proposal_stored_as_task_result">>,
         <<"reply_proposal_emits_proposal_created_with_correlation_id">>,
         <<"run_steps_proposal_starts_no_run">>,
         <<"malformed_proposal_marks_task_failed">>,
         <<"actor_survives_malformed_proposal_takes_next_send">>,
         <<"by_correlation_returns_proposal_actor_and_llm_events">>,
         %% v0.5.3 pure policy-decision proofs (soma_policy_tests).
         <<"run_steps_all_tools_allowed_returns_allow_test">>,
         <<"run_steps_unknown_tool_returns_reject_test">>,
         <<"run_steps_all_or_absent_allowlist_returns_allow_test">>,
         <<"toolless_kinds_return_allow_test">>,
         %% v0.5.3 actor-side policy-gate proofs (soma_policy_SUITE).
         <<"allowed_run_steps_emits_proposal_approved_with_correlation_id">>,
         <<"allowed_proposal_starts_no_run">>,
         <<"allowed_proposal_status_reads_approved">>,
         <<"rejected_proposal_emits_proposal_rejected_with_reason_and_correlation_id">>,
         <<"rejected_proposal_starts_no_run">>,
         <<"rejected_proposal_status_reads_rejected">>,
         <<"actor_survives_rejected_proposal_takes_next_send">>,
         <<"by_correlation_returns_verdict_created_actor_and_llm_events">>],
    [true = doc_contains(Doc, Case) || Case <- Cases],
    ok.

%% Reads docs/contracts/v0.5-test-contract.md. rebar3 keeps cwd at the project
%% root for ct, so the relative path resolves; if some runner does not, walk up
%% from cwd looking for the file before giving up.
read_contract_doc() ->
    Rel = "docs/contracts/v0.5-test-contract.md",
    case file:read_file(Rel) of
        {ok, Bin} -> Bin;
        {error, _} ->
            Path = find_upwards(Rel, filename:absname(".")),
            case file:read_file(Path) of
                {ok, Bin} -> Bin;
                {error, Reason} ->
                    error({cannot_read_contract_doc, Rel, Reason})
            end
    end.

find_upwards(Rel, Dir) ->
    Candidate = filename:join(Dir, Rel),
    case filelib:is_regular(Candidate) of
        true -> Candidate;
        false ->
            Parent = filename:dirname(Dir),
            case Parent of
                Dir -> Rel;
                _ -> find_upwards(Rel, Parent)
            end
    end.

doc_contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% True when the event-type binary starts with the `actor.' prefix.
is_actor_event_type(<<"actor.", _/binary>>) -> true;
is_actor_event_type(_) -> false.

%% True when the event-type binary starts with the `llm.' prefix.
is_llm_event_type(<<"llm.", _/binary>>) -> true;
is_llm_event_type(_) -> false.

%% Polls get_task_status until the task reaches the given status.
wait_for_status(_ActorPid, TaskId, Status, 0) ->
    error({timeout, TaskId, Status});
wait_for_status(ActorPid, TaskId, Status, N) ->
    case maps:get(status, soma_actor:get_task_status(ActorPid, TaskId)) of
        Status ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_status(ActorPid, TaskId, Status, N - 1)
    end.

%% Polls the store until one event of the given type appears, returning it.
wait_for_actor_event(_Store, Type, 0) ->
    error({timeout, Type});
wait_for_actor_event(Store, Type, N) ->
    Events = soma_event_store:all(Store),
    case [E || E <- Events,
               maps:get(event_type, E, undefined) =:= Type] of
        [Event | _] ->
            Event;
        [] ->
            timer:sleep(20),
            wait_for_actor_event(Store, Type, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
