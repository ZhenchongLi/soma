-module(soma_cli_resume_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_detached_run_journals_durable_cli_owner/1]).
-export([test_uncommitted_fresh_admission_fails_closed_after_registry_restart/1]).
-export([test_rejected_admission_outvotes_later_exact_acceptance/1]).
-export([test_committed_before_accepted_is_rejected/1]).
-export([test_acceptance_unknown_socket_returns_ids_and_retries_once/1]).
-export([test_activation_unknown_socket_returns_ids_without_effect/1]).
-export([test_restarted_detached_run_is_visible_cancellable_and_traceable/1]).
-export([test_unsafe_detached_resume_reports_failed_without_reexecution/1]).
-export([test_unmarked_foreground_run_is_not_adopted/1]).
-export([test_config_cli_tool_recovers_after_restart_and_cancel_kills_os_process/1]).
-export([test_listener_restart_adopts_live_detached_run_without_second_resume/1]).
-export([test_late_rejection_after_live_adoption_cancels_without_replay/1]).
-export([test_runtime_restart_recovers_with_registry_alive/1]).
-export([test_tool_registry_generation_reload_recovers_config_tool/1]).
-export([test_unresponsive_live_run_defers_without_duplicate/1]).
-export([test_suspended_run_supervisor_keeps_recovery_bounded/1]).
-export([test_start_in_doubt_resumes_once_after_supervisor_unblocks/1]).
-export([test_cancel_fences_start_in_doubt_before_first_tool/1]).
-export([test_cancelled_start_in_doubt_survives_registry_replacement/1]).
-export([test_store_unavailable_during_registry_scan_fails_closed/1]).
-export([test_mismatched_cancel_marker_is_not_owner_intent/1]).
-export([test_unrelated_unresponsive_run_does_not_block_adoption/1]).
-export([test_changed_manifest_cannot_weaken_in_flight_resume_safety/1]).
-export([test_malformed_marked_journal_fails_closed_without_daemon_crash/1]).
-export([test_stop_cancel_intent_survives_immediate_restart_without_replay/1]).
-export([test_stop_fails_closed_when_cancel_intent_store_unavailable/1]).
-export([test_stop_quiesce_rejects_concurrent_detached_admission/1]).
-export([test_timed_out_stop_cannot_close_admission_later/1]).
-export([test_timed_out_open_admission_cannot_rebind_dead_owner/1]).
-export([test_live_rebind_ignores_old_owner_down/1]).
-export([test_controlled_stop_retires_blocked_registry_workers/1]).
-export([test_timed_out_detached_start_has_no_late_effect/1]).
-export([test_timed_out_prepare_retires_claim_and_rejects_late_journal/1]).
-export([test_timed_out_supervisor_start_leaves_no_claim_or_effect/1]).
-export([test_rebound_tools_dir_is_used_after_tool_registry_restart/1]).
-export([test_nothing_to_do_projection_survives_registry_restart/1]).
-export([test_recorded_terminals_remain_monotonic_after_restart/1]).

all() ->
    [test_detached_run_journals_durable_cli_owner,
     test_uncommitted_fresh_admission_fails_closed_after_registry_restart,
     test_rejected_admission_outvotes_later_exact_acceptance,
     test_committed_before_accepted_is_rejected,
     test_acceptance_unknown_socket_returns_ids_and_retries_once,
     test_activation_unknown_socket_returns_ids_without_effect,
     test_restarted_detached_run_is_visible_cancellable_and_traceable,
     test_unsafe_detached_resume_reports_failed_without_reexecution,
     test_unmarked_foreground_run_is_not_adopted,
     test_config_cli_tool_recovers_after_restart_and_cancel_kills_os_process,
     test_listener_restart_adopts_live_detached_run_without_second_resume,
     test_late_rejection_after_live_adoption_cancels_without_replay,
     test_runtime_restart_recovers_with_registry_alive,
     test_tool_registry_generation_reload_recovers_config_tool,
     test_unresponsive_live_run_defers_without_duplicate,
     test_suspended_run_supervisor_keeps_recovery_bounded,
     test_start_in_doubt_resumes_once_after_supervisor_unblocks,
     test_cancel_fences_start_in_doubt_before_first_tool,
     test_cancelled_start_in_doubt_survives_registry_replacement,
     test_store_unavailable_during_registry_scan_fails_closed,
     test_mismatched_cancel_marker_is_not_owner_intent,
     test_unrelated_unresponsive_run_does_not_block_adoption,
     test_changed_manifest_cannot_weaken_in_flight_resume_safety,
     test_malformed_marked_journal_fails_closed_without_daemon_crash,
     test_stop_cancel_intent_survives_immediate_restart_without_replay,
     test_stop_fails_closed_when_cancel_intent_store_unavailable,
     test_stop_quiesce_rejects_concurrent_detached_admission,
     test_timed_out_stop_cannot_close_admission_later,
     test_timed_out_open_admission_cannot_rebind_dead_owner,
     test_live_rebind_ignores_old_owner_down,
     test_controlled_stop_retires_blocked_registry_workers,
     test_timed_out_detached_start_has_no_late_effect,
     test_timed_out_prepare_retires_claim_and_rejects_late_journal,
     test_timed_out_supervisor_start_leaves_no_claim_or_effect,
     test_rebound_tools_dir_is_used_after_tool_registry_restart,
     test_nothing_to_do_projection_survives_registry_restart,
     test_recorded_terminals_remain_monotonic_after_restart].

init_per_testcase(_Case, Config) ->
    stop_task_registry(),
    _ = application:stop(soma_actor),
    _ = application:stop(soma_runtime),
    application:unset_env(soma_runtime, event_store_log),
    TmpDir = make_tmp_dir(),
    LogPath = filename:join(TmpDir, "events.log"),
    SocketPath = filename:join(TmpDir, "soma.sock"),
    [{tmp_dir, TmpDir},
     {log_path, LogPath},
     {socket_path, SocketPath} | Config].

end_per_testcase(_Case, Config) ->
    stop_task_registry(),
    _ = application:stop(soma_actor),
    _ = application:stop(soma_runtime),
    application:unset_env(soma_runtime, event_store_log),
    ok = del_tmp_dir(?config(tmp_dir, Config)),
    ok.

%% Issue #256: a fresh detached start is a two-phase durable admission. The
%% runtime first records a marked run.started preparation; the CLI owner then
%% records exactly one cli.task.accepted commit before releasing the first tool
%% boundary. Both records carry the same restart-safe identity.
test_detached_run_journals_durable_cli_owner(Config) ->
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    try
        Request = <<"(run (detach) (step hold sleep (args (ms 5000))))">>,
        Reply = request(?config(socket_path, Config), Request),
        TaskId = accepted_id(<<"task-id">>, Reply),
        CorrelationId = accepted_id(<<"correlation-id">>, Reply),
        Store = event_store_pid(),
        Started = wait_for_started_by_session(Store, TaskId, 100),
        RunId = maps:get(run_id, Started),
        RunOptions = maps:get(run_options, maps:get(payload, Started)),

        %% VM-local unique_integer/1 restarts from a fresh sequence and can
        %% collide with ids already present in this durable log.  CLI ids use
        %% the same 128-bit random suffix contract as soma_service.
        ?assertEqual(match,
                     re:run(TaskId, "^task-[0-9A-F]{32}$",
                            [{capture, none}])),
        ?assertEqual(match,
                     re:run(CorrelationId, "^corr-[0-9A-F]{32}$",
                            [{capture, none}])),
        ?assertEqual(match,
                     re:run(RunId, "^run-[0-9A-F]{32}$",
                            [{capture, none}])),

        ?assertEqual(TaskId, maps:get(task_id, RunOptions)),
        ?assertEqual(TaskId, maps:get(session_id, RunOptions)),
        ?assertEqual(CorrelationId, maps:get(correlation_id, RunOptions)),
        ?assertEqual(cli_detached, maps:get(run_origin, RunOptions)),
        ?assertEqual(false, maps:get(auto_resume, RunOptions)),
        ?assertEqual(true, maps:get(admission_required, RunOptions)),
        AdmissionId = maps:get(admission_id, RunOptions),
        ?assert(is_binary(AdmissionId)),
        ?assert(byte_size(AdmissionId) > 0),

        ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
        Events = soma_event_store:by_run(Store, RunId),
        [Accepted] = [Event || Event <- Events,
                               maps:get(event_type, Event) =:=
                                   <<"cli.task.accepted">>],
        ?assertEqual(RunId, maps:get(run_id, Accepted)),
        ?assertEqual(TaskId, maps:get(task_id, Accepted)),
        ?assertEqual(TaskId, maps:get(session_id, Accepted)),
        ?assertEqual(CorrelationId, maps:get(correlation_id, Accepted)),
        ?assertEqual(cli_detached_v1,
                     maps:get(admission_protocol,
                              maps:get(payload, Accepted))),
        ?assertEqual(AdmissionId,
                     maps:get(admission_id, maps:get(payload, Accepted))),
        [Committed] =
            [Event || Event <- Events,
                      maps:get(event_type, Event) =:=
                          <<"run.admission.committed">>],
        ?assertEqual(AdmissionId,
                     maps:get(admission_id, maps:get(payload, Committed))),
        ?assertEqual(0, count(<<"cli.task.admission_rejected">>,
                              [maps:get(event_type, Event)
                               || Event <- Events])),
        ToolStarted = latest_event(Store, RunId, <<"tool.started">>),
        ?assertEqual(
           [<<"run.started">>, <<"cli.task.accepted">>,
            <<"run.admission.committed">>, <<"step.started">>,
            <<"tool.started">>],
           ordered_event_types(
             [<<"run.started">>, <<"cli.task.accepted">>,
              <<"run.admission.committed">>, <<"step.started">>,
              <<"tool.started">>], Events)),
        ?assertEqual(#{effect => reader, idempotent => true},
                     maps:get(resume_safety,
                              maps:get(payload, ToolStarted))),

        _ = request(?config(socket_path, Config),
                    <<"(cancel \"", TaskId/binary, "\")">>),
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 100)
    after
        stop_server(Server)
    end.

%% A prepared fresh journal is not an admitted task. Queue its acceptance
%% append behind a suspended store, then kill the paused run and owner before
%% that old-owner append lands. The replacement registry must treat the later
%% marker as stale authority: close the journal as cancelled without emitting
%% run.resumed or crossing a step/tool effect boundary.
test_uncommitted_fresh_admission_fails_closed_after_registry_restart(Config) ->
    ok = boot_runtime(Config),
    {ok, Server1} = start_server(Config),
    ok = wait_for_registry_ready(100),
    OldRegistry = whereis(soma_cli_task_registry),
    Store = event_store_pid(),
    TaskId = <<"task-uncommitted-fresh-admission">>,
    CorrelationId = <<"corr-uncommitted-fresh-admission">>,
    RunId = <<"run-uncommitted-fresh-admission">>,
    AdmissionId0 = crypto:strong_rand_bytes(16),
    Steps = [#{id => never, tool => echo,
               args => #{value => <<"must-not-run">>}}],
    {ok, RunPid} = soma_run_sup:start_run(
                     #{run_id => RunId,
                       task_id => TaskId,
                       session_id => TaskId,
                       session_pid => OldRegistry,
                       event_store => Store,
                       steps => Steps,
                       correlation_id => CorrelationId,
                       run_origin => cli_detached,
                       auto_resume => false,
                       admission_required => true,
                       admission_id => AdmissionId0,
                       start_paused => true}),
    ok = soma_run:prepare_start_sync(RunPid, infinity, 1000),
    ok = wait_for_event(Store, RunId, <<"run.started">>, 100),
    ?assertEqual([<<"run.started">>], event_types(Store, RunId)),
    [Prepared] = soma_event_store:by_run(Store, RunId),
    PreparedOptions = maps:get(run_options, maps:get(payload, Prepared)),
    AdmissionId = maps:get(admission_id, PreparedOptions),
    ?assertEqual(AdmissionId0, AdmissionId),
    AcceptedEvent =
        #{event_type => <<"cli.task.accepted">>,
          run_id => RunId,
          session_id => TaskId,
          task_id => TaskId,
          correlation_id => CorrelationId,
          payload => #{admission_protocol => cli_detached_v1,
                       admission_id => AdmissionId}},
    ok = sys:suspend(Store),
    Parent = self(),
    {LateAppender, LateAppenderMRef} =
        spawn_monitor(
          fun() ->
                  Parent ! {late_accepted_append_started, self()},
                  Result = soma_event_store:append(Store, AcceptedEvent),
                  Parent ! {late_accepted_append_result, self(), Result}
          end),
    receive
        {late_accepted_append_started, LateAppender} -> ok
    after 1000 ->
        ct:fail(late_accepted_appender_did_not_start)
    end,
    ok = wait_for_queued_store_append(
           Store, RunId, <<"cli.task.accepted">>, 100),
    exit(RunPid, kill),
    ok = wait_for_process_dead(RunPid, 100),
    ok = wait_for_run_claim_absent(RunId, 100),
    crash_server(Server1),
    try
        {ok, Server2} = start_server(Config),
        try
            %% The replacement's authoritative all-events scan is queued after
            %% the old owner's append. This proves the marker really lands late
            %% and is visible to recovery, rather than merely being absent.
            ok = wait_for_queued_store_all(Store, 100),
            ok = sys:resume(Store),
            receive
                {late_accepted_append_result, LateAppender, ok} -> ok
            after 2000 ->
                ct:fail(late_accepted_append_did_not_finish)
            end,
            receive
                {'DOWN', LateAppenderMRef, process, LateAppender, normal} -> ok
            after 1000 ->
                ct:fail(late_accepted_appender_did_not_exit)
            end,
            ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 150),
            ok = wait_for_run_claim_absent(RunId, 100),
            OrderedEvents = soma_event_store:by_run(Store, RunId),
            Types = [maps:get(event_type, Event)
                     || Event <- OrderedEvents],
            ?assertEqual(1, count(<<"run.started">>, Types)),
            ?assertEqual(1, count(<<"cli.task.accepted">>, Types)),
            [Rejected] =
                [Event || Event <- soma_event_store:by_run(Store, RunId),
                          maps:get(event_type, Event) =:=
                              <<"cli.task.admission_rejected">>],
            ?assertEqual(RunId, maps:get(run_id, Rejected)),
            ?assertEqual(TaskId, maps:get(task_id, Rejected)),
            ?assertEqual(TaskId, maps:get(session_id, Rejected)),
            ?assertEqual(CorrelationId,
                         maps:get(correlation_id, Rejected)),
            ?assertEqual(AdmissionId,
                         maps:get(admission_id,
                                  maps:get(payload, Rejected))),
            LateAccepted = latest_event(
                             Store, RunId, <<"cli.task.accepted">>),
            ?assert(event_position(LateAccepted, OrderedEvents) <
                        event_position(Rejected, OrderedEvents)),
            ?assertEqual(0,
                         count(<<"run.admission.committed">>, Types)),
            ?assertEqual(0, count(<<"run.resumed">>, Types)),
            ?assertEqual(0, count(<<"step.started">>, Types)),
            ?assertEqual(0, count(<<"tool.started">>, Types)),
            ?assertEqual(1, count(<<"run.cancelled">>, Types)),
            ?assertEqual({error, not_found},
                         soma_run_sup:find_run(RunId, 500)),
            {ok, #{status := cancelled}} =
                wait_for_registry_status(TaskId, cancelled, 100),
            ok
        after
            stop_server(Server2)
        end
    after
        maybe_resume_process(Store),
        case is_process_alive(LateAppender) of
            true -> exit(LateAppender, kill);
            false -> ok
        end,
        cancel_live_run(RunId),
        case is_process_alive(Server1) of
            true -> stop_server(Server1);
            false -> ok
        end
    end.

%% The rejection tombstone is monotonic, not merely an observation-order
%% shortcut. First let replacement recovery see the prepared trail, durably
%% reject it, and cancel it. Only then release the old generation's exact
%% accepted marker. A further registry rebuild must still project cancellation
%% and must never create the missing run-side commit or any execution boundary.
test_rejected_admission_outvotes_later_exact_acceptance(Config) ->
    ok = boot_runtime(Config),
    {ok, Server1} = start_server(Config),
    ok = wait_for_registry_ready(100),
    OldRegistry = whereis(soma_cli_task_registry),
    Store = event_store_pid(),
    TaskId = <<"task-rejected-before-late-accept">>,
    CorrelationId = <<"corr-rejected-before-late-accept">>,
    RunId = <<"run-rejected-before-late-accept">>,
    AdmissionId0 = crypto:strong_rand_bytes(16),
    Steps = [#{id => never, tool => echo,
               args => #{value => <<"must-not-run">>}}],
    {ok, RunPid} = soma_run_sup:start_run(
                     #{run_id => RunId,
                       task_id => TaskId,
                       session_id => TaskId,
                       session_pid => OldRegistry,
                       event_store => Store,
                       steps => Steps,
                       correlation_id => CorrelationId,
                       run_origin => cli_detached,
                       auto_resume => false,
                       admission_required => true,
                       admission_id => AdmissionId0,
                       start_paused => true}),
    ok = soma_run:prepare_start_sync(RunPid, infinity, 1000),
    [Prepared] = soma_event_store:by_run(Store, RunId),
    PreparedOptions = maps:get(run_options, maps:get(payload, Prepared)),
    AdmissionId = maps:get(admission_id, PreparedOptions),
    ?assertEqual(AdmissionId0, AdmissionId),
    AcceptedEvent =
        #{event_type => <<"cli.task.accepted">>,
          run_id => RunId,
          session_id => TaskId,
          task_id => TaskId,
          correlation_id => CorrelationId,
          payload => #{admission_protocol => cli_detached_v1,
                       admission_id => AdmissionId}},
    CommittedEvent =
        #{event_type => <<"run.admission.committed">>,
          run_id => RunId,
          session_id => TaskId,
          task_id => TaskId,
          correlation_id => CorrelationId,
          payload => #{admission_protocol => cli_detached_v1,
                       admission_id => AdmissionId}},
    Parent = self(),
    {LateAppender, LateAppenderMRef} =
        spawn_monitor(
          fun() ->
                  Parent ! {late_accept_after_reject_armed, self()},
                  receive
                      {release_late_accept_after_reject, Parent} ->
                          Result =
                              {soma_event_store:append(Store, AcceptedEvent),
                               soma_event_store:append(Store,
                                                       CommittedEvent)},
                          Parent ! {late_accept_after_reject_result,
                                    self(), Result}
                  end
          end),
    receive
        {late_accept_after_reject_armed, LateAppender} -> ok
    after 1000 ->
        ct:fail(late_accept_after_reject_was_not_armed)
    end,
    exit(RunPid, kill),
    ok = wait_for_process_dead(RunPid, 100),
    ok = wait_for_run_claim_absent(RunId, 100),
    crash_server(Server1),
    try
        {ok, Server2} = start_server(Config),
        try
            ok = wait_for_event(
                   Store, RunId, <<"cli.task.admission_rejected">>, 150),
            ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 150),
            ?assertEqual(0,
                         count(<<"cli.task.accepted">>,
                               event_types(Store, RunId))),

            LateAppender ! {release_late_accept_after_reject, self()},
            receive
                {late_accept_after_reject_result, LateAppender, {ok, ok}} -> ok
            after 2000 ->
                ct:fail(late_accept_after_reject_did_not_finish)
            end,
            receive
                {'DOWN', LateAppenderMRef, process, LateAppender, normal} -> ok
            after 1000 ->
                ct:fail(late_accept_after_reject_did_not_exit)
            end,
            ok = wait_for_event(
                   Store, RunId, <<"cli.task.accepted">>, 100),
            ok = wait_for_event(
                   Store, RunId, <<"run.admission.committed">>, 100),
            [Rejected] =
                [Event || Event <- soma_event_store:by_run(Store, RunId),
                          maps:get(event_type, Event) =:=
                              <<"cli.task.admission_rejected">>],
            [Accepted] =
                [Event || Event <- soma_event_store:by_run(Store, RunId),
                          maps:get(event_type, Event) =:=
                              <<"cli.task.accepted">>],
            [Committed] =
                [Event || Event <- soma_event_store:by_run(Store, RunId),
                          maps:get(event_type, Event) =:=
                              <<"run.admission.committed">>],
            OrderedEvents = soma_event_store:by_run(Store, RunId),
            ?assert(event_position(Rejected, OrderedEvents) <
                        event_position(Accepted, OrderedEvents)),
            ?assert(event_position(Accepted, OrderedEvents) <
                        event_position(Committed, OrderedEvents)),
            ?assertEqual(AdmissionId,
                         maps:get(admission_id,
                                  maps:get(payload, Rejected))),

            %% Rebuild once more so the durable projection must actively read
            %% the rejection-before-acceptance ordering from the trail.
            crash_server(Server2),
            {ok, Server3} = start_server(Config),
            try
                ok = wait_for_registry_ready(100),
                Status = request(
                           ?config(socket_path, Config),
                           <<"(status \"", TaskId/binary, "\")">>),
                ?assertEqual(match,
                             re:run(Status, "\\(state cancelled\\)",
                                    [{capture, none}])),
                Types = event_types(Store, RunId),
                ?assertEqual(1, count(<<"run.started">>, Types)),
                ?assertEqual(1, count(<<"cli.task.accepted">>, Types)),
                ?assertEqual(
                   1, count(<<"cli.task.admission_rejected">>, Types)),
                ?assertEqual(
                   1, count(<<"run.admission.committed">>, Types)),
                ?assertEqual(0, count(<<"run.resumed">>, Types)),
                ?assertEqual(0, count(<<"step.started">>, Types)),
                ?assertEqual(0, count(<<"tool.started">>, Types)),
                ?assertEqual(1, count(<<"run.cancelled">>, Types)),
                ?assertEqual({error, not_found},
                             soma_run_sup:find_run(RunId, 500)),
                ?assertEqual({error, not_found},
                             soma_run_index:lookup(RunId, 500))
            after
                stop_server(Server3)
            end
        after
            case is_process_alive(Server2) of
                true -> stop_server(Server2);
                false -> ok
            end
        end
    after
        case is_process_alive(LateAppender) of
            true -> exit(LateAppender, kill);
            false -> ok
        end,
        cancel_live_run(RunId),
        case is_process_alive(Server1) of
            true -> stop_server(Server1);
            false -> ok
        end
    end.

%% Exact identities are insufficient when their causal order is impossible.
%% A run-side commit that precedes the edge acceptance did not arise from the
%% admission protocol. A later matching acceptance cannot retroactively fill
%% that gap: replacement recovery must reject and cancel the trail effect-free.
test_committed_before_accepted_is_rejected(Config) ->
    TaskId = <<"task-commit-before-accept">>,
    CorrelationId = <<"corr-commit-before-accept">>,
    RunId = <<"run-commit-before-accept">>,
    AdmissionId = crypto:strong_rand_bytes(16),
    Step = #{id => never, tool => echo,
             args => #{value => <<"must-not-run">>}},
    RunOptions = #{run_id => RunId,
                   task_id => TaskId,
                   session_id => TaskId,
                   correlation_id => CorrelationId,
                   run_origin => cli_detached,
                   auto_resume => false,
                   admission_required => true,
                   admission_id => AdmissionId},
    Committed = #{event_type => <<"run.admission.committed">>,
                  run_id => RunId,
                  session_id => TaskId,
                  task_id => TaskId,
                  correlation_id => CorrelationId,
                  payload => #{admission_protocol => cli_detached_v1,
                               admission_id => AdmissionId}},
    Accepted = #{event_type => <<"cli.task.accepted">>,
                 run_id => RunId,
                 session_id => TaskId,
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 payload => #{admission_protocol => cli_detached_v1,
                              admission_id => AdmissionId}},
    ok = seed_started_log(Config, TaskId, CorrelationId, RunId, [Step],
                          RunOptions, [Committed, Accepted]),
    ok = boot_runtime(Config),
    ?assertEqual({error, not_found}, soma_run_sup:find_run(RunId, 500)),
    {ok, Server} = start_server(Config),
    try
        Store = event_store_pid(),
        ok = wait_for_event(
               Store, RunId, <<"cli.task.admission_rejected">>, 150),
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 150),
        Events = soma_event_store:by_run(Store, RunId),
        Types = [maps:get(event_type, Event) || Event <- Events],
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"run.admission.committed">>, Types)),
        ?assertEqual(1, count(<<"cli.task.accepted">>, Types)),
        ?assertEqual(1, count(<<"cli.task.admission_rejected">>, Types)),
        ?assertEqual(1, count(<<"run.cancelled">>, Types)),
        ?assertEqual(0, count(<<"run.resumed">>, Types)),
        ?assertEqual(0, count(<<"step.started">>, Types)),
        ?assertEqual(0, count(<<"tool.started">>, Types)),
        CommitEvent = latest_event(
                        Store, RunId, <<"run.admission.committed">>),
        AcceptEvent = latest_event(Store, RunId, <<"cli.task.accepted">>),
        RejectEvent = latest_event(
                        Store, RunId, <<"cli.task.admission_rejected">>),
        ?assert(event_position(CommitEvent, Events) <
                    event_position(AcceptEvent, Events)),
        ?assert(event_position(AcceptEvent, Events) <
                    event_position(RejectEvent, Events)),
        ?assertEqual(AdmissionId,
                     maps:get(admission_id,
                              maps:get(payload, RejectEvent))),
        ?assertEqual({error, not_found},
                     soma_run_sup:find_run(RunId, 500)),
        ?assertEqual({error, not_found},
                     soma_run_index:lookup(RunId, 500)),
        {ok, #{status := cancelled}} =
            wait_for_registry_status(TaskId, cancelled, 100),
        Status = request(
                   ?config(socket_path, Config),
                   <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state cancelled\\)",
                            [{capture, none}]))
    after
        stop_server(Server)
    end.

%% Drive the real socket -> daemon -> registry admission path while the event
%% store blocks the registry's first post-preparation by_run read. The request
%% therefore loses certainty about cli.task.accepted and must return the minted
%% ids as admission_in_doubt, never as accepted. Releasing the exact store call
%% proves the registry's pending-admission retry completes one handshake and
%% one tool invocation under the same queryable task id.
test_acceptance_unknown_socket_returns_ids_and_retries_once(Config) ->
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    ok = wait_for_registry_ready(100),
    Store = event_store_pid(),
    Registry = whereis(soma_cli_task_registry),
    OutputName = <<"acceptance-unknown-retry.txt">>,
    Output = filename:join(?config(tmp_dir, Config),
                           binary_to_list(OutputName)),
    Gate = install_admission_store_gate(Store, acceptance_read),
    try
        {TaskId, CorrelationId, RunId} =
            try
                Reply = request(
                          ?config(socket_path, Config),
                          <<"(run (detach) "
                            "(step once file_write "
                            "(args (path \"", OutputName/binary,
                            "\") (root \"",
                            (unicode:characters_to_binary(
                               ?config(tmp_dir, Config)))/binary,
                            "\") (bytes \"once\"))))">>),
                {ReplyTaskId, ReplyCorrelationId, ReplyRunId} =
                    admission_in_doubt_ids(Reply),
                {acceptance_read, ReplyRunId} =
                    wait_for_admission_store_gate(Gate, 1000),
                ?assertEqual(match,
                             re:run(ReplyTaskId,
                                    "^task-[0-9A-F]{32}$",
                                    [{capture, none}])),
                ?assertEqual(match,
                             re:run(ReplyCorrelationId,
                                    "^corr-[0-9A-F]{32}$",
                                    [{capture, none}])),
                ?assertEqual(match,
                             re:run(ReplyRunId,
                                    "^run-[0-9A-F]{32}$",
                                    [{capture, none}])),
                RegistryState = sys:get_state(Registry),
                Pending = maps:get(
                            ReplyTaskId, maps:get(tasks, RegistryState)),
                ?assertEqual(ReplyRunId, maps:get(run_id, Pending)),
                ?assertEqual(ReplyCorrelationId,
                             maps:get(correlation_id, Pending)),
                ?assertEqual(true,
                             maps:get(admission_accept_pending, Pending)),
                PendingRunPid = maps:get(pid, Pending),
                ?assert(is_process_alive(PendingRunPid)),
                ?assertEqual(false, filelib:is_file(Output)),
                {ReplyTaskId, ReplyCorrelationId, ReplyRunId}
            after
                release_admission_store_gate(Gate)
            end,
        ok = remove_admission_store_gate(Gate),

        ok = wait_for_event(Store, RunId, <<"run.completed">>, 200),
        {ok, <<"once">>} = file:read_file(Output),
        {ok, #{status := completed}} =
            wait_for_registry_status(TaskId, completed, 100),
        Status = request(
                   ?config(socket_path, Config),
                   <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state completed\\)",
                            [{capture, none}])),
        Events = soma_event_store:by_run(Store, RunId),
        Types = [maps:get(event_type, Event) || Event <- Events],
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"cli.task.accepted">>, Types)),
        ?assertEqual(1, count(<<"run.admission.committed">>, Types)),
        ?assertEqual(0,
                     count(<<"cli.task.admission_rejected">>, Types)),
        ?assertEqual(1, count(<<"tool.started">>, Types)),
        ?assertEqual(1, count(<<"step.succeeded">>, Types)),
        ?assertEqual(1, count(<<"run.completed">>, Types)),
        ?assertEqual(
           [<<"run.started">>, <<"cli.task.accepted">>,
            <<"run.admission.committed">>, <<"step.started">>,
            <<"tool.started">>],
           ordered_event_types(
             [<<"run.started">>, <<"cli.task.accepted">>,
              <<"run.admission.committed">>, <<"step.started">>,
              <<"tool.started">>], Events)),
        ?assert(is_process_alive(Registry)),
        ?assert(is_process_alive(Server)),
        ?assertEqual(CorrelationId,
                     maps:get(correlation_id,
                              latest_event(Store, RunId,
                                           <<"cli.task.accepted">>)))
    after
        _ = remove_admission_store_gate(Gate),
        stop_server(Server)
    end.

%% Block the run-owned admission commit itself after the edge acceptance is
%% durable. The real socket call must again return admission_in_doubt with all
%% ids and no accepted form. Once released after the request lease expired, the
%% run may durably finish that commit but must cancel before the first step/tool
%% boundary; the registry then projects the stable task id as cancelled.
test_activation_unknown_socket_returns_ids_without_effect(Config) ->
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    ok = wait_for_registry_ready(100),
    Store = event_store_pid(),
    Registry = whereis(soma_cli_task_registry),
    OutputName = <<"activation-unknown-must-not-exist.txt">>,
    Output = filename:join(?config(tmp_dir, Config),
                           binary_to_list(OutputName)),
    Gate = install_admission_store_gate(Store, activation_commit),
    try
        {TaskId, CorrelationId, RunId} =
            try
                Reply = request(
                          ?config(socket_path, Config),
                          <<"(run (detach) "
                            "(step never file_write "
                            "(args (path \"", OutputName/binary,
                            "\") (root \"",
                            (unicode:characters_to_binary(
                               ?config(tmp_dir, Config)))/binary,
                            "\") (bytes \"must-not-run\"))))">>),
                {ReplyTaskId, ReplyCorrelationId, ReplyRunId} =
                    admission_in_doubt_ids(Reply),
                {activation_commit, ReplyRunId} =
                    wait_for_admission_store_gate(Gate, 1000),
                RegistryState = sys:get_state(Registry),
                Pending = maps:get(
                            ReplyTaskId, maps:get(tasks, RegistryState)),
                ?assertEqual(true,
                             maps:get(admission_accepted, Pending)),
                ?assertEqual(true,
                             maps:get(admission_activation_pending, Pending)),
                ?assertEqual(ReplyRunId, maps:get(run_id, Pending)),
                ?assertEqual(ReplyCorrelationId,
                             maps:get(correlation_id, Pending)),
                ?assert(is_process_alive(maps:get(pid, Pending))),
                ?assertEqual(false, filelib:is_file(Output)),
                {ReplyTaskId, ReplyCorrelationId, ReplyRunId}
            after
                release_admission_store_gate(Gate)
            end,
        ok = remove_admission_store_gate(Gate),

        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 200),
        {ok, #{status := cancelled}} =
            wait_for_registry_status(TaskId, cancelled, 100),
        Status = request(
                   ?config(socket_path, Config),
                   <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state cancelled\\)",
                            [{capture, none}])),
        Events = soma_event_store:by_run(Store, RunId),
        Types = [maps:get(event_type, Event) || Event <- Events],
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"cli.task.accepted">>, Types)),
        ?assertEqual(1, count(<<"run.admission.committed">>, Types)),
        ?assertEqual(1, count(<<"run.cancelled">>, Types)),
        ?assertEqual(0,
                     count(<<"cli.task.admission_rejected">>, Types)),
        ?assertEqual(0, count(<<"step.started">>, Types)),
        ?assertEqual(0, count(<<"tool.started">>, Types)),
        ?assertEqual(0, count(<<"step.succeeded">>, Types)),
        ?assertEqual(0, count(<<"run.completed">>, Types)),
        ?assertEqual(false, filelib:is_file(Output)),
        ?assertEqual(
           [<<"run.started">>, <<"cli.task.accepted">>,
            <<"run.admission.committed">>, <<"run.cancelled">>],
           ordered_event_types(
             [<<"run.started">>, <<"cli.task.accepted">>,
              <<"run.admission.committed">>, <<"run.cancelled">>],
             Events)),
        ?assertEqual(CorrelationId,
                     maps:get(correlation_id,
                              latest_event(Store, RunId,
                                           <<"run.admission.committed">>)))
    after
        _ = remove_admission_store_gate(Gate),
        stop_server(Server)
    end.

%% Issue #256: after runtime restart, auto-resume deliberately leaves a
%% cli_detached/auto_resume=false journal alone.  Once the CLI registry starts
%% (after configured tools are loaded in the production daemon), it resumes the
%% run with itself as owner.  The existing task id is live through status and
%% cancel, cancellation kills the resumed worker, and the correlation trail is
%% one run.started -> run.resumed -> run.cancelled chain.  The listener remains
%% usable for a later task.
test_restarted_detached_run_is_visible_cancellable_and_traceable(Config) ->
    TaskId = <<"task-restart-visible">>,
    CorrelationId = <<"corr-restart-visible">>,
    RunId = <<"run-restart-visible">>,
    Steps = [#{id => hold, tool => sleep,
               args => #{ms => 5000}, timeout_ms => 10000}],
    ok = seed_detached_started_log(Config, TaskId, CorrelationId, RunId,
                                   Steps, []),
    ok = boot_runtime(Config),
    ?assertEqual({error, not_found}, soma_run_sup:find_run(RunId)),

    {ok, Server} = start_server(Config),
    try
        Store = event_store_pid(),
        ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
        WorkerPid = tool_call_pid(Store, RunId),
        ?assert(is_process_alive(WorkerPid)),

        Status = request(?config(socket_path, Config),
                         <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state running\\)",
                            [{capture, none}])),

        Cancel = request(?config(socket_path, Config),
                         <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Cancel, "\\(status cancelled\\)",
                            [{capture, none}])),
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 100),
        ok = wait_for_process_dead(WorkerPid, 100),

        Events = soma_event_store:by_run(Store, RunId),
        Types = [maps:get(event_type, Event) || Event <- Events],
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"run.resumed">>, Types)),
        ?assertEqual(1, count(<<"run.cancelled">>, Types)),
        ?assert(lists:all(
                  fun(Event) ->
                          maps:get(correlation_id, Event) =:= CorrelationId
                  end, Events)),

        EventCount = length(Events),
        RepeatedCancel = request(
                           ?config(socket_path, Config),
                           <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(RepeatedCancel, "\\(note already-terminal\\)",
                            [{capture, none}])),
        ?assertEqual(EventCount,
                     length(soma_event_store:by_run(Store, RunId))),

        Trace = request(?config(socket_path, Config),
                        <<"(trace \"", CorrelationId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Trace, "run\\.resumed", [{capture, none}])),
        ?assertEqual(match,
                     re:run(Trace, "run\\.cancelled", [{capture, none}])),

        Echo = request(?config(socket_path, Config),
                       <<"(run (step after echo (args (value \"alive\"))))">>),
        ?assertEqual(match,
                     re:run(Echo, "\\(status completed\\)",
                            [{capture, none}]))
    after
        stop_server(Server)
    end.

%% Issue #256: registry-owned recovery must preserve the runtime fail-safe.
%% An in-flight non-idempotent state step is never started again; recovery
%% appends the existing resume_unsafe run.failed terminal and CLI status exposes
%% failed rather than unknown.
test_unsafe_detached_resume_reports_failed_without_reexecution(Config) ->
    TaskId = <<"task-restart-unsafe">>,
    CorrelationId = <<"corr-restart-unsafe">>,
    RunId = <<"run-restart-unsafe">>,
    Output = filename:join(?config(tmp_dir, Config), "must-not-exist.txt"),
    Step = #{id => write_once, tool => file_write,
             args => #{path => list_to_binary(Output),
                       bytes => <<"must not be written twice">>}},
    ToolStarted = #{run_id => RunId,
                    session_id => TaskId,
                    correlation_id => CorrelationId,
                    step_id => write_once,
                    event_type => <<"tool.started">>,
                    payload => #{}},
    ok = seed_detached_started_log(Config, TaskId, CorrelationId, RunId,
                                   [Step], [ToolStarted]),
    ok = boot_runtime(Config),

    {ok, Server} = start_server(Config),
    try
        Store = event_store_pid(),
        ok = wait_for_event(Store, RunId, <<"run.failed">>, 100),
        ?assertEqual(false, filelib:is_file(Output)),
        ?assertEqual({error, not_found}, soma_run_sup:find_run(RunId)),

        Status = request(?config(socket_path, Config),
                         <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state failed\\)",
                            [{capture, none}])),
        Failed = [Event || Event <- soma_event_store:by_run(Store, RunId),
                           maps:get(event_type, Event) =:= <<"run.failed">>],
        ?assertMatch([_], Failed),
        [FailedEvent] = Failed,
        ?assertEqual({resume_unsafe, write_once},
                     maps:get(reason, maps:get(payload, FailedEvent)))
    after
        stop_server(Server)
    end.

%% Issue #256: a legacy journal has neither the detached marker nor the new
%% explicit runtime_default/true opt-in. Its old owner cannot be reconstructed,
%% so both generic boot and the CLI registry leave it effect-free and unowned.
test_unmarked_foreground_run_is_not_adopted(Config) ->
    TaskId = <<"task-foreground-unmarked">>,
    CorrelationId = <<"corr-foreground-unmarked">>,
    RunId = <<"run-foreground-unmarked">>,
    Step = #{id => hold, tool => sleep, args => #{ms => 5000}},
    ok = seed_started_log(Config, TaskId, CorrelationId, RunId, [Step],
                          #{run_id => RunId,
                            session_id => TaskId,
                            correlation_id => CorrelationId}, []),
    ok = boot_runtime(Config),
    Store = event_store_pid(),
    ?assertEqual({error, not_found}, soma_run_sup:find_run(RunId)),
    Baseline = soma_event_store:by_run(Store, RunId),
    ?assertEqual([<<"run.started">>],
                 [maps:get(event_type, Event) || Event <- Baseline]),

    {ok, Server} = start_server(Config),
    try
        ok = wait_for_registry_ready(100),
        ?assertEqual({error, not_found},
                     soma_cli_task_registry:lookup(TaskId)),
        ?assertEqual({error, not_found}, soma_run_sup:find_run(RunId)),
        Status = request(?config(socket_path, Config),
                         <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state unknown\\)",
                            [{capture, none}])),
        Cancel = request(?config(socket_path, Config),
                         <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Cancel, "\\(status unknown\\)",
                            [{capture, none}])),
        ?assertEqual(Baseline, soma_event_store:by_run(Store, RunId))
    after
        stop_server(Server)
    end.

%% Issue #256: config tools are loaded after soma_runtime starts.  A detached
%% CLI run therefore opts out of generic boot auto-resume and waits until the
%% descriptor has been restored; registry-owned recovery then starts a fresh
%% CLI worker.  Cancelling that recovered task must tear down both the BEAM
%% worker and its external OS process.
test_config_cli_tool_recovers_after_restart_and_cancel_kills_os_process(Config) ->
    ok = boot_runtime(Config),
    {Helper, PidFile} = write_cancel_cli_stub(?config(tmp_dir, Config)),
    ToolsDir = write_cancel_cli_manifest(?config(tmp_dir, Config),
                                         Helper, PidFile),
    #{registered := [<<"restart_cli_reader">>]} =
        soma_tool_config:load_dir(ToolsDir),
    {ok, Server1} = start_server(Config, #{tools_dir => ToolsDir}),
    Request = <<"(run (detach) "
                "(step external restart_cli_reader "
                "(args (value \"ignored\"))))">>,
    Reply = request(?config(socket_path, Config), Request),
    TaskId = accepted_id(<<"task-id">>, Reply),
    Store1 = event_store_pid(),
    Started = wait_for_started_by_session(Store1, TaskId, 100),
    RunId = maps:get(run_id, Started),
    CorrelationId = maps:get(correlation_id, Started),
    ok = wait_for_event(Store1, RunId, <<"tool.started">>, 100),
    OldWorker = latest_tool_call_pid(Store1, RunId),
    OldOsPid = wait_for_cli_os_pid(PidFile, 100),
    ?assert(is_process_alive(OldWorker)),
    ?assert(cli_os_process_alive(OldOsPid)),

    crash_server(Server1),
    ok = application:stop(soma_runtime),
    ok = wait_for_process_dead(OldWorker, 100),
    ok = wait_for_os_process_dead(OldOsPid, 100),
    _ = file:delete(PidFile),

    ok = boot_runtime(Config),
    %% Runtime boot has not guessed at a descriptor that is not loaded yet.
    ?assertEqual({error, not_found}, soma_run_sup:find_run(RunId)),
    #{registered := [<<"restart_cli_reader">>]} =
        soma_tool_config:load_dir(ToolsDir),
    {ok, Server2} = start_server(Config, #{tools_dir => ToolsDir}),
    try
        Store2 = event_store_pid(),
        ok = wait_for_event_count(Store2, RunId, <<"tool.started">>, 2, 100),
        NewWorker = latest_tool_call_pid(Store2, RunId),
        NewOsPid = wait_for_cli_os_pid(PidFile, 100),
        ?assertNotEqual(OldWorker, NewWorker),
        ?assert(is_process_alive(NewWorker)),
        ?assert(cli_os_process_alive(NewOsPid)),

        Status = request(?config(socket_path, Config),
                         <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state running\\)",
                            [{capture, none}])),
        Cancel = request(?config(socket_path, Config),
                         <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Cancel, "\\(status cancelled\\)",
                            [{capture, none}])),
        ok = wait_for_process_dead(NewWorker, 100),
        ok = wait_for_os_process_dead(NewOsPid, 100),

        Events = soma_event_store:by_run(Store2, RunId),
        Types = [maps:get(event_type, Event) || Event <- Events],
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"run.resumed">>, Types)),
        ?assertEqual(1, count(<<"run.cancelled">>, Types)),
        ?assert(lists:all(
                  fun(Event) ->
                          maps:get(correlation_id, Event) =:= CorrelationId
                  end, Events))
    after
        stop_server(Server2)
    end.

%% Issue #256: a control-plane/listener restart can happen while the runtime
%% and tool worker remain alive.  The new registry must find_run + adopt_owner,
%% not start a duplicate resumed child.
test_listener_restart_adopts_live_detached_run_without_second_resume(Config) ->
    ok = boot_runtime(Config),
    {ok, Server1} = start_server(Config),
    Reply = request(
              ?config(socket_path, Config),
              <<"(run (detach) (step hold sleep (args (ms 5000))))">>),
    TaskId = accepted_id(<<"task-id">>, Reply),
    Store = event_store_pid(),
    Started = wait_for_started_by_session(Store, TaskId, 100),
    RunId = maps:get(run_id, Started),
    ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
    RunPid = live_run_pid(RunId),
    WorkerPid = latest_tool_call_pid(Store, RunId),

    crash_server(Server1),
    ?assert(is_process_alive(RunPid)),
    ?assert(is_process_alive(WorkerPid)),

    {ok, Server2} = start_server(Config),
    try
        {ok, #{pid := RunPid, status := running}} =
            wait_for_registry_run(TaskId, 100),
        ?assertEqual(0,
                     count(<<"run.resumed">>,
                           [maps:get(event_type, Event)
                            || Event <- soma_event_store:by_run(Store, RunId)])),
        Cancel = request(?config(socket_path, Config),
                         <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Cancel, "\\(status cancelled\\)",
                            [{capture, none}])),
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 100),
        ok = wait_for_process_dead(WorkerPid, 100),
        {ok, #{status := cancelled}} =
            soma_cli_task_registry:lookup(TaskId)
    after
        stop_server(Server2)
    end.

%% A replacement registry that adopts a fully committed live run must retain
%% its exact admission identity.  A rejection append from an older generation
%% may land after that adoption; if the adopted run is then interrupted, the
%% replacement must re-read the absorbing tombstone and cancel rather than
%% softening the missing in-memory fields into a legacy resume permission.
test_late_rejection_after_live_adoption_cancels_without_replay(Config) ->
    ok = boot_runtime(Config),
    Output = filename:join(
               ?config(tmp_dir, Config), "late-rejection-effect.txt"),
    {ok, Server1} = start_server(Config),
    Reply = request(
              ?config(socket_path, Config),
              iolist_to_binary(
                ["(run (detach) ",
                 "(step hold sleep (args (ms 15000))) ",
                 "(step forbidden file_write (args (path ",
                 soma_lisp:render(unicode:characters_to_binary(Output)),
                 ") (bytes \"must-not-run\"))))"])),
    TaskId = accepted_id(<<"task-id">>, Reply),
    CorrelationId = accepted_id(<<"correlation-id">>, Reply),
    Store = event_store_pid(),
    Started = wait_for_started_by_session(Store, TaskId, 100),
    RunId = maps:get(run_id, Started),
    ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
    RunPid = live_run_pid(RunId),

    crash_server(Server1),
    ?assert(is_process_alive(RunPid)),

    {ok, Server2} = start_server(Config),
    try
        {ok, Adopted = #{pid := RunPid, status := running,
                         admission_required := true,
                         admission_id := AdmissionId,
                         admission_accepted := true,
                         admission_committed := true}} =
            wait_for_registry_run(TaskId, 100),
        ?assertEqual(TaskId, maps:get(task_id, Adopted)),
        ?assertEqual(RunId, maps:get(run_id, Adopted)),
        ?assert(is_binary(AdmissionId)),
        ?assert(byte_size(AdmissionId) > 0),

        ok = soma_event_store:append(
               Store,
               #{event_type => <<"cli.task.admission_rejected">>,
                 run_id => RunId,
                 session_id => TaskId,
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 payload =>
                     #{admission_protocol => cli_detached_v1,
                       admission_id => AdmissionId,
                       reason => delayed_old_generation}}),
        Rejection = latest_event(
                      Store, RunId, <<"cli.task.admission_rejected">>),

        exit(RunPid, kill),
        ok = wait_for_process_dead(RunPid, 100),
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 150),
        {ok, #{status := cancelled}} =
            wait_for_registry_status(TaskId, cancelled, 150),
        ok = wait_for_run_claim_absent(RunId, 100),

        Events = soma_event_store:by_run(Store, RunId),
        AfterRejection = lists:nthtail(
                           event_position(Rejection, Events), Events),
        AfterTypes = [maps:get(event_type, Event)
                      || Event <- AfterRejection],
        ?assertEqual([<<"run.cancelled">>], AfterTypes),
        ?assertEqual(
           [], [Type || Type <- AfterTypes,
                       lists:member(
                         Type,
                         [<<"run.resumed">>, <<"step.started">>,
                          <<"tool.started">>])]),
        ?assertEqual(false, filelib:is_file(Output)),
        ?assert(is_process_alive(Server2)),
        Registry2 = whereis(soma_cli_task_registry),
        ?assert(is_pid(Registry2)),
        ?assert(is_process_alive(Registry2))
    after
        stop_server(Server2)
    end.

%% Issue #256: restarting only soma_runtime leaves the listener-owned registry
%% alive. The monitored run DOWN is an interruption, not an in-memory terminal:
%% after the fresh runtime generation is ready the same registry must re-plan,
%% own the resumed pid, and keep status/cancel usable.
test_runtime_restart_recovers_with_registry_alive(Config) ->
    ok = boot_runtime(Config),
    {Helper, PidFile} = write_cancel_cli_stub(?config(tmp_dir, Config)),
    ToolsDir = write_cancel_cli_manifest(?config(tmp_dir, Config),
                                         Helper, PidFile),
    #{registered := [<<"restart_cli_reader">>]} =
        soma_tool_config:load_dir(ToolsDir),
    {ok, Server} = start_server(Config, #{tools_dir => ToolsDir}),
    try
        Reply = request(
                  ?config(socket_path, Config),
                  <<"(run (detach) "
                    "(step hold sleep (args (ms 15000))))">>),
        TaskId = accepted_id(<<"task-id">>, Reply),
        Store1 = event_store_pid(),
        Started = wait_for_started_by_session(Store1, TaskId, 100),
        RunId = maps:get(run_id, Started),
        ok = wait_for_event(Store1, RunId, <<"tool.started">>, 100),
        OldWorker = latest_tool_call_pid(Store1, RunId),

        ok = application:stop(soma_runtime),
        ok = wait_for_process_dead(OldWorker, 100),
        ?assert(is_process_alive(Server)),
        ?assert(is_pid(whereis(soma_cli_task_registry))),

        ok = boot_runtime(Config),
        Store2 = event_store_pid(),
        ok = wait_for_event(Store2, RunId, <<"run.resumed">>, 150),
        %% The surviving registry noticed the new event-store generation and
        %% restored its configured-tool directory before resuming any task.
        {ok, #{name := <<"restart_cli_reader">>}} =
            soma_tool_registry:resolve_descriptor(
              <<"restart_cli_reader">>),
        ok = wait_for_event_count(
               Store2, RunId, <<"tool.started">>, 2, 150),
        {ok, #{pid := NewRunPid, status := running}} =
            wait_for_registry_run(TaskId, 150),
        ?assert(is_process_alive(NewRunPid)),
        ?assertEqual({ok, NewRunPid}, soma_run_sup:find_run(RunId, 500)),
        NewWorker = latest_tool_call_pid(Store2, RunId),
        ?assertNotEqual(OldWorker, NewWorker),
        RecoveryTypes = [maps:get(event_type, Event)
                         || Event <- soma_event_store:by_run(Store2, RunId)],
        ?assertEqual(1, count(<<"run.resumed">>, RecoveryTypes)),
        ?assertEqual(2, count(<<"tool.started">>, RecoveryTypes)),

        Status = request(?config(socket_path, Config),
                         <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state running\\)",
                            [{capture, none}])),
        Cancel = request(?config(socket_path, Config),
                         <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Cancel, "\\(status cancelled\\)",
                            [{capture, none}])),
        ok = wait_for_process_dead(NewWorker, 100),

        Echo = request(?config(socket_path, Config),
                       <<"(run (step after echo "
                         "(args (value \"runtime-alive\"))))">>),
        ?assertEqual(match,
                     re:run(Echo, "\\(status completed\\)",
                            [{capture, none}]))
    after
        stop_server(Server)
    end.

%% A one_for_one restart of only soma_tool_registry keeps the CLI registry and
%% event store generations alive but drops every config descriptor. The next
%% interrupted-run recovery detects the tool-registry pid change, reloads the
%% configured directory into that exact generation, and resumes once.
test_tool_registry_generation_reload_recovers_config_tool(Config) ->
    ok = boot_runtime(Config),
    {Helper, PidFile} = write_cancel_cli_stub(?config(tmp_dir, Config)),
    ToolsDir = write_cancel_cli_manifest(?config(tmp_dir, Config),
                                         Helper, PidFile),
    #{registered := [<<"restart_cli_reader">>]} =
        soma_tool_config:load_dir(ToolsDir),
    {ok, Server} = start_server(Config, #{tools_dir => ToolsDir}),
    try
        Reply = request(
                  ?config(socket_path, Config),
                  <<"(run (detach) (step external restart_cli_reader "
                    "(args (value \"ignored\"))))">>),
        TaskId = accepted_id(<<"task-id">>, Reply),
        Store = event_store_pid(),
        Started = wait_for_started_by_session(Store, TaskId, 100),
        RunId = maps:get(run_id, Started),
        ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
        OldRunPid = live_run_pid(RunId),
        OldWorker = latest_tool_call_pid(Store, RunId),
        OldOsPid = wait_for_cli_os_pid(PidFile, 100),

        OldRegistry = whereis(soma_tool_registry),
        exit(OldRegistry, kill),
        NewRegistry = wait_for_new_registered_pid(
                        soma_tool_registry, OldRegistry, 100),
        ?assert(is_pid(NewRegistry)),
        ?assertEqual({error, not_found},
                     soma_tool_registry:resolve_descriptor(
                       <<"restart_cli_reader">>)),

        exit(OldRunPid, kill),
        ok = wait_for_process_dead(OldRunPid, 100),
        ok = wait_for_process_dead(OldWorker, 100),
        ok = wait_for_os_process_dead(OldOsPid, 100),
        _ = file:delete(PidFile),

        ok = wait_for_event(Store, RunId, <<"run.resumed">>, 150),
        {ok, #{name := <<"restart_cli_reader">>}} =
            soma_tool_registry:resolve_descriptor(
              <<"restart_cli_reader">>),
        ok = wait_for_event_count(
               Store, RunId, <<"tool.started">>, 2, 150),
        NewWorker = latest_tool_call_pid(Store, RunId),
        NewOsPid = wait_for_cli_os_pid(PidFile, 100),
        ?assertNotEqual(OldWorker, NewWorker),
        ?assert(cli_os_process_alive(NewOsPid)),
        Types = [maps:get(event_type, Event)
                 || Event <- soma_event_store:by_run(Store, RunId)],
        ?assertEqual(1, count(<<"run.resumed">>, Types)),
        ?assertEqual(2, count(<<"tool.started">>, Types)),

        Cancel = request(?config(socket_path, Config),
                         <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Cancel, "\\(status cancelled\\)",
                            [{capture, none}])),
        ok = wait_for_process_dead(NewWorker, 100),
        ok = wait_for_os_process_dead(NewOsPid, 100)
    after
        stop_server(Server)
    end.

%% Issue #256: liveness ambiguity is not absence. A suspended run cannot answer
%% identity/adoption calls; registry startup must return within a bound, expose
%% the task as active, and retry without emitting run.resumed or starting a
%% second child. Once the run responds, the new registry adopts it and receives
%% the cancellation terminal notification.
test_unresponsive_live_run_defers_without_duplicate(Config) ->
    ok = boot_runtime(Config),
    {ok, Server1} = start_server(Config),
    Reply = request(
              ?config(socket_path, Config),
              <<"(run (detach) "
                "(step hold sleep (args (ms 60000))))">>),
    TaskId = accepted_id(<<"task-id">>, Reply),
    Store = event_store_pid(),
    Started = wait_for_started_by_session(Store, TaskId, 100),
    RunId = maps:get(run_id, Started),
    ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
    RunPid = live_run_pid(RunId),
    WorkerPid = latest_tool_call_pid(Store, RunId),
    ok = sys:suspend(RunPid),
    crash_server(Server1),

    StartedAt = erlang:monotonic_time(millisecond),
    {ok, Server2} = start_server(Config),
    StartupMs = erlang:monotonic_time(millisecond) - StartedAt,
    try
        ?assert(StartupMs < 2000),
        {ok, #{status := running}} =
            wait_for_registry_status(TaskId, running, 100),
        RunChildren = active_run_pids(),
        ?assertEqual([RunPid], RunChildren),
        ?assertEqual(
           0,
           count(<<"run.resumed">>,
                 [maps:get(event_type, Event)
                  || Event <- soma_event_store:by_run(Store, RunId)])),

        ok = sys:resume(RunPid),
        {ok, #{pid := RunPid, status := running}} =
            wait_for_registry_run(TaskId, 150),
        Cancel = request(?config(socket_path, Config),
                         <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Cancel, "\\(status cancelled\\)",
                            [{capture, none}])),
        ok = wait_for_process_dead(WorkerPid, 100),
        {ok, #{status := cancelled}} =
            soma_cli_task_registry:lookup(TaskId),
        ?assertEqual(
           0,
           count(<<"run.resumed">>,
                 [maps:get(event_type, Event)
                  || Event <- soma_event_store:by_run(Store, RunId)]))
    after
        maybe_resume_run(RunPid),
        RunPid ! cancel,
        stop_server(Server2)
    end.

%% Exact ownership no longer scans supervisor children. Even while soma_run_sup
%% is suspended, the independent run-id index identifies the already-live run
%% and the new registry adopts it immediately; unrelated supervisor mailbox
%% state cannot create a duplicate attempt.
test_suspended_run_supervisor_keeps_recovery_bounded(Config) ->
    ok = boot_runtime(Config),
    {ok, Server1} = start_server(Config),
    Reply = request(
              ?config(socket_path, Config),
              <<"(run (detach) (step hold sleep (args (ms 60000))))">>),
    TaskId = accepted_id(<<"task-id">>, Reply),
    Store = event_store_pid(),
    Started = wait_for_started_by_session(Store, TaskId, 100),
    RunId = maps:get(run_id, Started),
    ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
    RunPid = live_run_pid(RunId),
    WorkerPid = latest_tool_call_pid(Store, RunId),
    crash_server(Server1),
    SupPid = whereis(soma_run_sup),
    ok = sys:suspend(SupPid),
    try
        StartedAt = erlang:monotonic_time(millisecond),
        {ok, Server2} = bounded_start_server(Config, 2000),
        StartupMs = erlang:monotonic_time(millisecond) - StartedAt,
        try
            ?assert(StartupMs < 2000),
            {ok, #{pid := RunPid, status := running}} =
                wait_for_registry_run(TaskId, 100),
            ?assert(is_process_alive(RunPid)),
            ?assert(is_process_alive(WorkerPid)),
            Types0 = [maps:get(event_type, Event)
                      || Event <- soma_event_store:by_run(Store, RunId)],
            ?assertEqual(0, count(<<"run.resumed">>, Types0)),
            ?assertEqual(1, count(<<"tool.started">>, Types0)),

            ok = sys:resume(SupPid),
            ?assertEqual([RunPid], active_run_pids()),
            Cancel = request(?config(socket_path, Config),
                             <<"(cancel \"", TaskId/binary, "\")">>),
            ?assertEqual(match,
                         re:run(Cancel, "\\(status cancelled\\)",
                                [{capture, none}])),
            ok = wait_for_process_dead(WorkerPid, 100)
        after
            maybe_resume_process(SupPid),
            stop_server(Server2)
        end
    after
        maybe_resume_process(SupPid),
        RunPid ! cancel
    end.

%% A bounded start may have committed in soma_run_sup even though the recovery
%% owner timed out waiting for its acknowledgement. The one barrier probe keeps
%% the task visible without enqueuing another start; after the supervisor wakes,
%% that exact paused child is adopted and activated once.
test_start_in_doubt_resumes_once_after_supervisor_unblocks(Config) ->
    TaskId = <<"task-start-in-doubt">>,
    CorrId = <<"corr-start-in-doubt">>,
    RunId = <<"run-start-in-doubt">>,
    Step = #{id => once, tool => echo, args => #{value => <<"once">>}},
    ok = seed_detached_started_log(
           Config, TaskId, CorrId, RunId, [Step], []),
    ok = boot_runtime(Config),
    SupPid = whereis(soma_run_sup),
    ok = sys:suspend(SupPid),
    {ok, Server} = bounded_start_server(Config, 2000),
    try
        {ok, Waiting} = wait_for_start_in_doubt(TaskId, 150),
        #{pid := Probe} = maps:get(start_probe, Waiting),
        ?assert(is_process_alive(Probe)),
        ?assertEqual({error, not_found}, soma_run_sup:find_run(RunId, 100)),

        ok = sys:resume(SupPid),
        Store = event_store_pid(),
        ok = wait_for_event(Store, RunId, <<"run.completed">>, 150),
        Types = [maps:get(event_type, Event)
                 || Event <- soma_event_store:by_run(Store, RunId)],
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"run.resumed">>, Types)),
        ?assertEqual(1, count(<<"tool.started">>, Types)),
        ?assertEqual(1, count(<<"step.succeeded">>, Types)),
        ?assertEqual(1, count(<<"run.completed">>, Types)),
        {ok, #{status := completed}} =
            soma_cli_task_registry:lookup(TaskId)
    after
        maybe_resume_process(SupPid),
        cancel_live_run(RunId),
        stop_server(Server)
    end.

%% Cancellation accepted while supervisor:start_child is in doubt is durable
%% before the queued child can initialize. The child remains behind its activate
%% barrier and goes directly to run.cancelled: no resume event and no tool call.
test_cancel_fences_start_in_doubt_before_first_tool(Config) ->
    TaskId = <<"task-cancel-start-in-doubt">>,
    CorrId = <<"corr-cancel-start-in-doubt">>,
    RunId = <<"run-cancel-start-in-doubt">>,
    Step = #{id => never, tool => echo, args => #{value => <<"never">>}},
    ok = seed_detached_started_log(
           Config, TaskId, CorrId, RunId, [Step], []),
    ok = boot_runtime(Config),
    SupPid = whereis(soma_run_sup),
    ok = sys:suspend(SupPid),
    {ok, Server} = bounded_start_server(Config, 2000),
    try
        {ok, _Waiting} = wait_for_start_in_doubt(TaskId, 150),
        CancelReply = request(
                        ?config(socket_path, Config),
                        <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(CancelReply, "\\(status running\\)",
                            [{capture, none}])),
        Store = event_store_pid(),
        ?assertEqual(
           1,
           count(<<"cli.task.cancel_requested">>,
                 [maps:get(event_type, Event)
                  || Event <- soma_event_store:by_run(Store, RunId)])),

        ok = sys:resume(SupPid),
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 150),
        Types = [maps:get(event_type, Event)
                 || Event <- soma_event_store:by_run(Store, RunId)],
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"cli.task.cancel_requested">>, Types)),
        ?assertEqual(0, count(<<"run.resumed">>, Types)),
        ?assertEqual(0, count(<<"tool.started">>, Types)),
        ?assertEqual(1, count(<<"run.cancelled">>, Types)),
        {ok, #{status := cancelled}} =
            soma_cli_task_registry:lookup(TaskId)
    after
        maybe_resume_process(SupPid),
        cancel_live_run(RunId),
        stop_server(Server)
    end.

%% A durable cancel cannot retire the ownership fence while an older registry
%% generation still has a timed-out start queued in soma_run_sup.  The new
%% registry first waits behind that supervisor barrier.  Once the supervisor
%% answers, the abandoned child is fenced/cancelled and the durable task reaches
%% one terminal without ever activating a resumed attempt or a tool worker.
test_cancelled_start_in_doubt_survives_registry_replacement(Config) ->
    TaskId = <<"task-cancelled-in-doubt-replacement">>,
    CorrId = <<"corr-cancelled-in-doubt-replacement">>,
    RunId = <<"run-cancelled-in-doubt-replacement">>,
    Step = #{id => never, tool => echo, args => #{value => <<"never">>}},
    ok = seed_detached_started_log(
           Config, TaskId, CorrId, RunId, [Step], []),
    ok = boot_runtime(Config),
    Store = event_store_pid(),
    SupPid = whereis(soma_run_sup),
    ok = sys:suspend(SupPid),
    {ok, Server1} = bounded_start_server(Config, 2000),
    try
        {ok, _Waiting} = wait_for_start_in_doubt(TaskId, 150),
        ok = soma_cli_task_registry:cancel(TaskId),
        ok = wait_for_event(
               Store, RunId, <<"cli.task.cancel_requested">>, 100),

        %% Kill both the listener and its linked registry while the old
        %% supervisor call is still queued.  The replacement owner sees the
        %% durable cancel but must not finalize it ahead of that queued call.
        crash_server(Server1),
        {ok, Server2} = bounded_start_server(Config, 2000),
        try
            {ok, #{status := running}} =
                wait_for_registry_status(TaskId, running, 150),
            timer:sleep(300),
            BeforeTypes = event_types(Store, RunId),
            ?assertEqual(0, count(<<"run.cancelled">>, BeforeTypes)),
            ?assertEqual(0, count(<<"run.resumed">>, BeforeTypes)),
            ?assertEqual(0, count(<<"tool.started">>, BeforeTypes)),
            ?assertEqual({error, not_found},
                         soma_run_index:lookup(RunId, 500)),

            ok = sys:resume(SupPid),
            ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 150),
            ok = wait_for_run_claim_absent(RunId, 150),
            Types = event_types(Store, RunId),
            ?assertEqual(1, count(<<"run.started">>, Types)),
            ?assertEqual(1,
                         count(<<"cli.task.cancel_requested">>, Types)),
            ?assertEqual(1, count(<<"run.cancelled">>, Types)),
            ?assertEqual(0, count(<<"run.resumed">>, Types)),
            ?assertEqual(0, count(<<"tool.started">>, Types)),
            ?assertEqual({error, not_found},
                         soma_run_sup:find_run(RunId, 500)),
            ?assertEqual({error, not_found},
                         soma_run_index:lookup(RunId, 500)),
            {ok, #{status := cancelled}} =
                wait_for_registry_status(TaskId, cancelled, 100),
            ok
        after
            stop_server(Server2)
        end
    after
        maybe_resume_process(SupPid),
        cancel_live_run(RunId),
        case is_process_alive(Server1) of
            true -> stop_server(Server1);
            false -> ok
        end
    end.

%% The listener remains responsive while its asynchronous authoritative scan is
%% blocked, but ownership-changing operations fail closed until the store can
%% answer. Once the scan lands, normal recovery and controlled stop resume.
test_store_unavailable_during_registry_scan_fails_closed(Config) ->
    TaskId = <<"task-scan-store-unavailable">>,
    CorrId = <<"corr-scan-store-unavailable">>,
    RunId = <<"run-scan-store-unavailable">>,
    Step = #{id => later, tool => echo, args => #{value => <<"later">>}},
    ok = seed_detached_started_log(
           Config, TaskId, CorrId, RunId, [Step], []),
    ok = boot_runtime(Config),
    Store = event_store_pid(),
    ok = sys:suspend(Store),
    {ok, Server} = bounded_start_server(Config, 2000),
    try
        Status = request(?config(socket_path, Config),
                         <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state recovering\\)",
                            [{capture, none}])),
        Cancel = request(?config(socket_path, Config),
                         <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Cancel, "recovery_incomplete|recovery-incomplete",
                            [{capture, none}])),
        StopFailed = request(?config(socket_path, Config), <<"(stop)">>),
        ?assertEqual(match,
                     re:run(StopFailed, "\\(status stop-failed\\)",
                            [{capture, none}])),
        ?assert(is_process_alive(Server)),

        ok = sys:resume(Store),
        ok = wait_for_event(Store, RunId, <<"run.completed">>, 150),
        {ok, #{status := completed}} =
            wait_for_registry_status(TaskId, completed, 150),
        StopOk = request(?config(socket_path, Config), <<"(stop)">>),
        ?assertEqual(match,
                     re:run(StopOk, "\\(status stopped\\)",
                            [{capture, none}])),
        ok = wait_for_process_dead(Server, 100)
    after
        maybe_resume_process(Store),
        case is_process_alive(Server) of
            true -> stop_server(Server);
            false -> ok
        end
    end.

%% A marker for the same run id but a different task/session/correlation is not
%% this owner's durable decision. Recovery executes the safe task; a subsequent
%% real cancel appends a distinct correctly-bound marker before signalling it.
test_mismatched_cancel_marker_is_not_owner_intent(Config) ->
    TaskId = <<"task-cancel-identity">>,
    CorrId = <<"corr-cancel-identity">>,
    RunId = <<"run-cancel-identity">>,
    Step = #{id => hold, tool => sleep, args => #{ms => 60000}},
    WrongMarker = #{run_id => RunId,
                    session_id => <<"other-task">>,
                    task_id => <<"other-task">>,
                    correlation_id => <<"other-correlation">>,
                    event_type => <<"cli.task.cancel_requested">>,
                    payload => #{reason => cli_cancel}},
    ok = seed_detached_started_log(
           Config, TaskId, CorrId, RunId, [Step], [WrongMarker]),
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    try
        Store = event_store_pid(),
        ok = wait_for_event(Store, RunId, <<"tool.started">>, 150),
        Cancel = request(?config(socket_path, Config),
                         <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Cancel, "\\(status cancelled\\)",
                            [{capture, none}])),
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 100),
        Markers = [Event
                   || Event <- soma_event_store:by_run(Store, RunId),
                      maps:get(event_type, Event) =:=
                          <<"cli.task.cancel_requested">>],
        ?assertEqual(2, length(Markers)),
        Correct = [Event || Event <- Markers,
                            maps:get(task_id, Event) =:= TaskId,
                            maps:get(session_id, Event) =:= TaskId,
                            maps:get(correlation_id, Event) =:= CorrId],
        ?assertEqual(1, length(Correct))
    after
        stop_server(Server)
    end.

%% Identity checks run concurrently under one deadline. An unrelated suspended
%% child is ambiguous, but it must not hide the exact responsive detached run
%% later in the supervisor child list.
test_unrelated_unresponsive_run_does_not_block_adoption(Config) ->
    ok = boot_runtime(Config),
    Store = event_store_pid(),
    OtherRunId = <<"run-unrelated-suspended">>,
    {ok, OtherRunPid} = soma_run_sup:start_run(
                          #{run_id => OtherRunId,
                            session_pid => self(),
                            event_store => Store,
                            steps => [#{id => other, tool => sleep,
                                        args => #{ms => 60000}}]}),
    ok = wait_for_event(Store, OtherRunId, <<"tool.started">>, 100),
    ok = sys:suspend(OtherRunPid),
    {ok, Server1} = start_server(Config),
    Reply = request(
              ?config(socket_path, Config),
              <<"(run (detach) (step target sleep (args (ms 60000))))">>),
    TaskId = accepted_id(<<"task-id">>, Reply),
    Started = wait_for_started_by_session(Store, TaskId, 100),
    RunId = maps:get(run_id, Started),
    ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
    {ok, TargetRunPid} = soma_run_sup:find_run(RunId, 500),
    TargetWorker = latest_tool_call_pid(Store, RunId),
    crash_server(Server1),
    try
        {ok, Server2} = bounded_start_server(Config, 2000),
        try
            {ok, #{pid := TargetRunPid, status := running}} =
                wait_for_registry_run(TaskId, 50),
            Types = [maps:get(event_type, Event)
                     || Event <- soma_event_store:by_run(Store, RunId)],
            ?assertEqual(0, count(<<"run.resumed">>, Types)),
            ?assert(is_process_alive(OtherRunPid)),
            Cancel = request(?config(socket_path, Config),
                             <<"(cancel \"", TaskId/binary, "\")">>),
            ?assertEqual(match,
                         re:run(Cancel, "\\(status cancelled\\)",
                                [{capture, none}])),
            ok = wait_for_process_dead(TargetWorker, 100)
        after
            stop_server(Server2)
        end
    after
        maybe_resume_process(OtherRunPid),
        OtherRunPid ! cancel,
        TargetRunPid ! cancel
    end.

%% Issue #256: resume safety is fixed by the descriptor used when the original
%% invocation began, not just by a mutable same-name manifest after restart.
%% Changing state/non-idempotent to reader/idempotent cannot authorize replay.
test_changed_manifest_cannot_weaken_in_flight_resume_safety(Config) ->
    TaskId = <<"task-mutated-manifest">>,
    CorrelationId = <<"corr-mutated-manifest">>,
    RunId = <<"run-mutated-manifest">>,
    ToolName = <<"mutable_resume_tool">>,
    Step = #{id => mutate_once, tool => ToolName, args => #{}},
    ToolStarted = #{run_id => RunId,
                    session_id => TaskId,
                    correlation_id => CorrelationId,
                    step_id => mutate_once,
                    event_type => <<"tool.started">>,
                    payload =>
                        #{resume_safety =>
                              #{effect => state, idempotent => false}}},
    ok = seed_detached_started_log(Config, TaskId, CorrelationId, RunId,
                                   [Step], [ToolStarted]),
    ok = boot_runtime(Config),
    ok = soma_tool_registry:register_tool(
           #{name => ToolName,
             effect => reader,
             idempotent => true,
             timeout_ms => 5000,
             adapter => cli,
             executable => "/bin/echo",
             argv => []}),

    {ok, Server} = start_server(Config),
    try
        Store = event_store_pid(),
        ok = wait_for_event(Store, RunId, <<"run.failed">>, 100),
        ?assertEqual({error, not_found}, soma_run_sup:find_run(RunId)),
        Events = soma_event_store:by_run(Store, RunId),
        Types = [maps:get(event_type, Event) || Event <- Events],
        ?assertEqual(1, count(<<"tool.started">>, Types)),
        ?assertEqual(0, count(<<"run.resumed">>, Types)),
        Failed = latest_event(Store, RunId, <<"run.failed">>),
        ?assertEqual({resume_unsafe, mutate_once},
                     maps:get(reason, maps:get(payload, Failed))),
        Status = request(?config(socket_path, Config),
                         <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state failed\\)",
                            [{capture, none}]))
    after
        stop_server(Server)
    end.

test_malformed_marked_journal_fails_closed_without_daemon_crash(Config) ->
    TaskId = <<"task-malformed-journal">>,
    CorrId = <<"corr-malformed-journal">>,
    RunId = <<"run-malformed-journal">>,
    Step = #{id => broken,
             tool => #{<<"not">> => a_tool_identity},
             args => #{}},
    ok = seed_detached_started_log(Config, TaskId, CorrId, RunId, [Step], []),
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    try
        Store = event_store_pid(),
        ok = wait_for_event(Store, RunId, <<"run.failed">>, 100),
        ?assert(is_process_alive(Server)),
        ?assertEqual({error, not_found}, soma_run_sup:find_run(RunId, 500)),
        Types = [maps:get(event_type, Event)
                 || Event <- soma_event_store:by_run(Store, RunId)],
        ?assertEqual(0, count(<<"run.resumed">>, Types)),
        ?assertEqual(0, count(<<"tool.started">>, Types)),
        ?assertEqual(1, count(<<"run.failed">>, Types)),
        Status = request(?config(socket_path, Config),
                         <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state failed\\)",
                            [{capture, none}]))
    after
        stop_server(Server)
    end.

%% A successful stop acknowledgement is a durable owner decision. Freeze the
%% run so it cannot consume cancel, stop the listener, then cut every live owner
%% immediately. On restart the intent lands one run.cancelled terminal directly;
%% no run.resumed or second tool.started is allowed.
test_stop_cancel_intent_survives_immediate_restart_without_replay(Config) ->
    ok = boot_runtime(Config),
    {ok, Server1} = start_server(Config),
    %% This case isolates the post-acknowledgement owner/runtime cut. Do not
    %% race it with the separate authoritative boot-scan fail-closed contract.
    ok = wait_for_registry_ready(100),
    Reply = request(
              ?config(socket_path, Config),
              <<"(run (detach) (step hold sleep (args (ms 60000))))">>),
    TaskId = accepted_id(<<"task-id">>, Reply),
    CorrId = accepted_id(<<"correlation-id">>, Reply),
    Store1 = event_store_pid(),
    Started = wait_for_started_by_session(Store1, TaskId, 100),
    RunId = maps:get(run_id, Started),
    ok = wait_for_event(Store1, RunId, <<"tool.started">>, 100),
    RunPid = live_run_pid(RunId),
    WorkerPid = latest_tool_call_pid(Store1, RunId),
    ok = sys:suspend(RunPid),

    StopReply = request(?config(socket_path, Config), <<"(stop)">>),
    ?assertEqual(match,
                 re:run(StopReply, "\\(status stopped\\)",
                        [{capture, none}])),
    ok = wait_for_process_dead(Server1, 100),
    IntentEvents = [Event || Event <- soma_event_store:by_run(Store1, RunId),
                             maps:get(event_type, Event) =:=
                                 <<"cli.task.cancel_requested">>],
    ?assertMatch([_], IntentEvents),
    [Intent] = IntentEvents,
    ?assertEqual(TaskId, maps:get(task_id, Intent)),
    ?assertEqual(CorrId, maps:get(correlation_id, Intent)),
    ?assertEqual(0,
                 count(<<"run.cancelled">>,
                       [maps:get(event_type, Event)
                        || Event <- soma_event_store:by_run(Store1, RunId)])),

    stop_task_registry(),
    exit(RunPid, kill),
    ok = wait_for_process_dead(RunPid, 100),
    ok = wait_for_process_dead(WorkerPid, 100),
    ok = application:stop(soma_runtime),
    ok = boot_runtime(Config),
    {ok, Server2} = start_server(Config),
    try
        Store2 = event_store_pid(),
        ok = wait_for_event(Store2, RunId, <<"run.cancelled">>, 100),
        {ok, #{status := cancelled}} =
            soma_cli_task_registry:lookup(TaskId),
        ?assertEqual({error, not_found}, soma_run_sup:find_run(RunId, 500)),
        Types = [maps:get(event_type, Event)
                 || Event <- soma_event_store:by_run(Store2, RunId)],
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"cli.task.cancel_requested">>, Types)),
        ?assertEqual(1, count(<<"tool.started">>, Types)),
        ?assertEqual(0, count(<<"run.resumed">>, Types)),
        ?assertEqual(1, count(<<"run.cancelled">>, Types)),
        Status = request(?config(socket_path, Config),
                         <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state cancelled\\)",
                            [{capture, none}])),

        Before = length(soma_event_store:by_run(Store2, RunId)),
        crash_server(Server2),
        {ok, Server3} = start_server(Config),
        try
            ok = wait_for_registry_ready(100),
            Status3 = request(?config(socket_path, Config),
                              <<"(status \"", TaskId/binary, "\")">>),
            ?assertEqual(match,
                         re:run(Status3, "\\(state cancelled\\)",
                                [{capture, none}])),
            ?assertEqual(Before,
                         length(soma_event_store:by_run(Store2, RunId)))
        after
            stop_server(Server3)
        end
    after
        case is_process_alive(Server2) of
            true -> stop_server(Server2);
            false -> ok
        end
    end.

test_stop_fails_closed_when_cancel_intent_store_unavailable(Config) ->
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    %% Exercise store unavailability after the authoritative boot projection is
    %% ready; recovery-scan fail-closed behavior has its own dedicated case.
    ok = wait_for_registry_ready(100),
    Reply = request(
              ?config(socket_path, Config),
              <<"(run (detach) (step hold sleep (args (ms 60000))))">>),
    TaskId = accepted_id(<<"task-id">>, Reply),
    Store = event_store_pid(),
    Started = wait_for_started_by_session(Store, TaskId, 100),
    RunId = maps:get(run_id, Started),
    ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
    ok = sys:suspend(Store),
    try
        StopFailed = request(?config(socket_path, Config), <<"(stop)">>),
        ?assertEqual(match,
                     re:run(StopFailed, "\\(status stop-failed\\)",
                            [{capture, none}])),
        ?assert(is_process_alive(Server)),
        ok = sys:resume(Store),
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 150),
        {ok, #{status := cancelled}} =
            soma_cli_task_registry:lookup(TaskId),
        StopOk = request(?config(socket_path, Config), <<"(stop)">>),
        ?assertEqual(match,
                     re:run(StopOk, "\\(status stopped\\)",
                            [{capture, none}])),
        ok = wait_for_process_dead(Server, 100)
    after
        maybe_resume_process(Store),
        case is_process_alive(Server) of
            true -> stop_server(Server);
            false -> ok
        end
    end.

%% Stop and detached admission are serialized in the registry. Hold the stop's
%% durable append, queue a request from an already-accepted second connection,
%% then release the store: stop succeeds and the queued admission is rejected.
test_stop_quiesce_rejects_concurrent_detached_admission(Config) ->
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    ok = wait_for_registry_ready(100),
    Path = ?config(socket_path, Config),
    First = request(
              Path,
              <<"(run (detach) (step hold sleep (args (ms 60000))))">>),
    TaskId = accepted_id(<<"task-id">>, First),
    Store = event_store_pid(),
    Started = wait_for_started_by_session(Store, TaskId, 100),
    RunId = maps:get(run_id, Started),
    ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
    {ok, StopSocket} = connect(Path),
    {ok, StartSocket} = connect(Path),
    %% Let the listener transfer both sockets to their independent handlers
    %% before the stop handler can close the accept loop.
    timer:sleep(250),
    ok = sys:suspend(Store),
    try
        ok = gen_tcp:send(StopSocket, <<"(stop)">>),
        timer:sleep(50),
        ok = gen_tcp:send(
               StartSocket,
               <<"(run (detach) (step late echo "
                 "(args (value \"must-not-run\"))))">>),
        ok = wait_for_queued_detached_start(
               whereis(soma_cli_task_registry), 100),
        ok = sys:resume(Store),
        {ok, StopReply} = gen_tcp:recv(StopSocket, 0, 5000),
        {ok, StartReply} = gen_tcp:recv(StartSocket, 0, 5000),
        ?assertEqual(match,
                     re:run(StopReply, "\\(status stopped\\)",
                            [{capture, none}])),
        ?assertEqual(match,
                     re:run(StartReply, "\\(status error\\)",
                            [{capture, none}])),
        ?assertEqual(nomatch,
                     re:run(StartReply, "^\\(accepted ",
                            [{capture, none}])),
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 100),
        AllTypes = [maps:get(event_type, Event)
                    || Event <- soma_event_store:all(Store)],
        ?assertEqual(1, count(<<"run.started">>, AllTypes)),
        ?assertEqual(1, count(<<"cli.task.cancel_requested">>, AllTypes)),
        ok = gen_tcp:close(StopSocket),
        ok = gen_tcp:close(StartSocket),
        ok = wait_for_process_dead(Server, 100)
    after
        maybe_resume_process(Store),
        _ = gen_tcp:close(StopSocket),
        _ = gen_tcp:close(StartSocket),
        case is_process_alive(Server) of
            true -> stop_server(Server);
            false -> ok
        end
    end.

%% gen_server:call/3 timing out is an explicit loss of authority: the queued
%% stop request must not close admission later merely because the registry is
%% resumed.  A subsequent detached start through the same listener generation
%% remains admissible and cancellable.
test_timed_out_stop_cannot_close_admission_later(Config) ->
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    ok = wait_for_registry_ready(100),
    Registry = whereis(soma_cli_task_registry),
    ok = sys:suspend(Registry),
    try
        TimedOut =
            try soma_cli_task_registry:cancel_all(Server)
            catch
                exit:CancelAllReason -> {'EXIT', CancelAllReason}
            end,
        ?assertMatch({'EXIT', {timeout, _}}, TimedOut),
        ok = sys:resume(Registry),

        %% This synchronous read is ordered behind the expired stop message,
        %% so its reply proves the registry has already discarded that call.
        {error, not_found} =
            soma_cli_task_registry:lookup(<<"__expired_stop_barrier__">>),
        Reply = request(
                  ?config(socket_path, Config),
                  <<"(run (detach) "
                    "(step after_timeout sleep (args (ms 60000))))">>),
        ?assertEqual(match,
                     re:run(Reply, "^\\(accepted ", [{capture, none}])),
        TaskId = accepted_id(<<"task-id">>, Reply),
        Store = event_store_pid(),
        Started = wait_for_started_by_session(Store, TaskId, 100),
        RunId = maps:get(run_id, Started),
        ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
        Cancel = request(
                   ?config(socket_path, Config),
                   <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Cancel, "\\(status cancelled\\)",
                            [{capture, none}])),
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 100)
    after
        maybe_resume_process(Registry),
        stop_server(Server)
    end.

%% Admission rebinding has the same bounded-authority rule as start and stop.
%% A short-lived listener that times out while the registry mailbox is frozen
%% no longer owns a generation. When its late message is dequeued, the registry
%% must neither link to that dead pid nor replace the current listener's tools
%% directory. The surviving listener remains able to admit real detached work.
test_timed_out_open_admission_cannot_rebind_dead_owner(Config) ->
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    ok = wait_for_registry_ready(100),
    Registry = whereis(soma_cli_task_registry),
    PoisonToolsDir = filename:join(
                       ?config(tmp_dir, Config), "expired-listener-tools"),
    ok = file:make_dir(PoisonToolsDir),
    State0 = sys:get_state(Registry),
    OriginalToolsDir = maps:get(tools_dir, State0),
    ?assertEqual(Server, maps:get(admission_owner, State0)),
    Parent = self(),
    ok = sys:suspend(Registry),
    {ExpiredOwner, OwnerMRef} =
        spawn_monitor(
          fun() ->
                  Result =
                      try soma_cli_task_registry:open_admission(
                            self(), PoisonToolsDir)
                      catch
                          exit:OpenReason -> {'EXIT', OpenReason}
                      end,
                  Parent ! {expired_open_admission_result, self(), Result}
          end),
    try
        receive
            {expired_open_admission_result, ExpiredOwner, TimedOut} ->
                ?assertMatch({'EXIT', {timeout, _}}, TimedOut)
        after 6000 ->
            ct:fail(expired_open_admission_did_not_time_out)
        end,
        receive
            {'DOWN', OwnerMRef, process, ExpiredOwner, normal} -> ok
        after 1000 ->
            ct:fail(expired_admission_owner_did_not_exit)
        end,
        ok = sys:resume(Registry),

        %% Ordered behind the expired open request: the old state must still be
        %% authoritative after the late mailbox entry has been discarded.
        {error, not_found} =
            soma_cli_task_registry:lookup(<<"__expired_open_barrier__">>),
        ?assertEqual(Registry, whereis(soma_cli_task_registry)),
        ?assert(is_process_alive(Registry)),
        State1 = sys:get_state(Registry),
        ?assertEqual(Server, maps:get(admission_owner, State1)),
        ?assertEqual(OriginalToolsDir, maps:get(tools_dir, State1)),
        ?assertNotEqual(PoisonToolsDir, maps:get(tools_dir, State1)),

        %% A hot-upgrade mailbox may still contain pre-deadline write forms.
        %% They have no remaining authority and cannot bypass the same rule.
        ?assertEqual(
           {error, request_expired},
           gen_server:call(
             Registry, {open_admission, self(), PoisonToolsDir})),
        ?assertEqual({error, request_expired},
                     gen_server:call(Registry, cancel_all)),
        LegacyTaskId = <<"task-legacy-mailbox-write">>,
        LegacyRunId = <<"run-legacy-mailbox-write">>,
        Store = event_store_pid(),
        ?assertEqual(
           {error, request_expired},
           gen_server:call(
             Registry,
             {start_detached_run,
              LegacyTaskId, <<"corr-legacy-mailbox-write">>, LegacyRunId,
              [#{id => never, tool => echo,
                 args => #{value => <<"must-not-run">>}}], Store, Server})),
        ?assertEqual([], soma_event_store:by_run(Store, LegacyRunId)),
        State2 = sys:get_state(Registry),
        ?assertEqual(Server, maps:get(admission_owner, State2)),
        ?assertEqual(OriginalToolsDir, maps:get(tools_dir, State2)),

        Reply = request(
                  ?config(socket_path, Config),
                  <<"(run (detach) "
                    "(step current_generation echo "
                    "(args (value \"still-open\"))))">>),
        ?assertEqual(match,
                     re:run(Reply, "^\\(accepted ", [{capture, none}])),
        TaskId = accepted_id(<<"task-id">>, Reply),
        Started = wait_for_started_by_session(Store, TaskId, 100),
        RunId = maps:get(run_id, Started),
        ok = wait_for_event(Store, RunId, <<"run.completed">>, 100)
    after
        maybe_resume_process(Registry),
        stop_server(Server)
    end.

%% A successful live rebind must remove both ownership mechanisms for the old
%% listener generation. Killing that still-live old listener afterward cannot
%% deliver a stale link or monitor exit that retires the rebound registry. The
%% new owner remains authoritative and can admit a fully committed fresh run.
test_live_rebind_ignores_old_owner_down(Config) ->
    ok = boot_runtime(Config),
    {ok, OldServer} = start_server(Config),
    ok = wait_for_registry_ready(100),
    Registry = whereis(soma_cli_task_registry),
    Parent = self(),
    NewOwner = spawn(
                 fun() ->
                         Parent ! {new_admission_owner_ready, self()},
                         receive stop -> ok end
                 end),
    receive
        {new_admission_owner_ready, NewOwner} -> ok
    after 1000 ->
        ct:fail(new_admission_owner_did_not_start)
    end,
    try
        ok = soma_cli_task_registry:open_admission(NewOwner),
        State0 = sys:get_state(Registry),
        ?assertEqual(NewOwner, maps:get(admission_owner, State0)),

        unlink(OldServer),
        OldServerMRef = monitor(process, OldServer),
        exit(OldServer, kill),
        receive
            {'DOWN', OldServerMRef, process, OldServer, killed} -> ok
        after 5000 ->
            ct:fail(old_listener_did_not_die)
        end,
        %% Ordered after the old-owner DOWN: stale ownership teardown must have
        %% been ignored, not merely delayed in the registry mailbox.
        {error, not_found} =
            soma_cli_task_registry:lookup(<<"__live_rebind_barrier__">>),
        ?assertEqual(Registry, whereis(soma_cli_task_registry)),
        ?assert(is_process_alive(Registry)),
        State1 = sys:get_state(Registry),
        ?assertEqual(NewOwner, maps:get(admission_owner, State1)),

        Store = event_store_pid(),
        TaskId = <<"task-live-rebound-owner">>,
        CorrId = <<"corr-live-rebound-owner">>,
        RunId = <<"run-live-rebound-owner">>,
        {ok, #{run_id := RunId}} =
            soma_cli_task_registry:start_detached_run(
              TaskId, CorrId, RunId,
              [#{id => rebound, tool => echo,
                 args => #{value => <<"new-owner">>}}],
              Store, NewOwner),
        ok = wait_for_event(Store, RunId, <<"run.completed">>, 100),
        Types = event_types(Store, RunId),
        ?assertEqual(1, count(<<"cli.task.accepted">>, Types)),
        ?assertEqual(1, count(<<"run.admission.committed">>, Types)),
        ?assertEqual(1, count(<<"tool.started">>, Types)),
        ?assertEqual(1, count(<<"run.completed">>, Types))
    after
        NewOwner ! stop,
        case is_process_alive(OldServer) of
            true -> stop_server(OldServer);
            false -> ok
        end
    end.

%% A registry generation owns its asynchronous recovery helpers. A controlled
%% normal close of the current listener must retire the registry and explicitly
%% kill both kinds of blocked helper: the full-trail scan waiting on a suspended
%% store and the start barrier waiting on a suspended run supervisor. Resuming
%% either dependency afterward cannot revive an old-generation process or let
%% its expired queued start cross the journal/effect boundary.
test_controlled_stop_retires_blocked_registry_workers(Config) ->
    ok = boot_runtime(Config),
    Store = event_store_pid(),

    %% Phase one: the registry owns a recovery-scan worker blocked in Store.
    ok = sys:suspend(Store),
    try
        {ok, Server1} = bounded_start_server(Config, 2000),
        try
            Registry1 = whereis(soma_cli_task_registry),
            #{pid := ScanWorker} =
                wait_for_recovery_scan_worker(Registry1, 100),
            ?assert(is_process_alive(ScanWorker)),
            ok = close_current_owner_normally(Server1, Registry1),
            ok = wait_for_process_dead(ScanWorker, 100),
            ?assertEqual(undefined, whereis(soma_cli_task_registry))
        after
            case is_process_alive(Server1) of
                true -> stop_server(Server1);
                false -> ok
            end
        end
    after
        maybe_resume_process(Store)
    end,

    %% Seed one recoverable detached trail into the still-running durable store.
    %% The replacement registry will reach its start barrier while run_sup is
    %% suspended; the old scan worker above must remain dead throughout.
    TaskId = <<"task-controlled-worker-retirement">>,
    CorrId = <<"corr-controlled-worker-retirement">>,
    RunId = <<"run-controlled-worker-retirement">>,
    Step = #{id => never, tool => echo,
             args => #{value => <<"old-generation-must-not-run">>}},
    RunOptions = #{run_id => RunId,
                   task_id => TaskId,
                   session_id => TaskId,
                   correlation_id => CorrId,
                   run_origin => cli_detached,
                   auto_resume => false},
    ok = soma_event_store:append(
           Store,
           #{run_id => RunId,
             session_id => TaskId,
             correlation_id => CorrId,
             event_type => <<"run.started">>,
             payload => #{steps => [Step], run_options => RunOptions}}),

    %% Phase two: the replacement registry owns a barrier probe blocked in
    %% soma_run_sup. Retiring that current owner must reap the probe as well.
    SupPid = whereis(soma_run_sup),
    ok = sys:suspend(SupPid),
    try
        {ok, Server2} = bounded_start_server(Config, 2000),
        try
            Registry2 = whereis(soma_cli_task_registry),
            {ok, Waiting} = wait_for_start_in_doubt(TaskId, 150),
            #{pid := Probe} = maps:get(start_probe, Waiting),
            ?assert(is_process_alive(Probe)),
            ok = close_current_owner_normally(Server2, Registry2),
            ok = wait_for_process_dead(Probe, 100),
            ?assertEqual(undefined, whereis(soma_cli_task_registry)),

            ok = sys:resume(SupPid),
            %% Ordered after the abandoned start and barrier calls. Any queued
            %% child now observes its expired paused-start lease and disappears.
            _ = supervisor:which_children(SupPid),
            ok = wait_for_run_claim_absent(RunId, 100),
            ?assertEqual({error, not_found},
                         soma_run_sup:find_run(RunId, 500)),
            ?assertEqual({error, not_found},
                         soma_run_index:lookup(RunId, 500)),
            Types = event_types(Store, RunId),
            ?assertEqual(1, count(<<"run.started">>, Types)),
            ?assertEqual(0, count(<<"run.resumed">>, Types)),
            ?assertEqual(0, count(<<"step.started">>, Types)),
            ?assertEqual(0, count(<<"tool.started">>, Types))
        after
            case is_process_alive(Server2) of
                true -> stop_server(Server2);
                false -> ok
            end
        end
    after
        maybe_resume_process(SupPid),
        cancel_live_run(RunId)
    end.

%% A detached-start caller that has already timed out cannot leave a write
%% behind in the registry mailbox.  Once that mailbox resumes and the expired
%% request is drained, its chosen identities remain wholly absent from the
%% durable trail, live RunId index, and task projection.
test_timed_out_detached_start_has_no_late_effect(Config) ->
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    ok = wait_for_registry_ready(100),
    Registry = whereis(soma_cli_task_registry),
    Store = event_store_pid(),
    TaskId = <<"task-expired-detached-start">>,
    CorrId = <<"corr-expired-detached-start">>,
    RunId = <<"run-expired-detached-start">>,
    Steps = [#{id => never, tool => echo,
               args => #{value => <<"must-not-run">>}}],
    ok = sys:suspend(Registry),
    try
        TimedOut =
            try soma_cli_task_registry:start_detached_run(
                  TaskId, CorrId, RunId, Steps, Store, Server)
            catch
                exit:StartReason -> {'EXIT', StartReason}
            end,
        ?assertMatch({'EXIT', {timeout, _}}, TimedOut),
        ok = sys:resume(Registry),

        %% Ordered behind the expired start, this proves all possible late
        %% handling has completed before the absence assertions below.
        {error, not_found} =
            soma_cli_task_registry:lookup(<<"__expired_start_barrier__">>),
        timer:sleep(100),
        ?assertEqual([], soma_event_store:by_run(Store, RunId)),
        ?assertEqual([], soma_event_store:by_session(Store, TaskId)),
        ?assertEqual({error, not_found},
                     soma_cli_task_registry:lookup(TaskId)),
        ?assertEqual({error, not_found},
                     soma_run_sup:find_run(RunId, 500)),
        ?assertEqual({error, not_found},
                     soma_run_index:lookup(RunId, 500))
    after
        maybe_resume_process(Registry),
        stop_server(Server)
    end.

%% A fresh child can claim its RunId and then block while durably preparing
%% run.started.  The registry's finite admission request must retire that exact
%% child before replying, even though the event store is still suspended.  If
%% the already-queued append lands later, it remains an unaccepted preparation:
%% recovery rejects and cancels it without an admission commit or effect.
test_timed_out_prepare_retires_claim_and_rejects_late_journal(Config) ->
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    ok = wait_for_registry_ready(100),
    Registry = whereis(soma_cli_task_registry),
    Store = event_store_pid(),
    TaskId = <<"task-expired-prepare">>,
    CorrId = <<"corr-expired-prepare">>,
    RunId = <<"run-expired-prepare">>,
    OutputName = <<"expired-prepare-must-not-exist.txt">>,
    Output = filename:join(?config(tmp_dir, Config),
                           binary_to_list(OutputName)),
    Steps = [#{id => never_write, tool => file_write,
               args => #{path => OutputName,
                         root => ?config(tmp_dir, Config),
                         bytes => <<"must-not-run">>}}],
    Parent = self(),
    ok = sys:suspend(Store),
    try
        {Caller, CallerMRef} =
            spawn_monitor(
              fun() ->
                      StartedAt = erlang:monotonic_time(millisecond),
                      Result = soma_cli_task_registry:start_detached_run(
                                 TaskId, CorrId, RunId, Steps, Store, Server),
                      Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
                      Parent ! {prepare_start_result, self(), Result, Elapsed}
              end),
        RunPid = wait_for_run_claim(RunId, 100),
        ok = wait_for_queued_store_append(
               Store, RunId, <<"run.started">>, 100),
        receive
            {prepare_start_result, Caller,
             {error, {run_start_failed, preparation_unresponsive}}, Elapsed} ->
                ?assert(Elapsed < 4000)
        after 5000 ->
            ct:fail(prepare_start_did_not_return_within_bound)
        end,
        receive
            {'DOWN', CallerMRef, process, Caller, normal} -> ok;
            {'DOWN', CallerMRef, process, Caller, Reason} ->
                ct:fail({prepare_start_caller_failed, Reason})
        after 1000 ->
            ct:fail(prepare_start_caller_did_not_exit)
        end,

        %% These assertions intentionally run while the store remains blocked.
        %% The request reply is therefore proof that cleanup did not depend on
        %% the late run.started append completing.
        ok = wait_for_process_dead(RunPid, 100),
        ok = wait_for_run_claim_absent(RunId, 100),
        ?assertEqual({error, not_found},
                     soma_run_sup:find_run(RunId, 500)),
        ?assertEqual({error, not_found},
                     soma_run_index:lookup(RunId, 500)),
        RegistryState = sys:get_state(Registry),
        ?assertEqual(false,
                     maps:is_key(TaskId, maps:get(tasks, RegistryState))),
        ?assertMatch({error, _}, soma_cli_task_registry:lookup(TaskId)),
        ?assertEqual(false, filelib:is_file(Output)),

        ok = sys:resume(Store),
        ok = wait_for_event(
               Store, RunId, <<"cli.task.admission_rejected">>, 200),
        ok = wait_for_event(Store, RunId, <<"run.cancelled">>, 200),
        Types = event_types(Store, RunId),
        ?assertEqual(1, count(<<"run.started">>, Types)),
        ?assertEqual(1, count(<<"cli.task.admission_rejected">>, Types)),
        ?assertEqual(1, count(<<"run.cancelled">>, Types)),
        ?assertEqual(0, count(<<"cli.task.accepted">>, Types)),
        ?assertEqual(0, count(<<"run.admission.committed">>, Types)),
        ?assertEqual(0, count(<<"run.resumed">>, Types)),
        ?assertEqual(0, count(<<"step.started">>, Types)),
        ?assertEqual(0, count(<<"tool.started">>, Types)),
        ?assertEqual(0, count(<<"step.succeeded">>, Types)),
        ?assertEqual(0, count(<<"run.completed">>, Types)),
        ?assertEqual(false, filelib:is_file(Output)),
        {ok, #{status := cancelled}} =
            soma_cli_task_registry:lookup(TaskId),
        ?assertEqual({error, not_found},
                     soma_run_sup:find_run(RunId, 500)),
        ?assertEqual({error, not_found},
                     soma_run_index:lookup(RunId, 500))
    after
        maybe_resume_process(Store),
        cancel_live_run(RunId),
        stop_server(Server)
    end.

%% The finite runtime-start seam has its own commit-unknown case: the registry
%% accepted a fresh request, but soma_run_sup did not answer before the request
%% lease expired.  A start_child already queued in the suspended supervisor may
%% still run later; its absolute paused-start lease must make it die before the
%% RunId claim, journal, or first tool boundary.
test_timed_out_supervisor_start_leaves_no_claim_or_effect(Config) ->
    ok = boot_runtime(Config),
    {ok, Server} = start_server(Config),
    ok = wait_for_registry_ready(100),
    Store = event_store_pid(),
    TaskId = <<"task-expired-supervisor-start">>,
    CorrId = <<"corr-expired-supervisor-start">>,
    RunId = <<"run-expired-supervisor-start">>,
    Steps = [#{id => never, tool => echo,
               args => #{value => <<"must-not-run">>}}],
    SupPid = whereis(soma_run_sup),
    ok = sys:suspend(SupPid),
    try
        StartedAt = erlang:monotonic_time(millisecond),
        Result = soma_cli_task_registry:start_detached_run(
                   TaskId, CorrId, RunId, Steps, Store, Server),
        Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
        ?assertMatch(
           {error,
            {run_start_failed, {run_supervisor_unresponsive, SupPid}}},
           Result),
        ?assert(Elapsed < 4000),
        ?assertEqual([], soma_event_store:by_run(Store, RunId)),
        ?assertEqual({error, not_found},
                     soma_run_index:lookup(RunId, 500)),

        ok = sys:resume(SupPid),
        %% The supervisor query is queued after the abandoned start request;
        %% once it replies, any late child has initialized (and rejected its
        %% expired lease) before these final absence assertions.
        _ = supervisor:which_children(SupPid),
        ok = wait_for_run_claim_absent(RunId, 100),
        ?assertEqual([], soma_event_store:by_run(Store, RunId)),
        ?assertEqual([], soma_event_store:by_session(Store, TaskId)),
        ?assertEqual({error, not_found},
                     soma_cli_task_registry:lookup(TaskId)),
        ?assertEqual({error, not_found},
                     soma_run_sup:find_run(RunId, 500)),
        ?assertEqual({error, not_found},
                     soma_run_index:lookup(RunId, 500))
    after
        maybe_resume_process(SupPid),
        cancel_live_run(RunId),
        stop_server(Server)
    end.

%% A normal controlled stop retires the old registry generation. The replacement
%% listener must rebuild the projection with, not retain, the old tools_dir.
%% After soma_tool_registry itself restarts, the first detached admission
%% reloads the new directory into the new registry generation and executes the
%% new descriptor.
test_rebound_tools_dir_is_used_after_tool_registry_restart(Config) ->
    TmpDir = ?config(tmp_dir, Config),
    OldRoot = filename:join(TmpDir, "old-tool-generation"),
    NewRoot = filename:join(TmpDir, "new-tool-generation"),
    ok = file:make_dir(OldRoot),
    ok = file:make_dir(NewRoot),
    {OldHelper, OldPidFile} = write_cancel_cli_stub(OldRoot),
    OldToolsDir = write_cancel_cli_manifest(
                    OldRoot, OldHelper, OldPidFile),
    {NewHelper, NewPidFile} = write_cancel_cli_stub(NewRoot),
    NewToolsDir = write_cancel_cli_manifest(
                    NewRoot, NewHelper, NewPidFile),
    ToolName = <<"restart_cli_reader">>,
    ok = boot_runtime(Config),
    {ok, Server1} = start_server(Config, #{tools_dir => OldToolsDir}),
    try
        ok = wait_for_registry_ready(100),
        ok = wait_for_tool_executable(ToolName, OldHelper, 100),
        Registry = whereis(soma_cli_task_registry),

        Stop = request(?config(socket_path, Config), <<"(stop)">>),
        ?assertEqual(match,
                     re:run(Stop, "\\(status stopped\\)",
                            [{capture, none}])),
        ok = wait_for_process_dead(Server1, 100),
        ok = wait_for_process_dead(Registry, 100),
        ?assertEqual(undefined, whereis(soma_cli_task_registry)),

        {ok, Server2} = start_server(
                          Config, #{tools_dir => NewToolsDir}),
        try
            NewRegistry = whereis(soma_cli_task_registry),
            ?assert(is_pid(NewRegistry)),
            ?assertNotEqual(Registry, NewRegistry),
            OldToolRegistry = whereis(soma_tool_registry),
            exit(OldToolRegistry, kill),
            NewToolRegistry = wait_for_new_registered_pid(
                                soma_tool_registry, OldToolRegistry, 100),
            ?assert(is_pid(NewToolRegistry)),

            Reply = request(
                      ?config(socket_path, Config),
                      <<"(run (detach) "
                        "(step rebound restart_cli_reader "
                        "(args (value \"ignored\"))))">>),
            ?assertEqual(match,
                         re:run(Reply, "^\\(accepted ",
                                [{capture, none}])),
            TaskId = accepted_id(<<"task-id">>, Reply),
            Store = event_store_pid(),
            Started = wait_for_started_by_session(Store, TaskId, 100),
            RunId = maps:get(run_id, Started),
            ok = wait_for_event(Store, RunId, <<"tool.started">>, 100),
            NewOsPid = wait_for_cli_os_pid(NewPidFile, 100),
            ?assert(cli_os_process_alive(NewOsPid)),
            ?assertEqual(false, filelib:is_file(OldPidFile)),
            ok = wait_for_tool_executable(ToolName, NewHelper, 100),

            Cancel = request(
                       ?config(socket_path, Config),
                       <<"(cancel \"", TaskId/binary, "\")">>),
            ?assertEqual(match,
                         re:run(Cancel, "\\(status cancelled\\)",
                                [{capture, none}])),
            ok = wait_for_os_process_dead(NewOsPid, 100)
        after
            stop_server(Server2)
        end
    after
        case is_process_alive(Server1) of
            true -> stop_server(Server1);
            false -> ok
        end
    end.

%% Issue #256: if the final step commit is durable but run.completed was lost,
%% there is no action to replay. Registry projection is completed, repeated
%% cancel is a no-op, and rebuilding the registry reaches the same projection
%% without appending an execution or terminal event.
test_nothing_to_do_projection_survives_registry_restart(Config) ->
    TaskId = <<"task-nothing-to-do">>,
    CorrelationId = <<"corr-nothing-to-do">>,
    RunId = <<"run-nothing-to-do">>,
    Step = #{id => done, tool => echo,
             args => #{value => <<"committed">>}},
    StepSucceeded = #{run_id => RunId,
                      session_id => TaskId,
                      correlation_id => CorrelationId,
                      step_id => done,
                      event_type => <<"step.succeeded">>,
                      payload => #{output => #{value => <<"committed">>}}},
    ok = seed_detached_started_log(Config, TaskId, CorrelationId, RunId,
                                   [Step], [StepSucceeded]),
    ok = boot_runtime(Config),
    Store = event_store_pid(),
    BaselineTypes = [maps:get(event_type, Event)
                     || Event <- soma_event_store:by_run(Store, RunId)],
    ?assertEqual([<<"run.started">>, <<"step.succeeded">>], BaselineTypes),
    {ok, Server1} = start_server(Config),
    ?assertEqual(BaselineTypes,
                 [maps:get(event_type, Event)
                  || Event <- soma_event_store:by_run(Store, RunId)]),
    InitialCount = length(BaselineTypes),
    {ok, #{status := completed}} =
        wait_for_registry_status(TaskId, completed, 100),
    crash_server(Server1),

    {ok, Server2} = start_server(Config),
    try
        {ok, #{status := completed}} =
            wait_for_registry_status(TaskId, completed, 100),
        Status = request(?config(socket_path, Config),
                         <<"(status \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Status, "\\(state completed\\)",
                            [{capture, none}])),
        Cancel = request(?config(socket_path, Config),
                         <<"(cancel \"", TaskId/binary, "\")">>),
        ?assertEqual(match,
                     re:run(Cancel, "\\(note already-terminal\\)",
                            [{capture, none}])),
        ?assertEqual(InitialCount,
                     length(soma_event_store:by_run(Store, RunId)))
    after
        stop_server(Server2)
    end.

%% Issue #256: recorded run terminals are the durable source of truth. Registry
%% recovery ignores them; status/cancel fall back to the trail and never start
%% or append work for any terminal class.
test_recorded_terminals_remain_monotonic_after_restart(Config) ->
    Rows = [{completed, <<"run.completed">>},
            {failed, <<"run.failed">>},
            {timeout, <<"run.timeout">>},
            {cancelled, <<"run.cancelled">>}],
    lists:foreach(
      fun({Status, EventType}) ->
              Suffix = atom_to_binary(Status, utf8),
              TaskId = <<"task-terminal-", Suffix/binary>>,
              CorrId = <<"corr-terminal-", Suffix/binary>>,
              RunId = <<"run-terminal-", Suffix/binary>>,
              Step = #{id => hold, tool => sleep, args => #{ms => 1}},
              Terminal = #{run_id => RunId,
                           session_id => TaskId,
                           correlation_id => CorrId,
                           event_type => EventType,
                           payload => #{}},
              ok = seed_detached_started_log(
                     Config, TaskId, CorrId, RunId, [Step], [Terminal])
      end, Rows),
    ok = boot_runtime(Config),
    Store = event_store_pid(),
    lists:foreach(
      fun({Expected, EventType}) ->
              Suffix = atom_to_binary(Expected, utf8),
              RunId = <<"run-terminal-", Suffix/binary>>,
              ?assertEqual(
                 [<<"run.started">>, EventType],
                 [maps:get(event_type, Event)
                  || Event <- soma_event_store:by_run(Store, RunId)]),
              ?assertEqual({error, not_found},
                           soma_run_sup:find_run(RunId, 500))
      end, Rows),
    {ok, Server} = start_server(Config),
    try
        ok = wait_for_registry_ready(100),
        lists:foreach(
          fun({Expected, _EventType}) ->
                  Suffix = atom_to_binary(Expected, utf8),
                  TaskId = <<"task-terminal-", Suffix/binary>>,
                  RunId = <<"run-terminal-", Suffix/binary>>,
                  BeforeTypes = [maps:get(event_type, Event)
                                 || Event <- soma_event_store:by_run(
                                                Store, RunId)],
                  ?assertEqual([<<"run.started">>, _EventType], BeforeTypes),
                  ?assertEqual({error, not_found},
                               soma_cli_task_registry:lookup(TaskId)),
                  StatusReply = request(
                                  ?config(socket_path, Config),
                                  <<"(status \"", TaskId/binary, "\")">>),
                  Pattern = iolist_to_binary(
                              ["\\(state ", atom_to_list(Expected), "\\)"]),
                  ?assertEqual(match,
                               re:run(StatusReply, Pattern,
                                      [{capture, none}])),
                  CancelReply = request(
                                  ?config(socket_path, Config),
                                  <<"(cancel \"", TaskId/binary, "\")">>),
                  ?assertEqual(match,
                               re:run(CancelReply,
                                      "\\(note already-terminal\\)",
                                      [{capture, none}])),
                  ?assertEqual(BeforeTypes,
                               [maps:get(event_type, Event)
                                || Event <- soma_event_store:by_run(
                                               Store, RunId)])
          end, Rows)
    after
        stop_server(Server)
    end.

boot_runtime(Config) ->
    ok = application:set_env(soma_runtime, event_store_log,
                             ?config(log_path, Config)),
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    ok.

start_server(Config) ->
    start_server(Config, #{}).

start_server(Config, Extra) ->
    soma_cli_server:start_link(
      maps:merge(#{socket => ?config(socket_path, Config)}, Extra)).

bounded_start_server(Config, Timeout) ->
    Parent = self(),
    {Pid, MRef} = spawn_monitor(
                    fun() ->
                            Parent ! {self(), start_server(Config)}
                    end),
    receive
        {Pid, Result} ->
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, {starter_down, Reason}}
    after Timeout ->
        exit(Pid, kill),
        erlang:demonitor(MRef, [flush]),
        {error, startup_timeout}
    end.

stop_server(Server) when is_pid(Server) ->
    unlink(Server),
    Ref = monitor(process, Server),
    exit(Server, shutdown),
    receive
        {'DOWN', Ref, process, Server, _Reason} -> ok
    after 5000 ->
        error(server_stop_timeout)
    end.

crash_server(Server) ->
    Registry = whereis(soma_cli_task_registry),
    true = is_pid(Registry),
    unlink(Server),
    ServerRef = monitor(process, Server),
    RegistryRef = monitor(process, Registry),
    exit(Server, kill),
    receive
        {'DOWN', ServerRef, process, Server, killed} -> ok
    after 5000 ->
        error(server_crash_timeout)
    end,
    receive
        {'DOWN', RegistryRef, process, Registry, _Reason} -> ok
    after 5000 ->
        error(registry_crash_timeout)
    end.

stop_task_registry() ->
    case whereis(soma_cli_task_registry) of
        undefined -> ok;
        Pid ->
            unlink(Pid),
            Ref = monitor(process, Pid),
            exit(Pid, shutdown),
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            after 5000 ->
                error(task_registry_stop_timeout)
            end
    end.

seed_detached_started_log(Config, TaskId, CorrelationId, RunId,
                          Steps, ExtraEvents) ->
    RunOptions = #{run_id => RunId,
                   task_id => TaskId,
                   session_id => TaskId,
                   correlation_id => CorrelationId,
                   run_origin => cli_detached,
                   auto_resume => false},
    seed_started_log(Config, TaskId, CorrelationId, RunId, Steps,
                     RunOptions, ExtraEvents).

seed_started_log(Config, TaskId, CorrelationId, RunId, Steps,
                 RunOptions, ExtraEvents) ->
    {ok, Store} = soma_event_store:start_link(
                    #{log => ?config(log_path, Config)}),
    ok = soma_event_store:append(
           Store,
           #{run_id => RunId,
             session_id => TaskId,
             correlation_id => CorrelationId,
             event_type => <<"run.started">>,
             payload => #{steps => Steps, run_options => RunOptions}}),
    lists:foreach(fun(Event) -> ok = soma_event_store:append(Store, Event) end,
                  ExtraEvents),
    stop_store(Store).

stop_store(Store) ->
    Ref = monitor(process, Store),
    ok = gen_server:stop(Store),
    receive
        {'DOWN', Ref, process, Store, _Reason} -> ok
    after 5000 ->
        error(store_stop_timeout)
    end.

request(Path, Bytes) ->
    {ok, Socket} = connect(Path),
    ok = gen_tcp:send(Socket, Bytes),
    {ok, Reply} = gen_tcp:recv(Socket, 0, 5000),
    ok = gen_tcp:close(Socket),
    Reply.

connect(Path) ->
    gen_tcp:connect({local, Path}, 0,
                    [binary, {packet, 4}, {active, false}], 5000).

accepted_id(Field, Reply) ->
    Pattern = <<"\\(", Field/binary, " \\\"([^\\\"]+)\\\"\\)">>,
    {match, [Value]} = re:run(Reply, Pattern,
                              [{capture, all_but_first, binary}]),
    Value.

admission_in_doubt_ids(Reply) ->
    ?assertEqual(match,
                 re:run(Reply, "\\(status error\\)",
                        [{capture, none}])),
    ?assertEqual(match,
                 re:run(Reply, "\\(error admission-in-doubt\\)",
                        [{capture, none}])),
    ?assertEqual(nomatch,
                 re:run(Reply, "\\(accepted ", [{capture, none}])),
    {accepted_id(<<"task-id">>, Reply),
     accepted_id(<<"correlation-id">>, Reply),
     accepted_id(<<"run-id">>, Reply)}.

install_admission_store_gate(Store, Mode)
  when Mode =:= acceptance_read; Mode =:= activation_commit ->
    Token = make_ref(),
    Name = case Mode of
               acceptance_read -> admission_acceptance_store_gate;
               activation_commit -> admission_activation_store_gate
           end,
    ok = sys:install(
           Store,
           {Name, fun admission_store_gate/3,
            #{observer => self(), token => Token, mode => Mode,
              done => false}}),
    #{store => Store, name => Name, token => Token, mode => Mode}.

admission_store_gate(
  State = #{mode := acceptance_read, done := false},
  {in, {'$gen_call', _From, {by_run, RunId}}}, _ProcessState) ->
    block_admission_store_gate(State, RunId);
admission_store_gate(
  State = #{mode := activation_commit, done := false},
  {in, {'$gen_call', _From,
        {append, #{event_type := <<"run.admission.committed">>,
                   run_id := RunId}}}}, _ProcessState) ->
    block_admission_store_gate(State, RunId);
admission_store_gate(State, _Event, _ProcessState) ->
    State.

block_admission_store_gate(
  State = #{observer := Observer, token := Token, mode := Mode}, RunId) ->
    Observer ! {admission_store_gate_blocked, Token, Mode, RunId},
    receive
        {release_admission_store_gate, Token} ->
            State#{done => true}
    after 10000 ->
            State#{done => true}
    end.

wait_for_admission_store_gate(#{token := Token}, Timeout) ->
    receive
        {admission_store_gate_blocked, Token, Mode, RunId} ->
            {Mode, RunId}
    after Timeout ->
        ct:fail(admission_store_gate_did_not_block)
    end.

release_admission_store_gate(#{store := Store, token := Token}) ->
    Store ! {release_admission_store_gate, Token},
    ok.

remove_admission_store_gate(#{store := Store, name := Name}) ->
    case is_process_alive(Store) of
        true ->
            _ = try sys:remove(Store, Name)
                catch
                    _:_ -> ok
                end,
            ok;
        false ->
            ok
    end.

wait_for_started_by_session(_Store, _TaskId, 0) ->
    error(run_started_timeout);
wait_for_started_by_session(Store, TaskId, Attempts) ->
    case [Event || Event <- soma_event_store:by_session(Store, TaskId),
                   maps:get(event_type, Event) =:= <<"run.started">>] of
        [Started | _] -> Started;
        [] ->
            timer:sleep(20),
            wait_for_started_by_session(Store, TaskId, Attempts - 1)
    end.

wait_for_event(_Store, _RunId, _Type, 0) ->
    error(event_timeout);
wait_for_event(Store, RunId, Type, Attempts) ->
    case lists:any(
           fun(Event) -> maps:get(event_type, Event) =:= Type end,
           soma_event_store:by_run(Store, RunId)) of
        true -> ok;
        false ->
            timer:sleep(20),
            wait_for_event(Store, RunId, Type, Attempts - 1)
    end.

wait_for_event_count(_Store, _RunId, _Type, _Expected, 0) ->
    error(event_count_timeout);
wait_for_event_count(Store, RunId, Type, Expected, Attempts) ->
    Count = count(Type,
                  [maps:get(event_type, Event)
                   || Event <- soma_event_store:by_run(Store, RunId)]),
    case Count >= Expected of
        true -> ok;
        false ->
            timer:sleep(20),
            wait_for_event_count(Store, RunId, Type, Expected, Attempts - 1)
    end.

tool_call_pid(Store, RunId) ->
    [Pid | _] = [maps:get(tool_call_pid, Event)
                 || Event <- soma_event_store:by_run(Store, RunId),
                    maps:get(event_type, Event) =:= <<"tool.started">>,
                    maps:is_key(tool_call_pid, Event)],
    Pid.

latest_tool_call_pid(Store, RunId) ->
    lists:last(
      [maps:get(tool_call_pid, Event)
       || Event <- soma_event_store:by_run(Store, RunId),
          maps:get(event_type, Event) =:= <<"tool.started">>,
          maps:is_key(tool_call_pid, Event)]).

latest_event(Store, RunId, Type) ->
    lists:last(
      [Event || Event <- soma_event_store:by_run(Store, RunId),
                maps:get(event_type, Event) =:= Type]).

event_types(Store, RunId) ->
    [maps:get(event_type, Event)
     || Event <- soma_event_store:by_run(Store, RunId)].

live_run_pid(RunId) ->
    {ok, RunPid} = soma_run_sup:find_run(RunId),
    RunPid.

active_run_pids() ->
    [Pid || {_ChildId, Pid, worker, [soma_run]} <-
                supervisor:which_children(soma_run_sup),
            is_pid(Pid)].

wait_for_registry_run(_TaskId, 0) ->
    error(registry_run_timeout);
wait_for_registry_run(TaskId, Attempts) ->
    case soma_cli_task_registry:lookup(TaskId) of
        {ok, #{status := running, pid := Pid} = Task} when is_pid(Pid) ->
            {ok, Task};
        _NotOwnedYet ->
            timer:sleep(20),
            wait_for_registry_run(TaskId, Attempts - 1)
    end.

wait_for_registry_ready(0) ->
    error(registry_recovery_scan_timeout);
wait_for_registry_ready(Attempts) ->
    case soma_cli_task_registry:lookup(<<"__recovery_probe__">>) of
        {error, recovery_incomplete} ->
            timer:sleep(20),
            wait_for_registry_ready(Attempts - 1);
        _AuthoritativeProjection ->
            ok
    end.

wait_for_recovery_scan_worker(_Registry, 0) ->
    error(recovery_scan_worker_timeout);
wait_for_recovery_scan_worker(Registry, Attempts) ->
    case maps:get(recovery_scan_worker,
                  sys:get_state(Registry), undefined) of
        #{pid := Worker} = Owned when is_pid(Worker) ->
            Owned;
        _NotStartedYet ->
            timer:sleep(20),
            wait_for_recovery_scan_worker(Registry, Attempts - 1)
    end.

close_current_owner_normally(Server, Registry) ->
    State = sys:get_state(Registry),
    ?assertEqual(Server, maps:get(admission_owner, State)),
    unlink(Server),
    ServerMRef = monitor(process, Server),
    RegistryMRef = monitor(process, Registry),
    Server ! close_listen,
    receive
        {'DOWN', ServerMRef, process, Server, normal} -> ok;
        {'DOWN', ServerMRef, process, Server, Reason} ->
            ct:fail({listener_did_not_stop_normally, Reason})
    after 5000 ->
        ct:fail(listener_normal_stop_timeout)
    end,
    receive
        {'DOWN', RegistryMRef, process, Registry, normal} -> ok;
        {'DOWN', RegistryMRef, process, Registry, Reason2} ->
            ct:fail({registry_did_not_stop_normally, Reason2})
    after 5000 ->
        ct:fail(registry_normal_stop_timeout)
    end.

wait_for_start_in_doubt(_TaskId, 0) ->
    error(start_in_doubt_timeout);
wait_for_start_in_doubt(TaskId, Attempts) ->
    case soma_cli_task_registry:lookup(TaskId) of
        {ok, #{start_in_doubt := SupPid,
               start_probe := #{pid := Probe}} = Task}
          when is_pid(SupPid), is_pid(Probe) ->
            {ok, Task};
        _ ->
            timer:sleep(20),
            wait_for_start_in_doubt(TaskId, Attempts - 1)
    end.

wait_for_registry_status(_TaskId, _Expected, 0) ->
    error(registry_status_timeout);
wait_for_registry_status(TaskId, Expected, Attempts) ->
    case soma_cli_task_registry:lookup(TaskId) of
        {ok, #{status := Expected} = Task} -> {ok, Task};
        _ ->
            timer:sleep(20),
            wait_for_registry_status(TaskId, Expected, Attempts - 1)
    end.

wait_for_new_registered_pid(_Name, _OldPid, 0) ->
    error(registered_process_restart_timeout);
wait_for_new_registered_pid(Name, OldPid, Attempts) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= OldPid -> Pid;
        _ ->
            timer:sleep(20),
            wait_for_new_registered_pid(Name, OldPid, Attempts - 1)
    end.

wait_for_tool_executable(_Name, _Expected, 0) ->
    error(configured_tool_reload_timeout);
wait_for_tool_executable(Name, Expected, Attempts) ->
    ExpectedBin = unicode:characters_to_binary(Expected),
    case soma_tool_registry:resolve_descriptor(Name) of
        {ok, #{executable := ExpectedBin}} ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_tool_executable(Name, Expected, Attempts - 1)
    end.

wait_for_queued_detached_start(_Registry, 0) ->
    error(detached_start_was_not_queued);
wait_for_queued_detached_start(Registry, Attempts) ->
    {messages, Messages} = process_info(Registry, messages),
    case lists:any(
           fun({'$gen_call', _From,
                {start_detached_run, _ReqId, _Deadline,
                 _TaskId, _CorrId, _RunId, _Steps, _Store, _Owner}}) -> true;
              ({'$gen_call', _From,
                {start_detached_run, _TaskId, _CorrId, _RunId,
                 _Steps, _Store, _Owner}}) -> true;
              (_Message) -> false
           end, Messages) of
        true -> ok;
        false ->
            timer:sleep(5),
            wait_for_queued_detached_start(Registry, Attempts - 1)
    end.

wait_for_queued_store_append(_Store, _RunId, _Type, 0) ->
    error(event_store_append_was_not_queued);
wait_for_queued_store_append(Store, RunId, Type, Attempts) ->
    {messages, Messages} = process_info(Store, messages),
    case lists:any(
           fun({'$gen_call', _From,
                {append, Event}}) ->
                   maps:get(run_id, Event, undefined) =:= RunId
                       andalso maps:get(event_type, Event, undefined) =:= Type;
              (_Message) -> false
           end, Messages) of
        true -> ok;
        false ->
            timer:sleep(5),
            wait_for_queued_store_append(
              Store, RunId, Type, Attempts - 1)
    end.

wait_for_queued_store_all(_Store, 0) ->
    error(event_store_scan_was_not_queued);
wait_for_queued_store_all(Store, Attempts) ->
    {messages, Messages} = process_info(Store, messages),
    case lists:any(
           fun({'$gen_call', _From, all}) -> true;
              (_Message) -> false
           end, Messages) of
        true -> ok;
        false ->
            timer:sleep(5),
            wait_for_queued_store_all(Store, Attempts - 1)
    end.

cancel_live_run(RunId) ->
    case soma_run_sup:find_run(RunId, 100) of
        {ok, RunPid} -> RunPid ! cancel;
        _ -> ok
    end.

wait_for_run_claim(_RunId, 0) ->
    error(run_claim_not_observed);
wait_for_run_claim(RunId, Attempts) ->
    case soma_run_index:lookup(RunId, 100) of
        {ok, RunPid} when is_pid(RunPid) ->
            RunPid;
        _ ->
            timer:sleep(20),
            wait_for_run_claim(RunId, Attempts - 1)
    end.

wait_for_run_claim_absent(_RunId, 0) ->
    error(run_claim_still_live);
wait_for_run_claim_absent(RunId, Attempts) ->
    case soma_run_index:lookup(RunId, 100) of
        {error, not_found} ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_run_claim_absent(RunId, Attempts - 1)
    end.

maybe_resume_run(RunPid) ->
    try sys:resume(RunPid) of
        ok -> ok
    catch
        exit:_Reason -> ok
    end.

maybe_resume_process(Pid) ->
    maybe_resume_run(Pid).

wait_for_process_dead(_Pid, 0) ->
    error(process_still_alive);
wait_for_process_dead(Pid, Attempts) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            timer:sleep(20),
            wait_for_process_dead(Pid, Attempts - 1)
    end.

write_cancel_cli_stub(TmpDir) ->
    Helper = filename:join(TmpDir, "restart-cli.sh"),
    PidFile = filename:join(TmpDir, "restart-cli.pid"),
    Script = <<"#!/bin/sh\n"
               "printf '%s\\n' \"$$\" > \"$1\"\n"
               "exec sleep 30\n">>,
    ok = file:write_file(Helper, Script),
    ok = file:change_mode(Helper, 8#755),
    {Helper, PidFile}.

write_cancel_cli_manifest(TmpDir, Helper, PidFile) ->
    ToolsDir = filename:join(TmpDir, "tools"),
    ok = file:make_dir(ToolsDir),
    Source = iolist_to_binary(
               ["(tool\n",
                "  (name \"restart_cli_reader\")\n",
                "  (effect reader)\n",
                "  (idempotent true)\n",
                "  (timeout-ms 60000)\n",
                "  (adapter cli)\n",
                "  (executable ",
                soma_lisp:render(unicode:characters_to_binary(Helper)),
                ")\n",
                "  (argv ",
                soma_lisp:render(unicode:characters_to_binary(PidFile)),
                "))\n"]),
    ok = file:write_file(
           filename:join(ToolsDir, "restart_cli_reader.lisp"), Source),
    ToolsDir.

wait_for_cli_os_pid(_PidFile, 0) ->
    error(cli_stub_did_not_write_os_pid);
wait_for_cli_os_pid(PidFile, Attempts) ->
    case file:read_file(PidFile) of
        {ok, Bytes} when byte_size(Bytes) > 0 ->
            list_to_integer(string:trim(binary_to_list(Bytes)));
        {ok, _Empty} ->
            timer:sleep(20),
            wait_for_cli_os_pid(PidFile, Attempts - 1);
        {error, enoent} ->
            timer:sleep(20),
            wait_for_cli_os_pid(PidFile, Attempts - 1)
    end.

wait_for_os_process_dead(_OsPid, 0) ->
    error(os_process_still_alive);
wait_for_os_process_dead(OsPid, Attempts) ->
    case cli_os_process_alive(OsPid) of
        false -> ok;
        true ->
            timer:sleep(20),
            wait_for_os_process_dead(OsPid, Attempts - 1)
    end.

cli_os_process_alive(OsPid) ->
    Kill = os:find_executable("kill"),
    Port = open_port(
             {spawn_executable, Kill},
             [{args, ["-0", integer_to_list(OsPid)]},
              exit_status, binary, use_stdio, stderr_to_stdout]),
    cli_os_process_probe_result(Port).

cli_os_process_probe_result(Port) ->
    receive
        {Port, {data, _Bytes}} ->
            cli_os_process_probe_result(Port);
        {Port, {exit_status, 0}} ->
            true;
        {Port, {exit_status, _NonZero}} ->
            false
    after 1000 ->
        erlang:port_close(Port),
        error(os_process_probe_timeout)
    end.

count(Value, Values) ->
    length([Found || Found <- Values, Found =:= Value]).

%% by_run/2 is oldest-first. Event ids are opaque correlation tokens, so every
%% causal-order proof indexes this append-ordered list instead of comparing id
%% binaries lexically.
event_position(Target, Events) ->
    event_position(Target, Events, 1).

event_position(Target, [Event | _Rest], Position) when Event =:= Target ->
    Position;
event_position(Target, [_Event | Rest], Position) ->
    event_position(Target, Rest, Position + 1);
event_position(_Target, [], _Position) ->
    error(event_not_found).

ordered_event_types([], _Events) ->
    [];
ordered_event_types(Expected, Events) ->
    Types = [maps:get(event_type, Event) || Event <- Events],
    ordered_types(Expected, Types).

ordered_types([], _Types) ->
    [];
ordered_types([Expected | Rest], Types) ->
    case lists:dropwhile(fun(Type) -> Type =/= Expected end, Types) of
        [Expected | Tail] -> [Expected | ordered_types(Rest, Tail)];
        [] -> []
    end.

event_store_pid() ->
    {soma_event_store, Pid, _Type, _Modules} =
        lists:keyfind(soma_event_store, 1,
                      supervisor:which_children(soma_sup)),
    Pid.

make_tmp_dir() ->
    Unique = erlang:integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(
            "/tmp", "soma_cli_resume_" ++ os:getpid() ++ "_" ++ Unique),
    ok = file:make_dir(Dir),
    Dir.

del_tmp_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:foreach(
              fun(Name) ->
                      Path = filename:join(Dir, Name),
                      case filelib:is_dir(Path) of
                          true -> ok = del_tmp_dir(Path);
                          false -> ok = file:delete(Path)
                      end
              end, Names),
            file:del_dir(Dir);
        {error, enoent} ->
            ok
    end.
