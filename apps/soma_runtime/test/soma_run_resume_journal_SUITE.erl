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

all() ->
    [test_session_start_journals_steps_in_run_started,
     test_direct_run_journals_durable_options_with_correlation_id,
     test_restarted_disk_log_by_run_exposes_run_started_journal,
     test_reconstruct_returns_journaled_steps,
     test_reconstruct_returns_journaled_durable_options,
     test_reconstruct_returns_committed_outputs_by_step_id].

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
