-module(soma_delegate_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([test_request_identity_reuses_one_live_coordinator/1]).

all() ->
    [test_request_identity_reuses_one_live_coordinator].

init_per_testcase(_TestCase, Config) ->
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config].

end_per_testcase(_TestCase, _Config) ->
    application:stop(soma_actor),
    application:stop(soma_runtime),
    ok.

test_request_identity_reuses_one_live_coordinator(_Config) ->
    RequestId = <<"delegate-request-one-coordinator">>,
    CorrelationId = <<"delegate-correlation-one-coordinator">>,
    TaskSpec = #{request_id => RequestId,
                 correlation_id => CorrelationId,
                 objective => <<"hold the first round open">>},

    FirstReply = submit_through_production_ingress(TaskSpec),
    ?assertMatch({ok, #{request_id := RequestId,
                        correlation_id := CorrelationId,
                        task_id := _}},
                 FirstReply),
    {ok, FirstHandle = #{task_id := TaskId}} = FirstReply,
    [CoordinatorPid] = live_coordinators(),
    FirstIdentity = coordinator_identity(CoordinatorPid),
    ?assertEqual(#{request_id => RequestId,
                   task_id => TaskId,
                   correlation_id => CorrelationId},
                 FirstIdentity),

    ?assertEqual({ok, FirstHandle},
                 submit_through_production_ingress(TaskSpec)),
    ?assertEqual([CoordinatorPid], live_coordinators()),
    ?assertEqual(FirstIdentity, coordinator_identity(CoordinatorPid)),
    ?assertEqual(true, is_process_alive(CoordinatorPid)).

submit_through_production_ingress(TaskSpec) ->
    case code:ensure_loaded(soma_delegate) of
        {module, soma_delegate} ->
            soma_delegate:submit(TaskSpec);
        {error, _Reason} ->
            {error, production_delegate_ingress_unavailable}
    end.

live_coordinators() ->
    [Pid || {_Id, Pid, worker, _Modules} <-
                supervisor:which_children(soma_delegate_coordinator_sup),
            is_pid(Pid),
            is_process_alive(Pid)].

coordinator_identity(CoordinatorPid) ->
    {_StateName, Data} = sys:get_state(CoordinatorPid),
    maps:with([request_id, task_id, correlation_id], Data).
