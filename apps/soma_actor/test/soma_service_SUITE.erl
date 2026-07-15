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
-export([test_out_of_scope_invocation_rejected_through_policy/1]).
-export([test_unscoped_invocation_uses_configured_or_empty_default_policy/1]).
-export([test_unknown_scope_entry_does_not_create_atom/1]).
-export([test_deadline_exceeded_cleans_run_worker_and_cli_process/1]).
-export([test_service_cancel_cleans_tool_worker_and_cli_process/1]).
-export([test_tool_crash_is_bounded_and_service_runs_again/1]).
-export([test_lifecycle_reads_are_monotonic/1]).
-export([test_unsafe_interrupted_state_invocation_recovers_in_doubt/1]).

all() ->
    [test_supervised_service_restarts_and_serves_again,
     test_single_tool_invocation_runs_without_llm_worker,
     test_oversized_result_fails_with_max_output_reason,
     test_flat_plan_preserves_order_and_from_step_output,
     test_identical_duplicate_reuses_running_handle_and_terminal_result,
     test_conflicting_request_id_rejected_before_new_run,
     test_run_started_journals_request_id_and_envelope_hash,
     test_durable_restart_rebuilds_dedupe_without_new_run_started,
     test_out_of_scope_invocation_rejected_through_policy,
     test_unscoped_invocation_uses_configured_or_empty_default_policy,
     test_unknown_scope_entry_does_not_create_atom,
     test_deadline_exceeded_cleans_run_worker_and_cli_process,
     test_service_cancel_cleans_tool_worker_and_cli_process,
     test_tool_crash_is_bounded_and_service_runs_again,
     test_lifecycle_reads_are_monotonic,
     test_unsafe_interrupted_state_invocation_recovers_in_doubt].

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
init_per_testcase(TestCase, Config)
  when TestCase =:= test_run_started_journals_request_id_and_envelope_hash;
       TestCase =:=
           test_durable_restart_rebuilds_dedupe_without_new_run_started ->
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
       TestCase =:=
           test_unsafe_interrupted_state_invocation_recovers_in_doubt;
       TestCase =:=
           test_run_started_journals_request_id_and_envelope_hash;
       TestCase =:=
           test_durable_restart_rebuilds_dedupe_without_new_run_started ->
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
    Envelope = tool_envelope(
                 RequestId, echo,
                 #{value => <<"durable request metadata">>}),
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
    RunOptions = maps:get(run_options, maps:get(payload, RunStarted)),
    ?assertEqual(
       #{request_id => RequestId, envelope_hash => EnvelopeHash},
       maps:with([request_id, envelope_hash], RunOptions)).

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
