-module(soma_delegate_adaptive_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([test_request_boundary_normalizes_allowlist_and_rejects_forbidden_inputs/1]).
-export([test_prompt_projection_uses_exact_task_local_fields/1]).

all() ->
    [test_request_boundary_normalizes_allowlist_and_rejects_forbidden_inputs,
     test_prompt_projection_uses_exact_task_local_fields].

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

receive_prompt_projection() ->
    receive
        {delegate_prompt_projection, Projection} ->
            Projection
    after 2000 ->
        ct:fail(delegate_prompt_projection_not_observed)
    end.

terminal_response(Text) ->
    Body =
        iolist_to_binary(
          json:encode(
            #{<<"choices">> =>
                  [#{<<"message">> => #{<<"content">> => Text}}]})),
    {200, Body}.

wait_for_terminal_projection(_TaskId, 0) ->
    ct:fail(delegate_task_did_not_finish);
wait_for_terminal_projection(TaskId, Attempts) ->
    case soma_delegate:status(TaskId) of
        {ok, #{status := Status} = Projection}
          when Status =:= succeeded; Status =:= failed;
               Status =:= timeout; Status =:= cancelled;
               Status =:= in_doubt ->
            Projection;
        {ok, #{status := running}} ->
            timer:sleep(10),
            wait_for_terminal_projection(TaskId, Attempts - 1)
    end.

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
