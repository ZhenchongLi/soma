-module(soma_actor_correlation_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([test_chain_retrievable_by_correlation_id/1]).

all() ->
    [test_chain_retrievable_by_correlation_id].

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

%% Criterion 5: after an actor task driven with correlation_id C completes,
%% by_correlation(Store, C) returns the four actor.* events together with the
%% run's run.* chain (run.started through run.completed, including the step and
%% tool events) -- the whole chain under the single id C. The runtime is booted
%% so soma_run_sup, soma_tool_registry, and the shared event store are live; the
%% actor is started through soma_actor_sup:start_actor/1 with the booted runtime's
%% event store so the actor and the run share one store. Enters through the real
%% soma_actor:send/2 call, no layer bypassed. The test drives one task with a
%% known correlation_id C, waits for actor.task.completed, then asserts
%% by_correlation(Store, C) returns every event of the full actor-plus-run chain.
test_chain_retrievable_by_correlation_id(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-corr-chain">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-corr-chain">>,
    CorrelationId = <<"corr-chain-C">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"a">>}}],
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 steps => Steps},
    {ok, TaskId} = soma_actor:send(Pid, Envelope),
    _ = wait_for_actor_event(Store, <<"actor.task.completed">>, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Types = [maps:get(event_type, E) || E <- Events],
    %% The four actor.* events.
    true = lists:member(<<"actor.message.received">>, Types),
    true = lists:member(<<"actor.task.accepted">>, Types),
    true = lists:member(<<"actor.result.created">>, Types),
    true = lists:member(<<"actor.task.completed">>, Types),
    %% The run.* chain, including the step and tool events.
    true = lists:member(<<"run.started">>, Types),
    true = lists:member(<<"step.started">>, Types),
    true = lists:member(<<"tool.started">>, Types),
    true = lists:member(<<"tool.succeeded">>, Types),
    true = lists:member(<<"step.succeeded">>, Types),
    true = lists:member(<<"run.completed">>, Types),
    %% Every event carries the single correlation id C.
    [CorrelationId] = lists:usort(
                        [maps:get(correlation_id, E) || E <- Events]),
    %% The whole chain comes back under the one id: the four actor.* events
    %% plus the run's six-event completion chain (run.started, step.started,
    %% tool.started, tool.succeeded, step.succeeded, run.completed).
    10 = length(Events),
    ok.

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
