%% @doc Pure task-local prompt projection for one delegated decision round.
%% Provider configuration and process-owned coordinator data are deliberately
%% absent from the returned map.
-module(soma_delegate_prompt).

-export([project/2, render/1]).

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
      artifact_excerpts => maps:get(artifacts, Request, []),
      tool_schemas => maps:get(tool_schemas, CoordinatorData, [])}.

render(Projection) when is_map(Projection) ->
    Content = iolist_to_binary(io_lib:format("~0p", [Projection])),
    [#{role => <<"user">>, content => Content}].
