-module(soma_delegate_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([test_request_identity_reuses_one_live_coordinator/1]).
-export([test_coordinator_owns_task_state_ingress_keeps_routes_and_terminal_projections/1]).
-export([test_status_and_cancel_route_by_task_id/1]).

all() ->
    [test_request_identity_reuses_one_live_coordinator,
     test_coordinator_owns_task_state_ingress_keeps_routes_and_terminal_projections,
     test_status_and_cancel_route_by_task_id].

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

test_coordinator_owns_task_state_ingress_keeps_routes_and_terminal_projections(
  _Config) ->
    RequestId = <<"delegate-request-state-owner">>,
    CorrelationId = <<"delegate-correlation-state-owner">>,
    Objective = #{goal => <<"objective-owned-only-by-coordinator">>},
    OutputContract = #{format => <<"output-owned-only-by-coordinator">>},
    Checkpoint = #{cursor => <<"checkpoint-owned-only-by-coordinator">>},
    Budgets = #{rounds => 2, tokens => 100},
    LeaseRequests = [#{name => <<"lease-owned-only-by-coordinator">>}],
    TaskSpec = #{request_id => RequestId,
                 correlation_id => CorrelationId,
                 objective => Objective,
                 output_contract => OutputContract,
                 checkpoint => Checkpoint,
                 budgets => Budgets,
                 lease_requests => LeaseRequests},

    {ok, #{task_id := TaskId}} = submit_through_production_ingress(TaskSpec),
    [CoordinatorPid] = live_coordinators(),
    {running, CoordinatorData} = sys:get_state(CoordinatorPid),
    ?assertEqual(
       #{objective => Objective,
         output_contract => OutputContract,
         context_checkpoint => Checkpoint,
         budgets => Budgets,
         usage => #{},
         mutation_ledger => [],
         unknown_outcome_ledger => [],
         scoped_leases => #{requests => LeaseRequests,
                            handles => #{},
                            guard => undefined},
         active_round => undefined,
         terminal_result => undefined},
       maps:with([objective, output_contract, context_checkpoint, budgets,
                  usage, mutation_ledger, unknown_outcome_ledger,
                  scoped_leases, active_round, terminal_result],
                 CoordinatorData)),

    IngressState = sys:get_state(soma_delegate),
    Route = maps:get(TaskId, maps:get(tasks, IngressState)),
    ?assertEqual(
       [accepted_handle, coordinator_mref, coordinator_pid, request_id,
        task_id, terminal_projection],
       lists:sort(maps:keys(Route))),
    lists:foreach(
      fun(TaskLocalValue) ->
              ?assertEqual(false, term_contains(IngressState, TaskLocalValue))
      end,
      [Objective, OutputContract, Checkpoint, Budgets, LeaseRequests]),

    exit(CoordinatorPid, kill),
    TerminalProjection = wait_for_terminal_projection(TaskId, 100),
    ?assertEqual(#{status => failed, reason => coordinator_crashed},
                 TerminalProjection),
    ?assert(byte_size(term_to_binary(TerminalProjection, [deterministic])) =<
            512),
    TerminalIngressState = sys:get_state(soma_delegate),
    lists:foreach(
      fun(TaskLocalValue) ->
              ?assertEqual(false,
                           term_contains(TerminalIngressState,
                                         TaskLocalValue))
      end,
      [Objective, OutputContract, Checkpoint, Budgets, LeaseRequests]).

test_status_and_cancel_route_by_task_id(_Config) ->
    RequestId = <<"delegate-request-status-cancel">>,
    CorrelationId = <<"delegate-correlation-status-cancel">>,
    TaskSpec = #{request_id => RequestId,
                 correlation_id => CorrelationId,
                 objective => <<"hold the delegated round for cancellation">>},

    {ok, #{task_id := TaskId}} =
        submit_through_production_ingress(TaskSpec),
    [CoordinatorPid] = live_coordinators(),
    RunningProjection = #{status => running,
                          request_id => RequestId,
                          task_id => TaskId,
                          correlation_id => CorrelationId},
    ?assertEqual({ok, RunningProjection}, soma_delegate:status(TaskId)),

    UnknownTaskId = <<"delegate-task-not-found">>,
    ?assertEqual({error, not_found}, soma_delegate:status(UnknownTaskId)),
    ?assertEqual({error, not_found}, soma_delegate:cancel(UnknownTaskId)),
    ?assertEqual(true, is_process_alive(CoordinatorPid)),

    {ok, CancelledProjection} = soma_delegate:cancel(TaskId),
    ?assertEqual(cancelled, maps:get(status, CancelledProjection)),
    ?assertEqual(TaskId, maps:get(task_id, CancelledProjection)),
    ?assertEqual(RequestId, maps:get(request_id, CancelledProjection)),
    ?assertEqual(CorrelationId,
                 maps:get(correlation_id, CancelledProjection)),
    wait_for_process_dead(CoordinatorPid, 100),
    ?assertEqual({ok, CancelledProjection}, soma_delegate:status(TaskId)),
    ?assertEqual({ok, CancelledProjection}, soma_delegate:cancel(TaskId)).

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

wait_for_terminal_projection(_TaskId, 0) ->
    ct:fail(terminal_projection_not_stored);
wait_for_terminal_projection(TaskId, Attempts) ->
    State = sys:get_state(soma_delegate),
    Route = maps:get(TaskId, maps:get(tasks, State)),
    case maps:get(terminal_projection, Route, undefined) of
        undefined ->
            timer:sleep(10),
            wait_for_terminal_projection(TaskId, Attempts - 1);
        Projection ->
            Projection
    end.

wait_for_process_dead(Pid, 0) ->
    ?assertEqual(false, is_process_alive(Pid));
wait_for_process_dead(Pid, Attempts) ->
    case is_process_alive(Pid) of
        true ->
            timer:sleep(10),
            wait_for_process_dead(Pid, Attempts - 1);
        false ->
            ok
    end.

term_contains(Term, Term) ->
    true;
term_contains(Map, Needle) when is_map(Map) ->
    lists:any(fun({Key, Value}) ->
                      term_contains(Key, Needle) orelse
                      term_contains(Value, Needle)
              end,
              maps:to_list(Map));
term_contains(List, Needle) when is_list(List) ->
    lists:any(fun(Value) -> term_contains(Value, Needle) end, List);
term_contains(Tuple, Needle) when is_tuple(Tuple) ->
    term_contains(tuple_to_list(Tuple), Needle);
term_contains(_Term, _Needle) ->
    false.
