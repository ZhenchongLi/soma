%% @doc Pure task-local prompt projection for one delegated decision round.
%% Provider configuration and process-owned coordinator data are deliberately
%% absent from the returned map.
-module(soma_delegate_prompt).

-export([project/2, artifact_excerpt/3, render/1, preflight/3]).

project(Snapshot, CoordinatorData)
  when is_map(Snapshot), is_map(CoordinatorData) ->
    Request = maps:get(request, CoordinatorData, #{}),
    #{objective => maps:get(objective, Snapshot, undefined),
      output_contract => maps:get(output_contract, Snapshot, undefined),
      task_summary => maps:get(task_summary, CoordinatorData, #{}),
      pinned_safety_state =>
          #{capability_scope => maps:get(capability_scope, Request, #{}),
            mutation_ledger =>
                maps:get(mutation_ledger, CoordinatorData, []),
            unknown_outcome_ledger =>
                maps:get(unknown_outcome_ledger, CoordinatorData, []),
            idempotency_state =>
                maps:get(idempotency_state, CoordinatorData, #{})},
      recent_rounds => maps:get(recent_rounds, CoordinatorData, []),
      artifact_excerpts =>
          maps:get(
            artifact_excerpts, CoordinatorData,
            maps:get(artifacts, Request, [])),
      tool_schemas => maps:get(tool_schemas, CoordinatorData, [])}.

artifact_excerpt(
  #{handle := Handle, bytes := ByteCount}, Bytes, MaxBytes)
  when is_binary(Handle), is_integer(ByteCount), ByteCount >= 0,
       is_binary(Bytes), is_integer(MaxBytes), MaxBytes >= 0 ->
    ExcerptBytes = min(byte_size(Bytes), MaxBytes),
    #{handle => Handle,
      bytes => ByteCount,
      excerpt => binary:part(Bytes, 0, ExcerptBytes),
      truncated => byte_size(Bytes) > ExcerptBytes}.

render(Projection) when is_map(Projection) ->
    Content = iolist_to_binary(io_lib:format("~0p", [Projection])),
    [#{role => <<"user">>, content => Content}].

%% Render exactly once, estimate conservatively at one token per rendered
%% UTF-8 byte, and apply both context admission checks before an LLM worker can
%% be created. The caller reuses the returned Messages for the provider call.
preflight(Projection, Budgets, CommittedPromptTokens)
  when is_map(Projection), is_map(Budgets),
       is_integer(CommittedPromptTokens), CommittedPromptTokens >= 0 ->
    Messages = render(Projection),
    EstimatedPromptTokens = estimate_prompt_tokens(Messages),
    case within_call_allowance(EstimatedPromptTokens, Budgets) andalso
         within_total_allowance(
           EstimatedPromptTokens, CommittedPromptTokens, Budgets) of
        true ->
            {ok, #{messages => Messages,
                   estimated_prompt_tokens => EstimatedPromptTokens}};
        false ->
            {error, context_budget_exceeded}
    end.

estimate_prompt_tokens(Messages) ->
    lists:sum(
      [byte_size(Content)
       || #{content := Content} <- Messages,
          is_binary(Content)]).

within_call_allowance(EstimatedPromptTokens, Budgets) ->
    case maps:find(max_context_tokens, Budgets) of
        error ->
            true;
        {ok, MaxContextTokens}
          when is_integer(MaxContextTokens), MaxContextTokens >= 0 ->
            case maps:get(reserved_completion_tokens, Budgets, 0) of
                ReservedCompletionTokens
                  when is_integer(ReservedCompletionTokens),
                       ReservedCompletionTokens >= 0 ->
                    EstimatedPromptTokens =<
                        MaxContextTokens - ReservedCompletionTokens;
                _InvalidReservation ->
                    false
            end;
        {ok, _InvalidContextLimit} ->
            false
    end.

within_total_allowance(
  EstimatedPromptTokens, CommittedPromptTokens, Budgets) ->
    case maps:find(max_total_prompt_tokens, Budgets) of
        error ->
            true;
        {ok, MaxTotalPromptTokens}
          when is_integer(MaxTotalPromptTokens),
               MaxTotalPromptTokens >= 0 ->
            CommittedPromptTokens + EstimatedPromptTokens =<
                MaxTotalPromptTokens;
        {ok, _InvalidTotalLimit} ->
            false
    end.
