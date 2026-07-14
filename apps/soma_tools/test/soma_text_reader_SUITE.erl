-module(soma_text_reader_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_text_grep_compilable_pattern_and_zero_match/1]).

all() ->
    [test_text_grep_compilable_pattern_and_zero_match].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

test_text_grep_compilable_pattern_and_zero_match(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    Text = <<"alpha\nbeta\nalphabet\nomega">>,
    Steps = [#{id => matching_lines,
               tool => text_grep,
               args => #{text => Text,
                         pattern => <<"^alpha">>,
                         max_matches => 10}},
             #{id => zero_matches,
               tool => text_grep,
               args => #{text => Text,
                         pattern => <<"^zeta">>,
                         max_matches => 10}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    #{text := <<"alpha\nalphabet\n">>,
      match_count := 2,
      truncated := false} = step_output(Events, matching_lines),
    #{text := <<>>,
      match_count := 0,
      truncated := false} = step_output(Events, zero_matches),
    ok.

step_output(Events, StepId) ->
    [Event] = [E || E <- Events,
                   maps:get(event_type, E) =:= <<"step.succeeded">>,
                   maps:get(step_id, E) =:= StepId],
    maps:get(output, maps:get(payload, Event)).

wait_for_run_completed(_StorePid, _RunId, 0) ->
    {error, timeout};
wait_for_run_completed(StorePid, RunId, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    case [E || E <- Events,
               maps:get(event_type, E) =:= <<"run.failed">>] of
        [Failed | _] ->
            Reason = maps:get(reason, maps:get(payload, Failed)),
            {error, {run_failed, Reason}};
        [] ->
            Types = [maps:get(event_type, E) || E <- Events],
            case lists:member(<<"run.completed">>, Types) of
                true ->
                    ok;
                false ->
                    timer:sleep(20),
                    wait_for_run_completed(StorePid, RunId, N - 1)
            end
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
