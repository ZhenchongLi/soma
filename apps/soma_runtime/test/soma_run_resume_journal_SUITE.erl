-module(soma_run_resume_journal_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_session_start_journals_steps_in_run_started/1]).
-export([test_direct_run_journals_durable_options_with_correlation_id/1]).
-export([test_restarted_disk_log_by_run_exposes_run_started_journal/1]).
-export([test_reconstruct_returns_journaled_steps/1]).
-export([test_reconstruct_returns_journaled_durable_options/1]).
-export([test_reconstruct_returns_committed_outputs_by_step_id/1]).
-export([test_reconstruct_returns_first_uncommitted_step/1]).
-export([test_reconstruct_returns_terminal_status/1]).
-export([test_reconstruct_rejects_missing_run_started_journal/1]).
-export([test_reconstruct_rejects_unknown_committed_step/1]).
-export([test_reconstruct_does_not_append_events/1]).
-export([test_reconstruct_does_not_start_run_children/1]).

all() ->
    [test_session_start_journals_steps_in_run_started,
     test_direct_run_journals_durable_options_with_correlation_id,
     test_restarted_disk_log_by_run_exposes_run_started_journal,
     test_reconstruct_returns_journaled_steps,
     test_reconstruct_returns_journaled_durable_options,
     test_reconstruct_returns_committed_outputs_by_step_id,
     test_reconstruct_returns_first_uncommitted_step,
     test_reconstruct_returns_terminal_status,
     test_reconstruct_rejects_missing_run_started_journal,
     test_reconstruct_rejects_unknown_committed_step,
     test_reconstruct_does_not_append_events,
     test_reconstruct_does_not_start_run_children].

init_per_testcase(test_restarted_disk_log_by_run_exposes_run_started_journal,
                  Config) ->
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    application:set_env(soma_runtime, event_store_log, Path),
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started}, {tmp_dir, TmpDir}, {log_path, Path} | Config];
init_per_testcase(_Case, Config) ->
    application:unset_env(soma_runtime, event_store_log),
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, Config) ->
    application:stop(soma_runtime),
    application:unset_env(soma_runtime, event_store_log),
    maybe_del_tmp_dir(Config),
    ok.

test_session_start_journals_steps_in_run_started(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"journal me">>}}],

    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    Events = soma_event_store:by_run(StorePid, RunId),
    [StartedEvent] = [E || E <- Events,
                           maps:get(event_type, E) =:= <<"run.started">>],
    Payload = maps:get(payload, StartedEvent, undefined),
    JournaledSteps = case Payload of
                         #{steps := StepsInPayload} -> StepsInPayload;
                         _ -> missing
                     end,

    ?assertEqual(Steps, JournaledSteps).

test_direct_run_journals_durable_options_with_correlation_id(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-durable-options-1">>,
    SessionId = <<"sess-durable-options-1">>,
    CorrelationId = <<"corr-durable-options-1">>,
    Steps = [#{id => s1, tool => echo, args => #{value => <<"direct">>}}],

    {ok, _RunPid} = soma_run_sup:start_run(#{run_id => RunId,
                                             session_id => SessionId,
                                             session_pid => self(),
                                             event_store => StorePid,
                                             correlation_id => CorrelationId,
                                             steps => Steps}),
    Events = soma_event_store:by_run(StorePid, RunId),
    [StartedEvent] = [E || E <- Events,
                           maps:get(event_type, E) =:= <<"run.started">>],
    Payload = maps:get(payload, StartedEvent, undefined),
    RunOptions = case Payload of
                     #{run_options := RunOptionsInPayload} ->
                         RunOptionsInPayload;
                     _ ->
                         missing
                 end,

    ?assertEqual(#{run_id => RunId,
                   session_id => SessionId,
                   correlation_id => CorrelationId},
                 RunOptions),
    ?assertNot(maps:is_key(session_pid, RunOptions)),
    ?assertNot(maps:is_key(event_store, RunOptions)).

test_restarted_disk_log_by_run_exposes_run_started_journal(Config) ->
    Path = ?config(log_path, Config),
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    SessionId = maps:get(session_id, soma_agent_session:get_status(SessionPid)),
    Steps = [#{id => s1, tool => echo,
               args => #{value => <<"persisted journal">>}}],

    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    ok = application:stop(soma_runtime),

    application:set_env(soma_runtime, event_store_log, Path),
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    RestartedStorePid = event_store_pid(),
    Events = soma_event_store:by_run(RestartedStorePid, RunId),
    [StartedEvent] = [E || E <- Events,
                           maps:get(event_type, E) =:= <<"run.started">>],
    Payload = maps:get(payload, StartedEvent, undefined),

    ?assertEqual(#{steps => Steps,
                   run_options => #{run_id => RunId,
                                    session_id => SessionId}},
                 Payload).

test_reconstruct_returns_journaled_steps(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => echo,
               args => #{value => <<"reconstruct journal">>}}],

    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),

    ?assertMatch({ok, #{steps := Steps}},
                 soma_run_resume:reconstruct(StorePid, RunId)).

test_reconstruct_returns_journaled_durable_options(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-reconstruct-options-1">>,
    SessionId = <<"sess-reconstruct-options-1">>,
    CorrId = <<"corr-reconstruct-options-1">>,
    Steps = [#{id => s1, tool => echo,
               args => #{value => <<"reconstruct durable options">>}}],

    {ok, _RunPid} = soma_run_sup:start_run(#{run_id => RunId,
                                             session_id => SessionId,
                                             session_pid => self(),
                                             event_store => StorePid,
                                             correlation_id => CorrId,
                                             steps => Steps}),

    ?assertMatch({ok, #{run_options := #{run_id := RunId,
                                         session_id := SessionId,
                                         correlation_id := CorrId}}},
                 soma_run_resume:reconstruct(StorePid, RunId)).

test_reconstruct_returns_committed_outputs_by_step_id(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => echo,
               args => #{value => <<"first committed">>}},
             #{id => s2, tool => echo,
               args => #{value => <<"second committed">>}}],

    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    CommittedOutputs = committed_outputs_by_step_id(Events),
    ?assertEqual(#{s1 => #{value => <<"first committed">>},
                   s2 => #{value => <<"second committed">>}},
                 CommittedOutputs),
    {ok, Reconstructed} = soma_run_resume:reconstruct(StorePid, RunId),

    ?assertEqual(CommittedOutputs, maps:get(outputs, Reconstructed, missing)).

test_reconstruct_returns_first_uncommitted_step(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-reconstruct-next-step-1">>,
    SessionId = <<"sess-reconstruct-next-step-1">>,
    S1 = #{id => s1, tool => echo,
           args => #{value => <<"committed">>}},
    S2 = #{id => s2, tool => echo,
           args => #{value => <<"uncommitted">>}},
    Steps = [S1, S2],
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => #{run_id => RunId,
                                                                 session_id => SessionId}}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s1,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"committed">>}}}),

    {ok, Reconstructed} = soma_run_resume:reconstruct(StorePid, RunId),

    ?assertEqual(S2, maps:get(next_step, Reconstructed, missing)).

test_reconstruct_returns_terminal_status(_Config) ->
    StorePid = event_store_pid(),
    Steps = [#{id => s1, tool => echo, args => #{value => <<"terminal">>}}],

    %% Each terminal event type maps to its terminal atom; a trail with no
    %% terminal event reports `undefined'.
    ?assertEqual(completed,
                 terminal_status_of(StorePid, <<"run-terminal-completed">>,
                                    Steps, <<"run.completed">>)),
    ?assertEqual(failed,
                 terminal_status_of(StorePid, <<"run-terminal-failed">>,
                                    Steps, <<"run.failed">>)),
    ?assertEqual(timeout,
                 terminal_status_of(StorePid, <<"run-terminal-timeout">>,
                                    Steps, <<"run.timeout">>)),
    ?assertEqual(cancelled,
                 terminal_status_of(StorePid, <<"run-terminal-cancelled">>,
                                    Steps, <<"run.cancelled">>)),
    ?assertEqual(undefined,
                 terminal_status_of(StorePid, <<"run-terminal-none">>,
                                    Steps, undefined)).

test_reconstruct_rejects_missing_run_started_journal(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-reconstruct-no-journal-1">>,
    SessionId = <<"sess-reconstruct-no-journal-1">>,
    %% A trail with run events but no usable `run.started' journal: a
    %% malformed `run.started' payload (no list-valued steps / map-valued
    %% run_options) plus a `step.succeeded', which must not satisfy the
    %% reconstruct precondition.
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s1,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"orphan">>}}}),

    ?assertEqual({error, no_run_started_journal},
                 soma_run_resume:reconstruct(StorePid, RunId)).

test_reconstruct_rejects_unknown_committed_step(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-reconstruct-unknown-step-1">>,
    SessionId = <<"sess-reconstruct-unknown-step-1">>,
    %% The journal commits to a single step `s1', but the trail then commits
    %% output for `s2', which the journal never declared. Such a trail cannot be
    %% reconciled with its own journal and must be rejected.
    Steps = [#{id => s1, tool => echo, args => #{value => <<"journaled">>}}],
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => #{run_id => RunId,
                                                                 session_id => SessionId}}}),
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => s2,
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"unknown">>}}}),

    ?assertEqual({error, {unknown_committed_step, s2}},
                 soma_run_resume:reconstruct(StorePid, RunId)).

test_reconstruct_does_not_append_events(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => echo,
               args => #{value => <<"no append">>}}],

    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),

    EventsBefore = soma_event_store:all(StorePid),
    {ok, _Reconstructed} = soma_run_resume:reconstruct(StorePid, RunId),
    EventsAfter = soma_event_store:all(StorePid),

    %% reconstruct is read-only, so the event store is byte-for-byte unchanged.
    ?assertEqual(EventsBefore, EventsAfter).

test_reconstruct_does_not_start_run_children(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Steps = [#{id => s1, tool => echo,
               args => #{value => <<"no run children">>}}],

    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),

    CountBefore = supervisor:count_children(soma_run_sup),
    {ok, _Reconstructed} = soma_run_resume:reconstruct(StorePid, RunId),
    CountAfter = supervisor:count_children(soma_run_sup),

    %% reconstruct is read-only, so it starts no run children: the
    %% `soma_run_sup' child tally is unchanged across the call.
    ?assertEqual(CountBefore, CountAfter).

terminal_status_of(StorePid, RunId, Steps, TerminalEventType) ->
    ok = soma_event_store:append(StorePid,
                                 #{run_id => RunId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options =>
                                                    #{run_id => RunId}}}),
    case TerminalEventType of
        undefined ->
            ok;
        _ ->
            ok = soma_event_store:append(StorePid,
                                         #{run_id => RunId,
                                           event_type => TerminalEventType,
                                           payload => #{}})
    end,
    {ok, Reconstructed} = soma_run_resume:reconstruct(StorePid, RunId),
    maps:get(terminal_status, Reconstructed, missing).

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

committed_outputs_by_step_id(Events) ->
    maps:from_list(
      [{maps:get(step_id, Event), maps:get(output, maps:get(payload, Event))}
       || Event <- Events,
          maps:get(event_type, Event, undefined) =:= <<"step.succeeded">>]).

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

make_tmp_dir() ->
    Unique = erlang:integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(["/tmp", "soma_run_resume_journal_" ++ Unique]),
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
            [ok = file:delete(filename:join(Dir, N)) || N <- Names],
            file:del_dir(Dir);
        {error, enoent} ->
            ok
    end.
