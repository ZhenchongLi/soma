-module(soma_text_reader_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_text_grep_compilable_pattern_and_zero_match/1,
         test_text_grep_invalid_regex_fails_bounded_session_alive/1,
         test_text_grep_input_validation_fails_named_session_alive/1,
         test_text_grep_default_and_explicit_match_caps/1,
         test_text_head_input_validation_fails_named_session_alive/1]).

all() ->
    [test_text_grep_compilable_pattern_and_zero_match,
     test_text_grep_invalid_regex_fails_bounded_session_alive,
     test_text_grep_input_validation_fails_named_session_alive,
     test_text_grep_default_and_explicit_match_caps,
     test_text_head_input_validation_fails_named_session_alive].

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

test_text_grep_input_validation_fails_named_session_alive(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    LargeNonBinary = lists:duplicate(4096, $x),
    Cases =
        [{grep_missing_text,
          #{pattern => <<"alpha">>},
          {missing_field, text}},
         {grep_missing_pattern,
          #{text => <<"alpha\n">>},
          {missing_field, pattern}},
         {grep_non_binary_text,
          #{text => LargeNonBinary, pattern => <<"alpha">>},
          {invalid_field_type, text, binary}},
         {grep_non_binary_pattern,
          #{text => <<"alpha\n">>, pattern => LargeNonBinary},
          {invalid_field_type, pattern, binary}},
         {grep_zero_max_matches,
          #{text => <<"alpha\n">>, pattern => <<"alpha">>, max_matches => 0},
          {invalid_limit, max_matches, positive_integer}},
         {grep_negative_max_matches,
          #{text => <<"alpha\n">>, pattern => <<"alpha">>, max_matches => -1},
          {invalid_limit, max_matches, positive_integer}},
         {grep_non_integer_max_matches,
          #{text => <<"alpha\n">>,
            pattern => <<"alpha">>,
            max_matches => LargeNonBinary},
          {invalid_limit, max_matches, positive_integer}}],
    ok = assert_validation_failures(SessionPid, StorePid, text_grep, Cases),
    ok = assert_session_completes_echo(SessionPid, StorePid,
                                       echo_after_grep_validation),
    ok.

test_text_grep_default_and_explicit_match_caps(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    ExplicitText = <<"match one\nskip\nmatch two\nmatch three\n">>,
    DefaultText = binary:copy(<<"match\n">>, 101),
    Steps = [#{id => explicit_match_cap,
               tool => text_grep,
               args => #{text => ExplicitText,
                         pattern => <<"^match">>,
                         max_matches => 2}},
             #{id => exact_match_cap,
               tool => text_grep,
               args => #{text => <<"match one\nmatch two\n">>,
                         pattern => <<"^match">>,
                         max_matches => 2}},
             #{id => default_match_cap,
               tool => text_grep,
               args => #{text => DefaultText,
                         pattern => <<"^match$">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    #{text := <<"match one\nmatch two\n">>,
      match_count := 2,
      truncated := true} = step_output(Events, explicit_match_cap),
    #{text := <<"match one\nmatch two\n">>,
      match_count := 2,
      truncated := false} = step_output(Events, exact_match_cap),
    #{text := ExpectedDefaultText,
      match_count := 100,
      truncated := true} = step_output(Events, default_match_cap),
    ExpectedDefaultText = binary:copy(<<"match\n">>, 100),
    ok.

test_text_head_input_validation_fails_named_session_alive(_Config) ->
    StorePid = event_store_pid(),
    {ok, SessionPid} = soma_agent_session:start_link(#{}),
    LargeNonBinary = lists:duplicate(4096, $x),
    Cases =
        [{head_missing_text,
          #{lines => 1},
          {missing_field, text}},
         {head_non_binary_text,
          #{text => LargeNonBinary, lines => 1},
          {invalid_field_type, text, binary}},
         {head_zero_lines,
          #{text => <<"alpha\n">>, lines => 0},
          {invalid_limit, lines, positive_integer}},
         {head_negative_lines,
          #{text => <<"alpha\n">>, lines => -1},
          {invalid_limit, lines, positive_integer}},
         {head_non_integer_lines,
          #{text => <<"alpha\n">>, lines => LargeNonBinary},
          {invalid_limit, lines, positive_integer}}],
    ok = assert_validation_failures(SessionPid, StorePid, text_head, Cases),
    ok = assert_session_completes_echo(SessionPid, StorePid,
                                       echo_after_head_validation),
    ok.

assert_validation_failures(SessionPid, StorePid, Tool, Cases) ->
    lists:foreach(
      fun({StepId, Args, ExpectedReason}) ->
              Steps = [#{id => StepId, tool => Tool, args => Args}],
              {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
              ok = wait_for_event(StorePid, RunId, <<"run.failed">>, 50),
              ExpectedReason = run_failure_reason(StorePid, RunId),
              true = byte_size(term_to_binary(ExpectedReason)) =< 128,
              ok = wait_for_run_status(SessionPid, RunId, failed, 50),
              true = is_process_alive(SessionPid)
      end,
      Cases),
    ok.

assert_session_completes_echo(SessionPid, StorePid, StepId) ->
    Steps = [#{id => StepId,
               tool => echo,
               args => #{value => <<"still alive">>}}],
    {ok, RunId} = soma_agent_session:start_run(SessionPid, Steps),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    ok = wait_for_run_status(SessionPid, RunId, completed, 50),
    true = is_process_alive(SessionPid),
    Events = soma_event_store:by_run(StorePid, RunId),
    #{value := <<"still alive">>} = step_output(Events, StepId),
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
