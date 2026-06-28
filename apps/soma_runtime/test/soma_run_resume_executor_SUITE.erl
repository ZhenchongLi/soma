-module(soma_run_resume_executor_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_between_steps_resume_starts_fresh_child_that_completes/1]).
-export([test_between_steps_resume_sends_owner_completed_with_merged_outputs/1]).
-export([test_in_flight_safe_step_reruns_in_own_worker_and_completes/1]).
-export([test_unsafe_in_flight_resume_starts_no_run/1]).
-export([test_unsafe_resume_appends_run_failed_with_resume_unsafe_reason/1]).
-export([test_after_unsafe_resume_reconstruct_reports_failed/1]).
-export([test_second_resume_of_unsafe_failed_run_is_terminal_noop/1]).
-export([test_resume_of_terminal_run_is_noop/1]).
-export([test_resume_of_fully_committed_run_is_nothing_to_do_noop/1]).
-export([test_resume_of_unreconstructable_trail_returns_error_noop/1]).

all() ->
    [test_between_steps_resume_starts_fresh_child_that_completes,
     test_between_steps_resume_sends_owner_completed_with_merged_outputs,
     test_in_flight_safe_step_reruns_in_own_worker_and_completes,
     test_unsafe_in_flight_resume_starts_no_run,
     test_unsafe_resume_appends_run_failed_with_resume_unsafe_reason,
     test_after_unsafe_resume_reconstruct_reports_failed,
     test_second_resume_of_unsafe_failed_run_is_terminal_noop,
     test_resume_of_terminal_run_is_noop,
     test_resume_of_fully_committed_run_is_nothing_to_do_noop,
     test_resume_of_unreconstructable_trail_returns_error_noop].

init_per_testcase(_Case, Config) ->
    application:unset_env(soma_runtime, event_store_log),
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    application:unset_env(soma_runtime, event_store_log),
    ok.

%% Criterion 1: resume/3 on a run interrupted between steps starts a NEW
%% soma_run child under soma_run_sup -- a distinct pid from any prior run -- that
%% continues from next_step and reaches run.completed. Seed a between-steps trail
%% ([s1, s2], s1 committed via step.succeeded, s2 pending, no tool.started), call
%% resume/3, and assert: {ok, RunPid} where RunPid is a live child of
%% soma_run_sup, and the run reaches run.completed without failing.
test_between_steps_resume_starts_fresh_child_that_completes(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-exec-between-steps-1">>,
    SessionId = <<"sess-exec-between-steps-1">>,
    Owner = self(),
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

    Result = soma_run_resume_executor:resume(RunId, Owner, StorePid),

    ?assertMatch({ok, _RunPid}, Result),
    {ok, RunPid} = Result,
    ?assert(is_pid(RunPid)),

    %% RunPid is a fresh child of soma_run_sup.
    ChildPids = [P || {_Id, P, _Type, _Mods}
                          <- supervisor:which_children(soma_run_sup),
                      is_pid(P)],
    ?assert(lists:member(RunPid, ChildPids)),

    %% the resumed run continues from next_step and reaches run.completed.
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Types = [maps:get(event_type, E)
             || E <- soma_event_store:by_run(StorePid, RunId)],
    ?assert(lists:member(<<"run.completed">>, Types)),
    ?assertNot(lists:member(<<"run.failed">>, Types)).

%% Criterion 2: on a between-steps resume, Owner (the run's session_pid) receives
%% a {run_completed, RunId, Outputs} message whose Outputs map holds BOTH the
%% seeded committed step's output (s1) AND the freshly-run pending step's output
%% (s2). Seed the same between-steps trail with s1 committed, resume with Owner =
%% self(), wait for run.completed, then assert the received Outputs merges both.
test_between_steps_resume_sends_owner_completed_with_merged_outputs(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-exec-merged-outputs-1">>,
    SessionId = <<"sess-exec-merged-outputs-1">>,
    Owner = self(),
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

    {ok, _RunPid} = soma_run_resume_executor:resume(RunId, Owner, StorePid),

    Outputs =
        receive
            {run_completed, RunId, O} -> O
        after 2000 ->
            ct:fail("Owner did not receive run_completed")
        end,

    ?assertEqual(#{value => <<"committed">>}, maps:get(s1, Outputs)),
    ?assertEqual(#{value => <<"pending">>}, maps:get(s2, Outputs)).

%% Criterion 3: resume/3 on a run interrupted DURING a safe in-flight step
%% (a tool.started landed for next_step but no step.succeeded) re-runs that step
%% in its own monitored soma_tool_call worker and the run reaches run.completed.
%% Seed a single-step file_read trail (file_read is reader/idempotent, so the
%% in-flight step is safe to re-run) with a tool.started for s1 and no
%% step.succeeded; the file is seeded first so the read succeeds. Resume, then
%% assert the post-resume trail carries a tool.started whose tool_call_pid is a
%% real pid distinct from the run pid, and that run.completed lands.
test_in_flight_safe_step_reruns_in_own_worker_and_completes(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-exec-in-flight-safe-1">>,
    SessionId = <<"sess-exec-in-flight-safe-1">>,
    Owner = self(),
    Root = make_temp_root(),
    Bytes = <<"in-flight safe read bytes">>,
    ok = file:write_file(filename:join(Root, "in.txt"), Bytes),
    S1 = #{id => s1, tool => file_read,
           args => #{path => <<"in.txt">>, root => list_to_binary(Root)}},
    Steps = [S1],
    RunOptions = #{run_id => RunId, session_id => SessionId},
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => RunOptions}}),
    %% A tool.started for s1 with NO step.succeeded: the step was mid-execution
    %% when the run was interrupted. file_read is reader/idempotent so the plan
    %% classifies it {resume, _}, not {unsafe, _}.
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s1,
                                   event_type => <<"tool.started">>,
                                   payload => #{tool_call_pid => self()}}),

    {ok, RunPid} = soma_run_resume_executor:resume(RunId, Owner, StorePid),
    ?assert(is_pid(RunPid)),

    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],

    %% The re-run of s1 happened in its own soma_tool_call worker: a fresh
    %% tool.started carries a real tool_call_pid distinct from the run pid.
    ToolStartedPids =
        [Pid
         || E <- Events,
            maps:get(event_type, E) =:= <<"tool.started">>,
            Pid <- [tool_call_pid_of(E)],
            is_pid(Pid),
            Pid =/= RunPid],
    ?assert(ToolStartedPids =/= []),

    %% the resumed run reaches run.completed and does not fail.
    ?assert(lists:member(<<"run.completed">>, Types)),
    ?assertNot(lists:member(<<"run.failed">>, Types)).

%% Criterion 4: resume/3 on a run interrupted DURING an unsafe in-flight step
%% (a non-idempotent `state' tool such as file_write) starts no soma_run child.
%% Seed a single file_write step trail with a tool.started for s1 and no
%% step.succeeded; file_write is state/non-idempotent so the plan classifies the
%% in-flight step {unsafe, s1}. Capture supervisor:count_children(soma_run_sup)
%% before and after resume/3, and assert the child tally is unchanged: nothing
%% was started.
test_unsafe_in_flight_resume_starts_no_run(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-exec-in-flight-unsafe-1">>,
    SessionId = <<"sess-exec-in-flight-unsafe-1">>,
    Owner = self(),
    Root = make_temp_root(),
    S1 = #{id => s1, tool => file_write,
           args => #{path => <<"out.txt">>,
                     content => <<"unsafe bytes">>,
                     root => list_to_binary(Root)}},
    Steps = [S1],
    RunOptions = #{run_id => RunId, session_id => SessionId},
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => RunOptions}}),
    %% A tool.started for s1 with NO step.succeeded: file_write was mid-execution
    %% when the run was interrupted. file_write is state/non-idempotent so the
    %% plan classifies it {unsafe, s1}, not {resume, _}.
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s1,
                                   event_type => <<"tool.started">>,
                                   payload => #{tool_call_pid => self()}}),

    BeforeCount = active_run_children(),

    _Result = soma_run_resume_executor:resume(RunId, Owner, StorePid),

    %% No soma_run child was started: the tally is unchanged.
    AfterCount = active_run_children(),
    ?assertEqual(BeforeCount, AfterCount).

%% Criterion 5: on an unsafe in-flight resume, a terminal run.failed event is
%% appended for the run whose payload.reason is {resume_unsafe, StepId}. Seed the
%% same single file_write in-flight trail (tool.started for s1, no step.succeeded;
%% file_write is state/non-idempotent so the plan classifies it {unsafe, s1}),
%% call resume/3, then assert the run's trail gains exactly one run.failed event
%% whose payload.reason equals {resume_unsafe, s1}.
test_unsafe_resume_appends_run_failed_with_resume_unsafe_reason(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-exec-in-flight-unsafe-reason-1">>,
    SessionId = <<"sess-exec-in-flight-unsafe-reason-1">>,
    Owner = self(),
    Root = make_temp_root(),
    S1 = #{id => s1, tool => file_write,
           args => #{path => <<"out.txt">>,
                     content => <<"unsafe bytes">>,
                     root => list_to_binary(Root)}},
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
                                   event_type => <<"tool.started">>,
                                   payload => #{tool_call_pid => self()}}),

    _Result = soma_run_resume_executor:resume(RunId, Owner, StorePid),

    Events = soma_event_store:by_run(StorePid, RunId),
    Failed = [E || E <- Events,
                   maps:get(event_type, E) =:= <<"run.failed">>],
    ?assertEqual(1, length(Failed)),
    [FailedEvent] = Failed,
    Reason = maps:get(reason, maps:get(payload, FailedEvent)),
    ?assertEqual({resume_unsafe, s1}, Reason).

%% Criterion 6: after an unsafe in-flight resume (which lands a terminal
%% run.failed), a later reader calling soma_run_resume:reconstruct/2 sees the run's
%% terminal_status as `failed'. Seed the same single file_write in-flight trail as
%% criteria 4/5 (tool.started for s1, no step.succeeded), call resume/3, then assert
%% reconstruct/2 returns {ok, #{terminal_status := failed}}.
test_after_unsafe_resume_reconstruct_reports_failed(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-exec-in-flight-unsafe-reconstruct-1">>,
    SessionId = <<"sess-exec-in-flight-unsafe-reconstruct-1">>,
    Owner = self(),
    Root = make_temp_root(),
    S1 = #{id => s1, tool => file_write,
           args => #{path => <<"out.txt">>,
                     content => <<"unsafe bytes">>,
                     root => list_to_binary(Root)}},
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
                                   event_type => <<"tool.started">>,
                                   payload => #{tool_call_pid => self()}}),

    _Result = soma_run_resume_executor:resume(RunId, Owner, StorePid),

    Reconstructed = soma_run_resume:reconstruct(StorePid, RunId),
    ?assertMatch({ok, #{terminal_status := failed}}, Reconstructed).

%% Criterion 7: a SECOND resume/3 of a run already failed with {resume_unsafe, _}
%% starts no new run and appends no new event, returning a terminal verdict. The
%% idempotency is structural: the first unsafe resume lands a terminal run.failed,
%% so the second plan/2 reconstructs terminal_status => failed and classifies
%% {terminal, failed} before it ever inspects next_step. Seed the same single
%% file_write in-flight trail (tool.started for s1, no step.succeeded), run the
%% first (unsafe) resume/3, then snapshot the run's event list and the soma_run_sup
%% child tally, call resume/3 again, and assert: the event list is byte-for-byte
%% unchanged, the child tally is unchanged, and the return is {terminal, failed}.
test_second_resume_of_unsafe_failed_run_is_terminal_noop(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-exec-second-resume-terminal-noop-1">>,
    SessionId = <<"sess-exec-second-resume-terminal-noop-1">>,
    Owner = self(),
    Root = make_temp_root(),
    S1 = #{id => s1, tool => file_write,
           args => #{path => <<"out.txt">>,
                     content => <<"unsafe bytes">>,
                     root => list_to_binary(Root)}},
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
                                   event_type => <<"tool.started">>,
                                   payload => #{tool_call_pid => self()}}),

    %% First resume: unsafe, lands the terminal run.failed.
    _First = soma_run_resume_executor:resume(RunId, Owner, StorePid),

    %% Snapshot the trail and the child tally after the first (unsafe) resume.
    EventsBefore = soma_event_store:by_run(StorePid, RunId),
    ChildrenBefore = active_run_children(),

    %% Second resume: the trail already carries terminal run.failed, so plan/2
    %% reconstructs terminal_status => failed and classifies {terminal, failed}.
    Result = soma_run_resume_executor:resume(RunId, Owner, StorePid),

    %% No new run, no new event, terminal verdict returned.
    EventsAfter = soma_event_store:by_run(StorePid, RunId),
    ChildrenAfter = active_run_children(),
    ?assertEqual(EventsBefore, EventsAfter),
    ?assertEqual(ChildrenBefore, ChildrenAfter),
    ?assertEqual({terminal, failed}, Result).

%% Criterion 8: resume/3 on an already-terminal run (one that reached
%% run.completed) starts no run, appends no event, and returns the terminal
%% verdict. The plan reconstructs terminal_status => completed and classifies
%% {terminal, completed} before it ever inspects next_step. Seed a terminal trail
%% (run.started for [s1] + step.succeeded for s1 + run.completed), snapshot the
%% run's event list and the soma_run_sup child tally, call resume/3, and assert:
%% the event list is byte-for-byte unchanged, the child tally is unchanged, and
%% the return is {terminal, completed}.
test_resume_of_terminal_run_is_noop(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-exec-terminal-noop-1">>,
    SessionId = <<"sess-exec-terminal-noop-1">>,
    Owner = self(),
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
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.completed">>,
                                   payload => #{}}),

    %% Snapshot the trail and the child tally before resume.
    EventsBefore = soma_event_store:by_run(StorePid, RunId),
    ChildrenBefore = active_run_children(),

    Result = soma_run_resume_executor:resume(RunId, Owner, StorePid),

    %% No new run, no new event, terminal verdict returned.
    EventsAfter = soma_event_store:by_run(StorePid, RunId),
    ChildrenAfter = active_run_children(),
    ?assertEqual(EventsBefore, EventsAfter),
    ?assertEqual(ChildrenBefore, ChildrenAfter),
    ?assertEqual({terminal, completed}, Result).

%% Criterion 9: resume/3 on a fully-committed run -- one whose only step already
%% committed step.succeeded but which carries no terminal event -- starts no run
%% and appends no event, returning nothing_to_do. The plan reconstructs no pending
%% suffix (every journal step is committed) and classifies nothing_to_do before any
%% child is started. Seed a single-step trail (run.started for [s1] + step.succeeded
%% for s1, no terminal event), snapshot the run's event list and the soma_run_sup
%% child tally, call resume/3, and assert: the event list is byte-for-byte
%% unchanged, the child tally is unchanged, and the return is nothing_to_do.
test_resume_of_fully_committed_run_is_nothing_to_do_noop(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-exec-nothing-to-do-noop-1">>,
    SessionId = <<"sess-exec-nothing-to-do-noop-1">>,
    Owner = self(),
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

    %% Snapshot the trail and the child tally before resume.
    EventsBefore = soma_event_store:by_run(StorePid, RunId),
    ChildrenBefore = active_run_children(),

    Result = soma_run_resume_executor:resume(RunId, Owner, StorePid),

    %% No new run, no new event, nothing_to_do returned.
    EventsAfter = soma_event_store:by_run(StorePid, RunId),
    ChildrenAfter = active_run_children(),
    ?assertEqual(EventsBefore, EventsAfter),
    ?assertEqual(ChildrenBefore, ChildrenAfter),
    ?assertEqual(nothing_to_do, Result).

%% Criterion 10: resume/3 on a trail that reconstructs to {error, _} -- here an
%% orphan step.succeeded with no run.started journal -- starts no run, appends no
%% event, and returns that error. The plan reconstructs no usable journal and
%% propagates {error, no_run_started_journal}; the executor passes it straight
%% through without touching the store or the supervisor. Seed only an orphan
%% step.succeeded (no run.started), snapshot the run's event list and the
%% soma_run_sup child tally, call resume/3, and assert: the event list is
%% byte-for-byte unchanged, the child tally is unchanged, and the return is
%% {error, no_run_started_journal}.
test_resume_of_unreconstructable_trail_returns_error_noop(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-exec-unreconstructable-error-1">>,
    SessionId = <<"sess-exec-unreconstructable-error-1">>,
    Owner = self(),
    %% An orphan step.succeeded with NO run.started journal: there is no journal
    %% to reconstruct from, so plan/2 returns {error, no_run_started_journal}.
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s1,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"orphan">>}}}),

    %% Snapshot the trail and the child tally before resume.
    EventsBefore = soma_event_store:by_run(StorePid, RunId),
    ChildrenBefore = active_run_children(),

    Result = soma_run_resume_executor:resume(RunId, Owner, StorePid),

    %% No new run, no new event, the error propagated.
    EventsAfter = soma_event_store:by_run(StorePid, RunId),
    ChildrenAfter = active_run_children(),
    ?assertEqual(EventsBefore, EventsAfter),
    ?assertEqual(ChildrenBefore, ChildrenAfter),
    ?assertEqual({error, no_run_started_journal}, Result).

active_run_children() ->
    proplists:get_value(active, supervisor:count_children(soma_run_sup)).

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

tool_call_pid_of(Event) ->
    case maps:get(payload, Event, undefined) of
        Payload when is_map(Payload) ->
            maps:get(tool_call_pid, Payload, undefined);
        _ ->
            undefined
    end.

make_temp_root() ->
    Dir = filename:join(
            ["/tmp",
             "soma_resume_exec_test_"
             ++ integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.
