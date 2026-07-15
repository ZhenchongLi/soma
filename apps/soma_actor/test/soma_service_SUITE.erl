-module(soma_service_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([test_supervised_service_restarts_and_serves_again/1]).
-export([test_single_tool_invocation_runs_without_llm_worker/1]).
-export([test_oversized_result_fails_with_max_output_reason/1]).
-export([test_flat_plan_preserves_order_and_from_step_output/1]).
-export([test_identical_duplicate_reuses_running_handle_and_terminal_result/1]).
-export([test_conflicting_request_id_rejected_before_new_run/1]).
-export([test_run_started_journals_request_id_and_envelope_hash/1]).
-export([test_durable_restart_rebuilds_dedupe_without_new_run_started/1]).
-export([test_fresh_vms_keep_durable_task_and_run_ids_distinct/1]).
-export([test_restarted_service_rearms_absolute_deadline/1]).
-export([test_timer_unsafe_deadline_rejected_before_journaling/1]).
-export([test_poison_deadline_metadata_recovers_bounded_terminal/1]).
-export([test_recovery_enforces_deadline_before_terminal_or_resume/1]).
-export([test_recovery_lands_every_unowned_trail_terminal/1]).
-export([test_recovery_preserves_owner_decisions_across_restarts/1]).
-export([test_start_failures_land_terminal_task_data/1]).
-export([test_out_of_scope_invocation_rejected_through_policy/1]).
-export([test_unscoped_invocation_uses_configured_or_empty_default_policy/1]).
-export([test_unknown_scope_entry_does_not_create_atom/1]).
-export([test_deadline_exceeded_cleans_run_worker_and_cli_process/1]).
-export([test_service_cancel_cleans_tool_worker_and_cli_process/1]).
-export([test_tool_crash_is_bounded_and_service_runs_again/1]).
-export([test_lifecycle_reads_are_monotonic/1]).
-export([test_unsafe_interrupted_state_invocation_recovers_in_doubt/1]).
-export([test_interrupted_reader_invocation_resumes_after_restart/1]).
-export([test_boot_recovery_registers_actor_tools_first/1]).
-export([test_rejection_reason_stays_bounded_for_large_plans/1]).

all() ->
    [test_supervised_service_restarts_and_serves_again,
     test_single_tool_invocation_runs_without_llm_worker,
     test_oversized_result_fails_with_max_output_reason,
     test_flat_plan_preserves_order_and_from_step_output,
     test_identical_duplicate_reuses_running_handle_and_terminal_result,
     test_conflicting_request_id_rejected_before_new_run,
     test_run_started_journals_request_id_and_envelope_hash,
     test_durable_restart_rebuilds_dedupe_without_new_run_started,
     test_fresh_vms_keep_durable_task_and_run_ids_distinct,
     test_restarted_service_rearms_absolute_deadline,
     test_timer_unsafe_deadline_rejected_before_journaling,
     test_poison_deadline_metadata_recovers_bounded_terminal,
     test_recovery_enforces_deadline_before_terminal_or_resume,
     test_recovery_lands_every_unowned_trail_terminal,
     test_recovery_preserves_owner_decisions_across_restarts,
     test_start_failures_land_terminal_task_data,
     test_out_of_scope_invocation_rejected_through_policy,
     test_unscoped_invocation_uses_configured_or_empty_default_policy,
     test_unknown_scope_entry_does_not_create_atom,
     test_deadline_exceeded_cleans_run_worker_and_cli_process,
     test_service_cancel_cleans_tool_worker_and_cli_process,
     test_tool_crash_is_bounded_and_service_runs_again,
     test_lifecycle_reads_are_monotonic,
     test_unsafe_interrupted_state_invocation_recovers_in_doubt,
     test_interrupted_reader_invocation_resumes_after_restart,
     test_boot_recovery_registers_actor_tools_first,
     test_rejection_reason_stays_bounded_for_large_plans].

init_per_testcase(
  test_tool_crash_is_bounded_and_service_runs_again, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [echo, fail]}),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config];
init_per_testcase(
  test_service_cancel_cleans_tool_worker_and_cli_process, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [service_cancel_cli]}),
    TmpDir = make_tmp_dir(),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started}, {tmp_dir, TmpDir} | Config];
init_per_testcase(
  test_deadline_exceeded_cleans_run_worker_and_cli_process, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [service_deadline_cli]}),
    TmpDir = make_tmp_dir(),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started}, {tmp_dir, TmpDir} | Config];
init_per_testcase(
  test_unsafe_interrupted_state_invocation_recovers_in_doubt, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [service_hanging_state]}),
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    ok = application:set_env(soma_runtime, event_store_log, Path),
    {ok, Started} = application:ensure_all_started(soma_actor),
    ok = soma_tool_registry:register_tool(
           soma_service_hanging_state_tool:manifest()),
    [{started_apps, Started}, {tmp_dir, TmpDir}, {log_path, Path} | Config];
init_per_testcase(
  test_boot_recovery_registers_actor_tools_first, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [sleep, ask_actor]}),
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    ok = application:set_env(soma_runtime, event_store_log, Path),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started}, {tmp_dir, TmpDir}, {log_path, Path} | Config];
init_per_testcase(
  test_rejection_reason_stays_bounded_for_large_plans, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [echo]}),
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    ok = application:set_env(soma_runtime, event_store_log, Path),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started}, {tmp_dir, TmpDir}, {log_path, Path} | Config];
init_per_testcase(
  test_interrupted_reader_invocation_resumes_after_restart, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [sleep]}),
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    ok = application:set_env(soma_runtime, event_store_log, Path),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started}, {tmp_dir, TmpDir}, {log_path, Path} | Config];
init_per_testcase(
  test_fresh_vms_keep_durable_task_and_run_ids_distinct, Config) ->
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    [{tmp_dir, TmpDir}, {log_path, Path} | Config];
init_per_testcase(test_start_failures_land_terminal_task_data, Config) ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [echo]}),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase =:= test_poison_deadline_metadata_recovers_bounded_terminal;
       TestCase =:= test_recovery_enforces_deadline_before_terminal_or_resume;
       TestCase =:= test_recovery_lands_every_unowned_trail_terminal;
       TestCase =:= test_recovery_preserves_owner_decisions_across_restarts ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [echo]}),
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    ok = application:set_env(soma_runtime, event_store_log, Path),
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started}, {tmp_dir, TmpDir}, {log_path, Path} | Config];
init_per_testcase(TestCase, Config)
  when TestCase =:= test_run_started_journals_request_id_and_envelope_hash;
       TestCase =:=
           test_durable_restart_rebuilds_dedupe_without_new_run_started;
       TestCase =:= test_restarted_service_rearms_absolute_deadline ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [echo, sleep]}),
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    ok = application:set_env(soma_runtime, event_store_log, Path),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started}, {tmp_dir, TmpDir}, {log_path, Path} | Config];
init_per_testcase(TestCase, Config)
  when TestCase =:= test_supervised_service_restarts_and_serves_again;
       TestCase =:= test_single_tool_invocation_runs_without_llm_worker;
       TestCase =:= test_oversized_result_fails_with_max_output_reason;
       TestCase =:= test_flat_plan_preserves_order_and_from_step_output;
       TestCase =:=
           test_identical_duplicate_reuses_running_handle_and_terminal_result;
       TestCase =:= test_conflicting_request_id_rejected_before_new_run;
       TestCase =:= test_out_of_scope_invocation_rejected_through_policy;
       TestCase =:=
           test_unscoped_invocation_uses_configured_or_empty_default_policy;
       TestCase =:= test_unknown_scope_entry_does_not_create_atom;
       TestCase =:= test_timer_unsafe_deadline_rejected_before_journaling;
       TestCase =:= test_lifecycle_reads_are_monotonic;
       TestCase =:=
           test_run_started_journals_request_id_and_envelope_hash;
       TestCase =:=
           test_durable_restart_rebuilds_dedupe_without_new_run_started ->
    ok = ensure_loaded(soma_actor),
    ok = application:set_env(
           soma_actor, service_policy,
           #{allowed_tools => [echo, sleep]}),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config].

end_per_testcase(TestCase, Config)
  when TestCase =:= test_supervised_service_restarts_and_serves_again;
       TestCase =:= test_single_tool_invocation_runs_without_llm_worker;
       TestCase =:= test_oversized_result_fails_with_max_output_reason;
       TestCase =:= test_flat_plan_preserves_order_and_from_step_output;
       TestCase =:=
           test_identical_duplicate_reuses_running_handle_and_terminal_result;
       TestCase =:= test_conflicting_request_id_rejected_before_new_run;
       TestCase =:= test_out_of_scope_invocation_rejected_through_policy;
       TestCase =:=
           test_unscoped_invocation_uses_configured_or_empty_default_policy;
       TestCase =:= test_unknown_scope_entry_does_not_create_atom;
       TestCase =:=
           test_deadline_exceeded_cleans_run_worker_and_cli_process;
       TestCase =:=
           test_service_cancel_cleans_tool_worker_and_cli_process;
       TestCase =:= test_tool_crash_is_bounded_and_service_runs_again;
       TestCase =:= test_lifecycle_reads_are_monotonic;
       TestCase =:= test_boot_recovery_registers_actor_tools_first;
       TestCase =:= test_rejection_reason_stays_bounded_for_large_plans;
       TestCase =:=
           test_unsafe_interrupted_state_invocation_recovers_in_doubt;
       TestCase =:=
           test_interrupted_reader_invocation_resumes_after_restart;
       TestCase =:=
           test_run_started_journals_request_id_and_envelope_hash;
       TestCase =:=
           test_durable_restart_rebuilds_dedupe_without_new_run_started;
       TestCase =:= test_fresh_vms_keep_durable_task_and_run_ids_distinct;
       TestCase =:= test_start_failures_land_terminal_task_data;
       TestCase =:= test_timer_unsafe_deadline_rejected_before_journaling;
       TestCase =:= test_poison_deadline_metadata_recovers_bounded_terminal;
       TestCase =:= test_recovery_enforces_deadline_before_terminal_or_resume;
       TestCase =:= test_recovery_lands_every_unowned_trail_terminal;
       TestCase =:= test_recovery_preserves_owner_decisions_across_restarts;
       TestCase =:= test_restarted_service_rearms_absolute_deadline ->
    application:stop(soma_actor),
    application:stop(soma_runtime),
    application:unset_env(soma_actor, service_policy),
    application:unset_env(soma_runtime, event_store_log),
    application:unload(soma_actor),
    maybe_del_tmp_dir(Config),
    ok.

test_supervised_service_restarts_and_serves_again(_Config) ->
    ServicePid = whereis(soma_service),
    ?assert(is_pid(ServicePid)),
    ?assert(is_process_alive(ServicePid)),

    SlowEnvelope = tool_envelope(
                     <<"service-restart-slow">>, sleep,
                     #{ms => 1000}),
    {ok, #{task_id := SlowTaskId, status := accepted}} =
        soma_service:invoke(SlowEnvelope),
    {ok, #{status := running}} = soma_service:status(SlowTaskId),
    OwnedRunPid = wait_for_monitored_run(ServicePid, 100),
    ?assert(is_process_alive(OwnedRunPid)),

    exit(ServicePid, kill),
    ReplacementPid = wait_for_replacement(ServicePid, 100),
    ?assert(is_process_alive(ReplacementPid)),

    EchoEnvelope = tool_envelope(
                     <<"service-restart-echo">>, echo,
                     #{value => <<"served again">>}),
    {ok, #{task_id := EchoTaskId, status := accepted}} =
        soma_service:invoke(EchoEnvelope),
    {ok, Terminal} = wait_for_status(EchoTaskId, succeeded, 100),
    ?assertEqual(
       #{<<"service-restart-echo">> => #{value => <<"served again">>}},
       maps:get(result, Terminal)),
    ?assertEqual(ReplacementPid, whereis(soma_service)).

test_single_tool_invocation_runs_without_llm_worker(_Config) ->
    {module, soma_llm_call} = code:ensure_loaded(soma_llm_call),
    ok = start_llm_start_trace(),
    try
        RequestId = <<"service-single-tool">>,
        Args = #{value => <<"exact service output">>},
        RawEnvelope = tool_envelope(RequestId, echo, Args),
        {ok, NormalizedEnvelope} =
            soma_service_envelope:normalize(RawEnvelope),
        Step = maps:get(
                 step, maps:get(operation, NormalizedEnvelope)),

        {ok, #{task_id := TaskId, status := accepted}} =
            soma_service:invoke(NormalizedEnvelope),
        {ok, Terminal} = wait_for_status(TaskId, succeeded, 100),
        ?assertEqual(#{RequestId => Args}, maps:get(result, Terminal)),

        StorePid = runtime_event_store(),
        Events = soma_event_store:all(StorePid),
        [RunStarted] =
            [Event || Event <- Events,
                      maps:get(event_type, Event) =:= <<"run.started">>,
                      maps:get(steps, maps:get(payload, Event)) =:= [Step]],
        RunId = maps:get(run_id, RunStarted),
        RunEvents = soma_event_store:by_run(StorePid, RunId),
        ?assert(lists:any(
                  fun(Event) ->
                          maps:get(event_type, Event) =:= <<"tool.started">>
                  end,
                  RunEvents)),

        ?assertEqual([], stop_llm_start_trace())
    after
        clear_llm_start_trace()
    end.

test_oversized_result_fails_with_max_output_reason(_Config) ->
    RequestId = <<"service-oversized-result">>,
    Envelope =
        (tool_envelope(
           RequestId, echo,
           #{value => <<"larger than the service result budget">>}))#{
          max_output_bytes => 16},

    {ok, #{task_id := TaskId, status := accepted}} =
        soma_service:invoke(Envelope),
    {ok, Terminal} = wait_for_terminal(TaskId, 100),
    ?assertEqual(failed, maps:get(status, Terminal)),
    ?assertEqual(max_output_bytes_exceeded, maps:get(reason, Terminal)),
    ?assertNot(maps:is_key(result, Terminal)).

test_flat_plan_preserves_order_and_from_step_output(_Config) ->
    FirstStepId = service_flat_plan_first,
    SecondStepId = service_flat_plan_second,
    FirstOutput = #{value => <<"source step output">>},
    Steps =
        [#{id => FirstStepId,
           tool => echo,
           args => FirstOutput},
         #{id => SecondStepId,
           tool => echo,
           args => #{from_step => FirstStepId}}],
    Envelope =
        #{kind => invoke,
          api_version => <<"1">>,
          request_id => <<"service-flat-plan">>,
          operation => #{kind => steps, steps => Steps}},

    {ok, #{task_id := TaskId, status := accepted}} =
        soma_service:invoke(Envelope),
    {ok, Terminal} = wait_for_status(TaskId, succeeded, 100),
    Outputs = maps:get(result, Terminal),
    ?assertEqual(FirstOutput, maps:get(FirstStepId, Outputs)),
    ?assertEqual(FirstOutput, maps:get(SecondStepId, Outputs)),

    StorePid = runtime_event_store(),
    [RunStarted] =
        [Event || Event <- soma_event_store:all(StorePid),
                  maps:get(event_type, Event) =:= <<"run.started">>,
                  maps:get(steps, maps:get(payload, Event)) =:= Steps],
    RunId = maps:get(run_id, RunStarted),
    StartedStepIds =
        [maps:get(step_id, Event)
         || Event <- soma_event_store:by_run(StorePid, RunId),
            maps:get(event_type, Event) =:= <<"step.started">>],
    ?assertEqual([FirstStepId, SecondStepId], StartedStepIds).

test_identical_duplicate_reuses_running_handle_and_terminal_result(_Config) ->
    RequestId = <<"service-identical-duplicate">>,
    Envelope = tool_envelope(RequestId, sleep, #{ms => 300}),
    {ok, NormalizedEnvelope} =
        soma_service_envelope:normalize(Envelope),
    Step = maps:get(step, maps:get(operation, NormalizedEnvelope)),

    {ok, #{task_id := TaskId, status := accepted} = Handle} =
        soma_service:invoke(Envelope),
    StorePid = runtime_event_store(),
    RunId = wait_for_run_started(StorePid, [Step], 100),
    ok = wait_for_run_event(StorePid, RunId, <<"tool.started">>, 100),

    ?assertEqual({ok, Handle}, soma_service:invoke(Envelope)),

    {ok, Terminal} = wait_for_status(TaskId, succeeded, 100),
    ?assertEqual({ok, Terminal}, soma_service:invoke(Envelope)),

    MatchingRunStarts =
        [Event || Event <- soma_event_store:all(StorePid),
                  maps:get(event_type, Event) =:= <<"run.started">>,
                  maps:get(steps, maps:get(payload, Event)) =:= [Step]],
    ?assertEqual(1, length(MatchingRunStarts)).

test_conflicting_request_id_rejected_before_new_run(_Config) ->
    RequestId = <<"service-request-id-conflict">>,
    FirstEnvelope = tool_envelope(RequestId, sleep, #{ms => 300}),
    ConflictingEnvelope = tool_envelope(RequestId, sleep, #{ms => 301}),
    {ok, FirstNormalized} =
        soma_service_envelope:normalize(FirstEnvelope),
    FirstStep = maps:get(step, maps:get(operation, FirstNormalized)),

    {ok, #{status := accepted}} = soma_service:invoke(FirstEnvelope),
    StorePid = runtime_event_store(),
    _RunId = wait_for_run_started(StorePid, [FirstStep], 100),
    RunStartCount = count_run_started(StorePid),

    ?assertEqual(
       {error, request_id_conflict},
       soma_service:invoke(ConflictingEnvelope)),
    ?assertEqual(RunStartCount, count_run_started(StorePid)).

test_run_started_journals_request_id_and_envelope_hash(Config) ->
    RequestId = <<"service-durable-request-identity">>,
    MaxOutputBytes = 4096,
    Envelope =
        (tool_envelope(
           RequestId, echo,
           #{value => <<"durable request metadata">>}))#{
          max_output_bytes => MaxOutputBytes,
          deadline_ms => 5000},
    {ok, NormalizedEnvelope} =
        soma_service_envelope:normalize(Envelope),
    EnvelopeHash =
        crypto:hash(
          sha256, term_to_binary(NormalizedEnvelope, [deterministic])),
    Step = maps:get(step, maps:get(operation, NormalizedEnvelope)),

    {ok, #{task_id := TaskId, status := accepted}} =
        soma_service:invoke(Envelope),
    {ok, #{status := succeeded}} =
        wait_for_status(TaskId, succeeded, 100),

    ok = application:stop(soma_actor),
    ok = application:stop(soma_runtime),
    ok = application:set_env(
           soma_runtime, event_store_log, ?config(log_path, Config)),
    {ok, _Started} = application:ensure_all_started(soma_runtime),

    [RunStarted] =
        [Event || Event <- soma_event_store:all(runtime_event_store()),
                  maps:get(event_type, Event) =:= <<"run.started">>,
                  maps:get(steps, maps:get(payload, Event)) =:= [Step]],
    [Accepted] =
        [Event || Event <- soma_event_store:all(runtime_event_store()),
                  maps:get(event_type, Event) =:=
                      <<"service.task.accepted">>,
                  maps:get(task_id, Event) =:= TaskId],
    DeadlineAtMs = maps:get(
                     deadline_at_ms, maps:get(payload, Accepted)),
    RunOptions = maps:get(run_options, maps:get(payload, RunStarted)),
    ?assertEqual(
       #{task_id => TaskId,
         request_id => RequestId,
         envelope_hash => EnvelopeHash,
         max_output_bytes => MaxOutputBytes,
         deadline_at_ms => DeadlineAtMs,
         auto_resume => false},
       maps:with(
         [task_id, request_id, envelope_hash, max_output_bytes,
          deadline_at_ms, auto_resume],
         RunOptions)).

test_durable_restart_rebuilds_dedupe_without_new_run_started(Config) ->
    RequestId = <<"service-durable-restart-dedupe">>,
    Envelope = tool_envelope(RequestId, sleep, #{ms => 1000}),
    {ok, NormalizedEnvelope} =
        soma_service_envelope:normalize(Envelope),
    Step = maps:get(step, maps:get(operation, NormalizedEnvelope)),

    ServicePid = whereis(soma_service),
    {ok, #{task_id := TaskId, status := accepted} = Handle} =
        soma_service:invoke(Envelope),
    StorePid = runtime_event_store(),
    RunId = wait_for_run_started(StorePid, [Step], 100),
    ok = wait_for_run_event(StorePid, RunId, <<"tool.started">>, 100),
    OwnedRunPid = wait_for_monitored_run(ServicePid, 100),

    exit(ServicePid, kill),
    ReplacementPid = wait_for_replacement(ServicePid, 100),
    ?assertEqual({ok, Handle}, soma_service:invoke(Envelope)),
    ?assertEqual(OwnedRunPid, wait_for_monitored_run(ReplacementPid, 100)),

    {ok, Terminal} = wait_for_status(TaskId, succeeded, 200),
    ?assertEqual(1, count_run_started(StorePid)),

    ok = application:stop(soma_actor),
    ok = application:stop(soma_runtime),
    ok = application:set_env(
           soma_runtime, event_store_log, ?config(log_path, Config)),
    {ok, _Started} = application:ensure_all_started(soma_actor),

    ReplayedStorePid = runtime_event_store(),
    ?assertEqual({ok, Terminal}, soma_service:invoke(Envelope)),
    ?assertEqual(1, count_run_started(ReplayedStorePid)).

test_fresh_vms_keep_durable_task_and_run_ids_distinct(Config) ->
    LogPath = ?config(log_path, Config),
    FirstRequest = <<"service-first-fresh-vm">>,
    FirstValue = <<"first durable result">>,
    First = run_fresh_service_vm(
              #{log_path => LogPath,
                request_id => FirstRequest,
                value => FirstValue}),

    SecondRequest = <<"service-second-fresh-vm">>,
    SecondValue = <<"second durable result">>,
    Second = run_fresh_service_vm(
               #{log_path => LogPath,
                 request_id => SecondRequest,
                 value => SecondValue,
                 duplicate =>
                     #{request_id => FirstRequest,
                       value => FirstValue}}),

    ?assertNotEqual(maps:get(task_id, First), maps:get(task_id, Second)),
    ?assertNotEqual(maps:get(run_id, First), maps:get(run_id, Second)),
    ?assertEqual(
       #{FirstRequest => #{value => FirstValue}},
       maps:get(result, maps:get(terminal, First))),
    ?assertEqual(
       #{SecondRequest => #{value => SecondValue}},
       maps:get(result, maps:get(terminal, Second))),
    ?assertEqual(
       maps:get(terminal, First),
       maps:get(duplicate, Second)).

test_restarted_service_rearms_absolute_deadline(_Config) ->
    RequestId = <<"service-restarted-deadline">>,
    Envelope =
        (tool_envelope(RequestId, sleep, #{ms => 3000}))#{
          deadline_ms => 500},
    ServicePid = whereis(soma_service),

    {ok, #{task_id := TaskId, status := accepted}} =
        soma_service:invoke(Envelope),
    StorePid = runtime_event_store(),
    {ok, Normalized} = soma_service_envelope:normalize(Envelope),
    Step = maps:get(step, maps:get(operation, Normalized)),
    RunId = wait_for_run_started(StorePid, [Step], 100),
    ok = wait_for_run_event(StorePid, RunId, <<"tool.started">>, 100),
    timer:sleep(100),

    exit(ServicePid, kill),
    ReplacementPid = wait_for_replacement(ServicePid, 100),
    {ok, Terminal} = wait_for_status(TaskId, failed, 150),

    ?assertEqual(deadline_exceeded, maps:get(reason, Terminal)),
    ?assertEqual(ReplacementPid, whereis(soma_service)),
    RunEventTypes =
        [maps:get(event_type, Event)
         || Event <- soma_event_store:by_run(StorePid, RunId)],
    ?assert(lists:member(
              <<"service.task.deadline_expired">>, RunEventTypes)),
    ?assert(lists:member(<<"run.cancelled">>, RunEventTypes)).

test_timer_unsafe_deadline_rejected_before_journaling(_Config) ->
    ServicePid = whereis(soma_service),
    StorePid = runtime_event_store(),
    EventsBefore = soma_event_store:all(StorePid),
    Envelope =
        (tool_envelope(
           <<"service-timer-unsafe-deadline">>, sleep,
           #{ms => 60000}))#{deadline_ms => 1 bsl 100},
    Expected =
        {error,
         [#{code => invalid_budget,
            message => <<"invoke budget is invalid">>}]},

    ?assertEqual(Expected, soma_service_envelope:normalize(Envelope)),
    ?assertEqual(Expected, soma_service:invoke(Envelope)),
    ?assertEqual(ServicePid, whereis(soma_service)),
    ?assert(is_process_alive(ServicePid)),
    ?assertEqual(EventsBefore, soma_event_store:all(StorePid)).

test_poison_deadline_metadata_recovers_bounded_terminal(_Config) ->
    StorePid = runtime_event_store(),
    Fixture0 = service_recovery_fixture(<<"poison-deadline">>),
    Step = #{id => poison_deadline_step,
             tool => sleep,
             args => #{ms => 60000},
             timeout_ms => 60000},
    Fixture = Fixture0#{step := Step},
    PoisonDeadline = erlang:system_time(millisecond) + (1 bsl 100),
    append_service_accepted(
      StorePid, Fixture, #{deadline_at_ms => PoisonDeadline}),
    {ok, RunPid} = soma_run_sup:start_run(
                     #{run_id => maps:get(run_id, Fixture),
                       task_id => maps:get(task_id, Fixture),
                       request_id => maps:get(request_id, Fixture),
                       envelope_hash => maps:get(envelope_hash, Fixture),
                       deadline_at_ms => PoisonDeadline,
                       auto_resume => false,
                       session_pid => self(),
                       event_store => StorePid,
                       steps => [Step]}),
    ok = wait_for_run_event(
           StorePid, maps:get(run_id, Fixture), <<"tool.started">>, 100),
    WorkerPid = tool_call_pid_from(StorePid, maps:get(run_id, Fixture)),

    {ok, _Started} = application:ensure_all_started(soma_actor),
    {ok, Terminal} = soma_service:status(maps:get(task_id, Fixture)),

    ?assertEqual(failed, maps:get(status, Terminal)),
    ?assertEqual(service_recovery_failed, maps:get(reason, Terminal)),
    ?assert(erlang:external_size(Terminal) =< 512),
    ?assert(is_process_alive(whereis(soma_service))),
    ok = wait_for_process_dead(RunPid, 100),
    ok = wait_for_process_dead(WorkerPid, 100),
    ?assertNot(lists:any(
                 fun(#{event_type := <<"run.resumed">>}) -> true;
                    (_Event) -> false
                 end,
                 soma_event_store:by_run(StorePid, maps:get(run_id, Fixture)))).

test_recovery_enforces_deadline_before_terminal_or_resume(_Config) ->
    StorePid = runtime_event_store(),
    DeadlineAtMs = erlang:system_time(millisecond) - 1000,

    Late = service_recovery_fixture(<<"late-completed-no-marker">>),
    LateStep = maps:get(step, Late),
    append_service_accepted(
      StorePid, Late, #{deadline_at_ms => DeadlineAtMs}),
    append_run_started(StorePid, Late),
    ok = soma_event_store:append(
           StorePid,
           #{run_id => maps:get(run_id, Late),
             step_id => maps:get(id, LateStep),
             event_type => <<"step.succeeded">>,
             payload => #{output => #{value => <<"too late">>}}}),
    ok = soma_event_store:append(
           StorePid,
           #{run_id => maps:get(run_id, Late),
             event_type => <<"run.completed">>,
             payload => #{}}),

    Expired = service_recovery_fixture(<<"expired-safe-reader">>),
    append_service_accepted(
      StorePid, Expired, #{deadline_at_ms => DeadlineAtMs}),
    append_run_started(StorePid, Expired),

    {ok, _Started} = application:ensure_all_started(soma_actor),
    {ok, LateTerminal} = soma_service:status(maps:get(task_id, Late)),
    {ok, ExpiredTerminal} = soma_service:status(maps:get(task_id, Expired)),

    ?assertEqual(
       #{status => failed, reason => deadline_exceeded},
       maps:with([status, reason], LateTerminal)),
    ?assertNot(maps:is_key(result, LateTerminal)),
    ?assertEqual(
       #{status => failed, reason => deadline_exceeded},
       maps:with([status, reason], ExpiredTerminal)),
    ?assertNot(lists:any(
                 fun(#{event_type := <<"run.resumed">>}) -> true;
                    (_Event) -> false
                 end,
                 soma_event_store:by_run(StorePid, maps:get(run_id, Expired)))).

test_recovery_lands_every_unowned_trail_terminal(_Config) ->
    StorePid = runtime_event_store(),

    AcceptedOnly = service_recovery_fixture(<<"accepted-only">>),
    append_service_accepted(StorePid, AcceptedOnly, #{}),

    AllCommitted = service_recovery_fixture(<<"all-committed">>),
    AllCommittedStep = maps:get(step, AllCommitted),
    AllCommittedOutput = #{value => <<"committed output">>},
    append_service_accepted(StorePid, AllCommitted, #{}),
    append_run_started(StorePid, AllCommitted),
    ok = soma_event_store:append(
           StorePid,
           #{run_id => maps:get(run_id, AllCommitted),
             step_id => maps:get(id, AllCommittedStep),
             event_type => <<"step.succeeded">>,
             payload => #{output => AllCommittedOutput}}),

    DeadlineCancelled = service_recovery_fixture(<<"deadline-cancelled">>),
    append_service_accepted(
      StorePid, DeadlineCancelled,
      #{deadline_at_ms => erlang:system_time(millisecond) - 1}),
    append_run_started(StorePid, DeadlineCancelled),
    append_service_event(
      StorePid, DeadlineCancelled,
      <<"service.task.deadline_expired">>, #{}),
    ok = soma_event_store:append(
           StorePid,
           #{run_id => maps:get(run_id, DeadlineCancelled),
             event_type => <<"run.cancelled">>,
             payload => #{}}),

    Unrecoverable = service_recovery_fixture(<<"unrecoverable">>),
    append_service_accepted(StorePid, Unrecoverable, #{}),
    append_run_started(StorePid, Unrecoverable),
    ok = soma_event_store:append(
           StorePid,
           #{run_id => maps:get(run_id, Unrecoverable),
             step_id => unknown_committed_step,
             event_type => <<"step.succeeded">>,
             payload => #{output => <<"not in journal">>}}),

    {ok, _Started} = application:ensure_all_started(soma_actor),

    {ok, AcceptedOnlyTerminal} =
        soma_service:status(maps:get(task_id, AcceptedOnly)),
    ?assertEqual(failed, maps:get(status, AcceptedOnlyTerminal)),
    ?assertEqual(
       service_interrupted_before_start,
       maps:get(reason, AcceptedOnlyTerminal)),

    {ok, AllCommittedTerminal} =
        soma_service:status(maps:get(task_id, AllCommitted)),
    ?assertEqual(succeeded, maps:get(status, AllCommittedTerminal)),
    ?assertEqual(
       #{maps:get(id, AllCommittedStep) => AllCommittedOutput},
       maps:get(result, AllCommittedTerminal)),

    {ok, DeadlineTerminal} =
        soma_service:status(maps:get(task_id, DeadlineCancelled)),
    ?assertEqual(failed, maps:get(status, DeadlineTerminal)),
    ?assertEqual(deadline_exceeded, maps:get(reason, DeadlineTerminal)),

    {ok, UnrecoverableTerminal} =
        soma_service:status(maps:get(task_id, Unrecoverable)),
    ?assertEqual(failed, maps:get(status, UnrecoverableTerminal)),
    ?assertEqual(
       service_recovery_failed,
       maps:get(reason, UnrecoverableTerminal)),

    lists:foreach(
      fun(Fixture) ->
              TaskId = maps:get(task_id, Fixture),
              [TerminalEvent] =
                  [Event || Event <- soma_event_store:all(StorePid),
                            maps:get(event_type, Event) =:=
                                <<"service.task.terminal">>,
                            maps:get(task_id, Event, undefined) =:= TaskId],
              ?assertNotEqual(running,
                              maps:get(status,
                                       maps:get(payload, TerminalEvent)))
      end,
      [AcceptedOnly, AllCommitted, DeadlineCancelled, Unrecoverable]).

test_recovery_preserves_owner_decisions_across_restarts(_Config) ->
    StorePid = runtime_event_store(),

    Deadline = service_recovery_fixture(<<"deadline-completed">>),
    DeadlineStep = maps:get(step, Deadline),
    DeadlineOutput = #{value => <<"completed after deadline decision">>},
    append_service_accepted(
      StorePid, Deadline,
      #{deadline_at_ms => erlang:system_time(millisecond) - 1}),
    append_run_started(StorePid, Deadline),
    append_service_event(
      StorePid, Deadline, <<"service.task.deadline_expired">>, #{}),
    ok = soma_event_store:append(
           StorePid,
           #{run_id => maps:get(run_id, Deadline),
             step_id => maps:get(id, DeadlineStep),
             event_type => <<"step.succeeded">>,
             payload => #{output => DeadlineOutput}}),
    ok = soma_event_store:append(
           StorePid,
           #{run_id => maps:get(run_id, Deadline),
             event_type => <<"run.completed">>,
             payload => #{}}),

    Committed = service_recovery_fixture(<<"committed-twice">>),
    CommittedStep = maps:get(step, Committed),
    CommittedOutput = #{value => <<"survives every restart">>},
    append_service_accepted(StorePid, Committed, #{}),
    append_run_started(StorePid, Committed),
    ok = soma_event_store:append(
           StorePid,
           #{run_id => maps:get(run_id, Committed),
             step_id => maps:get(id, CommittedStep),
             event_type => <<"step.succeeded">>,
             payload => #{output => CommittedOutput}}),

    {ok, _Started} = application:ensure_all_started(soma_actor),
    First = recovery_outcomes(Deadline, Committed),
    ok = application:stop(soma_actor),
    {ok, _Restarted} = application:ensure_all_started(soma_actor),
    Second = recovery_outcomes(Deadline, Committed),

    Expected =
        [#{status => failed, reason => deadline_exceeded},
         #{status => succeeded,
           result => #{maps:get(id, CommittedStep) => CommittedOutput}}],
    ?assertEqual({Expected, Expected}, {First, Second}).

recovery_outcomes(Deadline, Committed) ->
    {ok, DeadlineTask} =
        soma_service:status(maps:get(task_id, Deadline)),
    {ok, CommittedTask} =
        soma_service:status(maps:get(task_id, Committed)),
    [maps:with([status, result, reason], Task)
     || Task <- [DeadlineTask, CommittedTask]].

test_start_failures_land_terminal_task_data(_Config) ->
    {ok, StorePid} = soma_event_store:start_link(),
    Recovery = service_recovery_fixture(<<"resume-start-failure">>),
    append_service_accepted(StorePid, Recovery, #{}),
    append_run_started(StorePid, Recovery),
    SomaSup = start_fake_supervisor(
                soma_sup,
                fun(which_children) ->
                        [{soma_event_store, StorePid,
                          worker, [soma_event_store]}]
                end),
    RunSup = start_fake_supervisor(
               soma_run_sup,
               fun(which_children) ->
                       [];
                  ({start_child, _Args}) ->
                       {error, forced_run_start_failure}
               end),
    try
        {ok, ServicePid} = soma_service:start_link(),
        {ok, RecoveredTerminal} =
            soma_service:status(maps:get(task_id, Recovery)),
        NormalStartReply =
            soma_service:invoke(
              tool_envelope(
                <<"normal-start-failure">>, echo,
                #{value => <<"must not remain admitted">>})),

        ?assertEqual(failed, maps:get(status, RecoveredTerminal)),
        ?assertEqual(
           resume_start_failed, maps:get(reason, RecoveredTerminal)),
        ?assertMatch(
           {ok, #{status := failed, reason := run_start_failed}},
           NormalStartReply),
        {ok, NormalTerminal} =
            soma_service:status(
              maps:get(task_id, element(2, NormalStartReply))),
        ?assertEqual(element(2, NormalStartReply), NormalTerminal),
        gen_server:stop(ServicePid)
    after
        stop_registered_process(soma_service),
        stop_fake_supervisor(RunSup),
        stop_fake_supervisor(SomaSup),
        gen_server:stop(StorePid)
    end.

test_out_of_scope_invocation_rejected_through_policy(_Config) ->
    RequestId = <<"service-out-of-scope">>,
    Envelope =
        (tool_envelope(
           RequestId, echo,
           #{value => <<"must not run">>}))#{scope => [<<"sleep">>]},
    {ok, NormalizedEnvelope} =
        soma_service_envelope:normalize(Envelope),
    Step = maps:get(step, maps:get(operation, NormalizedEnvelope)),
    Proposal = #{kind => run_steps, steps => [Step]},
    StorePid = runtime_event_store(),
    RunStartCount = count_run_started(StorePid),
    ServicePid = whereis(soma_service),

    ok = start_policy_check_trace(ServicePid),
    try
        Reply = soma_service:invoke(Envelope),
        PolicyCalls = stop_policy_check_trace(ServicePid),
        ?assertEqual(
           [[Proposal, #{allowed_tools => [sleep]}]],
           PolicyCalls),

        {ok, #{task_id := TaskId,
               request_id := RequestId,
               status := rejected,
               reason := Rejection} = Terminal} = Reply,
        ?assertEqual(
           {policy_rejected, {tools_not_allowed, [echo]}},
           Rejection),
        ?assertEqual({ok, Terminal}, soma_service:status(TaskId)),

        [TerminalEvent] =
            [Event || Event <- soma_event_store:all(StorePid),
                      maps:get(event_type, Event) =:=
                          <<"service.task.terminal">>,
                      maps:get(task_id, Event) =:= TaskId],
        ?assertEqual(
           #{status => rejected, reason => Rejection},
           maps:get(payload, TerminalEvent)),
        ?assertEqual(RunStartCount, count_run_started(StorePid))
    after
        clear_policy_check_trace(ServicePid)
    end.

test_unscoped_invocation_uses_configured_or_empty_default_policy(_Config) ->
    Cases =
        [{configured, #{allowed_tools => [echo]}, succeeded, 1},
         {empty_default, application_default, rejected, 0}],
    lists:foreach(
      fun({Name, PolicySetting, ExpectedStatus, ExpectedRunStarts}) ->
              ok = restart_actor_with_service_policy(PolicySetting),
              StorePid = runtime_event_store(),
              RunStartsBefore = count_run_started(StorePid),
              RequestId = <<"service-unscoped-",
                            (atom_to_binary(Name, utf8))/binary>>,
              Envelope = tool_envelope(
                           RequestId, echo,
                           #{value => <<"unscoped policy">>}),

              {ok, InitialTask} = soma_service:invoke(Envelope),
              TaskId = maps:get(task_id, InitialTask),
              {ok, Terminal} =
                  case maps:get(status, InitialTask) of
                      accepted -> wait_for_terminal(TaskId, 100);
                      _Terminal -> {ok, InitialTask}
                  end,

              ?assertEqual(ExpectedStatus, maps:get(status, Terminal)),
              ?assertEqual(
                 ExpectedRunStarts,
                 count_run_started(StorePid) - RunStartsBefore)
      end,
      Cases).

test_unknown_scope_entry_does_not_create_atom(_Config) ->
    ok = code:ensure_modules_loaded(
           [soma_service, soma_service_envelope, soma_tool_registry,
            soma_policy, soma_event_store, crypto]),
    Unique = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    UnknownScopeEntry = <<"unknown-service-scope-", Unique/binary>>,
    Envelope =
        (tool_envelope(
           <<"service-unknown-scope">>, echo,
           #{value => <<"must not run">>}))#{scope => [UnknownScopeEntry]},
    AtomCountBefore = erlang:system_info(atom_count),

    {ok, #{status := rejected,
           reason := {policy_rejected,
                      {tools_not_allowed, [echo]}}}} =
        soma_service:invoke(Envelope),

    ?assertEqual(
       AtomCountBefore,
       erlang:system_info(atom_count)).

test_deadline_exceeded_cleans_run_worker_and_cli_process(Config) ->
    ServicePid = whereis(soma_service),
    {Helper, PidFile} = write_deadline_cli_stub(?config(tmp_dir, Config)),
    ok = soma_tool_registry:register_tool(
           #{name => service_deadline_cli,
             effect => reader,
             idempotent => true,
             timeout_ms => 60000,
             adapter => cli,
             executable => Helper,
             argv => [PidFile]}),
    Step = #{id => deadline_step,
             tool => service_deadline_cli,
             args => #{value => <<"ignored">>},
             timeout_ms => 60000},
    Envelope = #{kind => invoke,
                 api_version => <<"1">>,
                 request_id => <<"service-deadline-cli">>,
                 operation => #{kind => steps, steps => [Step]},
                 deadline_ms => 1000},

    {ok, #{task_id := TaskId, status := accepted}} =
        soma_service:invoke(Envelope),
    RunPid = wait_for_monitored_run(ServicePid, 100),
    StorePid = runtime_event_store(),
    RunId = wait_for_run_started(StorePid, [Step], 100),
    ok = wait_for_run_event(StorePid, RunId, <<"tool.started">>, 100),
    WorkerPid = tool_call_pid_from(StorePid, RunId),
    OsPid = wait_for_os_pid(PidFile, 100),
    try
        ?assert(is_process_alive(RunPid)),
        ?assert(is_process_alive(WorkerPid)),
        ?assert(os_process_alive(OsPid)),

        {ok, Terminal} = wait_for_status(TaskId, failed, 300),
        ?assertEqual(deadline_exceeded, maps:get(reason, Terminal)),
        ?assertEqual(ServicePid, whereis(soma_service)),
        ?assert(is_process_alive(ServicePid)),
        ok = wait_for_process_dead(RunPid, 100),
        ok = wait_for_process_dead(WorkerPid, 100),
        ok = wait_for_os_process_dead(OsPid, 100),
        ?assertNot(is_process_alive(RunPid)),
        ?assertNot(is_process_alive(WorkerPid)),
        ?assertNot(os_process_alive(OsPid))
    after
        maybe_cancel_run(RunPid)
    end.

test_service_cancel_cleans_tool_worker_and_cli_process(Config) ->
    ServicePid = whereis(soma_service),
    {Helper, PidFile} = write_deadline_cli_stub(?config(tmp_dir, Config)),
    ok = soma_tool_registry:register_tool(
           #{name => service_cancel_cli,
             effect => reader,
             idempotent => true,
             timeout_ms => 60000,
             adapter => cli,
             executable => Helper,
             argv => [PidFile]}),
    Step = #{id => cancel_step,
             tool => service_cancel_cli,
             args => #{value => <<"ignored">>},
             timeout_ms => 60000},
    Envelope = #{kind => invoke,
                 api_version => <<"1">>,
                 request_id => <<"service-cancel-cli">>,
                 operation => #{kind => steps, steps => [Step]}},

    {ok, #{task_id := TaskId, status := accepted}} =
        soma_service:invoke(Envelope),
    RunPid = wait_for_monitored_run(ServicePid, 100),
    StorePid = runtime_event_store(),
    RunId = wait_for_run_started(StorePid, [Step], 100),
    ok = wait_for_run_event(StorePid, RunId, <<"tool.started">>, 100),
    WorkerPid = tool_call_pid_from(StorePid, RunId),
    OsPid = wait_for_os_pid(PidFile, 100),
    try
        ?assert(is_process_alive(WorkerPid)),
        ?assert(os_process_alive(OsPid)),

        ok = soma_service:cancel(TaskId),
        ok = wait_for_process_dead(WorkerPid, 100),
        ok = wait_for_os_process_dead(OsPid, 100),
        ?assertNot(is_process_alive(WorkerPid)),
        ?assertNot(os_process_alive(OsPid)),
        ?assertEqual(ServicePid, whereis(soma_service)),
        ?assert(is_process_alive(ServicePid)),

        {ok, Terminal} = wait_for_status(TaskId, cancelled, 100),
        ?assertEqual(cancelled, maps:get(status, Terminal))
    after
        maybe_cancel_run(RunPid)
    end.

test_tool_crash_is_bounded_and_service_runs_again(_Config) ->
    ServicePid = whereis(soma_service),
    CrashEnvelope = tool_envelope(
                      <<"service-crashing-tool">>, fail,
                      #{mode => crash, reason => service_tool_boom}),
    {ok, #{task_id := CrashTaskId, status := accepted}} =
        soma_service:invoke(CrashEnvelope),
    {ok, Failed} = wait_for_status(CrashTaskId, failed, 100),

    EchoRequestId = <<"service-after-tool-crash">>,
    EchoArgs = #{value => <<"service still usable">>},
    {ok, #{task_id := EchoTaskId, status := accepted}} =
        soma_service:invoke(
          tool_envelope(EchoRequestId, echo, EchoArgs)),
    {ok, Succeeded} = wait_for_status(EchoTaskId, succeeded, 100),

    ?assertEqual(ServicePid, whereis(soma_service)),
    ?assert(is_process_alive(ServicePid)),
    ?assertEqual(#{EchoRequestId => EchoArgs}, maps:get(result, Succeeded)),
    ?assertEqual(run_failed, maps:get(reason, Failed)),
    EncodedFailed = term_to_binary(Failed, [deterministic]),
    ?assert(byte_size(EncodedFailed) =< 512),
    ?assertEqual(nomatch, binary:match(EncodedFailed, <<"soma_tool_fail">>)).

test_lifecycle_reads_are_monotonic(_Config) ->
    Envelope = tool_envelope(
                 <<"service-lifecycle-monotonic">>, sleep,
                 #{ms => 300}),
    {ok, #{task_id := TaskId, status := accepted} = Accepted} =
        soma_service:invoke(Envelope),
    {ok, #{status := running} = Running} =
        soma_service:status(TaskId),
    {ok, Terminal} = wait_for_status(TaskId, succeeded, 100),
    {ok, RepeatedTerminal} = soma_service:status(TaskId),

    ?assertEqual(
       [accepted, running, succeeded, succeeded],
       [maps:get(status, Task)
        || Task <- [Accepted, Running, Terminal, RepeatedTerminal]]),
    ?assertEqual(Terminal, RepeatedTerminal).

test_unsafe_interrupted_state_invocation_recovers_in_doubt(Config) ->
    StepId = unsafe_state_step,
    Step = #{id => StepId,
             tool => service_hanging_state,
             args => #{value => <<"must not be repeated">>}},
    Envelope = #{kind => invoke,
                 api_version => <<"1">>,
                 request_id => <<"service-unsafe-state-interruption">>,
                 operation => #{kind => steps, steps => [Step]}},

    ServicePid = whereis(soma_service),
    {ok, #{task_id := TaskId, status := accepted}} =
        soma_service:invoke(Envelope),
    StorePid = runtime_event_store(),
    RunId = wait_for_run_started(StorePid, [Step], 100),
    ok = wait_for_run_event(StorePid, RunId, <<"tool.started">>, 100),
    RunPid = wait_for_monitored_run(ServicePid, 100),
    WorkerPid = tool_call_pid_from(StorePid, RunId),
    ?assert(is_process_alive(RunPid)),
    ?assert(is_process_alive(WorkerPid)),

    ok = application:stop(soma_actor),
    ok = application:stop(soma_runtime),
    ok = wait_for_process_dead(RunPid, 100),
    exit(WorkerPid, kill),
    ok = wait_for_process_dead(WorkerPid, 100),

    ok = application:set_env(
           soma_runtime, event_store_log, ?config(log_path, Config)),
    {ok, _RuntimeStarted} = application:ensure_all_started(soma_runtime),
    ok = soma_tool_registry:register_tool(
           soma_service_hanging_state_tool:manifest()),
    {ok, _ActorStarted} = application:ensure_all_started(soma_actor),

    ReplayedStorePid = runtime_event_store(),
    {ok, Recovered} = soma_service:status(TaskId),
    ?assertEqual(in_doubt, maps:get(status, Recovered)),
    ?assertEqual({resume_unsafe, StepId}, maps:get(reason, Recovered)),
    ?assertEqual(
       [],
       [Pid || {_Id, Pid, worker, [soma_run]} <-
                   supervisor:which_children(soma_run_sup),
               is_pid(Pid)]),

    RunEvents = soma_event_store:by_run(ReplayedStorePid, RunId),
    RunEventTypes = [maps:get(event_type, Event) || Event <- RunEvents],
    ?assertEqual(1, length([started || <<"run.started">> <- RunEventTypes])),
    ?assertNot(lists:member(<<"run.resumed">>, RunEventTypes)),
    ?assertNot(lists:member(<<"run.failed">>, RunEventTypes)),
    [TerminalEvent] =
        [Event || Event <- RunEvents,
                  maps:get(event_type, Event) =:=
                      <<"service.task.terminal">>,
                  maps:get(task_id, Event) =:= TaskId],
    ?assertEqual(
       #{status => in_doubt, reason => {resume_unsafe, StepId}},
       maps:get(payload, TerminalEvent)).

test_interrupted_reader_invocation_resumes_after_restart(Config) ->
    StepId = interrupted_reader_step,
    Step = #{id => StepId,
             tool => sleep,
             args => #{ms => 500},
             timeout_ms => 5000},
    Envelope = #{kind => invoke,
                 api_version => <<"1">>,
                 request_id => <<"service-reader-interruption">>,
                 operation => #{kind => steps, steps => [Step]}},

    ServicePid = whereis(soma_service),
    {ok, #{task_id := TaskId, status := accepted}} =
        soma_service:invoke(Envelope),
    StorePid = runtime_event_store(),
    RunId = wait_for_run_started(StorePid, [Step], 100),
    ok = wait_for_run_event(StorePid, RunId, <<"tool.started">>, 100),
    RunPid = wait_for_monitored_run(ServicePid, 100),
    WorkerPid = tool_call_pid_from(StorePid, RunId),
    ?assert(is_process_alive(RunPid)),
    ?assert(is_process_alive(WorkerPid)),

    ok = application:stop(soma_actor),
    ok = application:stop(soma_runtime),
    ok = wait_for_process_dead(RunPid, 100),
    exit(WorkerPid, kill),
    ok = wait_for_process_dead(WorkerPid, 100),

    ok = application:set_env(
           soma_runtime, event_store_log, ?config(log_path, Config)),
    {ok, _RuntimeStarted} = application:ensure_all_started(soma_runtime),
    {ok, _ActorStarted} = application:ensure_all_started(soma_actor),

    ReplayedStorePid = runtime_event_store(),
    {ok, Recovered} = wait_for_status(TaskId, succeeded, 200),
    ?assertEqual(#{StepId => #{ms => 500}}, maps:get(result, Recovered)),

    RunEvents = soma_event_store:by_run(ReplayedStorePid, RunId),
    RunEventTypes = [maps:get(event_type, Event) || Event <- RunEvents],
    ?assertEqual(1, length([started || <<"run.started">> <- RunEventTypes])),
    ?assertEqual(1, length([resumed || <<"run.resumed">> <- RunEventTypes])),
    ?assertNot(lists:member(<<"run.failed">>, RunEventTypes)).

%% Review finding 1 (#244): service recovery must never run before the
%% actor-owned descriptors exist. A durable crash-window trail (accepted +
%% run.started, no tool.started) whose pending step is ask_actor has to
%% resolve the descriptor on boot instead of failing {unregistered_tool, _}.
test_boot_recovery_registers_actor_tools_first(Config) ->
    StorePid = runtime_event_store(),

    %% Seed one completed invocation to clone production event shapes from.
    TemplateStep = #{id => template_sleep,
                     tool => sleep,
                     args => #{ms => 1},
                     timeout_ms => 5000},
    TemplateEnvelope = #{kind => invoke,
                         api_version => <<"1">>,
                         request_id => <<"svc-boot-order-template">>,
                         operation => #{kind => steps,
                                        steps => [TemplateStep]}},
    {ok, #{task_id := TemplateTaskId}} =
        soma_service:invoke(TemplateEnvelope),
    {ok, _} = wait_for_status(TemplateTaskId, succeeded, 200),

    Events = soma_event_store:all(StorePid),
    [AcceptedTemplate | _] =
        [Event || #{event_type := <<"service.task.accepted">>,
                    task_id := EventTaskId} = Event <- Events,
                  EventTaskId =:= TemplateTaskId],
    TemplateRunId = maps:get(run_id, AcceptedTemplate),
    [RunStartedTemplate | _] =
        [Event || #{event_type := <<"run.started">>,
                    run_id := EventRunId} = Event <- Events,
                  EventRunId =:= TemplateRunId],

    %% Synthesize the crash-window trail with an ask_actor pending step.
    TaskId = <<"svc-boot-order-task">>,
    RequestId = <<"svc-boot-order-request">>,
    RunId = <<"svc-boot-order-run">>,
    AskStep = #{id => boot_order_ask,
                tool => ask_actor,
                args => #{target => <<"svc-boot-order-nobody">>,
                          message => <<"hello">>},
                timeout_ms => 5000},
    AcceptedSynthetic =
        maps:without(
          [event_id, timestamp],
          AcceptedTemplate#{task_id => TaskId,
                            request_id => RequestId,
                            run_id => RunId}),
    TemplatePayload = maps:get(payload, RunStartedTemplate),
    TemplateOptions = maps:get(run_options, TemplatePayload),
    SyntheticOptions = TemplateOptions#{run_id => RunId,
                                        request_id => RequestId},
    RunStartedSynthetic =
        maps:without(
          [event_id, timestamp],
          RunStartedTemplate#{run_id => RunId,
                              payload =>
                                  TemplatePayload#{
                                    steps => [AskStep],
                                    run_options => SyntheticOptions}}),
    ok = soma_event_store:append(StorePid, AcceptedSynthetic),
    ok = soma_event_store:append(StorePid, RunStartedSynthetic),

    ok = application:stop(soma_actor),
    ok = application:stop(soma_runtime),

    ok = application:set_env(
           soma_runtime, event_store_log, ?config(log_path, Config)),
    {ok, _RuntimeStarted} = application:ensure_all_started(soma_runtime),
    {ok, _ActorStarted} = application:ensure_all_started(soma_actor),

    %% The recovered run fails (the ask target does not exist), but it must
    %% fail through a resolved, started tool call — never unregistered_tool.
    {ok, Recovered} = wait_for_status(TaskId, failed, 200),
    ReplayedStorePid = runtime_event_store(),
    RunEvents = soma_event_store:by_run(ReplayedStorePid, RunId),
    RunEventTypes = [maps:get(event_type, Event) || Event <- RunEvents],
    ?assert(lists:member(<<"tool.started">>, RunEventTypes)),
    Encoded = term_to_binary({Recovered, RunEvents}),
    ?assertEqual(nomatch, binary:match(Encoded, <<"unregistered_tool">>)),
    ok.

%% Review finding 2 (#244): rejection data must not grow with the plan. A
%% large all-disallowed plan keeps both the public reply and the durable
%% terminal event bounded.
test_rejection_reason_stays_bounded_for_large_plans(_Config) ->
    StorePid = runtime_event_store(),
    Steps =
        [#{id => list_to_atom("reject_step_" ++ integer_to_list(N)),
           tool => file_write,
           args => #{}}
         || N <- lists:seq(1, 300)],
    Envelope = #{kind => invoke,
                 api_version => <<"1">>,
                 request_id => <<"svc-bounded-rejection">>,
                 operation => #{kind => steps, steps => Steps}},
    {ok, Public} = soma_service:invoke(Envelope),
    ?assertEqual(rejected, maps:get(status, Public)),
    {policy_rejected, {tools_not_allowed, Disallowed}} =
        maps:get(reason, Public),
    ?assertEqual([file_write], Disallowed),
    ?assert(byte_size(term_to_binary(Public)) < 1024),
    Events = soma_event_store:all(StorePid),
    [TerminalEvent | _] =
        [Event || #{event_type := <<"service.task.terminal">>,
                    request_id := EventRequestId} = Event <- Events,
                  EventRequestId =:= <<"svc-bounded-rejection">>],
    ?assert(byte_size(term_to_binary(TerminalEvent)) < 1024),
    ok.

run_fresh_service_vm(Spec) ->
    EncodedSpec = base64:encode(term_to_binary(Spec, [deterministic])),
    Eval = lists:flatten(
             io_lib:format(
               "Spec = binary_to_term(base64:decode(~p), [safe]), "
               "LogPath = maps:get(log_path, Spec), "
               "ok = application:load(soma_actor), "
               "ok = application:set_env(soma_runtime, event_store_log, LogPath), "
               "ok = application:set_env(soma_actor, service_policy, "
               "#{allowed_tools => [echo]}), "
               "{ok, _} = application:ensure_all_started(soma_actor), "
               "Envelope = fun(RequestId, Value) -> "
               "#{kind => invoke, api_version => <<\"1\">>, "
               "request_id => RequestId, operation => "
               "#{kind => tool, step => "
               "#{id => RequestId, tool => echo, "
               "args => #{value => Value}}}} end, "
               "RequestId = maps:get(request_id, Spec), "
               "Value = maps:get(value, Spec), "
               "{ok, #{task_id := TaskId}} = "
               "soma_service:invoke(Envelope(RequestId, Value)), "
               "Wait = fun F(0) -> erlang:error(service_task_timeout); "
               "F(N) -> case soma_service:status(TaskId) of "
               "{ok, #{status := succeeded} = Task} -> Task; "
               "_ -> timer:sleep(10), F(N - 1) end end, "
               "Terminal = Wait(200), "
               "Duplicate = case maps:get(duplicate, Spec, undefined) of "
               "undefined -> undefined; "
               "#{request_id := DuplicateRequestId, value := DuplicateValue} -> "
               "{ok, DuplicateTask} = soma_service:invoke("
               "Envelope(DuplicateRequestId, DuplicateValue)), "
               "DuplicateTask end, "
               "Children = supervisor:which_children(soma_sup), "
               "{soma_event_store, StorePid, _, _} = "
               "lists:keyfind(soma_event_store, 1, Children), "
               "[Accepted] = [Event || Event <- soma_event_store:all(StorePid), "
               "maps:get(event_type, Event) =:= <<\"service.task.accepted\">>, "
               "maps:get(request_id, Event, undefined) =:= RequestId], "
               "Result = #{task_id => TaskId, "
               "run_id => maps:get(run_id, Accepted), "
               "terminal => Terminal, duplicate => Duplicate}, "
               "_ = application:stop(soma_actor), "
               "_ = application:stop(soma_runtime), "
               "io:format(\"SOMA_TEST_RESULT:~~s~~n\", "
               "[base64:encode(term_to_binary(Result, [deterministic]))]), "
               "halt(0).",
               [EncodedSpec])),
    Erl = os:find_executable("erl"),
    Paths = [filename:absname(Path) || Path <- code:get_path()],
    PathArgs = lists:append([["-pa", Path] || Path <- Paths]),
    Port = open_port(
             {spawn_executable, Erl},
             [binary, use_stdio, stderr_to_stdout, exit_status,
              {args, ["+S", "2:2", "+A", "1", "-noshell"] ++
                         PathArgs ++ ["-eval", Eval]}]),
    {0, Output} = collect_port_output(Port, []),
    case re:run(
           Output,
           <<"SOMA_TEST_RESULT:([^\\r\\n]+)">>,
           [{capture, [1], binary}]) of
        {match, [EncodedResult]} ->
            binary_to_term(base64:decode(EncodedResult), [safe]);
        nomatch ->
            error({fresh_service_vm_missing_result, Output})
    end.

collect_port_output(Port, Acc) ->
    receive
        {Port, {data, Bytes}} ->
            collect_port_output(Port, [Bytes | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    after 15000 ->
        erlang:port_close(Port),
        error(fresh_service_vm_timeout)
    end.

service_recovery_fixture(Suffix) ->
    TaskId = <<"service-recovery-task-", Suffix/binary>>,
    RequestId = <<"service-recovery-request-", Suffix/binary>>,
    RunId = <<"service-recovery-run-", Suffix/binary>>,
    Step = #{id => Suffix,
             tool => echo,
             args => #{value => Suffix}},
    #{task_id => TaskId,
      request_id => RequestId,
      run_id => RunId,
      envelope_hash => crypto:hash(sha256, Suffix),
      step => Step}.

append_service_accepted(StorePid, Fixture, ExtraPayload) ->
    append_service_event(
      StorePid, Fixture, <<"service.task.accepted">>,
      maps:merge(
        #{envelope_hash => maps:get(envelope_hash, Fixture)},
        ExtraPayload)).

append_service_event(StorePid, Fixture, Type, Payload) ->
    soma_event_store:append(
      StorePid,
      maps:merge(
        maps:with([task_id, request_id, run_id], Fixture),
        #{event_type => Type, payload => Payload})).

append_run_started(StorePid, Fixture) ->
    RunId = maps:get(run_id, Fixture),
    RunOptions =
        maps:merge(
          maps:with(
            [task_id, request_id, envelope_hash], Fixture),
          #{run_id => RunId, auto_resume => false}),
    soma_event_store:append(
      StorePid,
      #{run_id => RunId,
        event_type => <<"run.started">>,
        payload => #{steps => [maps:get(step, Fixture)],
                     run_options => RunOptions}}).

start_fake_supervisor(Name, Handler) ->
    Parent = self(),
    Pid = spawn_link(
            fun() ->
                    true = register(Name, self()),
                    Parent ! {fake_supervisor_started, self()},
                    fake_supervisor_loop(Handler)
            end),
    receive
        {fake_supervisor_started, Pid} -> Pid
    after 1000 ->
        error({fake_supervisor_start_timeout, Name})
    end.

fake_supervisor_loop(Handler) ->
    receive
        {'$gen_call', From, Request} ->
            gen:reply(From, Handler(Request)),
            fake_supervisor_loop(Handler);
        stop ->
            ok
    end.

stop_fake_supervisor(Pid) ->
    unlink(Pid),
    Pid ! stop,
    ok.

stop_registered_process(Name) ->
    case whereis(Name) of
        undefined ->
            ok;
        Pid ->
            unlink(Pid),
            gen_server:stop(Pid)
    end.

ensure_loaded(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.

start_llm_start_trace() ->
    1 = erlang:trace_pattern({soma_llm_call, start, 1}, true, [local]),
    _ = erlang:trace(all, true, [call, {tracer, self()}]),
    _ = erlang:trace(new, true, [call, {tracer, self()}]),
    ok.

stop_llm_start_trace() ->
    _ = erlang:trace(all, false, [call]),
    _ = erlang:trace(new, false, [call]),
    Ref = erlang:trace_delivered(all),
    collect_llm_start_calls(Ref, []).

collect_llm_start_calls(Ref, Calls) ->
    receive
        {trace_delivered, all, Ref} ->
            lists:reverse(Calls);
        {trace, _Pid, call, {soma_llm_call, start, Args}} ->
            collect_llm_start_calls(Ref, [Args | Calls])
    after 1000 ->
        error(llm_start_trace_not_delivered)
    end.

clear_llm_start_trace() ->
    _ = erlang:trace(all, false, [call]),
    _ = erlang:trace(new, false, [call]),
    _ = erlang:trace_pattern({soma_llm_call, start, 1}, false, [local]),
    ok.

start_policy_check_trace(ServicePid) ->
    {module, soma_policy} = code:ensure_loaded(soma_policy),
    1 = erlang:trace_pattern({soma_policy, check, 2}, true, [local]),
    1 = erlang:trace(ServicePid, true, [call, {tracer, self()}]),
    ok.

stop_policy_check_trace(ServicePid) ->
    _ = erlang:trace(ServicePid, false, [call]),
    Ref = erlang:trace_delivered(ServicePid),
    collect_policy_check_calls(ServicePid, Ref, []).

collect_policy_check_calls(ServicePid, Ref, Calls) ->
    receive
        {trace_delivered, ServicePid, Ref} ->
            lists:reverse(Calls);
        {trace, ServicePid, call, {soma_policy, check, Args}} ->
            collect_policy_check_calls(ServicePid, Ref, [Args | Calls])
    after 1000 ->
        error(policy_check_trace_not_delivered)
    end.

clear_policy_check_trace(ServicePid) ->
    _ = erlang:trace(ServicePid, false, [call]),
    _ = erlang:trace_pattern({soma_policy, check, 2}, false, [local]),
    ok.

runtime_event_store() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, StorePid, _Type, _Modules} =
        lists:keyfind(soma_event_store, 1, Children),
    StorePid.

restart_actor_with_service_policy(PolicySetting) ->
    ok = application:stop(soma_actor),
    ok = application:unload(soma_actor),
    ok = ensure_loaded(soma_actor),
    case PolicySetting of
        application_default -> ok;
        Policy -> application:set_env(soma_actor, service_policy, Policy)
    end,
    {ok, _Started} = application:ensure_all_started(soma_actor),
    ok.

tool_envelope(RequestId, Tool, Args) ->
    #{kind => invoke,
      api_version => <<"1">>,
      request_id => RequestId,
      operation =>
          #{kind => tool,
            step => #{id => RequestId, tool => Tool, args => Args}}}.

write_deadline_cli_stub(TmpDir) ->
    Helper = filename:join(TmpDir, "deadline-cli.sh"),
    PidFile = filename:join(TmpDir, "deadline-cli.pid"),
    Script = <<"#!/bin/sh\n"
               "printf '%s\\n' \"$$\" > \"$1\"\n"
               "sleep 30\n">>,
    ok = file:write_file(Helper, Script),
    ok = file:change_mode(Helper, 8#755),
    {Helper, PidFile}.

tool_call_pid_from(StorePid, RunId) ->
    [WorkerPid] =
        [maps:get(tool_call_pid, Event)
         || Event <- soma_event_store:by_run(StorePid, RunId),
            maps:get(event_type, Event) =:= <<"tool.started">>],
    WorkerPid.

wait_for_os_pid(_PidFile, 0) ->
    error(cli_stub_did_not_write_os_pid);
wait_for_os_pid(PidFile, Attempts) ->
    case file:read_file(PidFile) of
        {ok, Bytes} ->
            list_to_integer(string:trim(binary_to_list(Bytes)));
        {error, enoent} ->
            timer:sleep(10),
            wait_for_os_pid(PidFile, Attempts - 1)
    end.

wait_for_process_dead(_Pid, 0) ->
    {error, process_still_alive};
wait_for_process_dead(Pid, Attempts) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(10),
            wait_for_process_dead(Pid, Attempts - 1)
    end.

wait_for_os_process_dead(_OsPid, 0) ->
    {error, os_process_still_alive};
wait_for_os_process_dead(OsPid, Attempts) ->
    case os_process_alive(OsPid) of
        false ->
            ok;
        true ->
            timer:sleep(10),
            wait_for_os_process_dead(OsPid, Attempts - 1)
    end.

os_process_alive(OsPid) ->
    Kill = os:find_executable("kill"),
    Port = open_port(
             {spawn_executable, Kill},
             [{args, ["-0", integer_to_list(OsPid)]},
              exit_status, binary, use_stdio, stderr_to_stdout]),
    os_process_probe_result(Port).

os_process_probe_result(Port) ->
    receive
        {Port, {data, _Bytes}} ->
            os_process_probe_result(Port);
        {Port, {exit_status, 0}} ->
            true;
        {Port, {exit_status, _NonZero}} ->
            false
    after 1000 ->
        erlang:port_close(Port),
        error(os_process_probe_timeout)
    end.

maybe_cancel_run(RunPid) ->
    case is_process_alive(RunPid) of
        true ->
            RunPid ! cancel,
            _ = wait_for_process_dead(RunPid, 100),
            ok;
        false ->
            ok
    end.

wait_for_run_started(_StorePid, _Steps, 0) ->
    error(service_run_did_not_start);
wait_for_run_started(StorePid, Steps, Attempts) ->
    case [maps:get(run_id, Event)
          || Event <- soma_event_store:all(StorePid),
             maps:get(event_type, Event) =:= <<"run.started">>,
             maps:get(steps, maps:get(payload, Event)) =:= Steps] of
        [RunId] ->
            RunId;
        [] ->
            timer:sleep(10),
            wait_for_run_started(StorePid, Steps, Attempts - 1)
    end.

wait_for_run_event(_StorePid, _RunId, _Type, 0) ->
    {error, timeout};
wait_for_run_event(StorePid, RunId, Type, Attempts) ->
    case lists:any(
           fun(Event) -> maps:get(event_type, Event) =:= Type end,
           soma_event_store:by_run(StorePid, RunId)) of
        true ->
            ok;
        false ->
            timer:sleep(10),
            wait_for_run_event(StorePid, RunId, Type, Attempts - 1)
    end.

count_run_started(StorePid) ->
    length(
      [Event || Event <- soma_event_store:all(StorePid),
                maps:get(event_type, Event) =:= <<"run.started">>]).

wait_for_monitored_run(_ServicePid, 0) ->
    error(service_did_not_monitor_owned_run);
wait_for_monitored_run(ServicePid, Attempts) ->
    {monitors, Monitors} = process_info(ServicePid, monitors),
    MonitoredPids = [Pid || {process, Pid} <- Monitors],
    RunPids = [Pid || {_Id, Pid, worker, [soma_run]} <-
                         supervisor:which_children(soma_run_sup),
                       is_pid(Pid)],
    case [Pid || Pid <- RunPids, lists:member(Pid, MonitoredPids)] of
        [RunPid | _] ->
            RunPid;
        [] ->
            timer:sleep(10),
            wait_for_monitored_run(ServicePid, Attempts - 1)
    end.

wait_for_replacement(_OldPid, 0) ->
    error(service_was_not_restarted);
wait_for_replacement(OldPid, Attempts) ->
    case whereis(soma_service) of
        Pid when is_pid(Pid), Pid =/= OldPid ->
            Pid;
        _ ->
            timer:sleep(10),
            wait_for_replacement(OldPid, Attempts - 1)
    end.

wait_for_status(_TaskId, _Expected, 0) ->
    error(service_task_did_not_reach_status);
wait_for_status(TaskId, Expected, Attempts) ->
    case soma_service:status(TaskId) of
        {ok, #{status := Expected} = Task} ->
            {ok, Task};
        {ok, _Task} ->
            timer:sleep(10),
            wait_for_status(TaskId, Expected, Attempts - 1)
    end.

wait_for_terminal(_TaskId, 0) ->
    error(service_task_did_not_reach_terminal_status);
wait_for_terminal(TaskId, Attempts) ->
    case soma_service:status(TaskId) of
        {ok, #{status := Status} = Task}
          when Status =:= succeeded;
               Status =:= failed;
               Status =:= rejected;
               Status =:= cancelled;
               Status =:= in_doubt ->
            {ok, Task};
        {ok, _Task} ->
            timer:sleep(10),
            wait_for_terminal(TaskId, Attempts - 1)
    end.

make_tmp_dir() ->
    Unique = erlang:integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(["/tmp", "soma_service_" ++ Unique]),
    ok = file:make_dir(Dir),
    Dir.

maybe_del_tmp_dir(Config) ->
    case proplists:get_value(tmp_dir, Config, undefined) of
        undefined ->
            ok;
        Dir ->
            del_tmp_dir(Dir)
    end.

del_tmp_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            [ok = file:delete(filename:join(Dir, Name)) || Name <- Names],
            file:del_dir(Dir);
        {error, enoent} ->
            ok
    end.
