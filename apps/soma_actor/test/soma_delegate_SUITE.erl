-module(soma_delegate_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([test_request_identity_reuses_one_live_coordinator/1]).
-export([test_coordinator_owns_task_state_ingress_keeps_routes_and_terminal_projections/1]).
-export([test_status_and_cancel_route_by_task_id/1]).
-export([test_coordinator_and_round_worker_crashes_leave_ingress_responsive/1]).
-export([test_delegate_action_crosses_full_worker_run_tool_spine/1]).
-export([test_coordinator_and_round_worker_split_child_ownership/1]).
-export([test_sequential_rounds_commit_before_distinct_next_worker/1]).
-export([test_round_snapshot_is_bounded_task_only_and_handle_scoped/1]).
-export([test_round_result_identity_rejects_stale_duplicate_and_mismatched_messages/1]).
-export([test_pre_stateful_worker_crash_and_timeout_are_bounded/1]).
-export([test_lost_state_result_is_in_doubt_without_replacement/1]).
-export([test_task_leases_are_stable_and_released_once_for_all_outcomes/1]).
-export([test_cancel_tears_down_llm_run_tool_and_os_children_once/1]).

all() ->
    [test_request_identity_reuses_one_live_coordinator,
     test_coordinator_owns_task_state_ingress_keeps_routes_and_terminal_projections,
     test_status_and_cancel_route_by_task_id,
     test_coordinator_and_round_worker_crashes_leave_ingress_responsive,
     test_delegate_action_crosses_full_worker_run_tool_spine,
     test_coordinator_and_round_worker_split_child_ownership,
     test_sequential_rounds_commit_before_distinct_next_worker,
     test_round_snapshot_is_bounded_task_only_and_handle_scoped,
     test_round_result_identity_rejects_stale_duplicate_and_mismatched_messages,
     test_pre_stateful_worker_crash_and_timeout_are_bounded,
     test_lost_state_result_is_in_doubt_without_replacement,
     test_task_leases_are_stable_and_released_once_for_all_outcomes,
     test_cancel_tears_down_llm_run_tool_and_os_children_once].

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

test_coordinator_and_round_worker_crashes_leave_ingress_responsive(_Config) ->
    IngressPid = whereis(soma_delegate),
    CoordinatorCrashSpec = crash_fixture(<<"coordinator-crash">>),
    {ok, #{task_id := CoordinatorCrashTaskId}} =
        submit_through_production_ingress(CoordinatorCrashSpec),
    CoordinatorPid = coordinator_for_task(CoordinatorCrashTaskId),
    CoordinatorOwnedWorker = wait_for_round_worker(100),

    exit(CoordinatorPid, kill),
    wait_for_process_dead(CoordinatorPid, 100),
    wait_for_process_dead(CoordinatorOwnedWorker, 100),
    CoordinatorCrashProjection =
        wait_for_terminal_projection(CoordinatorCrashTaskId, 100),
    ?assertEqual(#{status => failed, reason => coordinator_crashed},
                 CoordinatorCrashProjection),
    ?assert(byte_size(term_to_binary(CoordinatorCrashProjection,
                                     [deterministic])) =< 512),
    ?assertEqual(IngressPid, whereis(soma_delegate)),
    ?assertMatch({ok, #{status := failed,
                        reason := coordinator_crashed}},
                 soma_delegate:status(CoordinatorCrashTaskId)),

    WorkerCrashSpec = crash_fixture(<<"round-worker-crash">>),
    {ok, #{task_id := WorkerCrashTaskId}} =
        submit_through_production_ingress(WorkerCrashSpec),
    RoundWorkerPid = wait_for_round_worker(100),
    exit(RoundWorkerPid, kill),
    wait_for_process_dead(RoundWorkerPid, 100),
    WorkerCrashProjection =
        wait_for_terminal_projection(WorkerCrashTaskId, 100),
    ?assertEqual(#{status => failed,
                   reason => round_worker_crashed,
                   round => 1},
                 WorkerCrashProjection),
    ?assert(byte_size(term_to_binary(WorkerCrashProjection,
                                     [deterministic])) =< 512),
    ?assertEqual(IngressPid, whereis(soma_delegate)),
    ?assertMatch({ok, #{status := failed,
                        reason := round_worker_crashed,
                        round := 1}},
                 soma_delegate:status(WorkerCrashTaskId)),

    FreshSpec = #{request_id => <<"delegate-request-after-crashes">>,
                  objective => <<"prove ingress remains responsive">>},
    ?assertMatch({ok, #{status := accepted, task_id := _}},
                 submit_through_production_ingress(FreshSpec)),
    ?assertEqual(IngressPid, whereis(soma_delegate)).

test_delegate_action_crosses_full_worker_run_tool_spine(_Config) ->
    CorrelationId = <<"delegate-correlation-full-process-spine">>,
    FirstStepId = <<"delegate-spine-first">>,
    SecondStepId = <<"delegate-spine-second">>,
    Steps = [#{id => FirstStepId,
               tool => echo,
               args => #{value => <<"through-tool-worker-one">>}},
             #{id => SecondStepId,
               tool => echo,
               args => #{from_step => FirstStepId}}],
    TaskSpec =
        #{request_id => <<"delegate-request-full-process-spine">>,
          correlation_id => CorrelationId,
          objective => <<"execute one canonical delegated action">>,
          round_sequence =>
              [#{llm =>
                     #{directive => success,
                       output => <<"fixed-round-decision">>},
                 action_steps => Steps,
                 decision => terminal}]},

    {ok, #{task_id := TaskId}} =
        submit_through_production_ingress(TaskSpec),
    TerminalProjection = wait_for_terminal_projection(TaskId, 200),
    ?assertEqual(succeeded, maps:get(status, TerminalProjection)),

    StorePid = event_store_pid(),
    CorrelatedEvents =
        soma_event_store:by_correlation(StorePid, CorrelationId),
    [RunStarted] =
        [Event || Event <- CorrelatedEvents,
                  maps:get(event_type, Event) =:= <<"run.started">>],
    ?assertEqual(
       Steps,
       maps:get(steps, maps:get(payload, RunStarted))),
    RunId = maps:get(run_id, RunStarted),
    RunEvents = soma_event_store:by_run(StorePid, RunId),
    ToolStarted =
        [Event || Event <- RunEvents,
                  maps:get(event_type, Event) =:= <<"tool.started">>],
    ?assertEqual([FirstStepId, SecondStepId],
                 [maps:get(step_id, Event) || Event <- ToolStarted]),
    ToolWorkerPids =
        [maps:get(tool_call_pid, Event) || Event <- ToolStarted],
    ?assertEqual(2, length(lists:usort(ToolWorkerPids))),
    ?assert(lists:all(fun erlang:is_pid/1, ToolWorkerPids)),
    ?assert(lists:member(
              <<"run.completed">>,
              [maps:get(event_type, Event) || Event <- RunEvents])).

test_coordinator_and_round_worker_split_child_ownership(_Config) ->
    LlmSpec =
        #{request_id => <<"delegate-request-llm-child-owner">>,
          objective => <<"inspect ownership while the LLM is blocked">>,
          round_sequence =>
              [#{llm => #{directive => hang}, decision => terminal}]},
    {ok, #{task_id := LlmTaskId}} =
        submit_through_production_ingress(LlmSpec),
    LlmCoordinatorPid = coordinator_for_task(LlmTaskId),
    LlmRoundWorkerPid = wait_for_round_worker(100),
    {LlmWorkerData, ActiveLlm} =
        wait_for_worker_phase(
          LlmRoundWorkerPid, waiting_llm, active_llm, 100),
    LlmPid = maps:get(pid, ActiveLlm),
    LlmMRef = maps:get(mref, ActiveLlm),
    LlmTimerRef = maps:get(timer_ref, ActiveLlm, undefined),
    {running, LlmCoordinatorData} = sys:get_state(LlmCoordinatorPid),
    LlmActiveRound = maps:get(active_round, LlmCoordinatorData),
    LlmRoundTimerRef = maps:get(round_timer, LlmActiveRound),

    assert_coordinator_owns_round(
      LlmCoordinatorPid, LlmRoundWorkerPid, LlmActiveRound),
    assert_live_timer(LlmRoundTimerRef),
    ?assertEqual(false, term_contains(LlmCoordinatorData, LlmPid)),
    ?assertEqual(false,
                 lists:member(LlmPid, process_monitors(LlmCoordinatorPid))),
    ?assertEqual(LlmCoordinatorPid,
                 maps:get(coordinator_pid, LlmWorkerData)),
    ?assertEqual(LlmMRef, maps:get(mref, ActiveLlm)),
    ?assert(lists:member(LlmCoordinatorPid,
                         process_monitors(LlmRoundWorkerPid))),
    ?assert(lists:member(LlmPid, process_monitors(LlmRoundWorkerPid))),
    ?assert(lists:member(LlmPid, process_links(LlmRoundWorkerPid))),
    assert_live_timer(LlmTimerRef),

    {ok, #{status := cancelled}} = soma_delegate:cancel(LlmTaskId),
    wait_for_process_dead(LlmPid, 100),
    wait_for_process_dead(LlmRoundWorkerPid, 100),
    wait_for_process_dead(LlmCoordinatorPid, 100),
    assert_cancelled_timer(LlmTimerRef),
    assert_cancelled_timer(LlmRoundTimerRef),

    RunSpec =
        #{request_id => <<"delegate-request-run-child-owner">>,
          objective => <<"inspect ownership while the run is blocked">>,
          round_sequence =>
              [#{llm =>
                     #{directive => success,
                       output => <<"fixed-run-phase-decision">>},
                 action_steps =>
                     [#{id => <<"delegate-owned-blocked-step">>,
                        tool => sleep,
                        args => #{ms => 60000}}],
                 decision => terminal}]},
    {ok, #{task_id := RunTaskId}} =
        submit_through_production_ingress(RunSpec),
    RunCoordinatorPid = coordinator_for_task(RunTaskId),
    RunRoundWorkerPid = wait_for_round_worker(100),
    {RunWorkerData, ActiveRun} =
        wait_for_worker_phase(
          RunRoundWorkerPid, waiting_run, active_run, 100),
    RunPid = maps:get(pid, ActiveRun),
    RunMRef = maps:get(mref, ActiveRun),
    RunTimerRef = maps:get(timer_ref, ActiveRun, undefined),
    {running, RunCoordinatorData} = sys:get_state(RunCoordinatorPid),
    RunActiveRound = maps:get(active_round, RunCoordinatorData),
    RunRoundTimerRef = maps:get(round_timer, RunActiveRound),

    assert_coordinator_owns_round(
      RunCoordinatorPid, RunRoundWorkerPid, RunActiveRound),
    assert_live_timer(RunRoundTimerRef),
    ?assertEqual(false, term_contains(RunCoordinatorData, RunPid)),
    ?assertEqual(false,
                 lists:member(RunPid, process_monitors(RunCoordinatorPid))),
    ?assertEqual(RunCoordinatorPid,
                 maps:get(coordinator_pid, RunWorkerData)),
    ?assertEqual(RunMRef, maps:get(mref, ActiveRun)),
    ?assert(lists:member(RunCoordinatorPid,
                         process_monitors(RunRoundWorkerPid))),
    ?assert(lists:member(RunPid, process_monitors(RunRoundWorkerPid))),
    ?assert(lists:member(RunPid, process_links(RunRoundWorkerPid))),
    assert_live_timer(RunTimerRef),

    {ok, #{status := cancelled}} = soma_delegate:cancel(RunTaskId),
    wait_for_process_dead(RunPid, 100),
    wait_for_process_dead(RunRoundWorkerPid, 100),
    wait_for_process_dead(RunCoordinatorPid, 100),
    assert_cancelled_timer(RunTimerRef),
    assert_cancelled_timer(RunRoundTimerRef).

test_sequential_rounds_commit_before_distinct_next_worker(_Config) ->
    InitialCheckpoint = #{cursor => <<"before-round-one">>},
    CommittedCheckpoint = #{cursor => <<"after-round-one">>},
    CommittedUsage = #{rounds => 1, tokens => 13},
    FirstTerminalResult = #{status => succeeded,
                            value => <<"round-one-committed">>},
    TaskSpec =
        #{request_id => <<"delegate-request-sequential-rounds">>,
          correlation_id => <<"delegate-correlation-sequential-rounds">>,
          objective => <<"commit before starting the next round">>,
          checkpoint => InitialCheckpoint,
          round_sequence =>
              [#{llm => #{directive => hang}, decision => continue},
               #{llm => #{directive => hang}, decision => terminal}]},

    {ok, #{task_id := TaskId}} =
        submit_through_production_ingress(TaskSpec),
    CoordinatorPid = coordinator_for_task(TaskId),
    {FirstCoordinatorData, FirstActiveRound} =
        wait_for_active_round(CoordinatorPid, 1, 100),
    FirstWorkerPid = maps:get(worker_pid, FirstActiveRound),
    FirstRoundTimer = maps:get(round_timer, FirstActiveRound),
    _ = wait_for_worker_phase(
          FirstWorkerPid, waiting_llm, active_llm, 100),
    ?assertEqual(InitialCheckpoint,
                 maps:get(context_checkpoint, FirstCoordinatorData)),

    send_round_result(
      CoordinatorPid, TaskId, FirstActiveRound,
      #{status => succeeded,
        phase => decision,
        decision => continue,
        checkpoint => CommittedCheckpoint,
        usage => CommittedUsage,
        terminal_result => FirstTerminalResult}),

    {SecondCoordinatorData, SecondActiveRound} =
        wait_for_active_round(CoordinatorPid, 2, 100),
    SecondWorkerPid = maps:get(worker_pid, SecondActiveRound),
    {SecondWorkerData, _SecondActiveLlm} =
        wait_for_worker_phase(
          SecondWorkerPid, waiting_llm, active_llm, 100),
    ?assertNotEqual(FirstWorkerPid, SecondWorkerPid),
    ?assertEqual(false, is_process_alive(FirstWorkerPid)),
    ?assertEqual(false, erlang:read_timer(FirstRoundTimer)),
    ?assertEqual(false,
                 lists:member(FirstWorkerPid,
                              process_monitors(CoordinatorPid))),
    ?assertEqual(CommittedCheckpoint,
                 maps:get(context_checkpoint, SecondCoordinatorData)),
    ?assertEqual(CommittedUsage,
                 maps:get(usage, SecondCoordinatorData)),
    ?assertEqual(FirstTerminalResult,
                 maps:get(terminal_result, SecondCoordinatorData)),
    SecondSnapshot = maps:get(snapshot, SecondWorkerData),
    ?assertEqual(CommittedCheckpoint,
                 maps:get(context_checkpoint, SecondSnapshot)),
    ?assertEqual(CommittedUsage, maps:get(usage, SecondSnapshot)),

    {ok, #{status := cancelled}} = soma_delegate:cancel(TaskId).

test_round_snapshot_is_bounded_task_only_and_handle_scoped(_Config) ->
    ResourceManagerName = soma_delegate_test_resource_manager,
    undefined = whereis(ResourceManagerName),
    true = register(ResourceManagerName, self()),
    ok = soma_tool_registry:register_tool(
           soma_delegate_handle_test_tool:manifest()),
    try
        RequestId = <<"delegate-request-bounded-snapshot">>,
        CorrelationId = <<"delegate-correlation-bounded-snapshot">>,
        Objective = #{goal => <<"use the task-scoped resource handle">>},
        OutputContract = #{format => <<"opaque-handle-proof">>},
        Checkpoint = #{cursor => <<"snapshot-checkpoint">>},
        Budgets = #{rounds => 1, tokens => 32},
        LeaseName = <<"criterion-eight-resource">>,
        OpaqueHandle = <<"opaque-task-resource-handle">>,
        RawLease = {raw_resource_lease, make_ref()},
        ConversationData =
            #{messages => [<<"product-conversation-must-not-cross">>]},
        UserIdentity = <<"product-user-must-not-cross">>,
        SessionIdentity = <<"product-session-must-not-cross">>,
        AuthenticationState =
            #{bearer => <<"authentication-state-must-not-cross">>},
        ResourceManagerPid = self(),
        Observer = self(),
        PrepareRound =
            fun(Snapshot) ->
                    Observer ! {delegate_round_snapshot, Snapshot},
                    Handles = maps:get(resource_handles, Snapshot),
                    Handle = maps:get(LeaseName, Handles),
                    #{llm =>
                          #{directive => success,
                            output => <<"fixed-handle-decision">>},
                      action_steps =>
                          [#{id => <<"use-opaque-handle">>,
                             tool => delegate_handle_test,
                             args => #{handle => Handle}}],
                      decision => terminal}
            end,
        LeaseRequest =
            #{name => LeaseName,
              adapter => soma_delegate_test_lease_adapter,
              options => #{observer => Observer,
                           opaque_handle => OpaqueHandle,
                           raw_lease => RawLease,
                           resource_manager_pid => ResourceManagerPid}},
        TaskSpec =
            #{request_id => RequestId,
              correlation_id => CorrelationId,
              objective => Objective,
              output_contract => OutputContract,
              checkpoint => Checkpoint,
              budgets => Budgets,
              lease_requests => [LeaseRequest],
              round_sequence => [PrepareRound],
              product_conversation => ConversationData,
              product_user_id => UserIdentity,
              product_session_id => SessionIdentity,
              authentication_state => AuthenticationState,
              resource_manager_pid => ResourceManagerPid},

        {ok, #{task_id := TaskId}} =
            submit_through_production_ingress(TaskSpec),
        Snapshot =
            receive
                {delegate_round_snapshot, ActualSnapshot} ->
                    ActualSnapshot
            after 1000 ->
                ct:fail(round_snapshot_not_recorded)
            end,
        GuardPid =
            receive
                {delegate_test_lease_acquired, AcquiringGuardPid,
                 LeaseName, OpaqueHandle, RawLease} ->
                    AcquiringGuardPid
            after 1000 ->
                ct:fail(task_lease_not_acquired)
            end,
        ToolWorkerPid =
            receive
                {delegate_test_handle_used, InvokingToolPid,
                 #{handle := OpaqueHandle}} ->
                    InvokingToolPid
            after 1000 ->
                ct:fail(opaque_handle_not_used_by_tool)
            end,

        ExpectedSnapshot =
            #{task_id => TaskId,
              correlation_id => CorrelationId,
              objective => Objective,
              output_contract => OutputContract,
              context_checkpoint => Checkpoint,
              budgets => Budgets,
              usage => #{},
              mutation_ledger => [],
              unknown_outcome_ledger => [],
              resource_handles => #{LeaseName => OpaqueHandle}},
        ?assertEqual(ExpectedSnapshot, Snapshot),
        ?assert(byte_size(term_to_binary(Snapshot, [deterministic])) =<
                65536),

        ForbiddenSnapshotTerms =
            [ConversationData, UserIdentity, SessionIdentity,
             AuthenticationState, RawLease, ResourceManagerPid, GuardPid],
        lists:foreach(
          fun(ForbiddenTerm) ->
                  ?assertEqual(false,
                               term_contains(Snapshot, ForbiddenTerm))
          end,
          ForbiddenSnapshotTerms),

        CoordinatorPid = coordinator_for_task(TaskId),
        {running, CoordinatorData} = sys:get_state(CoordinatorPid),
        ?assertEqual(
           #{requests => [],
             handles => #{LeaseName => OpaqueHandle},
             guard => GuardPid},
           maps:get(scoped_leases, CoordinatorData)),
        lists:foreach(
          fun(ForbiddenTerm) ->
                  ?assertEqual(false,
                               term_contains(CoordinatorData,
                                             ForbiddenTerm))
          end,
          [ConversationData, UserIdentity, SessionIdentity,
           AuthenticationState, RawLease, ResourceManagerPid]),

        RoundWorkerPid = wait_for_round_worker(100),
        {waiting_run, WorkerData} = sys:get_state(RoundWorkerPid),
        ?assertEqual(Snapshot, maps:get(snapshot, WorkerData)),
        ?assertEqual(
           #{handle => OpaqueHandle},
           maps:get(args,
                    hd(maps:get(action_steps,
                                maps:get(work, WorkerData))))),
        lists:foreach(
          fun(ForbiddenTerm) ->
                  ?assertEqual(false,
                               term_contains(WorkerData, ForbiddenTerm))
          end,
          ForbiddenSnapshotTerms),

        {GuardState, GuardData} = sys:get_state(GuardPid),
        ?assertEqual(active, GuardState),
        ?assertEqual(true, term_contains(GuardData, RawLease)),
        ToolWorkerPid ! {delegate_test_continue, OpaqueHandle},
        TerminalProjection = wait_for_terminal_projection(TaskId, 200),
        ?assertEqual(succeeded, maps:get(status, TerminalProjection))
    after
        case whereis(soma_tool_registry) of
            undefined ->
                ok;
            _RegistryPid ->
                ok = soma_tool_registry:unregister_tool(
                       delegate_handle_test)
        end,
        case whereis(ResourceManagerName) of
            undefined ->
                ok;
            _ResourceManagerPid ->
                true = unregister(ResourceManagerName)
        end
    end.

test_round_result_identity_rejects_stale_duplicate_and_mismatched_messages(
  _Config) ->
    Checkpoint = #{cursor => <<"identity-commit">>},
    Usage = #{rounds => 1, tokens => 7},
    Mutation = #{invocation_id => <<"committed-mutation">>},
    UnknownOutcome = #{invocation_id => <<"committed-unknown-outcome">>},
    TerminalResult = #{status => succeeded,
                       value => <<"committed-once">>},
    TaskSpec =
        #{request_id => <<"delegate-request-round-result-identity">>,
          objective => <<"accept only the active round result">>,
          round_sequence =>
              [#{llm => #{directive => hang}, decision => continue},
               #{llm => #{directive => hang}, decision => terminal}]},

    {ok, #{task_id := TaskId}} =
        submit_through_production_ingress(TaskSpec),
    CoordinatorPid = coordinator_for_task(TaskId),
    {_FirstCoordinatorData,
     FirstActiveRound = #{round_id := FirstRoundId,
                          worker_pid := FirstWorkerPid,
                          worker_identity := FirstWorkerIdentity}} =
        wait_for_active_round(CoordinatorPid, 1, 100),
    _ = wait_for_worker_phase(
          FirstWorkerPid, waiting_llm, active_llm, 100),
    ?assertEqual(1, FirstRoundId),
    ?assert(is_binary(FirstWorkerIdentity)),

    ValidResult =
        #{status => succeeded,
          phase => decision,
          decision => continue,
          checkpoint => Checkpoint,
          usage => Usage,
          mutation => Mutation,
          unknown_outcome => UnknownOutcome,
          terminal_result => TerminalResult},
    ValidMessage =
        round_result_message(TaskId, FirstActiveRound, ValidResult),
    ?assertMatch(
       {delegate_round_result, TaskId, FirstRoundId, FirstWorkerPid,
        FirstWorkerIdentity, _ResultCapability, ValidResult},
       ValidMessage),
    CoordinatorPid ! ValidMessage,

    {CommittedData,
     SecondActiveRound = #{round_id := SecondRoundId,
                           worker_pid := SecondWorkerPid,
                           worker_identity := SecondWorkerIdentity}} =
        wait_for_active_round(CoordinatorPid, 2, 100),
    _ = wait_for_worker_phase(
          SecondWorkerPid, waiting_llm, active_llm, 100),
    ?assertEqual(FirstRoundId + 1, SecondRoundId),
    ?assertNotEqual(FirstWorkerPid, SecondWorkerPid),
    ?assert(is_binary(SecondWorkerIdentity)),
    ?assertNotEqual(FirstWorkerIdentity, SecondWorkerIdentity),

    StableProjection = sys:get_state(CoordinatorPid),
    InvalidRows =
        [{stale,
          round_result_message(
            TaskId, FirstActiveRound#{round_id := 0}, ValidResult)},
         {duplicate, ValidMessage},
         {task_mismatched,
          round_result_message(
            <<"another-delegate-task">>, SecondActiveRound,
            ValidResult)},
         {round_mismatched,
          round_result_message(
            TaskId,
            SecondActiveRound#{round_id := SecondRoundId + 1},
            ValidResult)},
         {worker_pid_mismatched,
          round_result_message(
            TaskId, SecondActiveRound#{worker_pid := self()},
            ValidResult)},
         {worker_identity_mismatched,
          round_result_message(
            TaskId,
            SecondActiveRound#{worker_identity :=
                                   <<"another-worker-identity">>},
            ValidResult)},
         {capability_mismatched,
          round_result_message(
            TaskId,
            SecondActiveRound#{result_capability := make_ref()},
            ValidResult)}],
    lists:foreach(
      fun({RowName, Message}) ->
              CoordinatorPid ! Message,
              ?assertEqual(
                 {RowName, StableProjection},
                 {RowName, sys:get_state(CoordinatorPid)})
      end,
      InvalidRows),

    ?assertEqual(Checkpoint,
                 maps:get(context_checkpoint, CommittedData)),
    ?assertEqual(Usage, maps:get(usage, CommittedData)),
    ?assertEqual([Mutation], maps:get(mutation_ledger, CommittedData)),
    ?assertEqual([UnknownOutcome],
                 maps:get(unknown_outcome_ledger, CommittedData)),
    ?assertEqual(TerminalResult,
                 maps:get(terminal_result, CommittedData)),

    {ok, #{status := cancelled}} = soma_delegate:cancel(TaskId).

test_pre_stateful_worker_crash_and_timeout_are_bounded(_Config) ->
    Rows =
        [{crash,
          #{status => failed, reason => round_worker_crashed}},
         {timeout,
          #{status => timeout, reason => round_timeout}}],
    lists:foreach(
      fun({FailureMode, ExpectedFailure}) ->
              RequestId =
                  <<"delegate-request-pre-stateful-",
                    (atom_to_binary(FailureMode))/binary>>,
              TaskSpec =
                  #{request_id => RequestId,
                    objective =>
                        <<"continue after one bounded round failure">>,
                    round_sequence =>
                        [#{llm => #{directive => hang,
                                   timeout_ms => 60000},
                           round_timeout_ms => 250,
                           decision => continue},
                         #{llm => #{directive => hang},
                           decision => terminal}]},
              {ok, #{task_id := TaskId}} =
                  submit_through_production_ingress(TaskSpec),
              CoordinatorPid = coordinator_for_task(TaskId),
              {_FirstData,
               #{worker_pid := FirstWorkerPid}} =
                  wait_for_active_round(CoordinatorPid, 1, 100),
              _ = wait_for_worker_phase(
                    FirstWorkerPid, waiting_llm, active_llm, 100),
              {ok, #{restart := temporary}} =
                  supervisor:get_childspec(
                    soma_delegate_round_sup, FirstWorkerPid),

              case FailureMode of
                  crash ->
                      exit(FirstWorkerPid, kill);
                  timeout ->
                      ok
              end,

              {SecondData,
               #{worker_pid := SecondWorkerPid}} =
                  wait_for_active_round(CoordinatorPid, 2, 200),
              _ = wait_for_worker_phase(
                    SecondWorkerPid, waiting_llm, active_llm, 100),
              FailureData = maps:get(recent_round_data, SecondData),
              ?assertEqual(ExpectedFailure#{round => 1}, FailureData),
              ?assert(byte_size(
                        term_to_binary(FailureData, [deterministic])) =<
                      16384),
              ?assertNotEqual(FirstWorkerPid, SecondWorkerPid),
              ?assertEqual(false, is_process_alive(FirstWorkerPid)),
              ?assertEqual(true, is_process_alive(CoordinatorPid)),
              ?assertMatch(
                 {ok, #{status := running, task_id := TaskId}},
                 soma_delegate:status(TaskId)),
              {ok, #{status := cancelled}} =
                  soma_delegate:cancel(TaskId)
      end,
      Rows).

test_lost_state_result_is_in_doubt_without_replacement(_Config) ->
    ToolName = service_hanging_state,
    StepId = <<"delegate-lost-state-result">>,
    CorrelationId = <<"delegate-correlation-lost-state-result">>,
    Steps = [#{id => StepId, tool => ToolName, args => #{}}],
    ok = soma_tool_registry:register_tool(
           soma_service_hanging_state_tool:manifest()),
    try
        TaskSpec =
            #{request_id => <<"delegate-request-lost-state-result">>,
              correlation_id => CorrelationId,
              objective => <<"never replay a state action with a lost result">>,
              round_sequence =>
                  [#{llm =>
                         #{directive => success,
                           output => <<"dispatch-one-state-action">>},
                     action_steps => Steps,
                     decision => continue},
                   #{llm => #{directive => hang},
                     decision => terminal}]},

        {ok, #{task_id := TaskId}} =
            submit_through_production_ingress(TaskSpec),
        CoordinatorPid = coordinator_for_task(TaskId),
        {_CoordinatorData,
         #{worker_pid := RoundWorkerPid}} =
            wait_for_active_round(CoordinatorPid, 1, 100),
        StorePid = event_store_pid(),
        [ToolStarted] =
            wait_for_correlated_events(
              StorePid, CorrelationId, <<"tool.started">>, 100),
        RunId = maps:get(run_id, ToolStarted),
        ToolCallPid = maps:get(tool_call_pid, ToolStarted),
        ?assertEqual(StepId, maps:get(step_id, ToolStarted)),
        ?assertEqual(true, is_process_alive(ToolCallPid)),

        exit(RoundWorkerPid, kill),
        wait_for_process_dead(RoundWorkerPid, 100),
        wait_for_process_dead(ToolCallPid, 100),

        StatusReply = wait_for_task_status(TaskId, in_doubt, 100),
        ?assertMatch({ok, #{status := in_doubt}}, StatusReply),
        CorrelatedEvents =
            soma_event_store:by_correlation(StorePid, CorrelationId),
        RunStarted =
            [Event || Event <- CorrelatedEvents,
                      maps:get(event_type, Event) =:= <<"run.started">>],
        StateInvocations =
            [Event || Event <- CorrelatedEvents,
                      maps:get(event_type, Event) =:= <<"tool.started">>,
                      maps:get(step_id, Event) =:= StepId],
        ?assertEqual(
           [Steps],
           [maps:get(steps, maps:get(payload, Event))
            || Event <- RunStarted]),
        ?assertEqual([RunId],
                     [maps:get(run_id, Event)
                      || Event <- StateInvocations]),
        ?assertEqual([], live_round_workers())
    after
        case whereis(soma_tool_registry) of
            undefined ->
                ok;
            _RegistryPid ->
                ok = soma_tool_registry:unregister_tool(ToolName)
        end
    end.

test_task_leases_are_stable_and_released_once_for_all_outcomes(_Config) ->
    Outcomes = [success, failure, timeout, cancellation,
                coordinator_crash],
    lists:foreach(fun assert_task_lease_lifecycle/1, Outcomes).

test_cancel_tears_down_llm_run_tool_and_os_children_once(Config) ->
    Observer = self(),
    LlmCorrelationId = <<"delegate-correlation-cancel-llm">>,
    LlmSpec =
        #{request_id => <<"delegate-request-cancel-llm">>,
          correlation_id => LlmCorrelationId,
          objective => <<"cancel one blocked owned LLM call">>,
          round_sequence =>
              [#{llm => #{directive => hang}, decision => continue},
               later_round_fixture(llm, Observer)]},
    {ok, #{task_id := LlmTaskId}} =
        submit_through_production_ingress(LlmSpec),
    LlmCoordinatorPid = coordinator_for_task(LlmTaskId),
    LlmRoundWorkerPid = wait_for_round_worker(100),
    {_LlmWorkerData, #{pid := LlmPid}} =
        wait_for_worker_phase(
          LlmRoundWorkerPid, waiting_llm, active_llm, 100),

    {ok, LlmCancelled = #{status := cancelled}} =
        soma_delegate:cancel(LlmTaskId),
    ?assertNot(is_process_alive(LlmPid)),
    ?assertNot(is_process_alive(LlmRoundWorkerPid)),
    ?assertEqual([], live_round_workers()),
    assert_one_terminal_cancellation(LlmTaskId, LlmCancelled),
    ?assertEqual(
       [],
       [Event || Event <-
                     soma_event_store:by_correlation(
                       event_store_pid(), LlmCorrelationId),
                 maps:get(event_type, Event) =:= <<"run.started">>]),
    assert_no_later_round(llm),
    wait_for_process_dead(LlmCoordinatorPid, 100),

    ToolName = delegate_cancel_cli,
    ActionCorrelationId = <<"delegate-correlation-cancel-action">>,
    {Helper, PidFile} =
        write_delegate_cancel_cli_stub(
          proplists:get_value(priv_dir, Config)),
    ok = soma_tool_registry:register_tool(
           #{name => ToolName,
             effect => reader,
             idempotent => true,
             timeout_ms => 60000,
             adapter => cli,
             executable => Helper,
             argv => [PidFile]}),
    try
        Step = #{id => <<"delegate-cancel-cli-step">>,
                 tool => ToolName,
                 args => #{value => <<"block until cancelled">>},
                 timeout_ms => 60000},
        ActionSpec =
            #{request_id => <<"delegate-request-cancel-action">>,
              correlation_id => ActionCorrelationId,
              objective =>
                  <<"cancel one delegated CLI action and its process">>,
              round_sequence =>
                  [#{llm =>
                         #{directive => success,
                           output => <<"dispatch-cli-action">>},
                     action_steps => [Step],
                     decision => continue},
                   later_round_fixture(action, Observer)]},
        {ok, #{task_id := ActionTaskId}} =
            submit_through_production_ingress(ActionSpec),
        ActionCoordinatorPid = coordinator_for_task(ActionTaskId),
        ActionRoundWorkerPid = wait_for_round_worker(100),
        {_ActionWorkerData,
         #{pid := RunPid, run_id := RunId}} =
            wait_for_worker_phase(
              ActionRoundWorkerPid, waiting_run, active_run, 100),
        [ToolStarted] =
            wait_for_correlated_events(
              event_store_pid(), ActionCorrelationId,
              <<"tool.started">>, 100),
        ToolCallPid = maps:get(tool_call_pid, ToolStarted),
        OsPid = wait_for_delegate_os_pid(PidFile, 100),
        ?assert(is_process_alive(ActionRoundWorkerPid)),
        ?assert(is_process_alive(RunPid)),
        ?assert(is_process_alive(ToolCallPid)),
        ?assert(delegate_os_process_alive(OsPid)),

        {ok, ActionCancelled = #{status := cancelled}} =
            soma_delegate:cancel(ActionTaskId),
        ?assertNot(is_process_alive(ActionRoundWorkerPid)),
        ?assertNot(is_process_alive(RunPid)),
        ?assertNot(is_process_alive(ToolCallPid)),
        ?assertNot(delegate_os_process_alive(OsPid)),
        ?assertEqual([], live_round_workers()),
        ?assertEqual([], live_runs()),
        assert_one_terminal_cancellation(
          ActionTaskId, ActionCancelled),
        RunEvents = soma_event_store:by_run(event_store_pid(), RunId),
        ?assertEqual(
           1,
           length([Event || Event <- RunEvents,
                            maps:get(event_type, Event) =:=
                                <<"run.cancelled">>])),
        ?assertEqual(
           1,
           length([Event || Event <-
                                soma_event_store:by_correlation(
                                  event_store_pid(),
                                  ActionCorrelationId),
                            maps:get(event_type, Event) =:=
                                <<"run.started">>])),
        assert_no_later_round(action),
        wait_for_process_dead(ActionCoordinatorPid, 100)
    after
        ok = soma_tool_registry:unregister_tool(ToolName)
    end.

assert_task_lease_lifecycle(Outcome) ->
    OutcomeBin = atom_to_binary(Outcome),
    RequestId = <<"delegate-request-task-leases-", OutcomeBin/binary>>,
    LeaseNames =
        [<<"delegate-lease-", OutcomeBin/binary, "-primary">>,
         <<"delegate-lease-", OutcomeBin/binary, "-secondary">>],
    OpaqueHandles =
        maps:from_list(
          [{Name, <<"opaque-handle:", Name/binary>>}
           || Name <- LeaseNames]),
    RawLeases =
        maps:from_list(
          [{Name, {raw_delegate_lease, Outcome, Name, make_ref()}}
           || Name <- LeaseNames]),
    Observer = self(),
    LeaseRequests =
        [#{name => Name,
           adapter => soma_delegate_test_lease_adapter,
           options =>
               #{observer => Observer,
                 opaque_handle => maps:get(Name, OpaqueHandles),
                 raw_lease => maps:get(Name, RawLeases)}}
         || Name <- LeaseNames],
    FirstRound =
        fun(Snapshot) ->
                Observer !
                    {delegate_lease_round_snapshot, Outcome, 1,
                     Snapshot},
                #{llm =>
                      #{directive => success,
                        output => <<"first-lease-round">>},
                  decision => continue}
        end,
    SecondRound =
        fun(Snapshot) ->
                Observer !
                    {delegate_lease_round_snapshot, Outcome, 2,
                     Snapshot},
                lease_terminal_round(Outcome)
        end,
    TaskSpec =
        #{request_id => RequestId,
          objective => <<"keep task leases stable across rounds">>,
          lease_requests => LeaseRequests,
          round_sequence => [FirstRound, SecondRound]},

    {ok, #{task_id := TaskId}} =
        submit_through_production_ingress(TaskSpec),
    CoordinatorPid =
        case Outcome of
            cancellation -> coordinator_for_task(TaskId);
            coordinator_crash -> coordinator_for_task(TaskId);
            _TerminalOutcome -> undefined
        end,
    Acquisitions = wait_for_lease_acquisitions(length(LeaseNames), []),
    [GuardPid] =
        lists:usort(
          [AcquiringGuardPid
           || {AcquiringGuardPid, _Name, _Handle, _RawLease} <-
                  Acquisitions]),
    ?assertEqual(
       lists:sort(
         [{Name, maps:get(Name, OpaqueHandles), maps:get(Name, RawLeases)}
          || Name <- LeaseNames]),
       lists:sort(
         [{Name, Handle, RawLease}
          || {_AcquiringGuardPid, Name, Handle, RawLease} <-
                 Acquisitions])),

    Snapshots =
        [wait_for_lease_snapshot(Outcome, RoundId)
         || RoundId <- [1, 2]],
    ?assertEqual(
       [OpaqueHandles, OpaqueHandles],
       [maps:get(resource_handles, Snapshot)
        || Snapshot <- Snapshots]),

    TerminalProjection =
        finish_lease_outcome(Outcome, TaskId, CoordinatorPid),
    ?assertEqual(expected_lease_outcome_status(Outcome),
                 maps:get(status, TerminalProjection)),
    Releases = wait_for_lease_releases(length(LeaseNames), []),
    ?assertEqual(
       lists:sort(
         [{GuardPid, Name, maps:get(Name, RawLeases)}
          || Name <- LeaseNames]),
       lists:sort(Releases)),
    wait_for_process_dead(GuardPid, 100),

    ExpectedReleaseCount = length(LeaseNames),
    ?assertEqual({Outcome, ExpectedReleaseCount},
                 {Outcome, length(Releases)}),
    assert_no_extra_lease_callbacks(Outcome).

lease_terminal_round(success) ->
    #{llm =>
          #{directive => success,
            output => <<"terminal-lease-round">>},
      decision => terminal};
lease_terminal_round(failure) ->
    #{llm => #{directive => crash}, decision => terminal};
lease_terminal_round(timeout) ->
    #{llm => #{directive => hang, timeout_ms => 60000},
      round_timeout_ms => 50,
      decision => terminal};
lease_terminal_round(cancellation) ->
    #{llm => #{directive => hang}, decision => terminal};
lease_terminal_round(coordinator_crash) ->
    #{llm => #{directive => hang}, decision => terminal}.

finish_lease_outcome(cancellation, TaskId, _CoordinatorPid) ->
    {ok, Projection} = soma_delegate:cancel(TaskId),
    Projection;
finish_lease_outcome(coordinator_crash, TaskId, CoordinatorPid) ->
    exit(CoordinatorPid, kill),
    wait_for_process_dead(CoordinatorPid, 100),
    wait_for_terminal_projection(TaskId, 100);
finish_lease_outcome(_Outcome, TaskId, _CoordinatorPid) ->
    wait_for_terminal_projection(TaskId, 200).

expected_lease_outcome_status(success) -> succeeded;
expected_lease_outcome_status(failure) -> failed;
expected_lease_outcome_status(timeout) -> timeout;
expected_lease_outcome_status(cancellation) -> cancelled;
expected_lease_outcome_status(coordinator_crash) -> failed.

wait_for_lease_acquisitions(0, Acquisitions) ->
    Acquisitions;
wait_for_lease_acquisitions(Remaining, Acquisitions) ->
    receive
        {delegate_test_lease_acquired, GuardPid, Name,
         OpaqueHandle, RawLease} ->
            wait_for_lease_acquisitions(
              Remaining - 1,
              [{GuardPid, Name, OpaqueHandle, RawLease}
               | Acquisitions])
    after 2000 ->
        ct:fail(task_lease_not_acquired)
    end.

wait_for_lease_snapshot(Outcome, RoundId) ->
    receive
        {delegate_lease_round_snapshot, Outcome, RoundId, Snapshot} ->
            Snapshot
    after 2000 ->
        ct:fail({task_lease_snapshot_not_recorded, Outcome, RoundId})
    end.

wait_for_lease_releases(0, Releases) ->
    Releases;
wait_for_lease_releases(Remaining, Releases) ->
    receive
        {delegate_test_lease_released, GuardPid, Name, RawLease} ->
            wait_for_lease_releases(
              Remaining - 1,
              [{GuardPid, Name, RawLease} | Releases])
    after 2000 ->
        ct:fail(task_lease_not_released)
    end.

assert_no_extra_lease_callbacks(Outcome) ->
    receive
        {delegate_test_lease_acquired, _GuardPid, _Name,
         _OpaqueHandle, _RawLease} = Callback ->
            ct:fail({unexpected_extra_lease_callback, Outcome, Callback});
        {delegate_test_lease_released, _GuardPid, _Name,
         _RawLease} = Callback ->
            ct:fail({unexpected_extra_lease_callback, Outcome, Callback})
    after 0 ->
        ok
    end.

later_round_fixture(Phase, Observer) ->
    fun(_Snapshot) ->
            Observer ! {delegate_later_round_started, Phase},
            #{llm => #{directive => hang}, decision => terminal}
    end.

assert_one_terminal_cancellation(TaskId, PublicProjection) ->
    ?assertEqual(
       [#{status => cancelled, round => 2}],
       cancelled_terminal_projections(TaskId)),
    ?assertEqual({ok, PublicProjection}, soma_delegate:status(TaskId)),
    ?assertEqual({ok, PublicProjection}, soma_delegate:cancel(TaskId)),
    ?assertEqual(
       [#{status => cancelled, round => 2}],
       cancelled_terminal_projections(TaskId)).

cancelled_terminal_projections(TaskId) ->
    IngressState = sys:get_state(soma_delegate),
    Tasks = maps:get(tasks, IngressState),
    [Projection
     || {StoredTaskId, Route} <- maps:to_list(Tasks),
        StoredTaskId =:= TaskId,
        Projection <- [maps:get(terminal_projection, Route, undefined)],
        is_map(Projection),
        maps:get(status, Projection, undefined) =:= cancelled].

assert_no_later_round(Phase) ->
    receive
        {delegate_later_round_started, Phase} ->
            ct:fail({later_round_started_after_cancel, Phase})
    after 100 ->
        ok
    end.

write_delegate_cancel_cli_stub(TmpDir) ->
    Helper = filename:join(TmpDir, "delegate-cancel-cli.sh"),
    PidFile = filename:join(TmpDir, "delegate-cancel-cli.pid"),
    Script = <<"#!/bin/sh\n"
               "printf '%s\\n' \"$$\" > \"$1\"\n"
               "sleep 30\n">>,
    ok = filelib:ensure_dir(Helper),
    ok = file:write_file(Helper, Script),
    ok = file:change_mode(Helper, 8#755),
    {Helper, PidFile}.

wait_for_delegate_os_pid(_PidFile, 0) ->
    ct:fail(delegate_cli_stub_did_not_write_os_pid);
wait_for_delegate_os_pid(PidFile, Attempts) ->
    case file:read_file(PidFile) of
        {ok, Bytes} ->
            list_to_integer(string:trim(binary_to_list(Bytes)));
        {error, enoent} ->
            timer:sleep(10),
            wait_for_delegate_os_pid(PidFile, Attempts - 1)
    end.

delegate_os_process_alive(OsPid) ->
    Kill = os:find_executable("kill"),
    Port = open_port(
             {spawn_executable, Kill},
             [{args, ["-0", integer_to_list(OsPid)]},
              exit_status, binary, use_stdio, stderr_to_stdout]),
    delegate_os_process_probe_result(Port).

delegate_os_process_probe_result(Port) ->
    receive
        {Port, {data, _Bytes}} ->
            delegate_os_process_probe_result(Port);
        {Port, {exit_status, 0}} ->
            true;
        {Port, {exit_status, _NonZero}} ->
            false
    after 1000 ->
        erlang:port_close(Port),
        ct:fail(delegate_os_process_probe_timeout)
    end.

crash_fixture(Suffix) ->
    #{request_id => <<"delegate-request-", Suffix/binary>>,
      objective => <<"hold a disposable round open">>,
      round_sequence =>
          [#{llm => #{directive => hang}, decision => continue}]}.

submit_through_production_ingress(TaskSpec) ->
    case code:ensure_loaded(soma_delegate) of
        {module, soma_delegate} ->
            soma_delegate:submit(TaskSpec);
        {error, _Reason} ->
            {error, production_delegate_ingress_unavailable}
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Modules} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

live_coordinators() ->
    [Pid || {_Id, Pid, worker, _Modules} <-
                supervisor:which_children(soma_delegate_coordinator_sup),
            is_pid(Pid),
            is_process_alive(Pid)].

live_round_workers() ->
    [Pid || {_Id, Pid, worker, _Modules} <-
                supervisor:which_children(soma_delegate_round_sup),
            is_pid(Pid),
            is_process_alive(Pid)].

live_runs() ->
    [Pid || {_Id, Pid, worker, _Modules} <-
                supervisor:which_children(soma_run_sup),
            is_pid(Pid),
            is_process_alive(Pid)].

coordinator_for_task(TaskId) ->
    [CoordinatorPid] =
        [Pid || Pid <- live_coordinators(),
                maps:get(task_id, element(2, sys:get_state(Pid))) =:= TaskId],
    CoordinatorPid.

wait_for_round_worker(0) ->
    ct:fail(round_worker_not_started);
wait_for_round_worker(Attempts) ->
    RoundWorkers =
        case whereis(soma_delegate_round_sup) of
            undefined ->
                [];
            _RoundSupPid ->
                [Pid || {_Id, Pid, worker, _Modules} <-
                            supervisor:which_children(soma_delegate_round_sup),
                        is_pid(Pid),
                        is_process_alive(Pid)]
        end,
    case RoundWorkers of
        [RoundWorkerPid] ->
            RoundWorkerPid;
        [] ->
            timer:sleep(10),
            wait_for_round_worker(Attempts - 1)
    end.

wait_for_worker_phase(_WorkerPid, _StateName, _ActiveKey, 0) ->
    ct:fail(round_worker_phase_not_reached);
wait_for_worker_phase(WorkerPid, StateName, ActiveKey, Attempts) ->
    case sys:get_state(WorkerPid) of
        {StateName, WorkerData} ->
            case maps:get(ActiveKey, WorkerData, undefined) of
                ActiveChild when is_map(ActiveChild) ->
                    {WorkerData, ActiveChild};
                undefined ->
                    timer:sleep(10),
                    wait_for_worker_phase(
                      WorkerPid, StateName, ActiveKey, Attempts - 1)
            end;
        {_OtherStateName, _WorkerData} ->
            timer:sleep(10),
            wait_for_worker_phase(
              WorkerPid, StateName, ActiveKey, Attempts - 1)
    end.

wait_for_active_round(_CoordinatorPid, ExpectedRoundId, 0) ->
    ?assertEqual(ExpectedRoundId, round_worker_not_started);
wait_for_active_round(CoordinatorPid, ExpectedRoundId, Attempts) ->
    case is_process_alive(CoordinatorPid) of
        false ->
            ?assertEqual(ExpectedRoundId,
                         coordinator_stopped_before_next_round);
        true ->
            try sys:get_state(CoordinatorPid) of
                {_StateName, CoordinatorData} ->
                    case maps:get(active_round, CoordinatorData,
                                  undefined) of
                        ActiveRound = #{round_id := ExpectedRoundId} ->
                            {CoordinatorData, ActiveRound};
                        _OtherRound ->
                            timer:sleep(10),
                            wait_for_active_round(
                              CoordinatorPid, ExpectedRoundId,
                              Attempts - 1)
                    end
            catch
                exit:_Reason ->
                    ?assertEqual(
                       ExpectedRoundId,
                       coordinator_stopped_before_next_round)
            end
    end.

send_round_result(
  CoordinatorPid, TaskId,
  #{round_id := RoundId,
    worker_pid := WorkerPid,
    worker_identity := WorkerIdentity,
    result_capability := ResultCapability},
  Result) ->
    CoordinatorPid !
        {delegate_round_result, TaskId, RoundId, WorkerPid,
         WorkerIdentity, ResultCapability, Result}.

round_result_message(
  TaskId,
  #{round_id := RoundId,
    worker_pid := WorkerPid,
    worker_identity := WorkerIdentity,
    result_capability := ResultCapability},
  Result) ->
    {delegate_round_result, TaskId, RoundId, WorkerPid,
     WorkerIdentity, ResultCapability, Result}.

assert_coordinator_owns_round(
  CoordinatorPid, RoundWorkerPid,
  #{round_id := RoundId,
    worker_identity := WorkerIdentity,
    worker_pid := RoundWorkerPid,
    worker_mref := WorkerMRef,
    result_capability := ResultCapability}) ->
    ?assert(is_integer(RoundId)),
    ?assert(is_binary(WorkerIdentity)),
    ?assert(is_reference(WorkerMRef)),
    ?assert(is_reference(ResultCapability)),
    ?assert(lists:member(RoundWorkerPid,
                         process_monitors(CoordinatorPid))).

assert_live_timer(TimerRef) ->
    ?assert(is_reference(TimerRef)),
    ?assert(is_integer(erlang:read_timer(TimerRef))).

assert_cancelled_timer(TimerRef) ->
    ?assertEqual(false, erlang:read_timer(TimerRef)).

process_monitors(Pid) ->
    {monitors, Monitors} = process_info(Pid, monitors),
    [MonitoredPid || {process, MonitoredPid} <- Monitors].

process_links(Pid) ->
    {links, Links} = process_info(Pid, links),
    Links.

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

wait_for_task_status(TaskId, _ExpectedStatus, 0) ->
    soma_delegate:status(TaskId);
wait_for_task_status(TaskId, ExpectedStatus, Attempts) ->
    case soma_delegate:status(TaskId) of
        {ok, #{status := ExpectedStatus}} = Reply ->
            Reply;
        _OtherReply ->
            timer:sleep(10),
            wait_for_task_status(
              TaskId, ExpectedStatus, Attempts - 1)
    end.

wait_for_correlated_events(
  _StorePid, _CorrelationId, EventType, 0) ->
    ct:fail({correlated_event_not_recorded, EventType});
wait_for_correlated_events(
  StorePid, CorrelationId, EventType, Attempts) ->
    Events =
        [Event || Event <-
                      soma_event_store:by_correlation(
                        StorePid, CorrelationId),
                  maps:get(event_type, Event) =:= EventType],
    case Events of
        [] ->
            timer:sleep(10),
            wait_for_correlated_events(
              StorePid, CorrelationId, EventType, Attempts - 1);
        [_First | _Remaining] ->
            Events
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
