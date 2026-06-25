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

all() ->
    [llm_worker_runs_in_distinct_pid,
     get_task_result_holds_llm_output,
     slow_call_times_out_worker_dead_actor_alive].

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
