-module(soma_run_resume_journal_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_session_start_journals_steps_in_run_started/1]).

all() ->
    [test_session_start_journals_steps_in_run_started].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
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

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
