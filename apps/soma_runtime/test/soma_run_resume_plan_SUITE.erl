-module(soma_run_resume_plan_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_between_steps_resumes_with_pending_suffix_outputs_and_options/1]).

all() ->
    [test_between_steps_resumes_with_pending_suffix_outputs_and_options].

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

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
