%% @doc Lisp-envelope proofs for soma_actor (L.1). A Lisp `(msg ...)' string
%% handed to soma_actor:send/2 is parsed at the client-side wrapper through
%% soma_lfe:compile/2 into the exact map envelope the actor already takes, then
%% runs through the unchanged map path. Set up like soma_actor_message_SUITE:
%% boot the soma_runtime app (so the shared event store and soma_run_sup are
%% alive) and start an actor through soma_actor_sup:start_actor/1, driving it
%% through the real soma_actor:send/2 entry point -- no layer bypassed.
-module(soma_actor_lisp_message_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([test_lisp_send_matches_map_send_outputs/1]).
-export([test_lisp_send_correlation_chain_matches_map/1]).

all() ->
    [test_lisp_send_matches_map_send_outputs,
     test_lisp_send_correlation_chain_matches_map].

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

%% Criterion 5: soma_actor:send/2 called with a valid Lisp `(msg ...)' string
%% produces the same run outputs as send/2 called with the equivalent map
%% envelope. The `(msg ...)' string carries one echo step; the equivalent map
%% envelope carries the same step list (and the same type/payload the parser
%% produces). Both drive the real soma_actor:send/2 on a single actor; each task
%% runs its own soma_run to completion. The test reads each task's outputs via
%% get_task_result/2 (polling until ready) and asserts the two are equal.
test_lisp_send_matches_map_send_outputs(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-lisp-send">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),

    %% Lisp path: a `(msg ...)' string with one echo step.
    LispSource = <<"(msg (type chat) (payload \"hi\") "
                   "(steps (step (id s1) (tool echo) "
                   "(args (value \"hi\")))))">>,
    {ok, LispTaskId} = soma_actor:send(Pid, LispSource),
    {ok, LispResult} = wait_for_task_result(Pid, LispTaskId, 100),

    %% Map path: the equivalent map envelope the parser produces for that string.
    MapEnvelope = #{type => chat,
                    payload => <<"hi">>,
                    steps => [#{id => s1,
                                tool => echo,
                                args => #{value => <<"hi">>}}]},
    {ok, MapTaskId} = soma_actor:send(Pid, MapEnvelope),
    {ok, MapResult} = wait_for_task_result(Pid, MapTaskId, 100),

    %% The same work through both entry forms yields equal run outputs.
    LispResult = MapResult,
    true = is_process_alive(Pid),
    ok.

%% Criterion 6: the correlation chain a Lisp `(msg ...)' send/2 leaves in the
%% event store -- read back through soma_event_store:by_correlation/2 -- matches
%% the chain the equivalent map send/2 leaves. Each path is driven under its own
%% known correlation id (carried in the envelope: `(correlation-id "...")' on the
%% Lisp side, `correlation_id => ...' on the map side) so the two buckets are
%% disjoint, then the event_type sequences pulled from each bucket are compared.
test_lisp_send_correlation_chain_matches_map(_Config) ->
    Store = event_store_pid(),
    Opts = #{actor_id => <<"actor-lisp-corr">>,
             model_config => #{},
             tool_policy => #{},
             event_store => Store},
    {ok, Pid} = soma_actor_sup:start_actor(Opts),

    LispCorr = <<"corr-lisp-1">>,
    MapCorr = <<"corr-map-1">>,

    %% Lisp path: a `(msg ...)' string with one echo step under LispCorr.
    LispSource = <<"(msg (type chat) (payload \"hi\") "
                   "(correlation-id \"corr-lisp-1\") "
                   "(steps (step (id s1) (tool echo) "
                   "(args (value \"hi\")))))">>,
    {ok, LispTaskId} = soma_actor:send(Pid, LispSource),
    {ok, _} = wait_for_task_result(Pid, LispTaskId, 100),

    %% Map path: the equivalent map envelope under MapCorr.
    MapEnvelope = #{type => chat,
                    payload => <<"hi">>,
                    correlation_id => MapCorr,
                    steps => [#{id => s1,
                                tool => echo,
                                args => #{value => <<"hi">>}}]},
    {ok, MapTaskId} = soma_actor:send(Pid, MapEnvelope),
    {ok, _} = wait_for_task_result(Pid, MapTaskId, 100),

    LispChain = correlation_event_types(Store, LispCorr),
    MapChain = correlation_event_types(Store, MapCorr),

    %% Both forms drive the same work, so the correlation chains match in shape.
    %% Staged red: pin a deliberately-wrong expected chain first.
    LispChain = [<<"deliberately.wrong">> | MapChain],
    true = is_process_alive(Pid),
    ok.

%% The event_type values from by_correlation/2, in store order.
correlation_event_types(Store, CorrelationId) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    [maps:get(event_type, E) || E <- Events].

%% Polls get_task_result/2 until the task has completed and returns {ok, Result}.
wait_for_task_result(_Pid, _TaskId, 0) ->
    error(no_task_result);
wait_for_task_result(Pid, TaskId, N) ->
    case soma_actor:get_task_result(Pid, TaskId) of
        {ok, Result} ->
            {ok, Result};
        _ ->
            timer:sleep(20),
            wait_for_task_result(Pid, TaskId, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
