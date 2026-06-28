-module(soma_run_resume_plan_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_between_steps_resumes_with_pending_suffix_outputs_and_options/1]).
-export([test_in_flight_safe_step_resumes/1]).
-export([test_in_flight_unsafe_state_step_is_unsafe/1]).
-export([test_terminal_trail_returns_terminal_status_over_next_step/1]).
-export([test_all_committed_no_terminal_is_nothing_to_do/1]).
-export([test_propagates_reconstruct_errors/1]).
-export([test_plan_is_read_only/1]).
-export([test_resume_payload_has_four_seam_fields/1]).

all() ->
    [test_between_steps_resumes_with_pending_suffix_outputs_and_options,
     test_in_flight_safe_step_resumes,
     test_in_flight_unsafe_state_step_is_unsafe,
     test_terminal_trail_returns_terminal_status_over_next_step,
     test_all_committed_no_terminal_is_nothing_to_do,
     test_propagates_reconstruct_errors,
     test_plan_is_read_only,
     test_resume_payload_has_four_seam_fields].

init_per_testcase(_Case, Config) ->
    application:unset_env(soma_runtime, event_store_log),
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    application:unset_env(soma_runtime, event_store_log),
    ok.

test_between_steps_resumes_with_pending_suffix_outputs_and_options(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-plan-between-steps-1">>,
    SessionId = <<"sess-plan-between-steps-1">>,
    S1 = #{id => s1, tool => echo, args => #{value => <<"committed">>}},
    S2 = #{id => s2, tool => echo, args => #{value => <<"pending">>}},
    Steps = [S1, S2],
    RunOptions = #{run_id => RunId, session_id => SessionId},
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => RunOptions}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s1,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"committed">>}}}),

    Verdict = soma_run_resume_plan:plan(StorePid, RunId),

    ?assertMatch({resume, _}, Verdict),
    {resume, P} = Verdict,
    ?assertEqual([S2], maps:get(pending, P, missing)),
    ?assertEqual(Steps, maps:get(steps, P, missing)),
    ?assertEqual(#{s1 => #{value => <<"committed">>}},
                 maps:get(outputs, P, missing)),
    ?assertEqual(RunOptions, maps:get(run_options, P, missing)).

test_in_flight_safe_step_resumes(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-plan-in-flight-safe-1">>,
    SessionId = <<"sess-plan-in-flight-safe-1">>,
    %% next_step uses file_read, a reader/idempotent tool: re-running it is safe.
    S1 = #{id => s1, tool => file_read, args => #{path => <<"x.txt">>}},
    Steps = [S1],
    RunOptions = #{run_id => RunId, session_id => SessionId},
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => RunOptions}}),
    %% the step is in flight: a tool.started landed but no step.succeeded.
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s1,
                                   event_type => <<"tool.started">>,
                                   payload => #{}}),

    Verdict = soma_run_resume_plan:plan(StorePid, RunId),

    ?assertMatch({resume, _}, Verdict).

test_in_flight_unsafe_state_step_is_unsafe(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-plan-in-flight-unsafe-1">>,
    SessionId = <<"sess-plan-in-flight-unsafe-1">>,
    %% next_step uses file_write, a state/non-idempotent tool: re-running it
    %% could repeat an irreversible write, so it must never resume.
    S1 = #{id => s1,
           tool => file_write,
           args => #{path => <<"x.txt">>, content => <<"data">>}},
    Steps = [S1],
    RunOptions = #{run_id => RunId, session_id => SessionId},
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => RunOptions}}),
    %% the step is in flight: a tool.started landed but no step.succeeded.
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s1,
                                   event_type => <<"tool.started">>,
                                   payload => #{}}),

    Verdict = soma_run_resume_plan:plan(StorePid, RunId),

    ?assertEqual({unsafe, s1}, Verdict),
    ?assertNotMatch({resume, _}, Verdict).

test_terminal_trail_returns_terminal_status_over_next_step(_Config) ->
    StorePid = event_store_pid(),
    %% A run that failed mid-step: s1 committed, s2 uncommitted (so next_step is
    %% s2), but a terminal run.failed is on the trail. Terminal wins over the
    %% uncommitted next_step.
    FailedRunId = <<"run-plan-terminal-failed-1">>,
    FailedSessionId = <<"sess-plan-terminal-failed-1">>,
    S1 = #{id => s1, tool => echo, args => #{value => <<"committed">>}},
    S2 = #{id => s2, tool => echo, args => #{value => <<"pending">>}},
    Steps = [S1, S2],
    FailedRunOptions = #{run_id => FailedRunId, session_id => FailedSessionId},
    ok = soma_event_store:append(StorePid,
                                 #{run_id => FailedRunId,
                                   session_id => FailedSessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => FailedRunOptions}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => FailedRunId,
                                   session_id => FailedSessionId,
                                   step_id => s1,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"committed">>}}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => FailedRunId,
                                   session_id => FailedSessionId,
                                   event_type => <<"run.failed">>,
                                   payload => #{}}),

    FailedVerdict = soma_run_resume_plan:plan(StorePid, FailedRunId),

    ?assertEqual({terminal, failed}, FailedVerdict),
    ?assertNotMatch({resume, _}, FailedVerdict),

    %% A run.completed trail maps to {terminal, completed}.
    CompletedRunId = <<"run-plan-terminal-completed-1">>,
    CompletedSessionId = <<"sess-plan-terminal-completed-1">>,
    CompletedRunOptions = #{run_id => CompletedRunId,
                            session_id => CompletedSessionId},
    ok = soma_event_store:append(StorePid,
                                 #{run_id => CompletedRunId,
                                   session_id => CompletedSessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => CompletedRunOptions}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => CompletedRunId,
                                   session_id => CompletedSessionId,
                                   step_id => s1,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"committed">>}}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => CompletedRunId,
                                   session_id => CompletedSessionId,
                                   event_type => <<"run.completed">>,
                                   payload => #{}}),

    CompletedVerdict = soma_run_resume_plan:plan(StorePid, CompletedRunId),

    ?assertEqual({terminal, completed}, CompletedVerdict).

test_all_committed_no_terminal_is_nothing_to_do(_Config) ->
    StorePid = event_store_pid(),
    %% A single-step run where the only journaled step is committed and no
    %% terminal event landed: reconstruct returns next_step => undefined, so
    %% there is nothing left to resume.
    RunId = <<"run-plan-all-committed-1">>,
    SessionId = <<"sess-plan-all-committed-1">>,
    S1 = #{id => s1, tool => echo, args => #{value => <<"committed">>}},
    Steps = [S1],
    RunOptions = #{run_id => RunId, session_id => SessionId},
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => RunOptions}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s1,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"committed">>}}}),

    Verdict = soma_run_resume_plan:plan(StorePid, RunId),

    ?assertEqual(nothing_to_do, Verdict),
    ?assertNotMatch({resume, _}, Verdict).

test_propagates_reconstruct_errors(_Config) ->
    StorePid = event_store_pid(),

    %% A trail with no usable run.started journal: reconstruct's
    %% {error, no_run_started_journal} comes straight back through plan.
    NoJournalRunId = <<"run-plan-no-journal-1">>,
    NoJournalSessionId = <<"sess-plan-no-journal-1">>,
    ok = soma_event_store:append(StorePid,
                                 #{run_id => NoJournalRunId,
                                   session_id => NoJournalSessionId,
                                   step_id => s1,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"orphan">>}}}),

    NoJournalVerdict = soma_run_resume_plan:plan(StorePid, NoJournalRunId),

    ?assertEqual({error, no_run_started_journal}, NoJournalVerdict),

    %% A trail that commits a step the journal never declared: reconstruct's
    %% {error, {unknown_committed_step, StepId}} comes straight back.
    UnknownRunId = <<"run-plan-unknown-committed-1">>,
    UnknownSessionId = <<"sess-plan-unknown-committed-1">>,
    S1 = #{id => s1, tool => echo, args => #{value => <<"declared">>}},
    Steps = [S1],
    RunOptions = #{run_id => UnknownRunId, session_id => UnknownSessionId},
    ok = soma_event_store:append(StorePid,
                                 #{run_id => UnknownRunId,
                                   session_id => UnknownSessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => RunOptions}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => UnknownRunId,
                                   session_id => UnknownSessionId,
                                   step_id => s_undeclared,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"ghost">>}}}),

    UnknownVerdict = soma_run_resume_plan:plan(StorePid, UnknownRunId),

    ?assertEqual({error, {unknown_committed_step, s_undeclared}}, UnknownVerdict).

test_plan_is_read_only(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => echo,
               args => #{value => <<"read only plan">>}}],

    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),

    EventsBefore = soma_event_store:all(StorePid),
    CountBefore = supervisor:count_children(soma_run_sup),
    _Verdict = soma_run_resume_plan:plan(StorePid, RunId),
    EventsAfter = soma_event_store:all(StorePid),
    CountAfter = supervisor:count_children(soma_run_sup),

    %% plan is read-only: it appends no events (byte-for-byte unchanged) and
    %% starts no run child (the soma_run_sup child tally is unchanged).
    ?assertEqual(EventsBefore, EventsAfter),
    ?assertEqual(CountBefore, CountAfter).

%% Criterion 8: the resume payload carries exactly the four fields the v0.7.2
%% seam consumes -- steps, pending, outputs, run_options -- so the executor can
%% hand it straight to soma_run:start_link/1 without re-deriving anything. Seed a
%% between-steps trail ([s1, s2], s1 committed, s2 pending, no tool.started for
%% s2), take the {resume, P} verdict, assert P's key set is exactly those four,
%% then map the four payload fields plus run_id/event_store onto resume opts and
%% start a run that must reach run.completed.
test_resume_payload_has_four_seam_fields(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-plan-seam-payload-1">>,
    SessionId = <<"sess-plan-seam-payload-1">>,
    S1 = #{id => s1, tool => echo, args => #{value => <<"committed">>}},
    S2 = #{id => s2, tool => echo, args => #{value => <<"pending">>}},
    Steps = [S1, S2],
    RunOptions = #{run_id => RunId, session_id => SessionId},
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => RunOptions}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s1,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"committed">>}}}),

    {resume, P} = soma_run_resume_plan:plan(StorePid, RunId),

    %% the payload carries exactly the four fields the seam consumes
    ?assertEqual([outputs, pending, run_options, steps],
                 lists:sort(maps:keys(P))),

    %% the seam consumes the payload straight: map its four fields plus
    %% run_id/event_store onto resume opts and the resumed run reaches completed.
    {ok, _RunPid} =
        soma_run:start_link(#{run_id => RunId,
                              event_store => StorePid,
                              steps => maps:get(steps, P),
                              pending => maps:get(pending, P),
                              outputs => maps:get(outputs, P)}),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Types = [maps:get(event_type, E)
             || E <- soma_event_store:by_run(StorePid, RunId)],
    ?assert(lists:member(<<"run.completed">>, Types)),
    ?assertNot(lists:member(<<"run.failed">>, Types)).

wait_for_run_completed(_StorePid, _RunId, 0) ->
    {error, timeout};
wait_for_run_completed(StorePid, RunId, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    case lists:any(fun(E) ->
                           maps:get(event_type, E, undefined) =:= <<"run.completed">>
                   end, Events) of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_for_run_completed(StorePid, RunId, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
