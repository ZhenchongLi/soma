-module(soma_run_auto_resume_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_boot_with_event_store_log_resumes_between_steps_interrupted_run/1]).
-export([test_boot_auto_resume_emits_run_resumed_for_first_pending_step/1]).
-export([test_boot_auto_resume_fails_unsafe_in_flight_state_step/1]).

all() ->
    [test_boot_with_event_store_log_resumes_between_steps_interrupted_run,
     test_boot_auto_resume_emits_run_resumed_for_first_pending_step,
     test_boot_auto_resume_fails_unsafe_in_flight_state_step].

init_per_testcase(_Case, Config) ->
    _ = application:stop(soma_runtime),
    application:unset_env(soma_runtime, event_store_log),
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    [{tmp_dir, TmpDir}, {log_path, Path} | Config].

end_per_testcase(_Case, Config) ->
    _ = application:stop(soma_runtime),
    application:unset_env(soma_runtime, event_store_log),
    ok = del_tmp_dir(?config(tmp_dir, Config)),
    ok.

%% v0.7.5 criterion 3: booting soma_runtime with event_store_log set replays the
%% durable log, discovers a run interrupted between steps, and hands it to the
%% existing resume executor so the pending suffix completes.
test_boot_with_event_store_log_resumes_between_steps_interrupted_run(Config) ->
    Path = ?config(log_path, Config),
    RunId = <<"run-auto-resume-between-steps-1">>,
    SessionId = <<"sess-auto-resume-between-steps-1">>,
    S1 = #{id => s1, tool => echo, args => #{value => <<"committed">>}},
    S2 = #{id => s2, tool => echo, args => #{value => <<"pending">>}},
    Steps = [S1, S2],

    ok = seed_between_steps_log(Path, RunId, SessionId, Steps),

    application:set_env(soma_runtime, event_store_log, Path),
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    StorePid = event_store_pid(),

    ?assertEqual(ok, wait_for_event(StorePid, RunId, <<"run.completed">>, 50)),
    Events = soma_event_store:by_run(StorePid, RunId),
    PendingOutputs =
        [maps:get(output, maps:get(payload, E))
         || E <- Events,
            maps:get(event_type, E, undefined) =:= <<"step.succeeded">>,
            maps:get(step_id, E, undefined) =:= s2],
    ?assertEqual([#{value => <<"pending">>}], PendingOutputs).

%% v0.7.5 criterion 4: an auto-resumed run emits `run.resumed' for the first
%% pending step, so the boot-resume trail names that step on the event.
test_boot_auto_resume_emits_run_resumed_for_first_pending_step(Config) ->
    Path = ?config(log_path, Config),
    RunId = <<"run-auto-resume-resumed-event-1">>,
    SessionId = <<"sess-auto-resume-resumed-event-1">>,
    S1 = #{id => s1, tool => echo, args => #{value => <<"committed">>}},
    S2 = #{id => s2, tool => echo, args => #{value => <<"pending">>}},
    Steps = [S1, S2],

    ok = seed_between_steps_log(Path, RunId, SessionId, Steps),

    application:set_env(soma_runtime, event_store_log, Path),
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    StorePid = event_store_pid(),

    ?assertEqual(ok, wait_for_event(StorePid, RunId, <<"run.resumed">>, 50)),
    Events = soma_event_store:by_run(StorePid, RunId),
    ResumedEvents =
        [E || E <- Events,
              maps:get(event_type, E, undefined) =:= <<"run.resumed">>],
    ?assertMatch([_], ResumedEvents),
    [Resumed] = ResumedEvents,
    ?assertEqual(RunId, maps:get(run_id, Resumed)),
    ?assertEqual(SessionId, maps:get(session_id, Resumed)),
    ?assertEqual(s2, maps:get(step_id, Resumed)),
    ?assertEqual(#{first_pending_step => s2}, maps:get(payload, Resumed)).

%% v0.7.5 criterion 5: boot auto-resume must fail safe when discovery finds a
%% run interrupted inside a non-idempotent state step. The runtime boot path
%% should append a terminal run.failed event with {resume_unsafe, StepId} and
%% keep that failure on the original durable run/session trail.
test_boot_auto_resume_fails_unsafe_in_flight_state_step(Config) ->
    Path = ?config(log_path, Config),
    RunId = <<"run-auto-resume-unsafe-state-1">>,
    SessionId = <<"sess-auto-resume-unsafe-state-1">>,
    S1 = #{id => s1,
           tool => file_write,
           args => #{path => <<"out.txt">>,
                     content => <<"unsafe bytes">>,
                     root => list_to_binary(?config(tmp_dir, Config))}},
    Steps = [S1],

    ok = seed_unsafe_in_flight_state_log(Path, RunId, SessionId, Steps),

    application:set_env(soma_runtime, event_store_log, Path),
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    StorePid = event_store_pid(),

    ?assertEqual(ok, wait_for_event(StorePid, RunId, <<"run.failed">>, 50)),
    Events = soma_event_store:by_run(StorePid, RunId),
    Failed = [E || E <- Events,
                   maps:get(event_type, E, undefined) =:= <<"run.failed">>],
    ?assertMatch([_], Failed),
    [FailedEvent] = Failed,
    ?assertEqual(RunId, maps:get(run_id, FailedEvent)),
    ?assertEqual(SessionId, maps:get(session_id, FailedEvent)),
    ?assertEqual(s1, maps:get(step_id, FailedEvent)),
    ?assertEqual({resume_unsafe, s1},
                 maps:get(reason, maps:get(payload, FailedEvent))).

seed_between_steps_log(Path, RunId, SessionId, Steps) ->
    [S1 | _] = Steps,
    {ok, Pid} = soma_event_store:start_link(#{log => Path}),
    ok = soma_event_store:append(Pid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => #{run_id => RunId,
                                                                 session_id => SessionId}}}),
    ok = soma_event_store:append(Pid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => maps:get(id, S1),
                                   event_type => <<"step.succeeded">>,
                                   payload => #{output => #{value => <<"committed">>}}}),
    stop_store(Pid).

seed_unsafe_in_flight_state_log(Path, RunId, SessionId, Steps) ->
    [S1 | _] = Steps,
    {ok, Pid} = soma_event_store:start_link(#{log => Path}),
    ok = soma_event_store:append(Pid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   event_type => <<"run.started">>,
                                   payload => #{steps => Steps,
                                                run_options => #{run_id => RunId,
                                                                 session_id => SessionId}}}),
    ok = soma_event_store:append(Pid,
                                 #{run_id => RunId,
                                   session_id => SessionId,
                                   step_id => maps:get(id, S1),
                                   event_type => <<"tool.started">>,
                                   payload => #{tool_call_pid => self()}}),
    stop_store(Pid).

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

wait_for_event(_StorePid, _RunId, _Type, 0) ->
    {error, timeout};
wait_for_event(StorePid, RunId, Type, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    case lists:any(fun(E) ->
                           maps:get(event_type, E, undefined) =:= Type
                   end, Events) of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_for_event(StorePid, RunId, Type, N - 1)
    end.

stop_store(Pid) ->
    Ref = monitor(process, Pid),
    gen_server:stop(Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 ->
        error(stop_store_timeout)
    end.

make_tmp_dir() ->
    Unique = erlang:integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(["/tmp", "soma_run_auto_resume_" ++ Unique]),
    ok = file:make_dir(Dir),
    Dir.

del_tmp_dir(Dir) ->
    {ok, Names} = file:list_dir(Dir),
    [ok = file:delete(filename:join(Dir, N)) || N <- Names],
    file:del_dir(Dir).
