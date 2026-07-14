%% @doc AS.3 actor exploration-loop proofs. Provider calls use the existing
%% fixed-response seam, so the suite exercises the real actor/worker/provider
%% path without opening a network socket.
-module(soma_actor_explore_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([explore_mode_provider_text_is_parsed_as_round_reply/1]).
-export([reader_explore_run_and_tool_worker_are_distinct_children/1]).
-export([reader_then_terminal_run_steps_carries_observation_and_outputs/1]).
-export([non_reader_explore_rejected_with_effect_and_no_run/1]).
-export([configured_observation_cap_counts_only_retained_output_bytes/1]).
-export([default_observation_cap_is_16384_bytes/1]).
-export([failed_explore_run_becomes_next_round_observation/1]).
-export([timed_out_explore_run_becomes_next_round_observation/1]).
-export([invalid_round_reply_becomes_bounded_next_observation/1]).
-export([configured_round_limit_stops_before_next_llm_start/1]).
-export([default_round_limit_is_five/1]).
-export([explore_rounds_consume_existing_llm_call_budget/1]).
-export([in_loop_llm_crash_is_terminal_failed/1]).
-export([policy_rejected_explore_becomes_bounded_observation_and_continues/1]).
-export([unknown_tool_explore_becomes_bounded_observation_and_continues/1]).
-export([in_loop_llm_error_result_is_terminal_failed/1]).
-export([finished_llm_call_bookkeeping_cleared_between_rounds/1]).
-export([in_loop_llm_timeout_is_terminal_timeout/1]).
-export([cancel_during_llm_round_kills_worker_and_cancels_task/1]).
-export([cancel_during_explore_run_kills_tool_worker_and_cancels_task/1]).
-export([actor_reusable_after_round_exhaustion/1]).
-export([actor_reusable_after_in_loop_llm_failure/1]).
-export([actor_reusable_after_exploration_cancel/1]).
-export([terminal_run_steps_reuses_proposal_execution_suffix/1]).
-export([terminal_reply_completes_without_run/1]).
-export([terminal_policy_rejection_starts_no_run/1]).
-export([terminal_max_steps_failure_starts_no_run/1]).
-export([round_events_use_bounded_schema_and_order/1]).

all() ->
    [explore_mode_provider_text_is_parsed_as_round_reply,
     reader_explore_run_and_tool_worker_are_distinct_children,
     reader_then_terminal_run_steps_carries_observation_and_outputs,
     non_reader_explore_rejected_with_effect_and_no_run,
     configured_observation_cap_counts_only_retained_output_bytes,
     default_observation_cap_is_16384_bytes,
     failed_explore_run_becomes_next_round_observation,
     timed_out_explore_run_becomes_next_round_observation,
     invalid_round_reply_becomes_bounded_next_observation,
     configured_round_limit_stops_before_next_llm_start,
     default_round_limit_is_five,
     explore_rounds_consume_existing_llm_call_budget,
     in_loop_llm_crash_is_terminal_failed,
     in_loop_llm_timeout_is_terminal_timeout,
     cancel_during_llm_round_kills_worker_and_cancels_task,
     cancel_during_explore_run_kills_tool_worker_and_cancels_task,
     actor_reusable_after_round_exhaustion,
     actor_reusable_after_in_loop_llm_failure,
     actor_reusable_after_exploration_cancel,
     terminal_run_steps_reuses_proposal_execution_suffix,
     terminal_reply_completes_without_run,
     terminal_policy_rejection_starts_no_run,
     terminal_max_steps_failure_starts_no_run,
     round_events_use_bounded_schema_and_order,
     policy_rejected_explore_becomes_bounded_observation_and_continues,
     unknown_tool_explore_becomes_bounded_observation_and_continues,
     in_loop_llm_error_result_is_terminal_failed,
     finished_llm_call_bookkeeping_cleared_between_rounds].

init_per_testcase(_TestCase, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    {ok, Sup} = soma_actor_sup:start_link(),
    [{sup, Sup}, {started_apps, Started} | Config].

end_per_testcase(_TestCase, Config) ->
    case ?config(sup, Config) of
        undefined ->
            ok;
        Sup ->
            unlink(Sup),
            exit(Sup, shutdown)
    end,
    application:stop(soma_runtime),
    ok.

explore_mode_provider_text_is_parsed_as_round_reply(_Config) ->
    Store = event_store_pid(),
    Source =
        <<"(explore (step (id inspect) (tool sleep) "
          "(args (ms 5000)) (timeout_ms 10000)))">>,
    Body =
        iolist_to_binary(
          json:encode(
            #{<<"choices">> =>
                  [#{<<"message">> => #{<<"content">> => Source}}]})),
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response => {200, Body}},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-explore-round-reply">>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => [sleep]},
            event_store => Store}),
    TaskId = <<"task-explore-round-reply">>,
    CorrelationId = <<"corr-explore-round-reply">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => <<"inspect input.txt">>},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_event(Store, CorrelationId, <<"llm.succeeded">>, 100),

    {idle, Data} = sys:get_state(ActorPid),
    Tasks = element(6, Data),
    Task = maps:get(TaskId, Tasks),
    ExpectedRoundReply =
        #{kind => explore,
          steps =>
              [#{id => inspect,
                 tool => sleep,
                 args => #{ms => 5000},
                 timeout_ms => 10000}]},
    ok = assert_equal(ExpectedRoundReply,
                      maps:get(explore_round_reply, Task, undefined)),
    ok = assert_equal(running, maps:get(status, Task)),
    ok = assert_equal(not_ready,
                      soma_actor:get_task_result(ActorPid, TaskId)),
    ok.

reader_explore_run_and_tool_worker_are_distinct_children(_Config) ->
    Store = event_store_pid(),
    Source =
        <<"(explore (step (id wait) (tool sleep) "
          "(args (ms 5000)) (timeout_ms 10000)))">>,
    Body =
        iolist_to_binary(
          json:encode(
            #{<<"choices">> =>
                  [#{<<"message">> => #{<<"content">> => Source}}]})),
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response => {200, Body}},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-explore-process-boundaries">>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => [sleep]},
            event_store => Store}),
    TaskId = <<"task-explore-process-boundaries">>,
    CorrelationId = <<"corr-explore-process-boundaries">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => <<"wait while inspecting">>},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    Started = wait_for_event_map(Store, CorrelationId,
                                 <<"tool.started">>, 100),
    ok = assert_equal(true, is_map(Started)),
    RunId = maps:get(run_id, Started),
    WorkerPid = maps:get(tool_call_pid, Started),
    {idle, Data} = sys:get_state(ActorPid),
    Tasks = element(6, Data),
    Task = maps:get(TaskId, Tasks),
    RunPid = maps:get(run_pid, Task),
    Runs = element(7, Data),
    RunContext = maps:get(RunId, Runs),
    RunChildren = [Pid || {_Id, Pid, _Type, _Mods} <-
                              supervisor:which_children(soma_run_sup),
                          is_pid(Pid)],

    ok = assert_equal(true, lists:member(RunPid, RunChildren)),
    ok = assert_equal(TaskId, maps:get(task_id, RunContext, undefined)),
    ok = assert_equal(explore_run,
                      maps:get(purpose, RunContext, undefined)),
    ok = assert_equal(true, is_process_alive(WorkerPid)),
    ok = assert_equal(true, ActorPid =/= RunPid),
    ok = assert_equal(true, ActorPid =/= WorkerPid),
    ok = assert_equal(true, RunPid =/= WorkerPid),
    ok.

reader_then_terminal_run_steps_carries_observation_and_outputs(_Config) ->
    Store = event_store_pid(),
    TestPid = self(),
    ExploreSource =
        <<"(explore (step (id inspect) (tool text_head) "
          "(args (text \"observed\") (lines 1))))">>,
    TerminalSource =
        <<"(run-steps (step (id finish) (tool echo) "
          "(args (value \"done\"))))">>,
    FirstResponse = fixed_response(ExploreSource),
    SecondResponse = fixed_response(TerminalSource),
    FirstResponder =
        fun(CallOpts) ->
                TestPid ! {provider_request, 1, CallOpts},
                FirstResponse
        end,
    SecondResponder =
        fun(CallOpts) ->
                TestPid ! {provider_request, 2, CallOpts},
                SecondResponse
        end,
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response_sequence => [FirstResponder, SecondResponder]},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-explore-loop-spine">>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => [text_head, echo]},
            event_store => Store}),
    TaskId = <<"task-explore-loop-spine">>,
    CorrelationId = <<"corr-explore-loop-spine">>,
    Prompt = <<"inspect, then finish">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => Prompt},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    FirstCallOpts = wait_for_provider_request(1),
    SecondCallOpts = wait_for_provider_request(2),
    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),

    [#{role := <<"system">>},
     #{role := <<"user">>, content := Prompt}] =
        maps:get(messages, FirstCallOpts),
    [#{role := <<"system">>},
     #{role := <<"user">>, content := Prompt},
     #{role := <<"assistant">>, content := ExploreSource},
     #{role := <<"user">>, content := Observation}] =
        maps:get(messages, SecondCallOpts),
    ExpectedObservation =
        <<"(observation (status completed) "
          "(outputs (step (id inspect) "
          "(output \"((text \\\"observed\\\") (truncated false))\"))))">>,
    ok = assert_equal(ExpectedObservation, Observation),
    ok = assert_equal({ok, #{finish => #{value => <<"done">>}}},
                      soma_actor:get_task_result(ActorPid, TaskId)),
    ok.

non_reader_explore_rejected_with_effect_and_no_run(_Config) ->
    Store = event_store_pid(),
    TestPid = self(),
    ExploreSource =
        <<"(explore (step (id mutate) (tool file_write) "
          "(args (path \"output.txt\") (bytes \"blocked\"))))">>,
    TerminalSource = <<"(reply (text \"done\"))">>,
    FirstResponse = fixed_response(ExploreSource),
    SecondResponse = fixed_response(TerminalSource),
    FirstResponder =
        fun(CallOpts) ->
                TestPid ! {provider_request, 1, CallOpts},
                FirstResponse
        end,
    SecondResponder =
        fun(CallOpts) ->
                TestPid ! {provider_request, 2, CallOpts},
                SecondResponse
        end,
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response_sequence => [FirstResponder, SecondResponder]},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-explore-non-reader">>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => [file_write]},
            event_store => Store}),
    TaskId = <<"task-explore-non-reader">>,
    CorrelationId = <<"corr-explore-non-reader">>,
    Prompt = <<"inspect without making changes">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => Prompt},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    _FirstCallOpts = wait_for_provider_request(1),
    SecondCallOpts = wait_for_provider_request(2),
    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),

    [#{role := <<"system">>},
     #{role := <<"user">>, content := Prompt},
     #{role := <<"assistant">>, content := ExploreSource},
     #{role := <<"user">>, content := Observation}] =
        maps:get(messages, SecondCallOpts),
    ExpectedObservation =
        <<"(observation (status rejected) "
          "(tool file_write) (effect state))">>,
    ok = assert_equal(ExpectedObservation, Observation),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    RunStarted =
        [Event || #{event_type := <<"run.started">>} = Event <- Events],
    ok = assert_equal([], RunStarted),
    ok = assert_equal({ok, #{kind => reply, text => <<"done">>}},
                      soma_actor:get_task_result(ActorPid, TaskId)),
    ok.

configured_observation_cap_counts_only_retained_output_bytes(_Config) ->
    Cap = 31,
    Text = binary:copy(<<"x">>, 128),
    {Observation, SerializedOutput} =
        completed_observation_for_cap(#{max_observation_bytes => Cap},
                                      Text, <<"configured">>),

    ok = assert_equal(true, byte_size(SerializedOutput) > Cap),
    ok = assert_truncated_observation(Observation, SerializedOutput, Cap).

default_observation_cap_is_16384_bytes(_Config) ->
    DefaultCap = 16384,
    Text = binary:copy(<<"y">>, 20000),
    {Observation, SerializedOutput} =
        completed_observation_for_cap(omitted, Text, <<"default">>),

    ok = assert_equal(true, byte_size(SerializedOutput) > DefaultCap),
    ok = assert_truncated_observation(Observation, SerializedOutput,
                                      DefaultCap).

failed_explore_run_becomes_next_round_observation(_Config) ->
    Cap = 12,
    ExploreSource =
        <<"(explore (step (id inspect) (tool text_head) "
          "(args (text \"x\") (lines 0))))">>,
    {Store, ActorPid, TaskId, CorrelationId, Prompt,
     FirstCallOpts, SecondCallOpts} =
        two_round_explore(<<"failed-run">>, [text_head],
                          #{max_explore_rounds => 3,
                            max_observation_bytes => Cap},
                          ExploreSource),

    ok = assert_round_allowance(FirstCallOpts, 1, 3),
    ok = assert_round_allowance(SecondCallOpts, 2, 2),
    [#{role := <<"system">>},
     #{role := <<"user">>, content := Prompt},
     #{role := <<"assistant">>, content := ExploreSource},
     #{role := <<"user">>, content := Observation}] =
        maps:get(messages, SecondCallOpts),
    Reason = {invalid_limit, lines, positive_integer},
    ExpectedObservation =
        bounded_term_observation(failed, reason, Reason, Cap),
    ok = assert_equal(ExpectedObservation, Observation),
    ok = wait_for_event(Store, CorrelationId, <<"run.failed">>, 100),
    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),
    ok = assert_equal({ok, #{kind => reply, text => <<"done">>}},
                      soma_actor:get_task_result(ActorPid, TaskId)),
    ok.

timed_out_explore_run_becomes_next_round_observation(_Config) ->
    ExploreSource =
        <<"(explore (step (id wait) (tool sleep) "
          "(args (ms 1000)) (timeout_ms 20)))">>,
    {Store, ActorPid, TaskId, CorrelationId, Prompt,
     FirstCallOpts, SecondCallOpts} =
        two_round_explore(<<"timed-out-run">>, [sleep],
                          #{max_explore_rounds => 3}, ExploreSource),

    ok = assert_round_allowance(FirstCallOpts, 1, 3),
    ok = assert_round_allowance(SecondCallOpts, 2, 2),
    [#{role := <<"system">>},
     #{role := <<"user">>, content := Prompt},
     #{role := <<"assistant">>, content := ExploreSource},
     #{role := <<"user">>, content := Observation}] =
        maps:get(messages, SecondCallOpts),
    ok = assert_equal(<<"(observation (status timeout))">>, Observation),
    ok = wait_for_event(Store, CorrelationId, <<"run.timeout">>, 100),
    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),
    ok = assert_equal({ok, #{kind => reply, text => <<"done">>}},
                      soma_actor:get_task_result(ActorPid, TaskId)),
    ok.

invalid_round_reply_becomes_bounded_next_observation(_Config) ->
    Cap = 19,
    InvalidSource = <<"not-a-lisp-form">>,
    {error, Diagnostics} = soma_lfe:compile(InvalidSource, #{}),
    {Store, ActorPid, TaskId, CorrelationId, Prompt,
     FirstCallOpts, SecondCallOpts} =
        two_round_explore(<<"invalid-reply">>, [text_head],
                          #{max_explore_rounds => 3,
                            max_observation_bytes => Cap},
                          InvalidSource),

    ok = assert_round_allowance(FirstCallOpts, 1, 3),
    ok = assert_round_allowance(SecondCallOpts, 2, 2),
    [#{role := <<"system">>},
     #{role := <<"user">>, content := Prompt},
     #{role := <<"assistant">>, content := InvalidSource},
     #{role := <<"user">>, content := Observation}] =
        maps:get(messages, SecondCallOpts),
    ExpectedObservation =
        bounded_term_observation(failed, diagnostic, Diagnostics, Cap),
    ok = assert_equal(ExpectedObservation, Observation),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    RunStarted =
        [Event || #{event_type := <<"run.started">>} = Event <- Events],
    ok = assert_equal([], RunStarted),
    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),
    ok = assert_equal({ok, #{kind => reply, text => <<"done">>}},
                      soma_actor:get_task_result(ActorPid, TaskId)),
    ok.

configured_round_limit_stops_before_next_llm_start(_Config) ->
    {Store, ActorPid, TaskId, CorrelationId} =
        nonterminal_round_budget_task(
          <<"configured-round-limit">>,
          #{max_explore_rounds => 2, max_llm_calls => 10}, 2),

    Status = wait_for_terminal_task_status(ActorPid, TaskId, 100),
    ok = assert_equal(failed, maps:get(status, Status)),
    ok = assert_equal({budget_exceeded, max_explore_rounds},
                      maps:get(reason, Status, undefined)),
    ok = assert_equal(2, event_count(Store, CorrelationId,
                                     <<"llm.started">>)),
    ok.

default_round_limit_is_five(_Config) ->
    {Store, ActorPid, TaskId, CorrelationId} =
        nonterminal_round_budget_task(
          <<"default-round-limit">>, omitted, 5),

    Status = wait_for_terminal_task_status(ActorPid, TaskId, 100),
    ok = assert_equal(failed, maps:get(status, Status)),
    ok = assert_equal({budget_exceeded, max_explore_rounds},
                      maps:get(reason, Status, undefined)),
    ok = assert_equal(5, event_count(Store, CorrelationId,
                                     <<"llm.started">>)),
    ok.

explore_rounds_consume_existing_llm_call_budget(_Config) ->
    {Store, ActorPid, TaskId, CorrelationId} =
        nonterminal_round_budget_task(
          <<"llm-call-budget">>,
          #{max_explore_rounds => 5, max_llm_calls => 2}, 2),

    Status = wait_for_terminal_task_status(ActorPid, TaskId, 100),
    ok = assert_equal(failed, maps:get(status, Status)),
    ok = assert_equal({budget_exceeded, max_llm_calls},
                      maps:get(reason, Status, undefined)),
    ok = assert_equal(2, event_count(Store, CorrelationId,
                                     <<"llm.succeeded">>)),
    ok = assert_equal(2, event_count(Store, CorrelationId,
                                     <<"llm.started">>)),
    ok.

in_loop_llm_crash_is_terminal_failed(_Config) ->
    TestPid = self(),
    CrashResponder =
        fun(CallOpts) ->
                TestPid ! {provider_worker_request, 2, self(), CallOpts},
                exit(in_loop_llm_crashed)
        end,
    {Store, ActorPid, TaskId, CorrelationId, ExploreSource,
     WorkerPid, SecondCallOpts} =
        in_loop_llm_terminal_task(<<"crash">>, CrashResponder),

    ok = assert_completed_observation(SecondCallOpts, ExploreSource),
    Status = wait_for_terminal_task_status(ActorPid, TaskId, 100),
    ok = assert_equal(failed, maps:get(status, Status)),
    ok = assert_equal(true, maps:is_key(reason, Status)),
    ok = assert_equal(false, is_process_alive(WorkerPid)),
    ok = assert_equal(true, is_process_alive(ActorPid)),
    ok = assert_equal(2, event_count(Store, CorrelationId,
                                     <<"llm.started">>)),
    RoundCompleted = wait_for_round_completed(
                       Store, CorrelationId, 2, 100),
    ok = assert_terminal_llm_round(RoundCompleted, TaskId,
                                   CorrelationId, failed),
    ok.

in_loop_llm_timeout_is_terminal_timeout(_Config) ->
    PreviousTimeout = application:get_env(soma_actor,
                                          llm_default_timeout_ms),
    application:set_env(soma_actor, llm_default_timeout_ms, 50),
    TestPid = self(),
    BlockingResponder =
        fun(CallOpts) ->
                TestPid ! {provider_worker_request, 2, self(), CallOpts},
                receive
                    never_release -> fixed_response(<<"(reply (text \"late\"))">>)
                end
        end,
    try
        {Store, ActorPid, TaskId, CorrelationId, ExploreSource,
         WorkerPid, SecondCallOpts} =
            in_loop_llm_terminal_task(<<"timeout">>, BlockingResponder),

        ok = assert_completed_observation(SecondCallOpts, ExploreSource),
        ok = wait_for_task_status(ActorPid, TaskId, timeout, 100),
        Status = soma_actor:get_task_status(ActorPid, TaskId),
        ok = assert_equal(timeout, maps:get(status, Status)),
        ok = assert_equal(false, is_process_alive(WorkerPid)),
        ok = assert_equal(true, is_process_alive(ActorPid)),
        ok = assert_equal(2, event_count(Store, CorrelationId,
                                         <<"llm.started">>)),
        RoundCompleted = wait_for_round_completed(
                           Store, CorrelationId, 2, 100),
        ok = assert_terminal_llm_round(RoundCompleted, TaskId,
                                       CorrelationId, timeout),
        ok
    after
        restore_llm_default_timeout(PreviousTimeout)
    end.

cancel_during_llm_round_kills_worker_and_cancels_task(_Config) ->
    TestPid = self(),
    BlockingResponder =
        fun(CallOpts) ->
                TestPid ! {provider_worker_request, 2, self(), CallOpts},
                receive
                    never_release -> fixed_response(<<"(reply (text \"late\"))">>)
                end
        end,
    {Store, ActorPid, TaskId, CorrelationId, ExploreSource,
     WorkerPid, SecondCallOpts} =
        in_loop_llm_terminal_task(<<"cancel">>, BlockingResponder),

    ok = assert_completed_observation(SecondCallOpts, ExploreSource),
    ok = soma_actor:cancel(ActorPid, TaskId),
    ok = wait_for_task_status(ActorPid, TaskId, cancelled, 100),
    ok = wait_for_process_dead(WorkerPid, 100),
    ok = assert_equal(true, is_process_alive(ActorPid)),
    ok = assert_equal(1, event_count(Store, CorrelationId,
                                     <<"llm.cancelled">>)),
    RoundCompleted = wait_for_round_completed(
                       Store, CorrelationId, 2, 100),
    ok = assert_terminal_llm_round(RoundCompleted, TaskId,
                                   CorrelationId, cancelled),
    ok = assert_equal(1, event_count(Store, CorrelationId,
                                     <<"actor.task.cancelled">>)),
    ok.

cancel_during_explore_run_kills_tool_worker_and_cancels_task(_Config) ->
    Store = event_store_pid(),
    Source =
        <<"(explore (step (id wait) (tool sleep) "
          "(args (ms 5000)) (timeout_ms 10000)))">>,
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response_sequence => [fixed_response(Source)]},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-cancel-explore-run">>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => [sleep]},
            budget => #{max_explore_rounds => 3},
            event_store => Store}),
    TaskId = <<"task-cancel-explore-run">>,
    CorrelationId = <<"corr-cancel-explore-run">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => <<"wait while inspecting">>},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    Started = wait_for_event_map(Store, CorrelationId,
                                 <<"tool.started">>, 100),
    RunId = maps:get(run_id, Started),
    WorkerPid = maps:get(tool_call_pid, Started),
    {idle, Data} = sys:get_state(ActorPid),
    Tasks = element(6, Data),
    RunPid = maps:get(run_pid, maps:get(TaskId, Tasks)),

    ok = soma_actor:cancel(ActorPid, TaskId),
    Cancelled = wait_for_event_map(Store, CorrelationId,
                                   <<"run.cancelled">>, 100),
    ok = assert_equal(RunId, maps:get(run_id, Cancelled)),
    ok = wait_for_task_status(ActorPid, TaskId, cancelled, 100),
    ok = wait_for_process_dead(WorkerPid, 100),
    ok = wait_for_run_state(RunPid, cancelled, 100),
    ok = assert_equal(true, is_process_alive(ActorPid)),
    ok = assert_equal(1, event_count(Store, CorrelationId,
                                     <<"actor.task.cancelled">>)),
    RoundCompleted = wait_for_round_completed(
                       Store, CorrelationId, 1, 100),
    ok = assert_cancelled_explore_run_round(
           RoundCompleted, TaskId, CorrelationId),
    ok.

actor_reusable_after_round_exhaustion(_Config) ->
    {_Store, ActorPid, TaskId, _CorrelationId} =
        nonterminal_round_budget_task(
          <<"reusable-after-round-exhaustion">>,
          #{max_explore_rounds => 1, max_llm_calls => 5}, 1),
    Status = wait_for_terminal_task_status(ActorPid, TaskId, 100),
    ok = assert_equal(failed, maps:get(status, Status)),
    ok = assert_equal({budget_exceeded, max_explore_rounds},
                      maps:get(reason, Status, undefined)),
    assert_later_direct_task_completes(ActorPid, <<"round-exhaustion">>).

actor_reusable_after_in_loop_llm_failure(_Config) ->
    TestPid = self(),
    CrashResponder =
        fun(CallOpts) ->
                TestPid ! {provider_worker_request, 2, self(), CallOpts},
                exit(reuse_in_loop_llm_crashed)
        end,
    {_Store, ActorPid, TaskId, _CorrelationId, _ExploreSource,
     WorkerPid, _SecondCallOpts} =
        in_loop_llm_terminal_task(<<"reusable-after-failure">>,
                                  CrashResponder),
    Status = wait_for_terminal_task_status(ActorPid, TaskId, 100),
    ok = assert_equal(failed, maps:get(status, Status)),
    ok = wait_for_process_dead(WorkerPid, 100),
    assert_later_direct_task_completes(ActorPid, <<"llm-failure">>).

actor_reusable_after_exploration_cancel(_Config) ->
    Store = event_store_pid(),
    Source =
        <<"(explore (step (id wait) (tool sleep) "
          "(args (ms 5000)) (timeout_ms 10000)))">>,
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response_sequence => [fixed_response(Source)]},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-reusable-after-exploration-cancel">>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => [sleep, echo]},
            budget => #{max_explore_rounds => 3},
            event_store => Store}),
    TaskId = <<"task-reusable-after-exploration-cancel">>,
    CorrelationId = <<"corr-reusable-after-exploration-cancel">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => <<"cancel this exploration">>},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    _Started = wait_for_event_map(Store, CorrelationId,
                                  <<"tool.started">>, 100),
    ok = soma_actor:cancel(ActorPid, TaskId),
    ok = wait_for_task_status(ActorPid, TaskId, cancelled, 100),
    assert_later_direct_task_completes(ActorPid,
                                       <<"exploration-cancel">>).

terminal_run_steps_reuses_proposal_execution_suffix(_Config) ->
    Source =
        <<"(run-steps (step (id finish) (tool echo) "
          "(args (value \"done\"))))">>,
    {Store, ActorPid, TaskId, CorrelationId} =
        terminal_explore_task(<<"run-steps">>, Source, [echo], omitted),
    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),
    ok = assert_equal({ok, #{finish => #{value => <<"done">>}}},
                      soma_actor:get_task_result(ActorPid, TaskId)),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    ProposalSuffix =
        [Type || #{event_type := Type} <- Events,
                 lists:member(Type,
                              [<<"proposal.created">>,
                               <<"proposal.approved">>,
                               <<"proposal.executed">>,
                               <<"proposal.rejected">>])],
    ok = assert_equal([<<"proposal.created">>,
                       <<"proposal.approved">>,
                       <<"proposal.executed">>],
                      ProposalSuffix),
    ok.

terminal_reply_completes_without_run(_Config) ->
    Source = <<"(reply (text \"done\"))">>,
    {Store, ActorPid, TaskId, CorrelationId} =
        terminal_explore_task(<<"reply">>, Source, [echo], omitted),

    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),
    ok = assert_equal({ok, #{kind => reply, text => <<"done">>}},
                      soma_actor:get_task_result(ActorPid, TaskId)),
    ok = assert_equal(0, event_count(Store, CorrelationId,
                                     <<"run.started">>)),
    ok.

terminal_policy_rejection_starts_no_run(_Config) ->
    Source =
        <<"(run-steps (step (id blocked) (tool sleep) "
          "(args (ms 1))))">>,
    {Store, ActorPid, TaskId, CorrelationId} =
        terminal_explore_task(<<"policy-rejection">>, Source, [echo], omitted),

    Status = wait_for_terminal_task_status(ActorPid, TaskId, 100),
    ok = assert_equal(rejected, maps:get(status, Status)),
    ok = assert_equal({tools_not_allowed, [sleep]},
                      maps:get(reason, Status, undefined)),
    ok = assert_equal(0, event_count(Store, CorrelationId,
                                     <<"run.started">>)),
    ok.

terminal_max_steps_failure_starts_no_run(_Config) ->
    Source =
        <<"(run-steps "
          "(step (id first) (tool echo) (args (value \"one\"))) "
          "(step (id second) (tool echo) (args (value \"two\"))))">>,
    {Store, ActorPid, TaskId, CorrelationId} =
        terminal_explore_task(<<"max-steps">>, Source, [echo],
                              #{max_steps => 1}),

    Status = wait_for_terminal_task_status(ActorPid, TaskId, 100),
    ok = assert_equal(failed, maps:get(status, Status)),
    ok = assert_equal({budget_exceeded, max_steps},
                      maps:get(reason, Status, undefined)),
    ok = assert_equal(0, event_count(Store, CorrelationId,
                                     <<"run.started">>)),
    ok.

round_events_use_bounded_schema_and_order(_Config) ->
    ExploreSource =
        <<"(explore (step (id inspect) (tool text_head) "
          "(args (text \"observed\") (lines 1))))">>,
    {Store, ActorPid, TaskId, CorrelationId, _Prompt,
     _FirstCallOpts, _SecondCallOpts} =
        two_round_explore(<<"round-events">>, [text_head],
                          #{max_explore_rounds => 2}, ExploreSource),

    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    RoundEvents =
        [Event || #{event_type := Type} = Event <- Events,
                  Type =:= <<"explore.round.started">>
                      orelse Type =:= <<"explore.round.completed">>],
    [Round1Started, Round1Completed,
     Round2Started, Round2Completed] = RoundEvents,

    ok = assert_round_event_keys(started, Round1Started),
    ok = assert_round_event_keys(completed, Round1Completed),
    ok = assert_round_event_keys(started, Round2Started),
    ok = assert_round_event_keys(completed, Round2Completed),
    ok = assert_equal(
           [{<<"explore.round.started">>, 1, 2},
            {<<"explore.round.completed">>, 1, 2},
            {<<"explore.round.started">>, 2, 1},
            {<<"explore.round.completed">>, 2, 1}],
           [{maps:get(event_type, Event), maps:get(round, Event),
             maps:get(remaining_rounds, Event)} || Event <- RoundEvents]),
    ok = assert_equal(explore, maps:get(action, Round1Completed)),
    ok = assert_equal(completed, maps:get(status, Round1Completed)),
    ObservationBytes = maps:get(observation_bytes, Round1Completed),
    true = is_integer(ObservationBytes) andalso ObservationBytes > 0,
    ok = assert_equal(false, maps:get(truncated, Round1Completed)),
    ok = assert_equal(proposal, maps:get(action, Round2Completed)),
    ok = assert_equal(completed, maps:get(status, Round2Completed)),
    ok = assert_equal(0, maps:get(observation_bytes, Round2Completed)),
    ok = assert_equal(false, maps:get(truncated, Round2Completed)),
    ok.

assert_round_event_keys(Kind, Event) ->
    Mandatory =
        [event_id, timestamp, session_id, run_id, step_id, tool_call_id,
         event_type, payload],
    Identity =
        [actor_id, task_id, correlation_id, round, remaining_rounds],
    Outcome =
        case Kind of
            started -> [];
            completed -> [action, status, observation_bytes, truncated]
        end,
    assert_equal(lists:sort(Mandatory ++ Identity ++ Outcome),
                 lists:sort(maps:keys(Event))).

terminal_explore_task(Suffix, Source, AllowedTools, Budget) ->
    Store = event_store_pid(),
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response => fixed_response(Source)},
    ActorOpts0 =
        #{actor_id => <<"actor-terminal-", Suffix/binary>>,
          model_config => ModelConfig,
          tool_policy => #{allowed_tools => AllowedTools},
          event_store => Store},
    ActorOpts =
        case Budget of
            omitted -> ActorOpts0;
            _ -> ActorOpts0#{budget => Budget}
        end,
    {ok, ActorPid} = soma_actor_sup:start_actor(ActorOpts),
    TaskId = <<"task-terminal-", Suffix/binary>>,
    CorrelationId = <<"corr-terminal-", Suffix/binary>>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => <<"finish the task">>},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    {Store, ActorPid, TaskId, CorrelationId}.

assert_later_direct_task_completes(ActorPid, Suffix) ->
    LaterTaskId = <<"task-reuse-follow-up-", Suffix/binary>>,
    LaterEnvelope =
        #{type => <<"chat">>,
          payload => #{prompt => <<"run after exploration terminal state">>},
          task_id => LaterTaskId,
          correlation_id => <<"corr-reuse-follow-up-", Suffix/binary>>,
          steps => [#{id => follow_up,
                      tool => echo,
                      args => #{value => <<"still reusable">>}}]},
    {ok, LaterTaskId} = soma_actor:send(ActorPid, LaterEnvelope),
    ok = wait_for_task_status(ActorPid, LaterTaskId, completed, 100),
    ok = assert_equal(true, is_process_alive(ActorPid)),
    assert_equal({ok, #{follow_up => #{value => <<"still reusable">>}}},
                 soma_actor:get_task_result(ActorPid, LaterTaskId)).

in_loop_llm_terminal_task(Suffix, SecondResponder) ->
    Store = event_store_pid(),
    ExploreSource =
        <<"(explore (step (id inspect) (tool text_head) "
          "(args (text \"observed\") (lines 1))))">>,
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response_sequence =>
              [fixed_response(ExploreSource), SecondResponder]},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-in-loop-llm-", Suffix/binary>>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => [text_head]},
            budget => #{max_explore_rounds => 3},
            event_store => Store}),
    TaskId = <<"task-in-loop-llm-", Suffix/binary>>,
    CorrelationId = <<"corr-in-loop-llm-", Suffix/binary>>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => <<"inspect before answering">>},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    {WorkerPid, SecondCallOpts} = wait_for_provider_worker_request(2),
    {Store, ActorPid, TaskId, CorrelationId, ExploreSource,
     WorkerPid, SecondCallOpts}.

assert_completed_observation(CallOpts, ExploreSource) ->
    [#{role := <<"system">>},
     #{role := <<"user">>},
     #{role := <<"assistant">>, content := ExploreSource},
     #{role := <<"user">>, content := Observation}] =
        maps:get(messages, CallOpts),
    assert_contains(Observation, <<"(observation (status completed)">>).

assert_terminal_llm_round(Event, TaskId, CorrelationId, Status) ->
    Expected =
        #{task_id => TaskId,
          correlation_id => CorrelationId,
          round => 2,
          remaining_rounds => 2,
          action => invalid_reply,
          status => Status,
          observation_bytes => 0,
          truncated => false},
    Actual = maps:with(maps:keys(Expected), Event),
    assert_equal(Expected, Actual).

assert_cancelled_explore_run_round(Event, TaskId, CorrelationId) ->
    Expected =
        #{task_id => TaskId,
          correlation_id => CorrelationId,
          round => 1,
          remaining_rounds => 3,
          action => explore,
          status => cancelled,
          observation_bytes => 0,
          truncated => false},
    Actual = maps:with(maps:keys(Expected), Event),
    assert_equal(Expected, Actual).

nonterminal_round_budget_task(Suffix, Budget, NonterminalRounds) ->
    Store = event_store_pid(),
    NonterminalResponse = fixed_response(<<"not-a-lisp-form">>),
    TerminalResponse = fixed_response(<<"(reply (text \"too late\"))">>),
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response_sequence =>
              lists:duplicate(NonterminalRounds, NonterminalResponse)
              ++ [TerminalResponse]},
    ActorOpts0 =
        #{actor_id => <<"actor-explore-budget-", Suffix/binary>>,
          model_config => ModelConfig,
          tool_policy => #{allowed_tools => [text_head]},
          event_store => Store},
    ActorOpts =
        case Budget of
            omitted -> ActorOpts0;
            _ -> ActorOpts0#{budget => Budget}
        end,
    {ok, ActorPid} = soma_actor_sup:start_actor(ActorOpts),
    TaskId = <<"task-explore-budget-", Suffix/binary>>,
    CorrelationId = <<"corr-explore-budget-", Suffix/binary>>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => <<"keep exploring">>},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    {Store, ActorPid, TaskId, CorrelationId}.

two_round_explore(Suffix, AllowedTools, Budget, FirstSource) ->
    Store = event_store_pid(),
    TestPid = self(),
    FirstResponse = fixed_response(FirstSource),
    SecondResponse = fixed_response(<<"(reply (text \"done\"))">>),
    FirstResponder =
        fun(CallOpts) ->
                TestPid ! {provider_request, 1, CallOpts},
                FirstResponse
        end,
    SecondResponder =
        fun(CallOpts) ->
                TestPid ! {provider_request, 2, CallOpts},
                SecondResponse
        end,
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response_sequence => [FirstResponder, SecondResponder]},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-explore-", Suffix/binary>>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => AllowedTools},
            budget => Budget,
            event_store => Store}),
    TaskId = <<"task-explore-", Suffix/binary>>,
    CorrelationId = <<"corr-explore-", Suffix/binary>>,
    Prompt = <<"inspect, then answer">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => Prompt},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    FirstCallOpts = wait_for_provider_request(1),
    SecondCallOpts = wait_for_provider_request(2),
    {Store, ActorPid, TaskId, CorrelationId, Prompt,
     FirstCallOpts, SecondCallOpts}.

assert_round_allowance(CallOpts, Round, RemainingRounds) ->
    [#{role := <<"system">>, content := SystemPrompt} | _] =
        maps:get(messages, CallOpts),
    RoundText = iolist_to_binary(
                  [<<"Current exploration round: ">>,
                   integer_to_binary(Round), <<".">>]),
    RemainingText =
        iolist_to_binary(
          [<<"Remaining max_explore_rounds allowance (including this round): ">>,
           integer_to_binary(RemainingRounds), <<".">>]),
    ok = assert_contains(SystemPrompt, RoundText),
    assert_contains(SystemPrompt, RemainingText).

bounded_term_observation(Status, Field, Term, Cap) ->
    Serialized = iolist_to_binary(soma_lisp:render(Term)),
    true = byte_size(Serialized) > Cap,
    Retained = binary:part(Serialized, 0, Cap),
    iolist_to_binary(
      [<<"(observation (status ">>, atom_to_binary(Status, utf8),
       <<") (">>, atom_to_binary(Field, utf8), <<" ">>,
       soma_lisp:render(Retained), <<") (truncated true))">>]).

completed_observation_for_cap(Budget, Text, Suffix) ->
    Store = event_store_pid(),
    TestPid = self(),
    ExploreSource =
        iolist_to_binary(
          [<<"(explore (step (id inspect) (tool text_head) "
             "(args (text \"">>, Text, <<"\") (lines 1))))">>]),
    TerminalSource = <<"(reply (text \"done\"))">>,
    SecondResponder =
        fun(CallOpts) ->
                TestPid ! {provider_request, 2, CallOpts},
                fixed_response(TerminalSource)
        end,
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response_sequence =>
              [fixed_response(ExploreSource), SecondResponder]},
    ActorOpts0 =
        #{actor_id => <<"actor-observation-cap-", Suffix/binary>>,
          model_config => ModelConfig,
          tool_policy => #{allowed_tools => [text_head]},
          event_store => Store},
    ActorOpts =
        case Budget of
            omitted -> ActorOpts0;
            _ -> ActorOpts0#{budget => Budget}
        end,
    {ok, ActorPid} = soma_actor_sup:start_actor(ActorOpts),
    TaskId = <<"task-observation-cap-", Suffix/binary>>,
    CorrelationId = <<"corr-observation-cap-", Suffix/binary>>,
    Prompt = <<"inspect a large value">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => Prompt},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},

    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    SecondCallOpts = wait_for_provider_request(2),
    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),
    [#{role := <<"system">>},
     #{role := <<"user">>, content := Prompt},
     #{role := <<"assistant">>, content := ExploreSource},
     #{role := <<"user">>, content := Observation}] =
        maps:get(messages, SecondCallOpts),
    SerializedOutput =
        iolist_to_binary(
          soma_lisp:render(#{text => Text, truncated => false})),
    {Observation, SerializedOutput}.

assert_truncated_observation(Observation, SerializedOutput, Cap) ->
    Marker = <<"(truncated true)">>,
    case binary:match(Observation, Marker) of
        nomatch ->
            ct:fail({missing_observation_truncation_marker, Cap});
        _ ->
            ok
    end,
    RetainedOutput = binary:part(SerializedOutput, 0, Cap),
    ExpectedObservation =
        iolist_to_binary(
          [<<"(observation (status completed) (outputs "
             "(step (id inspect) (output ">>,
           soma_lisp:render(RetainedOutput),
           <<"))) (truncated true))">>]),
    ok = assert_equal(Cap, byte_size(RetainedOutput)),
    assert_equal(ExpectedObservation, Observation).

fixed_response(Content) ->
    Body =
        iolist_to_binary(
          json:encode(
            #{<<"choices">> =>
                  [#{<<"message">> => #{<<"content">> => Content}}]})),
    {200, Body}.

wait_for_provider_request(Round) ->
    receive
        {provider_request, Round, CallOpts} ->
            CallOpts
    after 2000 ->
        ct:fail({provider_request_timeout, Round})
    end.

wait_for_provider_worker_request(Round) ->
    receive
        {provider_worker_request, Round, WorkerPid, CallOpts} ->
            {WorkerPid, CallOpts}
    after 2000 ->
        ct:fail({provider_worker_request_timeout, Round})
    end.

wait_for_task_status(_ActorPid, _TaskId, Status, 0) ->
    ct:fail({task_status_timeout, Status});
wait_for_task_status(ActorPid, TaskId, Status, N) ->
    case soma_actor:get_task_status(ActorPid, TaskId) of
        #{status := Status} ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_task_status(ActorPid, TaskId, Status, N - 1)
    end.

wait_for_process_dead(_Pid, 0) ->
    ct:fail(process_still_alive);
wait_for_process_dead(Pid, N) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(20),
            wait_for_process_dead(Pid, N - 1)
    end.

wait_for_run_state(_RunPid, Target, 0) ->
    ct:fail({run_state_timeout, Target});
wait_for_run_state(RunPid, Target, N) ->
    case sys:get_state(RunPid) of
        {Target, _Data} ->
            ok;
        {_Other, _Data} ->
            timer:sleep(20),
            wait_for_run_state(RunPid, Target, N - 1)
    end.

wait_for_terminal_task_status(_ActorPid, _TaskId, 0) ->
    ct:fail(task_terminal_status_timeout);
wait_for_terminal_task_status(ActorPid, TaskId, N) ->
    Status = soma_actor:get_task_status(ActorPid, TaskId),
    case maps:get(status, Status) of
        completed -> Status;
        failed -> Status;
        rejected -> Status;
        cancelled -> Status;
        _ ->
            timer:sleep(20),
            wait_for_terminal_task_status(ActorPid, TaskId, N - 1)
    end.

event_count(Store, CorrelationId, EventType) ->
    length([Event || Event <-
                         soma_event_store:by_correlation(Store, CorrelationId),
                     maps:get(event_type, Event, undefined) =:= EventType]).

assert_equal(Expected, Actual) when Expected =:= Actual ->
    ok;
assert_equal(Expected, Actual) ->
    ct:fail({assert_equal, [{expected, Expected}, {actual, Actual}]}).

assert_contains(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        nomatch ->
            ct:fail({missing_binary, Needle, Haystack});
        _ ->
            ok
    end.

wait_for_event(_Store, _CorrelationId, EventType, 0) ->
    error({timeout, EventType});
wait_for_event(Store, CorrelationId, EventType, N) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    case lists:any(
           fun(Event) -> maps:get(event_type, Event, undefined) =:= EventType end,
           Events) of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait_for_event(Store, CorrelationId, EventType, N - 1)
    end.

wait_for_event_map(_Store, _CorrelationId, _EventType, 0) ->
    undefined;
wait_for_event_map(Store, CorrelationId, EventType, N) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    case [Event || Event <- Events,
                   maps:get(event_type, Event, undefined) =:= EventType] of
        [Event | _] ->
            Event;
        [] ->
            timer:sleep(20),
            wait_for_event_map(Store, CorrelationId, EventType, N - 1)
    end.

wait_for_round_completed(_Store, _CorrelationId, Round, 0) ->
    error({timeout, <<"explore.round.completed">>, Round});
wait_for_round_completed(Store, CorrelationId, Round, N) ->
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    case [Event || Event <- Events,
                   maps:get(event_type, Event, undefined) =:=
                       <<"explore.round.completed">>,
                   maps:get(round, Event, undefined) =:= Round] of
        [Event | _] ->
            Event;
        [] ->
            timer:sleep(20),
            wait_for_round_completed(Store, CorrelationId, Round, N - 1)
    end.

restore_llm_default_timeout(undefined) ->
    application:unset_env(soma_actor, llm_default_timeout_ms);
restore_llm_default_timeout({ok, TimeoutMs}) ->
    application:set_env(soma_actor, llm_default_timeout_ms, TimeoutMs).

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

%% Review finding 1 (#231): an admission rejection that is not the
%% non-reader case must still close the round as a bounded observation --
%% a policy-denied tool must not strand the task in `running'.
policy_rejected_explore_becomes_bounded_observation_and_continues(_Config) ->
    Store = event_store_pid(),
    ExploreSource =
        <<"(explore (step (id mutate) (tool file_write) "
          "(args (path \"blocked.txt\") (bytes \"blocked\"))))">>,
    {_Store, ActorPid, TaskId, CorrelationId, Prompt,
     _FirstCallOpts, SecondCallOpts} =
        two_round_explore(<<"policy-rejected">>, [echo],
                          #{max_explore_rounds => 3}, ExploreSource),
    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),

    [#{role := <<"system">>},
     #{role := <<"user">>, content := Prompt},
     #{role := <<"assistant">>, content := ExploreSource},
     #{role := <<"user">>, content := Observation}] =
        maps:get(messages, SecondCallOpts),
    ExpectedObservation =
        <<"(observation (status rejected) "
          "(policy tools_not_allowed) (tools file_write))">>,
    ok = assert_equal(ExpectedObservation, Observation),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    RunStarted =
        [Event || #{event_type := <<"run.started">>} = Event <- Events],
    ok = assert_equal([], RunStarted),
    Completed =
        [Event || #{event_type := <<"explore.round.completed">>,
                    round := 1} = Event <- Events],
    [#{action := explore, status := rejected}] = Completed,
    ok = assert_equal({ok, #{kind => reply, text => <<"done">>}},
                      soma_actor:get_task_result(ActorPid, TaskId)),
    ok.

%% Review finding 1 (#231), second admission shape: a tool with no live
%% descriptor closes the round as a bounded observation instead of leaving
%% the task `running' with no completion event.
unknown_tool_explore_becomes_bounded_observation_and_continues(_Config) ->
    Store = event_store_pid(),
    ExploreSource =
        <<"(explore (step (id ghost) (tool text_vanished) "
          "(args (text \"x\"))))">>,
    {_Store, ActorPid, TaskId, CorrelationId, _Prompt,
     _FirstCallOpts, SecondCallOpts} =
        two_round_explore(<<"unknown-tool">>, [text_vanished],
                          #{max_explore_rounds => 3}, ExploreSource),
    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),

    [_, _, _, #{role := <<"user">>, content := Observation}] =
        maps:get(messages, SecondCallOpts),
    ExpectedObservation =
        <<"(observation (status rejected) "
          "(tool text_vanished) (error not_found))">>,
    ok = assert_equal(ExpectedObservation, Observation),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    RunStarted =
        [Event || #{event_type := <<"run.started">>} = Event <- Events],
    ok = assert_equal([], RunStarted),
    Completed =
        [Event || #{event_type := <<"explore.round.completed">>,
                    round := 1} = Event <- Events],
    [#{action := explore, status := rejected}] = Completed,
    ok = assert_equal({ok, #{kind => reply, text => <<"done">>}},
                      soma_actor:get_task_result(ActorPid, TaskId)),
    ok.

%% Review finding 2 (#231): a normal provider `{error, Reason}' result (an
%% HTTP 500, not a worker crash) must become terminal failed task data
%% immediately instead of being swallowed and later mislabelled `timeout'.
in_loop_llm_error_result_is_terminal_failed(_Config) ->
    Store = event_store_pid(),
    TestPid = self(),
    ExploreSource =
        <<"(explore (step (id inspect) (tool text_head) "
          "(args (text \"observed\") (lines 1))))">>,
    SecondResponder =
        fun(CallOpts) ->
                TestPid ! {provider_request, 2, CallOpts},
                {500, <<"boom">>}
        end,
    ModelConfig =
        #{provider => openai_compat,
          base_url => <<"api.example.test/v1">>,
          model => <<"test-model">>,
          explore => true,
          response_sequence =>
              [fixed_response(ExploreSource), SecondResponder]},
    {ok, ActorPid} =
        soma_actor_sup:start_actor(
          #{actor_id => <<"actor-explore-llm-error">>,
            model_config => ModelConfig,
            tool_policy => #{allowed_tools => [text_head]},
            budget => #{max_explore_rounds => 3},
            event_store => Store}),
    TaskId = <<"task-explore-llm-error">>,
    CorrelationId = <<"corr-explore-llm-error">>,
    Envelope =
        #{type => <<"chat">>,
          payload => #{prompt => <<"inspect before answering">>},
          task_id => TaskId,
          correlation_id => CorrelationId,
          llm => #{}},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    _SecondCallOpts = wait_for_provider_request(2),
    ok = wait_for_task_status(ActorPid, TaskId, failed, 100),

    Events = soma_event_store:by_correlation(Store, CorrelationId),
    LlmFailed =
        [Event || #{event_type := <<"llm.failed">>} = Event <- Events],
    ok = assert_equal(1, length(LlmFailed)),
    TerminalRounds =
        [Event || #{event_type := <<"explore.round.completed">>,
                    round := 2, action := invalid_reply,
                    status := failed} = Event <- Events],
    ok = assert_equal(1, length(TerminalRounds)),
    %% The status must not be rewritten to `timeout' by a stale call timer.
    timer:sleep(100),
    Status = soma_actor:get_task_status(ActorPid, TaskId),
    ok = assert_equal(failed, maps:get(status, Status)),
    ok.

%% Review finding 3 (#231): a finished LLM call must leave no bookkeeping
%% behind -- no `llm_calls' entry and no stale call fields on the task --
%% so a queued timeout for an old call can never target the next round's
%% worker.
finished_llm_call_bookkeeping_cleared_between_rounds(_Config) ->
    ExploreSource =
        <<"(explore (step (id inspect) (tool text_head) "
          "(args (text \"observed\") (lines 1))))">>,
    {_Store, ActorPid, TaskId, _CorrelationId, _Prompt,
     _FirstCallOpts, _SecondCallOpts} =
        two_round_explore(<<"bookkeeping">>, [text_head],
                          #{max_explore_rounds => 3}, ExploreSource),
    ok = wait_for_task_status(ActorPid, TaskId, completed, 100),

    {idle, Data} = sys:get_state(ActorPid),
    LlmCalls = element(10, Data),
    ok = assert_equal(#{}, LlmCalls),
    Tasks = element(6, Data),
    Task = maps:get(TaskId, Tasks),
    ok = assert_equal(false, maps:is_key(llm_call_id, Task)),
    ok = assert_equal(false, maps:is_key(llm_call_pid, Task)),
    ok = assert_equal(false, maps:is_key(llm_call_mref, Task)),
    ok = assert_equal(false, maps:is_key(llm_timer_ref, Task)),
    ok.
