-module(soma_text_reader_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_text_grep_compilable_pattern_and_zero_match/1,
         test_text_grep_invalid_regex_fails_bounded_session_alive/1]).

all() ->
    [test_text_grep_compilable_pattern_and_zero_match,
     test_text_grep_invalid_regex_fails_bounded_session_alive].

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

test_text_grep_invalid_regex_fails_bounded_session_alive(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    InvalidPattern = binary:copy(<<"(">>, 4096),
    BadSteps = [#{id => invalid_regex,
                  tool => text_grep,
                  args => #{text => <<"alpha\nbeta\n">>,
                            pattern => InvalidPattern}}],
    {ok, BadRunId} = soma_agent_session:start_run(SessionPid, BadSteps),
    ok = wait_for_event(StorePid, BadRunId, <<"run.failed">>, 50),
    FailureReason = run_failure_reason(StorePid, BadRunId),
    {invalid_pattern,
     #{offset := Offset, diagnostic := Diagnostic} = Detail} = FailureReason,
    2 = map_size(Detail),
    true = is_integer(Offset),
    true = is_binary(Diagnostic),
    true = byte_size(Diagnostic) =< 128,
    true = byte_size(term_to_binary(FailureReason)) =< 256,
    nomatch = binary:match(term_to_binary(FailureReason), InvalidPattern),
    ok = wait_for_run_status(SessionPid, BadRunId, failed, 50),
    true = is_process_alive(SessionPid),

    GoodSteps = [#{id => echo_after_invalid_regex,
                   tool => echo,
                   args => #{value => <<"still alive">>}}],
    {ok, GoodRunId} = soma_agent_session:start_run(SessionPid, GoodSteps),
    ok = wait_for_event(StorePid, GoodRunId, <<"run.completed">>, 50),
    ok = wait_for_run_status(SessionPid, GoodRunId, completed, 50),
    true = is_process_alive(SessionPid),
    ok.

step_output(Events, StepId) ->
    [Event] = [E || E <- Events,
                   maps:get(event_type, E) =:= <<"step.succeeded">>,
                   maps:get(step_id, E) =:= StepId],
    maps:get(output, maps:get(payload, Event)).

run_failure_reason(StorePid, RunId) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    [Event] = [E || E <- Events,
                   maps:get(event_type, E) =:= <<"run.failed">>],
    maps:get(reason, maps:get(payload, Event)).

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

wait_for_event(_StorePid, _RunId, _Type, 0) ->
    {error, timeout};
wait_for_event(StorePid, RunId, Type, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(Type, Types) of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_for_event(StorePid, RunId, Type, N - 1)
    end.

wait_for_run_status(_SessionPid, _RunId, _Expected, 0) ->
    {error, timeout};
wait_for_run_status(SessionPid, RunId, Expected, N) ->
    Status = soma_agent_session:get_status(SessionPid),
    Runs = maps:get(runs, Status, #{}),
    case maps:get(RunId, Runs, undefined) of
        Expected ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_run_status(SessionPid, RunId, Expected, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
