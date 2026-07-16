-module(soma_delegate_adaptive_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([test_request_boundary_normalizes_allowlist_and_rejects_forbidden_inputs/1]).
-export([test_prompt_projection_uses_exact_task_local_fields/1]).
-export([test_model_action_admission_order_and_state_spine/1]).
-export([test_denied_and_malformed_actions_stop_before_run/1]).
-export([test_reader_state_terminal_sequence_threads_observations/1]).
-export([test_failed_and_timed_out_actions_feed_observations_with_fresh_invocations/1]).
-export([test_prompt_schemas_equal_policy_capability_intersection/1]).
-export([test_round_llm_and_tool_budgets_stop_before_child_start_and_reset/1]).
-export([test_task_deadline_tears_down_all_owned_execution_children/1]).
-export([test_context_preflight_and_provider_usage_accounting/1]).
-export([test_oversized_observation_uses_stable_task_artifact_and_bounded_slice/1]).
-export([test_recent_round_window_replaces_old_observations_with_one_summary/1]).
-export([test_pinned_safety_state_is_exact_and_never_truncated/1]).
-export([test_maximum_round_prompts_obey_cumulative_input_bound/1]).
-export([test_adaptive_events_are_documented_scrubbed_and_4096_byte_bounded/1]).
-export([test_terminal_projection_has_exact_public_contract/1]).
-export([test_review_regressions_are_bounded_and_safety_preserving/1]).
-export([test_review_actual_dispatch_usage_and_observation_regressions/1]).
-export([invoke/2]).

all() ->
    [test_request_boundary_normalizes_allowlist_and_rejects_forbidden_inputs,
     test_prompt_projection_uses_exact_task_local_fields,
     test_model_action_admission_order_and_state_spine,
     test_denied_and_malformed_actions_stop_before_run,
     test_reader_state_terminal_sequence_threads_observations,
     test_failed_and_timed_out_actions_feed_observations_with_fresh_invocations,
     test_prompt_schemas_equal_policy_capability_intersection,
     test_round_llm_and_tool_budgets_stop_before_child_start_and_reset,
     test_task_deadline_tears_down_all_owned_execution_children,
     test_context_preflight_and_provider_usage_accounting,
     test_oversized_observation_uses_stable_task_artifact_and_bounded_slice,
     test_recent_round_window_replaces_old_observations_with_one_summary,
     test_pinned_safety_state_is_exact_and_never_truncated,
     test_maximum_round_prompts_obey_cumulative_input_bound,
     test_adaptive_events_are_documented_scrubbed_and_4096_byte_bounded,
     test_terminal_projection_has_exact_public_contract,
     test_review_regressions_are_bounded_and_safety_preserving,
     test_review_actual_dispatch_usage_and_observation_regressions].

init_per_testcase(_TestCase, Config) ->
    ok = application:unset_env(soma_actor, delegate_runtime_options),
    {ok, Started} = application:ensure_all_started(soma_actor),
    [{started_apps, Started} | Config].

end_per_testcase(_TestCase, _Config) ->
    application:stop(soma_actor),
    application:stop(soma_runtime),
    ok = application:unset_env(soma_actor, delegate_runtime_options),
    ok.

test_request_boundary_normalizes_allowlist_and_rejects_forbidden_inputs(
  _Config) ->
    AllowedKeys =
        [request_id, correlation_id, objective, output_contract,
         capability_scope, resource_handles, artifacts, budgets],
    ValidRequest =
        #{request_id => <<"delegate-boundary-valid">>,
          correlation_id => <<"delegate-boundary-correlation">>,
          objective => #{goal => <<"return a bounded result">>},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => [<<"echo">>]},
          resource_handles => #{workspace => <<"workspace-1">>},
          artifacts => [#{handle => <<"artifact-1">>}],
          budgets => #{max_rounds => 1}},
    ForbiddenRows =
        [{product_conversation_history,
          #{objective =>
                #{product_conversation_history =>
                      [#{role => user, text => <<"private history">>}]}}},
         {provider_credentials,
          #{resource_handles =>
                #{provider_credentials =>
                      #{api_key => <<"provider-secret">>}}}},
         {raw_leases,
          #{resource_handles =>
                #{raw_leases => [#{lease => <<"raw-lease">>}]}}},
         {process_terms,
          #{artifacts =>
                [#{pid => self(),
                   reference => make_ref(),
                   callback => fun() -> ok end}]}},
         {invalid_budgets_shape,
          #{budgets => []}},
         {invalid_capability_shape,
          #{capability_scope => []}},
         {invalid_artifacts_shape,
          #{artifacts => #{handle => <<"artifact-1">>}}},
         {invalid_resource_handles_shape,
          #{resource_handles => []}},
         {invalid_artifact_handle_shape,
          #{artifacts => [#{handle => []}]}},
         {round_sequence,
          #{round_sequence => []}}],
    Cases =
        [{accepted, ValidRequest}
         | [{forbidden,
             Class,
             maps:merge(
               ValidRequest#{request_id =>
                                 <<"delegate-boundary-forbidden-",
                                   (atom_to_binary(Class, utf8))/binary>>},
               Extra)}
            || {Class, Extra} <- ForbiddenRows]],
    Actual = [observe_boundary_case(Case) || Case <- Cases],
    Expected =
        [#{case_name => accepted,
           reply => accepted,
           coordinator_count => 1,
           normalized_request => ValidRequest,
           normalized_keys => lists:sort(AllowedKeys)}
         | [#{case_name => Class,
              reply => {error, invalid_delegate_request},
              coordinator_count => 0}
            || {Class, _Extra} <- ForbiddenRows]],
    ?assertEqual(Expected, Actual).

test_prompt_projection_uses_exact_task_local_fields(_Config) ->
    TestPid = self(),
    Objective = #{goal => <<"return the task-local answer">>},
    OutputContract = #{format => <<"text">>},
    CapabilityScope = #{tools => []},
    Responder =
        fun(CallOpts) ->
                TestPid !
                    {delegate_prompt_projection,
                     maps:get(prompt_projection, CallOpts, missing)},
                terminal_response(<<"task-local answer">>)
        end,
    RuntimeOptions =
        #{round_sequence =>
              [#{llm =>
                     #{provider => openai_compat,
                       base_url => <<"api.example.test/v1">>,
                       api_key => <<"test-only-key">>,
                       model => <<"test-model">>,
                       response => Responder},
                 decision => terminal}]},
    ok = application:set_env(
           soma_actor, delegate_runtime_options, RuntimeOptions),
    Request =
        #{request_id => <<"delegate-prompt-fields">>,
          correlation_id => <<"delegate-prompt-fields-correlation">>,
          objective => Objective,
          output_contract => OutputContract,
          capability_scope => CapabilityScope,
          artifacts => []},

    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Projection = receive_prompt_projection(),
    #{status := succeeded} = wait_for_terminal_projection(TaskId, 100),

    ExpectedKeys =
        lists:sort(
          [objective, output_contract, task_summary,
           pinned_safety_state, recent_rounds, artifact_excerpts,
           tool_schemas]),
    Actual =
        case Projection of
            Prompt when is_map(Prompt) ->
                #{keys => lists:sort(maps:keys(Prompt)),
                  objective => maps:get(objective, Prompt, missing),
                  output_contract =>
                      maps:get(output_contract, Prompt, missing),
                  pinned_safety_state =>
                      maps:get(pinned_safety_state, Prompt, missing)};
            Missing ->
                Missing
        end,
    Expected =
        #{keys => ExpectedKeys,
          objective => Objective,
          output_contract => OutputContract,
          pinned_safety_state =>
              #{capability_scope => CapabilityScope,
                mutation_ledger => [],
                unknown_outcome_ledger => [],
                idempotency_state => #{}}},
    ?assertEqual(Expected, Actual).

test_model_action_admission_order_and_state_spine(_Config) ->
    ToolName = delegate_state_probe,
    ToolManifest =
        #{name => ToolName,
          effect => state,
          idempotent => false,
          timeout_ms => 1000,
          adapter => erlang_module,
          module => ?MODULE,
          description => <<"Records one local state transition.">>},
    ok = soma_tool_registry:register_tool(ToolManifest),
    {ok, #{effect := state}} =
        soma_tool_registry:resolve_descriptor(ToolName),
    ActionSource =
        <<"(run-steps (step (id state_action) "
          "(tool delegate_state_probe) "
          "(args (value \"committed\"))))">>,
    Responder = fun(_CallOpts) -> terminal_response(ActionSource) end,
    RuntimeOptions =
        #{tool_policy => #{allowed_tools => [ToolName]},
          round_sequence =>
              [#{llm =>
                     #{provider => openai_compat,
                       base_url => <<"api.example.test/v1">>,
                       api_key => <<"test-only-key">>,
                       model => <<"test-model">>,
                       response => Responder},
                 decision => terminal},
               #{llm =>
                     #{directive => success,
                       output => <<"admission trace complete">>},
                 decision => terminal}]},
    ok = application:set_env(
           soma_actor, delegate_runtime_options, RuntimeOptions),
    Request =
        #{request_id => <<"delegate-admission-state-spine">>,
          correlation_id => <<"delegate-admission-state-spine-correlation">>,
          objective => #{goal => <<"perform the admitted state action">>},
          output_contract => #{format => <<"state-result">>},
          capability_scope => #{tools => [atom_to_binary(ToolName, utf8)]},
          artifacts => []},

    ok = start_admission_spine_trace(),
    Trace =
        try
            {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
            #{status := succeeded} =
                wait_for_terminal_projection(TaskId, 100),
            collect_admission_spine_trace([])
        after
            clear_admission_spine_trace()
        end,

    AdmissionOrder =
        [Marker || {Marker, _Pid, _Args} <- Trace,
                   lists:member(
                     Marker, [proposal_normalize, global_policy,
                              task_capability])],
    ?assertEqual(
       [proposal_normalize, global_policy, task_capability],
       AdmissionOrder),
    AdmissionPids =
        lists:usort(
          [Pid || {Marker, Pid, _Args} <- Trace,
                  lists:member(
                    Marker, [proposal_normalize, global_policy,
                             task_capability, run_start])]),
    [RoundWorkerPid] = AdmissionPids,
    [{run_start, RoundWorkerPid, [RunOpts]}] =
        [Call || {run_start, _, _} = Call <- Trace],
    ?assertEqual(
       [#{id => state_action,
          tool => ToolName,
          args => #{value => <<"committed">>}}],
       maps:get(steps, RunOpts)),
    [{tool_start, RunPid, [ToolOpts]}] =
        [Call || {tool_start, _, _} = Call <- Trace],
    ?assertEqual(?MODULE, maps:get(module, ToolOpts)),
    [{state_invoke, ToolCallPid,
      [#{value := <<"committed">>}, _Ctx]}] =
        [Call || {state_invoke, _, _} = Call <- Trace],
    ?assert(RoundWorkerPid =/= RunPid),
    ?assert(RunPid =/= ToolCallPid),
    ?assert(RoundWorkerPid =/= ToolCallPid).

test_denied_and_malformed_actions_stop_before_run(_Config) ->
    Action =
        #{kind => run_steps,
          steps =>
              [#{id => denied_action,
                 tool => echo,
                 args => #{value => <<"must not run">>}}]},
    MalformedAction =
        #{kind => run_steps,
          steps => [#{id => malformed_action, args => #{}}]},
    Cases =
        [{global_policy_denied,
          #{allowed_tools => []},
          #{tools => [<<"echo">>]},
          Action,
          rejected},
         {task_capability_denied,
          #{allowed_tools => [echo]},
          #{tools => []},
          Action,
          rejected},
         {model_rejected,
          #{allowed_tools => [echo]},
          #{tools => []},
          #{kind => reject, reason => <<"model declined the task">>},
          rejected},
         {malformed_action,
          #{allowed_tools => [echo]},
          #{tools => [<<"echo">>]},
          MalformedAction,
          failed}],
    Actual = [observe_denied_action_case(Case) || Case <- Cases],
    Expected =
        [#{case_name => CaseName,
           status => ExpectedStatus,
           run_started => false}
         || {CaseName, _Policy, _Scope, _Proposal, ExpectedStatus} <- Cases],
    ?assertEqual(Expected, Actual).

test_reader_state_terminal_sequence_threads_observations(_Config) ->
    ToolName = delegate_state_probe,
    ToolManifest =
        #{name => ToolName,
          effect => state,
          idempotent => false,
          timeout_ms => 1000,
          adapter => erlang_module,
          module => ?MODULE,
          description => <<"Records one local state transition.">>},
    ok = soma_tool_registry:register_tool(ToolManifest),
    ReaderObservation = <<"reader observation committed">>,
    StateObservation = <<"state observation committed">>,
    FinalResult = <<"reader and state complete">>,
    Responses =
        [<<"(run-steps (step (id reader_action) (tool text_head) "
           "(args (text \"reader observation committed\") (lines 1))))">>,
         <<"(run-steps (step (id state_action) "
           "(tool delegate_state_probe) "
           "(args (value \"state observation committed\"))))">>,
         <<"(reply (text \"reader and state complete\"))">>],
    TestPid = self(),
    RoundSequence =
        [#{llm =>
               #{provider => openai_compat,
                 base_url => <<"api.example.test/v1">>,
                 api_key => <<"test-only-key">>,
                 model => <<"test-model">>,
                 response =>
                     fun(CallOpts) ->
                             TestPid !
                                 {delegate_sequence_prompt,
                                  Round, CallOpts},
                             terminal_response(Response)
                     end}}
         || {Round, Response} <- lists:enumerate(Responses)],
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{tool_policy => #{allowed_tools => [text_head, ToolName]},
             round_sequence => RoundSequence}),
    CorrelationId = <<"delegate-reader-state-terminal-correlation">>,
    Request =
        #{request_id => <<"delegate-reader-state-terminal">>,
          correlation_id => CorrelationId,
          objective => #{goal => <<"read, update state, then reply">>},
          output_contract => #{format => <<"text">>},
          capability_scope =>
              #{tools => [<<"text_head">>,
                           atom_to_binary(ToolName, utf8)]},
          artifacts => []},

    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Terminal = wait_for_terminal_projection(TaskId, 100),
    Prompts = collect_sequence_prompts([]),
    Events =
        soma_event_store:by_correlation(
          event_store_pid(), CorrelationId),
    StartedSteps =
        [StepId || #{event_type := <<"tool.started">>,
                     step_id := StepId} <- Events],
    StateStartedCount =
        length([state_action || state_action <- StartedSteps]),
    Actual =
        #{terminal =>
              #{status => maps:get(status, Terminal),
                result => maps:get(result, Terminal, missing)},
          prompt_rounds => [Round || {Round, _CallOpts} <- Prompts],
          reader_observation_in_next_prompt =>
              next_prompt_contains(1, ReaderObservation, Prompts),
          state_observation_in_next_prompt =>
              next_prompt_contains(2, StateObservation, Prompts),
          started_steps => StartedSteps,
          state_tool_started_count => StateStartedCount},
    Expected =
        #{terminal => #{status => succeeded, result => FinalResult},
          prompt_rounds => [1, 2, 3],
          reader_observation_in_next_prompt => true,
          state_observation_in_next_prompt => true,
          started_steps => [reader_action, state_action],
          state_tool_started_count => 1},
    ?assertEqual(Expected, Actual).

test_failed_and_timed_out_actions_feed_observations_with_fresh_invocations(
  _Config) ->
    ToolName = delegate_state_probe,
    ToolManifest =
        #{name => ToolName,
          effect => state,
          idempotent => false,
          timeout_ms => 1000,
          adapter => erlang_module,
          module => ?MODULE,
          description =>
              <<"Fails, times out, or records one local state transition.">>},
    ok = soma_tool_registry:register_tool(ToolManifest),
    ObservationCap = 64,
    FailureReason = known_state_failure_reason(),
    ExpectedFailureObservation =
        bounded_failure_observation(FailureReason, ObservationCap),
    Responses =
        [<<"(run-steps (step (id state_action) "
           "(tool delegate_state_probe) (args (mode \"error\"))))">>,
         <<"(run-steps (step (id state_action) "
           "(tool delegate_state_probe) (args (mode \"timeout\")) "
           "(timeout_ms 20)))">>,
         <<"(run-steps (step (id state_action) "
           "(tool delegate_state_probe) (args (mode \"success\"))))">>,
         <<"(reply (text \"known failures observed and retry complete\"))">>],
    TestPid = self(),
    RoundSequence =
        [#{llm =>
               #{provider => openai_compat,
                 base_url => <<"api.example.test/v1">>,
                 api_key => <<"test-only-key">>,
                 model => <<"test-model">>,
                 response =>
                     fun(CallOpts) ->
                             TestPid !
                                 {delegate_failure_prompt,
                                  Round,
                                  maps:get(prompt_projection, CallOpts)},
                             terminal_response(Response)
                     end}}
         || {Round, Response} <- lists:enumerate(Responses)],
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{tool_policy => #{allowed_tools => [ToolName]},
             round_sequence => RoundSequence}),
    CorrelationId = <<"delegate-known-action-failures-correlation">>,
    Request =
        #{request_id => <<"delegate-known-action-failures">>,
          correlation_id => CorrelationId,
          objective => #{goal => <<"observe known failures, then retry">>},
          output_contract => #{format => <<"text">>},
          capability_scope =>
              #{tools => [atom_to_binary(ToolName, utf8)]},
          artifacts => [],
          budgets => #{max_observation_bytes => ObservationCap}},

    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Terminal = wait_for_terminal_projection(TaskId, 200),
    Prompts = collect_failure_prompts([]),
    FailureObservation = next_round_observation(1, Prompts),
    TimeoutObservation = next_round_observation(2, Prompts),
    FinalMutations = prompt_mutation_ledger(4, Prompts),
    Events =
        soma_event_store:by_correlation(
          event_store_pid(), CorrelationId),
    Invocations =
        [maps:with([run_id, step_id, tool_call_id], Event)
         || #{event_type := <<"tool.started">>,
              step_id := state_action} = Event <- Events],
    RunIds = [maps:get(run_id, Invocation) || Invocation <- Invocations],
    ToolCallIds =
        [maps:get(tool_call_id, Invocation) || Invocation <- Invocations],
    MutationRunIds =
        [maps:get(run_id, Mutation, missing) || Mutation <- FinalMutations],
    MutationOutcomes =
        [maps:get(outcome, Mutation, missing) || Mutation <- FinalMutations],
    Actual =
        #{terminal_status => maps:get(status, Terminal),
          prompt_rounds => [Round || {Round, _Projection} <- Prompts],
          failure_observation => FailureObservation,
          timeout_observation => TimeoutObservation,
          state_invocation_count => length(Invocations),
          fresh_run_ids => length(lists:usort(RunIds)) =:= 3,
          fresh_tool_call_ids =>
              length(lists:usort(ToolCallIds)) =:= 3,
          mutation_runs_match_correlation_trail =>
              MutationRunIds =:= RunIds,
          mutation_outcomes => MutationOutcomes},
    Expected =
        #{terminal_status => succeeded,
          prompt_rounds => [1, 2, 3, 4],
          failure_observation => ExpectedFailureObservation,
          timeout_observation => #{status => timeout},
          state_invocation_count => 3,
          fresh_run_ids => true,
          fresh_tool_call_ids => true,
          mutation_runs_match_correlation_trail => true,
          mutation_outcomes => [failed, timeout, succeeded]},
    ?assertEqual(Expected, Actual).

test_prompt_schemas_equal_policy_capability_intersection(_Config) ->
    TestPid = self(),
    Responder =
        fun(CallOpts) ->
                TestPid !
                    {delegate_prompt_projection,
                     maps:get(prompt_projection, CallOpts, missing)},
                terminal_response(<<"schema intersection observed">>)
        end,
    RuntimeOptions =
        #{tool_policy => #{allowed_tools => [echo, sleep]},
          round_sequence =>
              [#{llm =>
                     #{provider => openai_compat,
                       base_url => <<"api.example.test/v1">>,
                       api_key => <<"test-only-key">>,
                       model => <<"test-model">>,
                       response => Responder},
                 decision => terminal}]},
    ok = application:set_env(
           soma_actor, delegate_runtime_options, RuntimeOptions),
    Request =
        #{request_id => <<"delegate-prompt-schema-intersection">>,
          correlation_id =>
              <<"delegate-prompt-schema-intersection-correlation">>,
          objective => #{goal => <<"inspect the admitted schema">>},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => [<<"echo">>, <<"file_read">>]},
          artifacts => []},

    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Projection = receive_prompt_projection(),
    #{status := succeeded} = wait_for_terminal_projection(TaskId, 100),
    Catalog = soma_tool_registry:catalog(),
    Expected = [Schema || Schema = #{name := echo} <- Catalog],
    ?assertEqual(Expected, maps:get(tool_schemas, Projection, missing)).

test_round_llm_and_tool_budgets_stop_before_child_start_and_reset(
  _Config) ->
    Cases =
        [{max_rounds,
          #{max_rounds => 1,
            max_llm_calls => 10,
            max_tool_calls => 10},
          terminal,
          #{rounds => 1, llm_calls => 1, tool_calls => 1},
          #{round_workers => 1, llm_workers => 1, runs => 1}},
         {max_llm_calls,
          #{max_rounds => 10,
            max_llm_calls => 1,
            max_tool_calls => 10},
          terminal,
          #{rounds => 2, llm_calls => 1, tool_calls => 1},
          #{round_workers => 2, llm_workers => 1, runs => 1}},
         {max_tool_calls,
          #{max_rounds => 10,
            max_llm_calls => 10,
            max_tool_calls => 1},
          action,
          #{rounds => 2, llm_calls => 2, tool_calls => 1},
          #{round_workers => 2, llm_workers => 2, runs => 1}}],
    ActualCases = [observe_budget_case(Case) || Case <- Cases],
    ExpectedCases =
        [#{limit => Limit,
           status => failed,
           budget_data => {budget_exceeded, Limit},
           usage => ExpectedUsage,
           prompt_tokens_match_estimates => true,
           started_children => ExpectedStarts,
           llm_workers_dead => true,
           live_round_workers => 0,
           live_runs => 0}
         || {Limit, _Budgets, _SecondDecision,
             ExpectedUsage, ExpectedStarts} <- Cases],
    Actual =
        #{budget_cases => ActualCases,
          fresh_usage => observe_fresh_usage()},
    Expected =
        #{budget_cases => ExpectedCases,
          fresh_usage =>
              #{rounds => 0, llm_calls => 0,
                tool_calls => 0, prompt_tokens => 0}},
    ?assertEqual(Expected, Actual).

test_task_deadline_tears_down_all_owned_execution_children(Config) ->
    DeadlineMs = 1000,
    LlmResult = observe_blocked_llm_deadline(DeadlineMs),
    CliResult = observe_blocked_cli_deadline(DeadlineMs, Config),
    Expected =
        [#{case_name => blocked_llm,
           status => timeout,
           owned_beam_pids_dead => true,
           external_process_dead => not_applicable,
           live_round_workers => 0,
           live_runs => 0},
         #{case_name => blocked_cli_action,
           status => timeout,
           owned_beam_pids_dead => true,
           external_process_dead => true,
           live_round_workers => 0,
           live_runs => 0}],
    ?assertEqual(Expected, [LlmResult, CliResult]).

test_context_preflight_and_provider_usage_accounting(_Config) ->
    Rows =
        [{per_call,
          #{max_context_tokens => 1,
            reserved_completion_tokens => 1,
            max_total_prompt_tokens => 100000},
          undefined},
         {total,
          #{max_context_tokens => 100000,
            reserved_completion_tokens => 1000,
            max_total_prompt_tokens => 1},
          undefined},
         {provider_usage,
          #{max_context_tokens => 100000,
            reserved_completion_tokens => 1000,
            max_total_prompt_tokens => 100000},
          7}],
    Actual = [observe_context_budget_row(Row) || Row <- Rows],
    EmptyUsage =
        #{rounds => 0, llm_calls => 0,
          tool_calls => 0, prompt_tokens => 0},
    Expected =
        [#{case_name => per_call,
           status => failed,
           result => context_budget_exceeded,
           usage => EmptyUsage,
           llm_worker_count => 0,
           llm_workers_dead => true,
           provider_usage_replaced_estimate => not_applicable},
         #{case_name => total,
           status => failed,
           result => context_budget_exceeded,
           usage => EmptyUsage,
           llm_worker_count => 0,
           llm_workers_dead => true,
           provider_usage_replaced_estimate => not_applicable},
         #{case_name => provider_usage,
           status => succeeded,
           result => <<"provider usage committed">>,
           usage =>
               #{rounds => 1, llm_calls => 1,
                 tool_calls => 0, prompt_tokens => 7},
           llm_worker_count => 1,
           llm_workers_dead => true,
           provider_usage_replaced_estimate => true}],
    ?assertEqual(Expected, Actual).

test_oversized_observation_uses_stable_task_artifact_and_bounded_slice(
  _Config) ->
    ToolName = delegate_artifact_reader,
    ok = soma_tool_registry:register_tool(
           #{name => ToolName,
             effect => reader,
             idempotent => true,
             timeout_ms => 1000,
             adapter => erlang_module,
             module => ?MODULE,
             description => <<"Returns one local oversized observation.">>}),
    try
        MaxObservationBytes = 64,
        RequestedSliceBytes = 13,
        LargeOutput =
            binary:copy(<<"complete-artifact-observation-">>, 32),
        Observation =
            #{status => succeeded,
              outputs =>
                  #{artifact_reader_action => #{value => LargeOutput}}},
        CompleteBytes =
            iolist_to_binary(soma_lisp:render(Observation)),
        true = byte_size(CompleteBytes) > MaxObservationBytes,
        Action =
            #{kind => run_steps,
              steps =>
                  [#{id => artifact_reader_action,
                     tool => ToolName,
                     args => #{value => LargeOutput}}]},
        TestPid = self(),
        Responder =
            fun(CallOpts) ->
                    TestPid !
                        {delegate_artifact_prompt,
                         maps:get(prompt_projection, CallOpts)},
                    terminal_response(<<"oversized observation stored">>)
            end,
        ok = application:set_env(
               soma_actor, delegate_runtime_options,
               #{tool_policy => #{allowed_tools => [ToolName]},
                 round_sequence =>
                     [#{llm => #{directive => proposal,
                                 output => Action}},
                      #{llm =>
                            #{provider => openai_compat,
                              base_url => <<"api.example.test/v1">>,
                              api_key => <<"test-only-key">>,
                              model => <<"test-model">>,
                              response => Responder}}]}),
        CorrelationId =
            <<"delegate-oversized-observation-correlation">>,
        Request =
            #{request_id => <<"delegate-oversized-observation">>,
              correlation_id => CorrelationId,
              objective => #{goal => <<"retain the complete reader output">>},
              output_contract => #{format => <<"text">>},
              capability_scope =>
                  #{tools => [atom_to_binary(ToolName, utf8)]},
              artifacts => [],
              budgets =>
                  #{max_observation_bytes => MaxObservationBytes}},

        {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
        Prompt = receive_artifact_prompt(),
        Terminal = wait_for_terminal_projection(TaskId, 100),
        [PromptArtifact] = maps:get(artifact_excerpts, Prompt, missing),
        #{handle := PromptHandle,
          bytes := CompleteByteCount,
          excerpt := Excerpt,
          truncated := true} = PromptArtifact,
        ?assertEqual(
           [bytes, excerpt, handle, truncated],
           lists:sort(maps:keys(PromptArtifact))),
        [#{round := 1,
           observation := PromptObservationRef}] =
            maps:get(recent_rounds, Prompt, missing),
        ?assertEqual(#{handle => PromptHandle}, PromptObservationRef),
        ?assertEqual(
           binary:part(CompleteBytes, 0, MaxObservationBytes), Excerpt),
        ?assertEqual(MaxObservationBytes, byte_size(Excerpt)),
        ?assertEqual(byte_size(CompleteBytes), CompleteByteCount),
        ?assertEqual(
           nomatch,
           binary:match(term_to_binary(Prompt), LargeOutput)),

        Events =
            soma_event_store:by_correlation(
              event_store_pid(), CorrelationId),
        [#{payload := #{observation_ref := AuditObservationRef}}] =
            [Event || #{event_type := <<"delegate.action.completed">>} = Event
                          <- Events],
        #{handle := AuditHandle} = AuditObservationRef,
        [#{handle := TerminalHandle}] =
            maps:get(artifacts, Terminal, missing),

        {ok, StoredCompleteBytes} =
            soma_delegate:artifact_slice(
              TaskId, PromptHandle, 0, CompleteByteCount),
        SliceOffset = 7,
        {ok, RequestedSlice} =
            soma_delegate:artifact_slice(
              TaskId, PromptHandle, SliceOffset, RequestedSliceBytes),
        ?assertEqual(
           binary:part(
             CompleteBytes, SliceOffset, RequestedSliceBytes),
           RequestedSlice),
        ?assert(byte_size(RequestedSlice) =< RequestedSliceBytes),
        ?assertEqual(
           {error, not_found},
           soma_delegate:artifact_slice(
             <<"another-task">>, PromptHandle, 0,
             RequestedSliceBytes)),

        Actual =
            #{stable_handles =>
                  [PromptHandle, AuditHandle, TerminalHandle],
              opaque_handle =>
                  is_binary(PromptHandle) andalso
                      binary:match(PromptHandle, TaskId) =:= nomatch,
              complete_bytes => StoredCompleteBytes,
              bounded_slice_bytes => byte_size(RequestedSlice)},
        Expected =
            #{stable_handles =>
                  [PromptHandle, PromptHandle, PromptHandle],
              opaque_handle => true,
              complete_bytes => CompleteBytes,
              bounded_slice_bytes => RequestedSliceBytes},
        ?assertEqual(Expected, Actual)
    after
        ok = soma_tool_registry:unregister_tool(ToolName)
    end.

test_recent_round_window_replaces_old_observations_with_one_summary(
  _Config) ->
    RecentRoundWindow = 2,
    SummaryByteLimit = 512,
    OldSentinels =
        [<<"evicted-raw-observation-one">>,
         <<"evicted-raw-observation-two">>],
    RecentSentinels =
        [<<"recent-raw-observation-three">>,
         <<"recent-raw-observation-four">>],
    Sentinels = OldSentinels ++ RecentSentinels,
    StepIds =
        [window_action_one, window_action_two,
         window_action_three, window_action_four],
    Actions =
        [#{kind => run_steps,
           steps =>
               [#{id => StepId,
                  tool => text_head,
                  args => #{text => Sentinel, lines => 1}}]}
         || {StepId, Sentinel} <- lists:zip(StepIds, Sentinels)],
    TestPid = self(),
    FinalResponder =
        fun(CallOpts) ->
                TestPid !
                    {delegate_recent_window_prompt,
                     maps:get(prompt_projection, CallOpts)},
                terminal_response(<<"recent window observed">>)
        end,
    RoundSequence =
        [#{llm => #{directive => proposal, output => Action}}
         || Action <- Actions] ++
        [#{llm =>
               #{provider => openai_compat,
                 base_url => <<"api.example.test/v1">>,
                 api_key => <<"test-only-key">>,
                 model => <<"test-model">>,
                 response => FinalResponder}}],
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{tool_policy => #{allowed_tools => [text_head]},
             round_sequence => RoundSequence}),
    Request =
        #{request_id => <<"delegate-recent-round-window">>,
          correlation_id =>
              <<"delegate-recent-round-window-correlation">>,
          objective => #{goal => <<"summarize evicted observations">>},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => [<<"text_head">>]},
          artifacts => [],
          budgets => #{recent_round_window => RecentRoundWindow}},

    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Prompt = receive_recent_window_prompt(),
    #{status := succeeded} = wait_for_terminal_projection(TaskId, 100),
    PromptBytes = term_to_binary(Prompt, [deterministic]),
    RecentRounds = maps:get(recent_rounds, Prompt, missing),
    Summary = maps:get(task_summary, Prompt, missing),
    Actual =
        #{recent_round_numbers =>
              [Round || #{round := Round} <- RecentRounds],
          recent_raw_observations_retained =>
              lists:all(
                fun(Sentinel) ->
                        binary:match(PromptBytes, Sentinel) =/= nomatch
                end,
                RecentSentinels),
          old_raw_observations_removed =>
              lists:all(
                fun(Sentinel) ->
                        binary:match(PromptBytes, Sentinel) =:= nomatch
                end,
                OldSentinels),
          summary => Summary,
          summary_bounded =>
              byte_size(term_to_binary(Summary, [deterministic])) =<
                  SummaryByteLimit},
    Expected =
        #{recent_round_numbers => [3, 4],
          recent_raw_observations_retained => true,
          old_raw_observations_removed => true,
          summary =>
              #{action => tool_observation,
                status => succeeded,
                counts => #{rounds => 2, succeeded => 2},
                first_round => 1,
                last_round => 2,
                observation_ref => #{inline => true}},
          summary_bounded => true},
    ?assertEqual(Expected, Actual).

test_pinned_safety_state_is_exact_and_never_truncated(_Config) ->
    CapabilityScope =
        #{tools => [<<"echo">>],
          constraints => #{workspace => <<"task-workspace">>}},
    Invocation =
        #{run_id => <<"delegate-safety-run">>,
          step_id => safety_state_action,
          tool => echo},
    Mutation = Invocation#{round => 1, outcome => succeeded},
    UnknownOutcome =
        #{round => 1,
          invocation => Invocation,
          outcome => unknown},
    ExpectedInitialSafety =
        #{capability_scope => CapabilityScope,
          mutation_ledger => [],
          unknown_outcome_ledger => [],
          idempotency_state => #{}},
    ExpectedCommittedSafety =
        #{capability_scope => CapabilityScope,
          mutation_ledger => [Mutation],
          unknown_outcome_ledger => [UnknownOutcome],
          idempotency_state =>
              #{<<"delegate-safety-run">> =>
                    Mutation#{outcome => unknown}}},
    TestPid = self(),
    FirstResponder =
        fun(CallOpts) ->
                TestPid !
                    {delegate_safety_prompt, 1,
                     maps:get(prompt_projection, CallOpts)},
                receive
                    delegate_safety_responder_release ->
                        terminal_response(
                          <<"unreachable blocked response">>)
                end
        end,
    SecondResponder =
        fun(CallOpts) ->
                TestPid !
                    {delegate_safety_prompt, 2,
                     maps:get(prompt_projection, CallOpts)},
                terminal_response(<<"pinned safety state observed">>)
        end,
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{tool_policy => #{allowed_tools => [echo]},
             round_sequence =>
                 [#{llm => safety_llm(FirstResponder)},
                  #{llm => safety_llm(SecondResponder)}]}),
    Request =
        #{request_id => <<"delegate-pinned-safety-exact">>,
          correlation_id =>
              <<"delegate-pinned-safety-exact-correlation">>,
          objective => #{goal => <<"preserve authoritative safety data">>},
          output_contract => #{format => <<"text">>},
          capability_scope => CapabilityScope,
          artifacts => []},

    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    FirstProjection = receive_safety_prompt(1),
    [CoordinatorPid] = live_coordinators(),
    {running, CoordinatorData} = sys:get_state(CoordinatorPid),
    ActiveRound = maps:get(active_round, CoordinatorData),
    send_safety_round_result(
      CoordinatorPid, TaskId, ActiveRound,
      #{status => succeeded,
        phase => decision,
        decision => continue,
        mutation => Mutation,
        unknown_outcome => UnknownOutcome,
        terminal_result => #{status => succeeded}}),
    SecondProjection = receive_safety_prompt(2),
    _Terminal = wait_for_terminal_projection(TaskId, 100),
    wait_for_no_coordinators(100),

    OversizedMarker = binary:copy(<<"pinned-safety-marker">>, 64),
    OversizedCapability =
        #{tools => [],
          constraints => #{mutation_guard => OversizedMarker}},
    ExpectedOversizedSafety =
        #{capability_scope => OversizedCapability,
          mutation_ledger => [],
          unknown_outcome_ledger => [],
          idempotency_state => #{}},
    PerCallAllowance = 128,
    true = safety_state_bytes(ExpectedOversizedSafety) > PerCallAllowance,
    OversizedResponder =
        fun(_CallOpts) ->
                TestPid ! delegate_oversized_safety_llm_started,
                terminal_response(<<"must not start">>)
        end,
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{round_sequence =>
                 [#{llm => safety_llm(OversizedResponder)}]}),
    OversizedRequest =
        #{request_id => <<"delegate-pinned-safety-oversized">>,
          correlation_id =>
              <<"delegate-pinned-safety-oversized-correlation">>,
          objective => #{goal => <<"reject without truncating safety">>},
          output_contract => #{format => <<"text">>},
          capability_scope => OversizedCapability,
          artifacts => [],
          budgets =>
              #{max_context_tokens => PerCallAllowance,
                reserved_completion_tokens => 0,
                max_total_prompt_tokens => 100000}},
    start_safety_preflight_trace(),
    {OversizedProjection, OversizedTerminal} =
        try
            {ok, #{task_id := OversizedTaskId}} =
                soma_delegate:submit(OversizedRequest),
            Projection = receive_safety_preflight_projection(),
            Terminal =
                wait_for_terminal_projection(OversizedTaskId, 100),
            {Projection, Terminal}
        after
            clear_safety_preflight_trace()
        end,

    ActualSafetyStates =
        [maps:get(pinned_safety_state, Projection, missing)
         || Projection <-
                [FirstProjection, SecondProjection, OversizedProjection]],
    ExpectedSafetyStates =
        [ExpectedInitialSafety, ExpectedCommittedSafety,
         ExpectedOversizedSafety],
    Actual =
        #{safety_states => ActualSafetyStates,
          oversized_terminal =>
              maps:with([status, result], OversizedTerminal),
          oversized_llm_started => oversized_safety_llm_started()},
    Expected =
        #{safety_states => ExpectedSafetyStates,
          oversized_terminal =>
              #{status => failed, result => context_budget_exceeded},
          oversized_llm_started => false},
    ?assertEqual(Expected, Actual).

test_maximum_round_prompts_obey_cumulative_input_bound(_Config) ->
    RoundCount = 4,
    PerCallInputAllowance = 16384,
    ReservedCompletionTokens = 1024,
    MaximumPromptSlack = 1024,
    ObjectivePadding = binary:copy(<<"p">>, 15000),
    Responses =
        [<<"(run-steps (step (id budget_action_one) (tool echo) "
           "(args (value \"one\"))))">>,
         <<"(run-steps (step (id budget_action_two) (tool echo) "
           "(args (value \"two\"))))">>,
         <<"(run-steps (step (id reader_action) (tool echo) "
           "(args (value \"three\"))))">>,
         <<"(reply (text \"maximum prompts bounded\"))">>],
    TestPid = self(),
    RoundSequence =
        [#{llm =>
               #{provider => openai_compat,
                 base_url => <<"api.example.test/v1">>,
                 api_key => <<"test-only-key">>,
                 model => <<"test-model">>,
                 response =>
                     fun(CallOpts) ->
                             Messages = maps:get(messages, CallOpts),
                             Estimate =
                                 lists:sum(
                                   [byte_size(Content)
                                    || #{content := Content} <- Messages]),
                             TestPid !
                                 {delegate_maximum_prompt_estimate,
                                  Round, Estimate},
                             terminal_response(Response)
                     end}}
         || {Round, Response} <- lists:enumerate(Responses)],
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{tool_policy => #{allowed_tools => [echo]},
             round_sequence => RoundSequence}),
    Request =
        #{request_id => <<"delegate-maximum-round-prompts">>,
          correlation_id =>
              <<"delegate-maximum-round-prompts-correlation">>,
          objective => #{goal => ObjectivePadding},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => [<<"echo">>]},
          artifacts => [],
          budgets =>
              #{max_rounds => RoundCount,
                max_llm_calls => RoundCount,
                max_tool_calls => RoundCount - 1,
                max_context_tokens =>
                    PerCallInputAllowance + ReservedCompletionTokens,
                reserved_completion_tokens => ReservedCompletionTokens,
                max_total_prompt_tokens =>
                    RoundCount * PerCallInputAllowance,
                recent_round_window => RoundCount}},

    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Terminal = wait_for_terminal_projection(TaskId, 100),
    Estimates = collect_maximum_prompt_estimates(RoundCount, []),
    #{status := succeeded,
      usage := #{rounds := RoundCount,
                 llm_calls := RoundCount,
                 tool_calls := 3,
                 prompt_tokens := TerminalPromptTokens}} = Terminal,
    ?assert(
       lists:all(
         fun(Estimate) ->
                 Estimate >= PerCallInputAllowance - MaximumPromptSlack
         end,
         Estimates)),
    ?assert(
       lists:all(
         fun(Estimate) -> Estimate =< PerCallInputAllowance end,
         Estimates)),
    ?assert(
       TerminalPromptTokens =< RoundCount * PerCallInputAllowance),
    ?assertEqual(lists:sum(Estimates), TerminalPromptTokens).

test_adaptive_events_are_documented_scrubbed_and_4096_byte_bounded(
  _Config) ->
    ToolName = delegate_state_probe,
    ok = soma_tool_registry:register_tool(
           #{name => ToolName,
             effect => state,
             idempotent => false,
             timeout_ms => 1000,
             adapter => erlang_module,
             module => ?MODULE,
             description => <<"Records one audited state transition.">>}),
    OversizedSecret =
        binary:copy(<<"delegate-event-secret-sentinel">>, 256),
    ProcessRef = make_ref(),
    ProcessFun = fun() -> OversizedSecret end,
    Port = open_port({spawn_executable, "/bin/cat"}, [binary]),
    try
        Action =
            #{kind => run_steps,
              steps =>
                  [#{id => audited_state_action,
                     tool => ToolName,
                     args => #{value => OversizedSecret}}]},
        TerminalReply =
            #{kind => reply, text => <<"adaptive audit complete">>},
        RuntimeNoise =
            #{oversized_secret => OversizedSecret,
              owner => self(),
              monitor => ProcessRef,
              port => Port,
              callback => ProcessFun},
        ok = application:set_env(
               soma_actor, delegate_runtime_options,
               #{tool_policy =>
                     #{allowed_tools => [ToolName],
                       event_test_noise => RuntimeNoise},
                 round_sequence =>
                     [#{llm =>
                            #{directive => proposal,
                              output => Action},
                        event_test_noise => RuntimeNoise},
                      #{llm =>
                            #{directive => proposal,
                              output => TerminalReply},
                        event_test_noise => RuntimeNoise}]}),
        CorrelationId = <<"delegate-adaptive-events-correlation">>,
        Request =
            #{request_id => <<"delegate-adaptive-events">>,
              correlation_id => CorrelationId,
              objective => #{goal => <<"exercise adaptive audit events">>},
              output_contract => #{format => <<"text">>},
              capability_scope =>
                  #{tools => [atom_to_binary(ToolName, utf8)]},
              artifacts => [],
              budgets => #{max_observation_bytes => 64}},

        {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
        Terminal = wait_for_terminal_projection(TaskId, 100),
        #{status := succeeded,
          artifacts := [#{handle := ObservationHandle}],
          mutations := [#{invocation_id := InvocationId}]} = Terminal,
        Events =
            soma_event_store:by_correlation(
              event_store_pid(), CorrelationId),
        [#{run_id := RunId,
           tool_call_id := ToolCallId}] =
            [Event || #{event_type := <<"tool.started">>,
                        step_id := audited_state_action} = Event <- Events],
        Forbidden =
            [OversizedSecret, self(), ProcessRef, Port, ProcessFun],
        Rows =
            [{decision, <<"delegate.decision.completed">>},
             {action, <<"delegate.action.completed">>},
             {terminal, <<"delegate.task.terminal">>}],
        Actual =
            [adaptive_event_observation(Row, Events, Forbidden)
             || Row <- Rows],
        Expected =
            [#{case_name => decision,
               event_count => 2,
               rounds => [1, 2],
               documented_fields =>
                   [#{action_summary =>
                          #{kind => run_steps, step_count => 1},
                      global_policy_verdict => allow,
                      task_capability_verdict => allow},
                    #{action_summary => #{kind => reply},
                      global_policy_verdict => allow,
                      task_capability_verdict => allow}],
               bounded => true,
               scrubbed => true},
             #{case_name => action,
               event_count => 1,
               rounds => [1],
               documented_fields =>
                   [#{run_id => RunId,
                      tool_call_ids => [ToolCallId],
                      observation_ref => #{handle => ObservationHandle}}],
               bounded => true,
               scrubbed => true},
             #{case_name => terminal,
               event_count => 1,
               rounds => [0],
               documented_fields =>
                   [#{status => succeeded,
                      mutation_state =>
                          [#{round => 1,
                             run_id => RunId,
                             invocation_id => InvocationId,
                             step_id => audited_state_action,
                             tool => ToolName,
                             outcome => succeeded}],
                      unknown_outcome_state => []}],
               bounded => true,
               scrubbed => true}],
        ?assertEqual(Expected, Actual),

        PreflightCorrelationId =
            <<"delegate-adaptive-events-preflight-correlation">>,
        PreflightTerminalFields =
            observe_preflight_terminal_event(PreflightCorrelationId),
        ?assertEqual(
           #{status => failed,
             mutation_state => [],
             unknown_outcome_state => []},
           PreflightTerminalFields)
    after
        erlang:port_close(Port),
        ok = soma_tool_registry:unregister_tool(ToolName)
    end.

test_terminal_projection_has_exact_public_contract(_Config) ->
    ToolName = delegate_terminal_projection_state,
    ok = soma_tool_registry:register_tool(
           #{name => ToolName,
             effect => state,
             idempotent => false,
             timeout_ms => 10000,
             adapter => erlang_module,
             module => ?MODULE,
             description =>
                 <<"Holds one unsafe invocation for terminal projection. ">>}),
    FixedResult = <<"fixed output-contract response">>,
    FixedContract = #{format => <<"text">>},
    UnsafeAction =
        #{kind => run_steps,
          steps =>
              [#{id => terminal_projection_state_action,
                 tool => ToolName,
                 args => #{mode => <<"timeout">>},
                 timeout_ms => 10000}]},
    Rows =
        [{succeeded,
          #{round_sequence =>
                [#{llm =>
                       #{directive => proposal,
                         output => #{kind => reply, text => FixedResult}}}]},
          await},
         {failed,
          #{round_sequence =>
                [#{llm =>
                       #{directive => proposal,
                         output => #{kind => reply}}}]},
          await},
         {rejected,
          #{tool_policy => #{allowed_tools => []},
            round_sequence =>
                [#{llm =>
                       #{directive => proposal,
                         output =>
                             #{kind => run_steps,
                               steps =>
                                   [#{id => terminal_projection_denied,
                                      tool => echo,
                                      args => #{value => <<"denied">>}}]}}}]},
          await},
         {timeout,
          #{round_sequence =>
                [#{llm => #{directive => hang, timeout_ms => 60000},
                   round_timeout_ms => 20}]},
          await},
         {cancelled,
          #{round_sequence =>
                [#{llm => #{directive => hang, timeout_ms => 60000},
                   round_timeout_ms => 60000}]},
          cancel},
         {in_doubt,
          #{tool_policy => #{allowed_tools => [ToolName]},
            round_sequence =>
                [#{llm =>
                       #{directive => proposal, output => UnsafeAction},
                   round_timeout_ms => 60000}]},
          lose_unsafe_result}],
    try
        Actual =
            [observe_terminal_projection_case(
               Row, FixedContract, FixedResult, ToolName)
             || Row <- Rows],
        PublicKeys =
            lists:sort(
              [request_id, task_id, correlation_id, status, result,
               artifacts, mutations, unknown_outcomes, usage, trace_ref]),
        Expected =
            [#{case_name => Status,
               keys => PublicKeys,
               status => Status,
               identifiers_match => true,
               result =>
                   case Status of
                       succeeded -> FixedResult;
                       _ -> undefined
                   end,
               artifacts => [],
               mutation_count =>
                   case Status of
                       in_doubt -> 1;
                       _ -> 0
                   end,
               unknown_outcome_count =>
                   case Status of
                       in_doubt -> 1;
                       _ -> 0
                   end,
               usage_keys =>
                   [llm_calls, prompt_tokens, rounds, tool_calls],
               usage_is_non_negative => true,
               trace_ref_matches => true}
             || {Status, _RuntimeOptions, _Trigger} <- Rows],
        ?assertEqual(Expected, Actual)
    after
        ok = soma_tool_registry:unregister_tool(ToolName)
    end.

test_review_regressions_are_bounded_and_safety_preserving(_Config) ->
    assert_review_budget_boundary(),
    assert_review_all_state_steps_are_ledgered(),
    assert_review_malformed_map_emits_invalid_decision(),
    assert_review_coordinator_loss_preserves_safety(),
    assert_review_large_provider_usage_preserves_result().

test_review_actual_dispatch_usage_and_observation_regressions(_Config) ->
    assert_review_ledgers_follow_actual_dispatch_and_terminal_facts(),
    assert_review_valid_usage_aggregate_survives_public_projection(),
    assert_review_compatible_observation_budget_commits_completed_action().

assert_review_ledgers_follow_actual_dispatch_and_terminal_facts() ->
    FirstTool = delegate_review_actual_state_one,
    SecondTool = delegate_review_actual_state_two,
    ToolNames = [FirstTool, SecondTool],
    [ok = soma_tool_registry:register_tool(
            #{name => ToolName,
              effect => state,
              idempotent => false,
              timeout_ms => 10000,
              adapter => erlang_module,
              module => ?MODULE,
              description =>
                  <<"Exercises reviewed actual-dispatch safety facts.">>})
     || ToolName <- ToolNames],
    try
        PartialCorrelationId =
            <<"delegate-review-actual-partial-correlation">>,
        PartialAction =
            #{kind => run_steps,
              steps =>
                  [#{id => review_actual_first,
                     tool => FirstTool,
                     args => #{mode => <<"error">>}},
                   #{id => review_actual_never_started,
                     tool => SecondTool,
                     args => #{value => <<"must not run">>}}]},
        ok = application:set_env(
               soma_actor, delegate_runtime_options,
               #{tool_policy => #{allowed_tools => ToolNames},
                 round_sequence =>
                     [#{llm =>
                            #{directive => proposal,
                              output => PartialAction}},
                      #{llm =>
                            #{directive => proposal,
                              output =>
                                  #{kind => reply,
                                    text => <<"failure observed">>}}}]}),
        PartialRequest =
            #{request_id => <<"delegate-review-actual-partial">>,
              correlation_id => PartialCorrelationId,
              objective =>
                  #{goal => <<"ledger only the state call that ran">>},
              output_contract => #{format => <<"text">>},
              capability_scope =>
                  #{tools => [atom_to_binary(ToolName, utf8)
                              || ToolName <- ToolNames]},
              artifacts => []},
        {ok, #{task_id := PartialTaskId}} =
            soma_delegate:submit(PartialRequest),
        PartialTerminal =
            wait_for_terminal_projection(PartialTaskId, 200),
        PartialEvents =
            soma_event_store:by_correlation(
              event_store_pid(), PartialCorrelationId),
        ?assertEqual(
           [review_actual_first],
           [StepId
            || #{event_type := <<"tool.started">>,
                 step_id := StepId} <- PartialEvents]),
        PartialMutations = maps:get(mutations, PartialTerminal),
        ?assertEqual(1, length(PartialMutations)),
        [PartialMutation] = PartialMutations,
        ?assertEqual(review_actual_first,
                     maps:get(step_id, PartialMutation)),
        ?assertEqual(FirstTool, maps:get(tool, PartialMutation)),
        ?assertEqual(failed, maps:get(outcome, PartialMutation)),
        ?assertEqual([], maps:get(unknown_outcomes, PartialTerminal)),
        wait_for_no_coordinators(100),

        CancelCorrelationId =
            <<"delegate-review-actual-cancel-correlation">>,
        CancelAction =
            #{kind => run_steps,
              steps =>
                  [#{id => review_actual_cancelled,
                     tool => FirstTool,
                     args => #{mode => <<"timeout">>},
                     timeout_ms => 10000}]},
        ok = application:set_env(
               soma_actor, delegate_runtime_options,
               #{tool_policy => #{allowed_tools => [FirstTool]},
                 round_sequence =>
                     [#{llm =>
                            #{directive => proposal,
                              output => CancelAction},
                        round_timeout_ms => 60000}]}),
        CancelRequest =
            #{request_id => <<"delegate-review-actual-cancel">>,
              correlation_id => CancelCorrelationId,
              objective =>
                  #{goal => <<"retain an unresolved started mutation">>},
              output_contract => #{format => <<"text">>},
              capability_scope =>
                  #{tools => [atom_to_binary(FirstTool, utf8)]},
              artifacts => []},
        {ok, #{task_id := CancelTaskId}} =
            soma_delegate:submit(CancelRequest),
        CancelToolCallPid =
            wait_for_tool_call_pid(CancelCorrelationId, 200),
        {ok, CancelTerminal} = soma_delegate:cancel(CancelTaskId),
        ?assertEqual(in_doubt, maps:get(status, CancelTerminal)),
        [CancelMutation] = maps:get(mutations, CancelTerminal),
        [CancelUnknown] = maps:get(unknown_outcomes, CancelTerminal),
        ?assertEqual(review_actual_cancelled,
                     maps:get(step_id, CancelMutation)),
        ?assertEqual(unknown, maps:get(outcome, CancelMutation)),
        ?assertEqual(unknown, maps:get(outcome, CancelUnknown)),
        ?assertEqual(
           maps:get(invocation_id, CancelMutation),
           maps:get(
             invocation_id, maps:get(invocation, CancelUnknown))),
        review_wait_for_process_dead(CancelToolCallPid, 200),
        wait_for_no_coordinators(100)
    after
        [ok = soma_tool_registry:unregister_tool(ToolName)
         || ToolName <- ToolNames]
    end.

assert_review_valid_usage_aggregate_survives_public_projection() ->
    PromptTokensPerCall = 3000000000,
    Responses =
        [<<"(run-steps (step (id review_usage_action) (tool echo) "
           "(args (value \"usage\"))))">>,
         <<"(reply (text \"usage preserved\"))">>],
    RoundSequence =
        [#{llm =>
               #{provider => openai_compat,
                 base_url => <<"api.example.test/v1">>,
                 api_key => <<"test-only-key">>,
                 model => <<"test-model">>,
                 response =>
                     fun(_CallOpts) ->
                             terminal_response(
                               Response, PromptTokensPerCall)
                     end}}
         || Response <- Responses],
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{tool_policy => #{allowed_tools => [echo]},
             round_sequence => RoundSequence}),
    Request =
        #{request_id => <<"delegate-review-usage-aggregate">>,
          correlation_id =>
              <<"delegate-review-usage-aggregate-correlation">>,
          objective => #{goal => <<"retain valid aggregate usage">>},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => [<<"echo">>]},
          artifacts => [],
          budgets =>
              #{max_rounds => 2,
                max_llm_calls => 2,
                max_tool_calls => 1,
                max_total_prompt_tokens => 7000000000}},
    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Terminal = wait_for_terminal_projection(TaskId, 200),
    ?assertEqual(succeeded, maps:get(status, Terminal)),
    ?assertEqual(<<"usage preserved">>, maps:get(result, Terminal)),
    ?assertEqual(
       #{rounds => 2,
         llm_calls => 2,
         tool_calls => 1,
         prompt_tokens => 6000000000},
       maps:get(usage, Terminal)),
    wait_for_no_coordinators(100).

assert_review_compatible_observation_budget_commits_completed_action() ->
    LargeOutput = binary:copy(<<"x">>, 17000),
    ActionSource =
        iolist_to_binary(
          [<<"(run-steps (step (id review_large_observation) "
             "(tool echo) (args (value ">>,
           $\",
           LargeOutput,
           <<"\"))))">>]),
    TestPid = self(),
    RoundSequence =
        [#{llm =>
               #{provider => openai_compat,
                 base_url => <<"api.example.test/v1">>,
                 api_key => <<"test-only-key">>,
                 model => <<"test-model">>,
                 response =>
                     fun(_CallOpts) -> terminal_response(ActionSource) end}},
         #{llm =>
               #{provider => openai_compat,
                 base_url => <<"api.example.test/v1">>,
                 api_key => <<"test-only-key">>,
                 model => <<"test-model">>,
                 response =>
                     fun(CallOpts) ->
                             TestPid !
                                 {delegate_review_large_observation_prompt,
                                  maps:get(
                                    prompt_projection, CallOpts, missing)},
                             terminal_response(
                               <<"(reply (text \"large observation kept\"))">>)
                     end}}],
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{tool_policy => #{allowed_tools => [echo]},
             round_sequence => RoundSequence}),
    CorrelationId =
        <<"delegate-review-large-observation-correlation">>,
    Request =
        #{request_id => <<"delegate-review-large-observation">>,
          correlation_id => CorrelationId,
          objective => #{goal => <<"commit the completed large action">>},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => [<<"echo">>]},
          artifacts => [],
          budgets => #{max_observation_bytes => 20000}},
    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Terminal = wait_for_terminal_projection(TaskId, 200),
    Prompt = receive_review_large_observation_prompt(),
    RecentRounds = maps:get(recent_rounds, Prompt),
    ?assertEqual(1, length(RecentRounds)),
    [#{round := 1, observation := #{handle := Handle}}] = RecentRounds,
    [#{handle := Handle}] = maps:get(artifacts, Terminal),
    [#{payload := ActionPayload}] =
        [Event
         || #{event_type := <<"delegate.action.completed">>} = Event <-
                soma_event_store:by_correlation(
                  event_store_pid(), CorrelationId)],
    ?assertEqual(#{handle => Handle},
                 maps:get(observation_ref, ActionPayload)),
    ?assertEqual(succeeded, maps:get(status, Terminal)),
    ?assertEqual(<<"large observation kept">>, maps:get(result, Terminal)),
    wait_for_no_coordinators(100).

receive_review_large_observation_prompt() ->
    receive
        {delegate_review_large_observation_prompt, Projection} ->
            Projection
    after 2000 ->
        ct:fail(delegate_review_large_observation_prompt_missing)
    end.

observe_terminal_projection_case(
  {ExpectedStatus, RuntimeOptions0, Trigger},
  OutputContract, FixedResult, ToolName) ->
    RuntimeOptions =
        case ExpectedStatus of
            rejected -> RuntimeOptions0;
            in_doubt -> RuntimeOptions0;
            _ ->
                RuntimeOptions0#{tool_policy => #{allowed_tools => []}}
        end,
    ok = application:set_env(
           soma_actor, delegate_runtime_options, RuntimeOptions),
    Suffix = atom_to_binary(ExpectedStatus, utf8),
    RequestId = <<"delegate-terminal-projection-", Suffix/binary>>,
    CorrelationId =
        <<"delegate-terminal-projection-", Suffix/binary,
          "-correlation">>,
    CapabilityScope =
        case ExpectedStatus of
            rejected -> #{tools => [<<"echo">>]};
            in_doubt -> #{tools => [atom_to_binary(ToolName, utf8)]};
            _ -> #{tools => []}
        end,
    Request =
        #{request_id => RequestId,
          correlation_id => CorrelationId,
          objective => #{goal => <<"return one terminal projection">>},
          output_contract => OutputContract,
          capability_scope => CapabilityScope,
          artifacts => []},
    {ok, Accepted = #{task_id := TaskId}} = soma_delegate:submit(Request),
    Projection =
        trigger_terminal_projection(Trigger, TaskId),
    wait_for_no_coordinators(100),
    Usage = maps:get(usage, Projection, missing),
    Mutations = maps:get(mutations, Projection, missing),
    UnknownOutcomes = maps:get(unknown_outcomes, Projection, missing),
    #{case_name => ExpectedStatus,
      keys => lists:sort(maps:keys(Projection)),
      status => maps:get(status, Projection, missing),
      identifiers_match =>
          maps:get(request_id, Projection, missing) =:= RequestId andalso
              maps:get(task_id, Projection, missing) =:=
                  maps:get(task_id, Accepted) andalso
              maps:get(correlation_id, Projection, missing) =:=
                  CorrelationId,
      result => maps:get(result, Projection, missing),
      artifacts => maps:get(artifacts, Projection, missing),
      mutation_count => terminal_list_length(Mutations),
      unknown_outcome_count => terminal_list_length(UnknownOutcomes),
      usage_keys => terminal_usage_keys(Usage),
      usage_is_non_negative => terminal_usage_is_non_negative(Usage),
      trace_ref_matches =>
          maps:get(trace_ref, Projection, missing) =:= CorrelationId andalso
              maps:get(status, Projection, missing) =:= ExpectedStatus andalso
              (ExpectedStatus =/= succeeded orelse
               maps:get(result, Projection, missing) =:= FixedResult)}.

trigger_terminal_projection(await, TaskId) ->
    wait_for_terminal_projection(TaskId, 300);
trigger_terminal_projection(cancel, TaskId) ->
    _Running = wait_for_running_projection(TaskId, 100),
    {ok, Projection} = soma_delegate:cancel(TaskId),
    Projection;
trigger_terminal_projection(lose_unsafe_result, TaskId) ->
    RoundWorkerPid = wait_for_unsafe_round_worker(TaskId, 200),
    exit(RoundWorkerPid, kill),
    wait_for_terminal_projection(TaskId, 300).

wait_for_unsafe_round_worker(_TaskId, 0) ->
    ct:fail(delegate_terminal_unsafe_dispatch_not_observed);
wait_for_unsafe_round_worker(TaskId, Attempts) ->
    Matching =
        [CoordinatorData
         || CoordinatorPid <- live_coordinators(),
            {_StateName, CoordinatorData} <- [sys:get_state(CoordinatorPid)],
            maps:get(task_id, CoordinatorData, undefined) =:= TaskId],
    case Matching of
        [#{active_round :=
               #{unsafe_action_dispatched := true,
                 worker_pid := RoundWorkerPid}}] ->
            RoundWorkerPid;
        _NotYetDispatched ->
            timer:sleep(10),
            wait_for_unsafe_round_worker(TaskId, Attempts - 1)
    end.

terminal_list_length(Value) when is_list(Value) ->
    length(Value);
terminal_list_length(_MissingOrInvalid) ->
    invalid.

terminal_usage_keys(Usage) when is_map(Usage) ->
    lists:sort(maps:keys(Usage));
terminal_usage_keys(_MissingOrInvalid) ->
    invalid.

terminal_usage_is_non_negative(Usage) when is_map(Usage) ->
    lists:all(
      fun(Value) -> is_integer(Value) andalso Value >= 0 end,
      maps:values(Usage));
terminal_usage_is_non_negative(_MissingOrInvalid) ->
    false.

assert_review_budget_boundary() ->
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{round_sequence => []}),
    InvalidRequest =
        #{request_id => <<"delegate-review-invalid-deadline">>,
          correlation_id =>
              <<"delegate-review-invalid-deadline-correlation">>,
          objective => #{goal => <<"reject an invalid task deadline">>},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => []},
          artifacts => [],
          budgets => #{deadline_ms => <<"forever">>}},
    InvalidReply = soma_delegate:submit(InvalidRequest),
    cleanup_accepted(InvalidReply),
    ?assertEqual({error, invalid_delegate_request}, InvalidReply),

    ActionSource =
        <<"(run-steps (step (id review_bounded_action) (tool echo) "
          "(args (value \"bounded\"))))">>,
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{tool_policy => #{allowed_tools => [echo]},
             round_sequence =>
                 [#{llm =>
                        #{provider => openai_compat,
                          base_url => <<"api.example.test/v1">>,
                          api_key => <<"test-only-key">>,
                          model => <<"test-model">>,
                          response =>
                              fun(_CallOpts) ->
                                      terminal_response(ActionSource)
                              end}}]}),
    Request =
        #{request_id => <<"delegate-review-default-bounds">>,
          correlation_id =>
              <<"delegate-review-default-bounds-correlation">>,
          objective => #{goal => <<"stop the repeated action">>},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => [<<"echo">>]},
          artifacts => []},
    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Terminal = wait_for_terminal_projection(TaskId, 500),
    ?assertEqual(failed, maps:get(status, Terminal)),
    ?assertEqual(
       {budget_exceeded, max_rounds}, maps:get(result, Terminal)),
    Usage = maps:get(usage, Terminal),
    Rounds = maps:get(rounds, Usage),
    ?assert(Rounds > 0),
    ?assert(Rounds =< 64),
    ?assertEqual(Rounds, maps:get(llm_calls, Usage)),
    ?assertEqual(Rounds, maps:get(tool_calls, Usage)),
    wait_for_no_coordinators(100).

assert_review_all_state_steps_are_ledgered() ->
    ToolNames =
        [delegate_review_state_one, delegate_review_state_two],
    [ok = soma_tool_registry:register_tool(
            #{name => ToolName,
              effect => state,
              idempotent => false,
              timeout_ms => 1000,
              adapter => erlang_module,
              module => ?MODULE,
              description => <<"Records one reviewed state invocation.">>})
     || ToolName <- ToolNames],
    try
        TestPid = self(),
        ActionSource =
            <<"(run-steps "
              "(step (id review_state_one) "
              "(tool delegate_review_state_one) "
              "(args (value \"one\"))) "
              "(step (id review_state_two) "
              "(tool delegate_review_state_two) "
              "(args (value \"two\"))))">>,
        Responses =
            [ActionSource, <<"(reply (text \"done\"))">>],
        RoundSequence =
            [#{llm =>
                   #{provider => openai_compat,
                     base_url => <<"api.example.test/v1">>,
                     api_key => <<"test-only-key">>,
                     model => <<"test-model">>,
                     response =>
                         fun(CallOpts) ->
                                 TestPid !
                                     {delegate_review_multistep_prompt,
                                      Round,
                                      maps:get(
                                        prompt_projection, CallOpts,
                                        missing)},
                                 terminal_response(Response)
                         end}}
             || {Round, Response} <- lists:enumerate(Responses)],
        ok = application:set_env(
               soma_actor, delegate_runtime_options,
               #{tool_policy => #{allowed_tools => ToolNames},
                 round_sequence => RoundSequence}),
        Request =
            #{request_id => <<"delegate-review-multistep-ledger">>,
              correlation_id =>
                  <<"delegate-review-multistep-ledger-correlation">>,
              objective => #{goal => <<"record both mutations">>},
              output_contract => #{format => <<"text">>},
              capability_scope =>
                  #{tools => [atom_to_binary(ToolName, utf8)
                              || ToolName <- ToolNames]},
              artifacts => []},
        {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
        _FirstPrompt = receive_review_multistep_prompt(1),
        SecondPrompt = receive_review_multistep_prompt(2),
        Terminal = wait_for_terminal_projection(TaskId, 200),
        ?assertEqual(succeeded, maps:get(status, Terminal)),
        ?assertEqual(<<"done">>, maps:get(result, Terminal)),
        Mutations = maps:get(mutations, Terminal),
        ?assertEqual(2, length(Mutations)),
        ?assertEqual(
           lists:sort(ToolNames),
           lists:sort([maps:get(tool, Mutation)
                       || Mutation <- Mutations])),
        InvocationIds =
            [maps:get(invocation_id, Mutation) || Mutation <- Mutations],
        ?assertEqual(2, length(lists:usort(InvocationIds))),
        ?assertEqual(
           [succeeded, succeeded],
           lists:sort([maps:get(outcome, Mutation)
                       || Mutation <- Mutations])),
        SafetyState = maps:get(pinned_safety_state, SecondPrompt),
        ?assertEqual(Mutations, maps:get(mutation_ledger, SafetyState)),
        ?assertEqual(2, map_size(maps:get(idempotency_state, SafetyState))),
        wait_for_no_coordinators(100)
    after
        [ok = soma_tool_registry:unregister_tool(ToolName)
         || ToolName <- ToolNames]
    end.

receive_review_multistep_prompt(ExpectedRound) ->
    receive
        {delegate_review_multistep_prompt, ExpectedRound, Projection} ->
            Projection
    after 2000 ->
        ct:fail({delegate_review_multistep_prompt_missing, ExpectedRound})
    end.

assert_review_malformed_map_emits_invalid_decision() ->
    CorrelationId = <<"delegate-review-malformed-map-correlation">>,
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{tool_policy => #{allowed_tools => []},
             round_sequence =>
                 [#{llm => #{directive => proposal, output => #{}},
                    decision => terminal}]}),
    Request =
        #{request_id => <<"delegate-review-malformed-map">>,
          correlation_id => CorrelationId,
          objective => #{goal => <<"reject an empty proposal map">>},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => []},
          artifacts => []},
    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Terminal = wait_for_terminal_projection(TaskId, 200),
    ?assertEqual(failed, maps:get(status, Terminal)),
    Events =
        soma_event_store:by_correlation(event_store_pid(), CorrelationId),
    [#{payload := DecisionPayload}] =
        [Event || #{event_type := <<"delegate.decision.completed">>} = Event
                      <- Events],
    ?assertEqual(
       #{action_summary => #{kind => invalid},
         global_policy_verdict => not_evaluated,
         task_capability_verdict => not_evaluated},
       maps:with(
         [action_summary, global_policy_verdict,
          task_capability_verdict],
         DecisionPayload)),
    ?assertEqual(
       [],
       [Event || #{event_type := <<"run.started">>} = Event <- Events]),
    wait_for_no_coordinators(100).

assert_review_coordinator_loss_preserves_safety() ->
    ToolName = delegate_review_coordinator_loss_state,
    ok = soma_tool_registry:register_tool(
           #{name => ToolName,
             effect => state,
             idempotent => false,
             timeout_ms => 10000,
             adapter => erlang_module,
             module => ?MODULE,
             description => <<"Blocks one reviewed unsafe invocation.">>}),
    try
        CorrelationId =
            <<"delegate-review-coordinator-loss-correlation">>,
        Action =
            #{kind => run_steps,
              steps =>
                  [#{id => review_coordinator_loss_state,
                     tool => ToolName,
                     args => #{mode => <<"timeout">>},
                     timeout_ms => 10000}]},
        ok = application:set_env(
               soma_actor, delegate_runtime_options,
               #{tool_policy => #{allowed_tools => [ToolName]},
                 round_sequence =>
                     [#{llm => #{directive => proposal, output => Action},
                        round_timeout_ms => 60000}]}),
        Request =
            #{request_id => <<"delegate-review-coordinator-loss">>,
              correlation_id => CorrelationId,
              objective => #{goal => <<"preserve unsafe task state">>},
              output_contract => #{format => <<"text">>},
              capability_scope =>
                  #{tools => [atom_to_binary(ToolName, utf8)]},
              artifacts => []},
        {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
        ToolCallPid = wait_for_tool_call_pid(CorrelationId, 200),
        [CoordinatorPid] = live_coordinators(),
        exit(CoordinatorPid, kill),
        Terminal = wait_for_terminal_projection(TaskId, 200),
        ?assertEqual(in_doubt, maps:get(status, Terminal)),
        ?assertEqual(1, maps:get(rounds, maps:get(usage, Terminal))),
        ?assertEqual(1, maps:get(llm_calls, maps:get(usage, Terminal))),
        ?assertEqual(1, maps:get(tool_calls, maps:get(usage, Terminal))),
        [Mutation] = maps:get(mutations, Terminal),
        [UnknownOutcome] = maps:get(unknown_outcomes, Terminal),
        ?assertEqual(ToolName, maps:get(tool, Mutation)),
        ?assertEqual(unknown, maps:get(outcome, UnknownOutcome)),
        ?assertEqual(
           maps:get(invocation_id, Mutation),
           maps:get(
             invocation_id, maps:get(invocation, UnknownOutcome))),
        TerminalEvents =
            [Event
             || #{event_type := <<"delegate.task.terminal">>} = Event <-
                    soma_event_store:by_correlation(
                      event_store_pid(), CorrelationId)],
        [#{payload := TerminalPayload}] = TerminalEvents,
        ?assertEqual(
           [mutation_state, phase, status, unknown_outcome_state],
           lists:sort(maps:keys(TerminalPayload))),
        ?assertEqual(in_doubt, maps:get(status, TerminalPayload)),
        ?assertEqual(1, length(maps:get(mutation_state, TerminalPayload))),
        ?assertEqual(
           1, length(maps:get(unknown_outcome_state, TerminalPayload))),
        review_wait_for_process_dead(ToolCallPid, 200),
        wait_for_no_coordinators(100),
        wait_for_no_budget_children(100)
    after
        ok = soma_tool_registry:unregister_tool(ToolName)
    end.

review_wait_for_process_dead(_Pid, 0) ->
    ct:fail(delegate_review_process_still_alive);
review_wait_for_process_dead(Pid, Attempts) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(10),
            review_wait_for_process_dead(Pid, Attempts - 1)
    end.

assert_review_large_provider_usage_preserves_result() ->
    HugePromptTokens =
        binary_to_integer(binary:copy(<<"9">>, 12000)),
    Result = <<"done">>,
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{tool_policy => #{allowed_tools => []},
             round_sequence =>
                 [#{llm =>
                        #{provider => openai_compat,
                          base_url => <<"api.example.test/v1">>,
                          api_key => <<"test-only-key">>,
                          model => <<"test-model">>,
                          response =>
                              fun(_CallOpts) ->
                                      terminal_response(
                                        Result, HugePromptTokens)
                              end}}]}),
    Request =
        #{request_id => <<"delegate-review-large-provider-usage">>,
          correlation_id =>
              <<"delegate-review-large-provider-usage-correlation">>,
          objective => #{goal => <<"preserve the valid result">>},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => []},
          artifacts => []},
    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Terminal = wait_for_terminal_projection(TaskId, 200),
    ?assertEqual(succeeded, maps:get(status, Terminal)),
    ?assertEqual(Result, maps:get(result, Terminal)),
    PromptTokens = maps:get(prompt_tokens, maps:get(usage, Terminal)),
    ?assert(is_integer(PromptTokens)),
    ?assert(PromptTokens >= 0),
    ?assert(PromptTokens < HugePromptTokens),
    ?assert(
       byte_size(term_to_binary(Terminal, [deterministic])) =< 4096),
    wait_for_no_coordinators(100).

observe_preflight_terminal_event(CorrelationId) ->
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{round_sequence =>
                 [#{llm =>
                        #{provider => openai_compat,
                          base_url => <<"api.example.test/v1">>,
                          api_key => <<"test-only-key">>,
                          model => <<"test-model">>,
                          response =>
                              fun(_CallOpts) ->
                                      terminal_response(
                                        <<"must not start">>)
                              end}}]}),
    Request =
        #{request_id => <<"delegate-adaptive-events-preflight">>,
          correlation_id => CorrelationId,
          objective => #{goal => <<"fail before the first model child">>},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => []},
          artifacts => [],
          budgets => #{max_context_tokens => 0}},
    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    #{status := failed, result := context_budget_exceeded} =
        wait_for_terminal_projection(TaskId, 100),
    Events =
        soma_event_store:by_correlation(
          event_store_pid(), CorrelationId),
    [#{payload := Payload}] =
        [Event || #{event_type := <<"delegate.task.terminal">>} = Event
                      <- Events],
    maps:with(
      [status, mutation_state, unknown_outcome_state], Payload).

adaptive_event_observation(
  {CaseName, EventType}, Events, Forbidden) ->
    Matching =
        [Event || #{event_type := ActualType} = Event <- Events,
                  ActualType =:= EventType],
    #{case_name => CaseName,
      event_count => length(Matching),
      rounds => [maps:get(round, Event, missing) || Event <- Matching],
      documented_fields =>
          [adaptive_event_fields(CaseName, Event) || Event <- Matching],
      bounded =>
          lists:all(
            fun(Event) ->
                    byte_size(term_to_binary(Event, [deterministic])) =<
                        soma_delegate_event:max_bytes()
            end,
            Matching),
      scrubbed =>
          lists:all(
            fun(Event) ->
                    no_process_local_terms(Event) andalso
                        lists:all(
                          fun(Value) ->
                                  not adaptive_term_contains(Event, Value)
                          end,
                          Forbidden)
            end,
            Matching)}.

adaptive_event_fields(decision, #{payload := Payload}) ->
    maps:with(
      [action_summary, global_policy_verdict,
       task_capability_verdict],
      Payload);
adaptive_event_fields(action, Event = #{payload := Payload}) ->
    (maps:with([tool_call_ids, observation_ref], Payload))#{
      run_id => maps:get(run_id, Event, missing)};
adaptive_event_fields(terminal, #{payload := Payload}) ->
    maps:with(
      [status, mutation_state, unknown_outcome_state], Payload).

no_process_local_terms(Term) when is_map(Term) ->
    lists:all(
      fun no_process_local_terms/1,
      maps:keys(Term) ++ maps:values(Term));
no_process_local_terms(Term) when is_list(Term) ->
    lists:all(fun no_process_local_terms/1, Term);
no_process_local_terms(Term) when is_tuple(Term) ->
    no_process_local_terms(tuple_to_list(Term));
no_process_local_terms(Term)
  when is_pid(Term); is_port(Term); is_reference(Term);
       is_function(Term) ->
    false;
no_process_local_terms(_Term) ->
    true.

adaptive_term_contains(Term, Term) ->
    true;
adaptive_term_contains(Map, Needle) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
              adaptive_term_contains(Key, Needle) orelse
                  adaptive_term_contains(Value, Needle)
      end,
      maps:to_list(Map));
adaptive_term_contains(List, Needle) when is_list(List) ->
    lists:any(
      fun(Value) -> adaptive_term_contains(Value, Needle) end,
      List);
adaptive_term_contains(Tuple, Needle) when is_tuple(Tuple) ->
    adaptive_term_contains(tuple_to_list(Tuple), Needle);
adaptive_term_contains(_Term, _Needle) ->
    false.

invoke(#{mode := <<"error">>}, _Ctx) ->
    {error, known_state_failure_reason()};
invoke(#{mode := <<"timeout">>}, _Ctx) ->
    timer:sleep(5000),
    {ok, unreachable};
invoke(Input, _Ctx) ->
    {ok, Input}.

known_state_failure_reason() ->
    {known_delegate_state_error, binary:copy(<<"e">>, 256)}.

bounded_failure_observation(Reason, MaxBytes) ->
    Serialized = iolist_to_binary(soma_lisp:render(Reason)),
    RetainedBytes = min(byte_size(Serialized), MaxBytes),
    Retained = binary:part(Serialized, 0, RetainedBytes),
    Base = #{status => failed, reason => Retained},
    case byte_size(Serialized) > MaxBytes of
        true -> Base#{truncated => true};
        false -> Base
    end.

start_admission_spine_trace() ->
    Modules =
        [soma_proposal, soma_policy, soma_delegate_capability,
         soma_run_sup, soma_tool_call, ?MODULE],
    _ = [code:ensure_loaded(Module) || Module <- Modules],
    Patterns =
        [{soma_proposal, normalize, 1},
         {soma_policy, check, 2},
         {soma_delegate_capability, check, 2},
         {soma_run_sup, start_run, 1},
         {soma_tool_call, start, 1},
         {?MODULE, invoke, 2}],
    _ = [erlang:trace_pattern(Pattern, true, [local])
         || Pattern <- Patterns],
    _ = erlang:trace(new, true, [call, {tracer, self()}]),
    ok.

collect_admission_spine_trace(Acc) ->
    receive
        {trace, Pid, call, {soma_proposal, normalize, Args}} ->
            collect_admission_spine_trace(
              [{proposal_normalize, Pid, Args} | Acc]);
        {trace, Pid, call, {soma_policy, check, Args}} ->
            collect_admission_spine_trace(
              [{global_policy, Pid, Args} | Acc]);
        {trace, Pid, call, {soma_delegate_capability, check, Args}} ->
            collect_admission_spine_trace(
              [{task_capability, Pid, Args} | Acc]);
        {trace, Pid, call, {soma_run_sup, start_run, Args}} ->
            collect_admission_spine_trace(
              [{run_start, Pid, Args} | Acc]);
        {trace, Pid, call, {soma_tool_call, start, Args}} ->
            collect_admission_spine_trace(
              [{tool_start, Pid, Args} | Acc]);
        {trace, Pid, call, {?MODULE, invoke, Args}} ->
            collect_admission_spine_trace(
              [{state_invoke, Pid, Args} | Acc])
    after 100 ->
        lists:reverse(Acc)
    end.

clear_admission_spine_trace() ->
    _ = erlang:trace(new, false, [call]),
    Patterns =
        [{soma_proposal, normalize, 1},
         {soma_policy, check, 2},
         {soma_delegate_capability, check, 2},
         {soma_run_sup, start_run, 1},
         {soma_tool_call, start, 1},
         {?MODULE, invoke, 2}],
    _ = [erlang:trace_pattern(Pattern, false, [local])
         || Pattern <- Patterns],
    ok.

receive_prompt_projection() ->
    receive
        {delegate_prompt_projection, Projection} ->
            Projection
    after 2000 ->
        ct:fail(delegate_prompt_projection_not_observed)
    end.

receive_artifact_prompt() ->
    receive
        {delegate_artifact_prompt, Projection} ->
            Projection
    after 2000 ->
        ct:fail(delegate_artifact_prompt_not_observed)
    end.

receive_recent_window_prompt() ->
    receive
        {delegate_recent_window_prompt, Projection} ->
            Projection
    after 2000 ->
        ct:fail(delegate_recent_window_prompt_not_observed)
    end.

receive_safety_prompt(Round) ->
    receive
        {delegate_safety_prompt, Round, Projection} ->
            Projection
    after 2000 ->
        ct:fail({delegate_safety_prompt_not_observed, Round})
    end.

safety_llm(Responder) ->
    #{provider => openai_compat,
      base_url => <<"api.example.test/v1">>,
      api_key => <<"test-only-key">>,
      model => <<"test-model">>,
      response => Responder}.

send_safety_round_result(
  CoordinatorPid, TaskId,
  #{round_id := RoundId,
    worker_pid := WorkerPid,
    worker_identity := WorkerIdentity,
    result_capability := ResultCapability},
  Result) ->
    CoordinatorPid !
        {delegate_round_result, TaskId, RoundId, WorkerPid,
         WorkerIdentity, ResultCapability, Result},
    ok.

safety_state_bytes(SafetyState) ->
    byte_size(
      iolist_to_binary(io_lib:format("~0p", [SafetyState]))).

start_safety_preflight_trace() ->
    {module, soma_delegate_prompt} =
        code:ensure_loaded(soma_delegate_prompt),
    _ = erlang:trace_pattern(
          {soma_delegate_prompt, preflight, 3}, true, [local]),
    _ = erlang:trace(new, true, [call, {tracer, self()}]),
    ok.

receive_safety_preflight_projection() ->
    receive
        {trace, _CoordinatorPid, call,
         {soma_delegate_prompt, preflight,
          [Projection, _Budgets, _CommittedPromptTokens]}} ->
            Projection
    after 2000 ->
        ct:fail(delegate_safety_preflight_not_observed)
    end.

clear_safety_preflight_trace() ->
    _ = erlang:trace(new, false, [call]),
    _ = erlang:trace_pattern(
          {soma_delegate_prompt, preflight, 3}, false, [local]),
    ok.

oversized_safety_llm_started() ->
    receive
        delegate_oversized_safety_llm_started ->
            true
    after 100 ->
        false
    end.

collect_maximum_prompt_estimates(0, Acc) ->
    [Estimate || {_Round, Estimate} <- lists:keysort(1, Acc)];
collect_maximum_prompt_estimates(Remaining, Acc) ->
    receive
        {delegate_maximum_prompt_estimate, Round, Estimate} ->
            collect_maximum_prompt_estimates(
              Remaining - 1, [{Round, Estimate} | Acc])
    after 2000 ->
        ct:fail(delegate_maximum_prompt_estimate_not_observed)
    end.

terminal_response(Text) ->
    Body =
        iolist_to_binary(
          json:encode(
            #{<<"choices">> =>
                  [#{<<"message">> => #{<<"content">> => Text}}]})),
    {200, Body}.

terminal_response(Text, PromptTokens) ->
    Body =
        iolist_to_binary(
          json:encode(
            #{<<"choices">> =>
                  [#{<<"message">> => #{<<"content">> => Text}}],
              <<"usage">> => #{<<"prompt_tokens">> => PromptTokens}})),
    {200, Body}.

collect_sequence_prompts(Acc) ->
    receive
        {delegate_sequence_prompt, Round, CallOpts} ->
            collect_sequence_prompts([{Round, CallOpts} | Acc])
    after 100 ->
        lists:keysort(1, Acc)
    end.

collect_failure_prompts(Acc) ->
    receive
        {delegate_failure_prompt, Round, Projection} ->
            collect_failure_prompts([{Round, Projection} | Acc])
    after 100 ->
        lists:keysort(1, Acc)
    end.

next_round_observation(ActionRound, Prompts) ->
    case lists:keyfind(ActionRound + 1, 1, Prompts) of
        {_NextRound, Projection} ->
            RecentRounds = maps:get(recent_rounds, Projection, []),
            case [maps:get(observation, RecentRound, missing)
                  || #{round := Round} = RecentRound <- RecentRounds,
                     Round =:= ActionRound] of
                [Observation] -> Observation;
                _MissingOrDuplicate -> missing
            end;
        false ->
            missing
    end.

prompt_mutation_ledger(Round, Prompts) ->
    case lists:keyfind(Round, 1, Prompts) of
        {_Round, Projection} ->
            SafetyState = maps:get(pinned_safety_state, Projection, #{}),
            maps:get(mutation_ledger, SafetyState, []);
        false ->
            []
    end.

next_prompt_contains(ActionRound, Observation, Prompts) ->
    case lists:keyfind(ActionRound + 1, 1, Prompts) of
        {_NextRound, CallOpts} ->
            messages_contain(
              maps:get(messages, CallOpts, []), Observation);
        false ->
            false
    end.

messages_contain(Messages, Observation) ->
    lists:any(
      fun(#{content := Content}) when is_binary(Content) ->
              binary:match(Content, Observation) =/= nomatch;
         (_OtherMessage) ->
              false
      end,
      Messages).

observe_denied_action_case(
  {CaseName, ToolPolicy, CapabilityScope, Proposal, _ExpectedStatus}) ->
    Suffix = atom_to_binary(CaseName, utf8),
    CorrelationId = <<"delegate-denial-", Suffix/binary, "-correlation">>,
    RuntimeOptions =
        #{tool_policy => ToolPolicy,
          round_sequence =>
              [#{llm => #{directive => proposal, output => Proposal},
                 decision => terminal}]},
    ok = application:set_env(
           soma_actor, delegate_runtime_options, RuntimeOptions),
    Request =
        #{request_id => <<"delegate-denial-", Suffix/binary>>,
          correlation_id => CorrelationId,
          objective => #{goal => <<"exercise action admission">>},
          output_contract => #{format => <<"task-data">>},
          capability_scope => CapabilityScope,
          artifacts => []},
    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    #{status := Status} = wait_for_terminal_projection(TaskId, 100),
    Events =
        soma_event_store:by_correlation(
          event_store_pid(), CorrelationId),
    #{case_name => CaseName,
      status => Status,
      run_started =>
          lists:any(
            fun(#{event_type := <<"run.started">>}) -> true;
               (_) -> false
            end,
            Events)}.

observe_budget_case(
  {Limit, Budgets, SecondDecision, _ExpectedUsage, _ExpectedStarts}) ->
    TestPid = self(),
    Suffix = atom_to_binary(Limit, utf8),
    Responses =
        case Limit of
            max_rounds ->
                [budget_action_response(1)];
            _OtherLimit ->
                [budget_action_response(1),
                 budget_second_response(SecondDecision)]
        end,
    RoundSequence =
        [#{llm =>
               #{provider => openai_compat,
                 base_url => <<"api.example.test/v1">>,
                 api_key => <<"test-only-key">>,
                 model => <<"test-model">>,
                 response =>
                     fun(CallOpts) ->
                             TestPid !
                                 {delegate_budget_llm_started,
                                  Limit, Round, self(),
                                  rendered_prompt_tokens(CallOpts)},
                             terminal_response(Response)
                     end}}
         || {Round, Response} <- lists:enumerate(Responses)],
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{tool_policy => #{allowed_tools => [echo]},
             round_sequence => RoundSequence}),
    CorrelationId =
        <<"delegate-budget-", Suffix/binary, "-correlation">>,
    Request =
        #{request_id => <<"delegate-budget-", Suffix/binary>>,
          correlation_id => CorrelationId,
          objective => #{goal => <<"stop before the prohibited child">>},
          output_contract => #{format => <<"task-data">>},
          capability_scope => #{tools => [<<"echo">>]},
          artifacts => [],
          budgets => Budgets},

    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Terminal = wait_for_terminal_projection(TaskId, 100),
    wait_for_no_coordinators(100),
    LlmStarts = collect_budget_llm_workers(Limit, []),
    LlmWorkers = [Pid || {_Round, Pid, _Estimate} <- LlmStarts],
    PromptEstimates =
        [Estimate || {_Round, _Pid, Estimate} <- LlmStarts],
    Usage = maps:get(usage, Terminal, missing),
    Events =
        soma_event_store:by_correlation(
          event_store_pid(), CorrelationId),
    wait_for_no_budget_children(100),
    #{limit => Limit,
      status => maps:get(status, Terminal),
      budget_data => maps:get(result, Terminal, missing),
      usage => maps:remove(prompt_tokens, Usage),
      prompt_tokens_match_estimates =>
          maps:get(prompt_tokens, Usage, missing) =:=
              lists:sum(PromptEstimates),
      started_children =>
          #{round_workers =>
                event_type_count(
                  <<"delegate.round.started">>, Events),
            llm_workers => length(LlmWorkers),
            runs => event_type_count(<<"run.started">>, Events)},
      llm_workers_dead =>
          lists:all(
            fun(Pid) -> not is_process_alive(Pid) end,
            LlmWorkers),
      live_round_workers => length(live_round_workers()),
      live_runs => length(live_runs())}.

observe_context_budget_row({CaseName, Budgets, ReportedPromptTokens}) ->
    TestPid = self(),
    ResponseText = <<"provider usage committed">>,
    Responder =
        fun(CallOpts) ->
                EstimatedPromptTokens =
                    lists:sum(
                      [byte_size(Content)
                       || #{content := Content} <-
                              maps:get(messages, CallOpts, []),
                          is_binary(Content)]),
                TestPid !
                    {delegate_context_llm_started,
                     CaseName, self(), EstimatedPromptTokens},
                case ReportedPromptTokens of
                    undefined ->
                        terminal_response(ResponseText);
                    PromptTokens ->
                        terminal_response(ResponseText, PromptTokens)
                end
        end,
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{round_sequence =>
                 [#{llm =>
                        #{provider => openai_compat,
                          base_url => <<"api.example.test/v1">>,
                          api_key => <<"test-only-key">>,
                          model => <<"test-model">>,
                          response => Responder},
                    decision => terminal}]}),
    Suffix = atom_to_binary(CaseName, utf8),
    Request =
        #{request_id => <<"delegate-context-", Suffix/binary>>,
          correlation_id =>
              <<"delegate-context-", Suffix/binary, "-correlation">>,
          objective => #{goal => <<"enforce the context allowance">>},
          output_contract => #{format => <<"text">>},
          capability_scope => #{tools => []},
          artifacts => [],
          budgets => Budgets},
    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    Terminal = wait_for_terminal_projection(TaskId, 100),
    wait_for_no_coordinators(100),
    Starts = collect_context_llm_starts(CaseName, []),
    Estimates = [Estimate || {_Pid, Estimate} <- Starts],
    #{case_name => CaseName,
      status => maps:get(status, Terminal),
      result => maps:get(result, Terminal, missing),
      usage => maps:get(usage, Terminal, missing),
      llm_worker_count => length(Starts),
      llm_workers_dead =>
          lists:all(
            fun({WorkerPid, _Estimate}) ->
                    not is_process_alive(WorkerPid)
            end,
            Starts),
      provider_usage_replaced_estimate =>
          case ReportedPromptTokens of
              undefined ->
                  not_applicable;
              PromptTokens ->
                  Estimates =/= [] andalso
                      lists:all(
                        fun(Estimate) -> Estimate =/= PromptTokens end,
                        Estimates)
          end}.

collect_context_llm_starts(CaseName, Acc) ->
    receive
        {delegate_context_llm_started,
         CaseName, WorkerPid, EstimatedPromptTokens} ->
            collect_context_llm_starts(
              CaseName, [{WorkerPid, EstimatedPromptTokens} | Acc])
    after 100 ->
        lists:reverse(Acc)
    end.

observe_blocked_llm_deadline(DeadlineMs) ->
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{round_sequence =>
                 [#{llm => #{directive => hang, timeout_ms => 60000},
                    decision => terminal}]}),
    Request =
        #{request_id => <<"delegate-deadline-blocked-llm">>,
          correlation_id => <<"delegate-deadline-blocked-llm-correlation">>,
          objective => #{goal => <<"stop one blocked model call">>},
          output_contract => #{format => <<"task-data">>},
          capability_scope => #{tools => []},
          artifacts => [],
          budgets => #{deadline_ms => DeadlineMs}},
    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    RoundWorkerPid = wait_for_single_round_worker(100),
    #{pid := LlmPid} =
        wait_for_worker_child(
          RoundWorkerPid, waiting_llm, active_llm, 100),
    ?assert(is_process_alive(RoundWorkerPid)),
    ?assert(is_process_alive(LlmPid)),

    Terminal = wait_for_deadline_terminal_or_cancel(TaskId, 300),
    #{case_name => blocked_llm,
      status => maps:get(status, Terminal),
      owned_beam_pids_dead =>
          lists:all(
            fun(Pid) -> not is_process_alive(Pid) end,
            [RoundWorkerPid, LlmPid]),
      external_process_dead => not_applicable,
      live_round_workers => length(live_round_workers()),
      live_runs => length(live_runs())}.

observe_blocked_cli_deadline(DeadlineMs, Config) ->
    ToolName = delegate_deadline_cli,
    {Helper, PidFile} =
        write_deadline_cli_stub(
          proplists:get_value(priv_dir, Config)),
    ok = soma_tool_registry:register_tool(
           #{name => ToolName,
             effect => reader,
             idempotent => true,
             timeout_ms => 60000,
             adapter => cli,
             executable => Helper,
             argv => [PidFile],
             description => <<"Blocks until the task owner cancels it.">>}),
    try
        TestPid = self(),
        ActionSource =
            <<"(run-steps (step (id deadline_cli_action) "
              "(tool delegate_deadline_cli) "
              "(args (value \"block until deadline\")) "
              "(timeout_ms 60000)))">>,
        Responder =
            fun(_CallOpts) ->
                    TestPid ! {delegate_deadline_action_llm, self()},
                    terminal_response(ActionSource)
            end,
        ok = application:set_env(
               soma_actor, delegate_runtime_options,
               #{tool_policy => #{allowed_tools => [ToolName]},
                 round_sequence =>
                     [#{llm =>
                            #{provider => openai_compat,
                              base_url => <<"api.example.test/v1">>,
                              api_key => <<"test-only-key">>,
                              model => <<"test-model">>,
                              timeout_ms => 60000,
                              response => Responder}}]}),
        CorrelationId =
            <<"delegate-deadline-blocked-cli-correlation">>,
        Request =
            #{request_id => <<"delegate-deadline-blocked-cli">>,
              correlation_id => CorrelationId,
              objective => #{goal => <<"stop one blocked CLI action">>},
              output_contract => #{format => <<"task-data">>},
              capability_scope => #{tools => [<<"delegate_deadline_cli">>]},
              artifacts => [],
              budgets => #{deadline_ms => DeadlineMs}},
        {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
        ActionLlmPid = receive_deadline_action_llm(),
        RoundWorkerPid = wait_for_single_round_worker(100),
        #{pid := RunPid} =
            wait_for_worker_child(
              RoundWorkerPid, waiting_run, active_run, 100),
        ToolCallPid =
            wait_for_tool_call_pid(CorrelationId, 100),
        OsPid = wait_for_deadline_os_pid(PidFile, 100),
        ?assert(is_process_alive(RoundWorkerPid)),
        ?assert(is_process_alive(RunPid)),
        ?assert(is_process_alive(ToolCallPid)),
        ?assert(deadline_os_process_alive(OsPid)),

        Terminal = wait_for_deadline_terminal_or_cancel(TaskId, 300),
        #{case_name => blocked_cli_action,
          status => maps:get(status, Terminal),
          owned_beam_pids_dead =>
              lists:all(
                fun(Pid) -> not is_process_alive(Pid) end,
                [ActionLlmPid, RoundWorkerPid, RunPid, ToolCallPid]),
          external_process_dead => not deadline_os_process_alive(OsPid),
          live_round_workers => length(live_round_workers()),
          live_runs => length(live_runs())}
    after
        ok = soma_tool_registry:unregister_tool(ToolName)
    end.

write_deadline_cli_stub(TmpDir) ->
    Helper = filename:join(TmpDir, "delegate-deadline-cli.sh"),
    PidFile = filename:join(TmpDir, "delegate-deadline-cli.pid"),
    _ = file:delete(PidFile),
    Script = <<"#!/bin/sh\n"
               "printf '%s\\n' \"$$\" > \"$1\"\n"
               "sleep 30\n">>,
    ok = filelib:ensure_dir(Helper),
    ok = file:write_file(Helper, Script),
    ok = file:change_mode(Helper, 8#755),
    {Helper, PidFile}.

receive_deadline_action_llm() ->
    receive
        {delegate_deadline_action_llm, LlmPid} ->
            LlmPid
    after 2000 ->
        ct:fail(delegate_deadline_action_llm_not_started)
    end.

wait_for_single_round_worker(0) ->
    ct:fail(delegate_deadline_round_worker_not_started);
wait_for_single_round_worker(Attempts) ->
    case live_round_workers() of
        [RoundWorkerPid] ->
            RoundWorkerPid;
        [] ->
            timer:sleep(10),
            wait_for_single_round_worker(Attempts - 1)
    end.

wait_for_worker_child(_WorkerPid, _StateName, _ChildKey, 0) ->
    ct:fail(delegate_deadline_child_not_started);
wait_for_worker_child(WorkerPid, StateName, ChildKey, Attempts) ->
    case sys:get_state(WorkerPid) of
        {StateName, WorkerData} ->
            case maps:get(ChildKey, WorkerData, undefined) of
                Child when is_map(Child) ->
                    Child;
                undefined ->
                    timer:sleep(10),
                    wait_for_worker_child(
                      WorkerPid, StateName, ChildKey, Attempts - 1)
            end;
        {_OtherStateName, _WorkerData} ->
            timer:sleep(10),
            wait_for_worker_child(
              WorkerPid, StateName, ChildKey, Attempts - 1)
    end.

wait_for_tool_call_pid(_CorrelationId, 0) ->
    ct:fail(delegate_deadline_tool_worker_not_started);
wait_for_tool_call_pid(CorrelationId, Attempts) ->
    Events =
        soma_event_store:by_correlation(
          event_store_pid(), CorrelationId),
    case [maps:get(tool_call_pid, Event)
          || #{event_type := <<"tool.started">>} = Event <- Events] of
        [ToolCallPid] ->
            ToolCallPid;
        [] ->
            timer:sleep(10),
            wait_for_tool_call_pid(CorrelationId, Attempts - 1)
    end.

wait_for_deadline_os_pid(_PidFile, 0) ->
    ct:fail(delegate_deadline_cli_did_not_write_os_pid);
wait_for_deadline_os_pid(PidFile, Attempts) ->
    case file:read_file(PidFile) of
        {ok, Bytes} ->
            list_to_integer(string:trim(binary_to_list(Bytes)));
        {error, enoent} ->
            timer:sleep(10),
            wait_for_deadline_os_pid(PidFile, Attempts - 1)
    end.

wait_for_deadline_terminal_or_cancel(TaskId, 0) ->
    {ok, Cancelled} = soma_delegate:cancel(TaskId),
    Cancelled;
wait_for_deadline_terminal_or_cancel(TaskId, Attempts) ->
    case soma_delegate:status(TaskId) of
        {ok, #{status := Status} = Projection}
          when Status =:= succeeded; Status =:= failed;
               Status =:= rejected; Status =:= timeout;
               Status =:= cancelled; Status =:= in_doubt ->
            Projection;
        {ok, #{status := Status}}
          when Status =:= accepted; Status =:= running ->
            timer:sleep(10),
            wait_for_deadline_terminal_or_cancel(
              TaskId, Attempts - 1)
    end.

deadline_os_process_alive(OsPid) ->
    Kill = os:find_executable("kill"),
    Port = open_port(
             {spawn_executable, Kill},
             [{args, ["-0", integer_to_list(OsPid)]},
              exit_status, binary, use_stdio, stderr_to_stdout]),
    deadline_os_process_probe_result(Port).

deadline_os_process_probe_result(Port) ->
    receive
        {Port, {data, _Bytes}} ->
            deadline_os_process_probe_result(Port);
        {Port, {exit_status, 0}} ->
            true;
        {Port, {exit_status, _NonZero}} ->
            false
    after 1000 ->
        erlang:port_close(Port),
        ct:fail(delegate_deadline_os_process_probe_timeout)
    end.

budget_action_response(1) ->
    <<"(run-steps (step (id budget_action_one) (tool echo) "
      "(args (value \"one\"))))">>.

budget_second_response(terminal) ->
    <<"(reply (text \"the budget gate should stop before this reply\"))">>;
budget_second_response(action) ->
    <<"(run-steps (step (id budget_action_two) (tool echo) "
      "(args (value \"two\"))))">>.

collect_budget_llm_workers(Limit, Acc) ->
    receive
        {delegate_budget_llm_started,
         Limit, Round, WorkerPid, EstimatedPromptTokens} ->
            collect_budget_llm_workers(
              Limit,
              [{Round, WorkerPid, EstimatedPromptTokens} | Acc])
    after 100 ->
        lists:keysort(1, Acc)
    end.

rendered_prompt_tokens(CallOpts) ->
    lists:sum(
      [byte_size(Content)
       || #{content := Content} <- maps:get(messages, CallOpts, []),
          is_binary(Content)]).

event_type_count(EventType, Events) ->
    length(
      [Event || #{event_type := ActualType} = Event <- Events,
                ActualType =:= EventType]).

observe_fresh_usage() ->
    ok = application:set_env(
           soma_actor, delegate_runtime_options,
           #{round_sequence => []}),
    Request =
        #{request_id => <<"delegate-budget-fresh-request">>,
          correlation_id => <<"delegate-budget-fresh-correlation">>,
          objective => #{goal => <<"expose fresh counters">>},
          output_contract => #{format => <<"task-data">>},
          capability_scope => #{tools => []},
          artifacts => []},
    {ok, #{task_id := TaskId}} = soma_delegate:submit(Request),
    _Projection = wait_for_running_projection(TaskId, 100),
    [CoordinatorPid] = live_coordinators(),
    {running, CoordinatorData} = sys:get_state(CoordinatorPid),
    Usage = maps:get(counters, CoordinatorData, missing),
    {ok, #{status := cancelled}} = soma_delegate:cancel(TaskId),
    wait_for_no_coordinators(100),
    Usage.

wait_for_running_projection(_TaskId, 0) ->
    ct:fail(delegate_task_did_not_start);
wait_for_running_projection(TaskId, Attempts) ->
    case soma_delegate:status(TaskId) of
        {ok, #{status := running} = Projection} ->
            Projection;
        {ok, #{status := accepted}} ->
            timer:sleep(10),
            wait_for_running_projection(TaskId, Attempts - 1)
    end.

wait_for_terminal_projection(_TaskId, 0) ->
    ct:fail(delegate_task_did_not_finish);
wait_for_terminal_projection(TaskId, Attempts) ->
    case soma_delegate:status(TaskId) of
        {ok, #{status := Status} = Projection}
          when Status =:= succeeded; Status =:= failed;
               Status =:= rejected;
               Status =:= timeout; Status =:= cancelled;
               Status =:= in_doubt ->
            Projection;
        {ok, #{status := running}} ->
            timer:sleep(10),
            wait_for_terminal_projection(TaskId, Attempts - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Modules} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.

observe_boundary_case({accepted, Request}) ->
    Reply = soma_delegate:submit(Request),
    Coordinators = live_coordinators(),
    NormalizedRequest = coordinator_request(Coordinators),
    Observation =
        #{case_name => accepted,
          reply => reply_class(Reply),
          coordinator_count => length(Coordinators),
          normalized_request => NormalizedRequest,
          normalized_keys => normalized_keys(NormalizedRequest)},
    cleanup_accepted(Reply),
    Observation;
observe_boundary_case({forbidden, Class, Request}) ->
    Reply = soma_delegate:submit(Request),
    Coordinators = live_coordinators(),
    Observation =
        #{case_name => Class,
          reply => reply_class(Reply),
          coordinator_count => length(Coordinators)},
    cleanup_accepted(Reply),
    Observation.

coordinator_request([CoordinatorPid]) ->
    {_StateName, CoordinatorData} = sys:get_state(CoordinatorPid),
    maps:get(request, CoordinatorData, missing);
coordinator_request(_Coordinators) ->
    missing.

normalized_keys(Request) when is_map(Request) ->
    lists:sort(maps:keys(Request));
normalized_keys(_Missing) ->
    [].

reply_class({ok, #{status := accepted}}) ->
    accepted;
reply_class(Reply) ->
    Reply.

cleanup_accepted({ok, #{task_id := TaskId}}) ->
    _ = soma_delegate:cancel(TaskId),
    wait_for_no_coordinators(100);
cleanup_accepted(_Rejected) ->
    ?assertEqual([], live_coordinators()).

wait_for_no_coordinators(0) ->
    ?assertEqual([], live_coordinators());
wait_for_no_coordinators(Attempts) ->
    case live_coordinators() of
        [] ->
            ok;
        _StillRunning ->
            timer:sleep(10),
            wait_for_no_coordinators(Attempts - 1)
    end.

live_coordinators() ->
    [Pid || {_Id, Pid, worker, _Modules} <-
                supervisor:which_children(
                  soma_delegate_coordinator_sup),
            is_pid(Pid),
            is_process_alive(Pid)].

live_round_workers() ->
    [Pid || {_Id, Pid, worker, _Modules} <-
                supervisor:which_children(soma_delegate_round_sup),
            is_pid(Pid),
            is_process_alive(Pid)].

live_runs() ->
    [Pid || {_Id, Pid, worker, _Modules} <-
                supervisor:which_children(soma_run_sup),
            is_pid(Pid),
            is_process_alive(Pid)].

wait_for_no_budget_children(0) ->
    ?assertEqual(
       {[], []}, {live_round_workers(), live_runs()});
wait_for_no_budget_children(Attempts) ->
    case {live_round_workers(), live_runs()} of
        {[], []} ->
            ok;
        _ChildrenStillRunning ->
            timer:sleep(10),
            wait_for_no_budget_children(Attempts - 1)
    end.
