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
-export([status_promptly_while_llm_call_in_flight/1]).
-export([completed_call_appends_llm_event_with_correlation_id/1]).
-export([by_correlation_returns_llm_and_actor_events/1]).

all() ->
    [llm_worker_runs_in_distinct_pid,
     get_task_result_holds_llm_output,
     slow_call_times_out_worker_dead_actor_alive,
     cancel_in_flight_call_worker_dead_actor_alive,
     crash_reaches_actor_as_failed_via_down,
     status_promptly_while_llm_call_in_flight,
     completed_call_appends_llm_event_with_correlation_id,
     by_correlation_returns_llm_and_actor_events].

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
    Llm = #{directive => success, output => Output},
    TaskId = <<"task-llm-result">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    {ok, Output} = soma_actor:get_task_result(ActorPid, TaskId),
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
