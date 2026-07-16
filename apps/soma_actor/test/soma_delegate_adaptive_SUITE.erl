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
     test_oversized_observation_uses_stable_task_artifact_and_bounded_slice].

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
          #{rounds => 1, llm_calls => 1,
            tool_calls => 1, prompt_tokens => 0},
          #{round_workers => 1, llm_workers => 1, runs => 1}},
         {max_llm_calls,
          #{max_rounds => 10,
            max_llm_calls => 1,
            max_tool_calls => 10},
          terminal,
          #{rounds => 2, llm_calls => 1,
            tool_calls => 1, prompt_tokens => 0},
          #{round_workers => 2, llm_workers => 1, runs => 1}},
         {max_tool_calls,
          #{max_rounds => 10,
            max_llm_calls => 10,
            max_tool_calls => 1},
          action,
          #{rounds => 2, llm_calls => 2,
            tool_calls => 1, prompt_tokens => 0},
          #{round_workers => 2, llm_workers => 2, runs => 1}}],
    ActualCases = [observe_budget_case(Case) || Case <- Cases],
    ExpectedCases =
        [#{limit => Limit,
           status => failed,
           budget_data => {budget_exceeded, Limit},
           usage => ExpectedUsage,
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
        [budget_action_response(1),
         budget_second_response(SecondDecision)],
    RoundSequence =
        [#{llm =>
               #{provider => openai_compat,
                 base_url => <<"api.example.test/v1">>,
                 api_key => <<"test-only-key">>,
                 model => <<"test-model">>,
                 response =>
                     fun(_CallOpts) ->
                             TestPid !
                                 {delegate_budget_llm_started,
                                  Limit, Round, self()},
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
    LlmWorkers = collect_budget_llm_workers(Limit, []),
    Events =
        soma_event_store:by_correlation(
          event_store_pid(), CorrelationId),
    wait_for_no_budget_children(100),
    #{limit => Limit,
      status => maps:get(status, Terminal),
      budget_data => maps:get(result, Terminal, missing),
      usage => maps:get(usage, Terminal, missing),
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
        {delegate_budget_llm_started, Limit, Round, WorkerPid} ->
            collect_budget_llm_workers(
              Limit, [{Round, WorkerPid} | Acc])
    after 100 ->
        [WorkerPid || {_Round, WorkerPid} <- lists:keysort(1, Acc)]
    end.

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
