%% @doc Actor-side proofs that an actor started with a real-provider
%% `model_config' drives an `llm' task to completion through the real provider
%% module (`soma_llm_openai') -- node B.2. Set up like soma_proposal_exec_SUITE:
%% boot the soma_runtime app (so the event store is alive), start an actor
%% through soma_actor_sup:start_actor/1 with a real-provider `model_config', and
%% drive it through the real soma_actor:send/2. The real-provider `model_config'
%% carries a fixed `response' so soma_llm_openai:chat/1 parses it directly and
%% opens no socket -- the same seam node B.1's gate test used. Outcomes are read
%% back through get_task_result/2.
-module(soma_actor_real_provider_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([real_provider_actor_completes_llm_task_through_openai_no_socket/1]).
-export([mock_model_config_completes_llm_task_same_result_and_events/1]).
-export([api_key_appears_in_no_emitted_event/1]).
-export([test_rendered_reply_carries_no_api_key/1]).

all() ->
    [real_provider_actor_completes_llm_task_through_openai_no_socket,
     mock_model_config_completes_llm_task_same_result_and_events,
     api_key_appears_in_no_emitted_event,
     test_rendered_reply_carries_no_api_key].

init_per_testcase(_TestCase, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    {ok, Sup} = soma_actor_sup:start_link(),
    [{sup, Sup}, {started_apps, Started} | Config].

end_per_testcase(_TestCase, Config) ->
    case ?config(sup, Config) of
        undefined -> ok;
        Sup ->
            unlink(Sup),
            exit(Sup, shutdown)
    end,
    application:stop(soma_runtime),
    ok.

%% Criterion 4: an actor started with a real-provider `model_config' drives an
%% `llm' task to completion through soma_llm_openai using the fixed `response'
%% seam (no socket opened), and the task result is the parsed `reply' proposal.
%% The actor is started with a real-provider `model_config'
%% (`provider => openai_compat', a base_url, a model, an api_key) carrying a fixed
%% `response' -- a {200, JSON body}. Enters through the real soma_actor:send/2 with
%% an `llm' envelope (so the actor takes its llm-call path); the actor's
%% build_call_opts/2 threads the model_config's real-provider fields and the fixed
%% `response' into the worker opts, so soma_llm_openai:chat/1 parses the response
%% directly and opens no socket. The test waits for the task to reach `completed',
%% then asserts get_task_result/2 returns the parsed reply proposal
%% (`#{kind => reply, text => Content}') drawn from choices[0].message.content.
real_provider_actor_completes_llm_task_through_openai_no_socket(_Config) ->
    Store = event_store_pid(),
    Content = <<"hello from the real provider">>,
    Body = iolist_to_binary(
             json:encode(#{<<"choices">> =>
                               [#{<<"message">> =>
                                      #{<<"content">> => Content}}]})),
    %% Scheme-less host literal: the `response' seam means soma_llm_openai:chat/1
    %% parses the fixed response directly and never dials this url, so the suite
    %% names no scheme-prefixed network address (criterion 7's guard).
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    api_key => <<"sk-test-key">>,
                    response => {200, Body}},
    Opts = #{actor_id => <<"actor-real-provider">>,
             model_config => ModelConfig,
             tool_policy => #{allowed_tools => all},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-real-provider">>,
    CorrelationId = <<"corr-real-provider">>,
    %% The envelope carries an `llm' field so the actor takes its llm-call path;
    %% the payload's `prompt' is what build_call_opts/2 turns into the user
    %% message. With a real-provider model_config the envelope's `llm' map is not
    %% the opts the worker runs -- the builder replaces it.
    Envelope = #{type => <<"chat">>,
                 payload => #{prompt => <<"say hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => #{}},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    {ok, Result} = soma_actor:get_task_result(ActorPid, TaskId),
    #{kind := reply, text := Content} = Result,
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 5: an actor started with an empty `model_config' still drives an
%% `llm' task to completion through the mock, with the same task result and the
%% same events as in v0.5. The actor is started with an empty `model_config'
%% (so build_call_opts/2 takes its mock branch and returns the envelope's `llm'
%% map unchanged) and sent the same `proposal' mock envelope the v0.5
%% soma_proposal_exec_SUITE uses for an approved `reply' proposal. The test
%% asserts the task result is the normalized `#{kind => reply, text => Text}'
%% proposal and that the by_correlation/2 event set matches the v0.5 mock
%% behaviour: an `actor.*' and an `llm.*' event, `proposal.created' and
%% `proposal.approved', and no `run.started' (a toolless reply runs nothing).
mock_model_config_completes_llm_task_same_result_and_events(_Config) ->
    Store = event_store_pid(),
    %% Empty model_config -> build_call_opts/2 mock branch -> mock LLM path.
    Opts = #{actor_id => <<"actor-mock-config">>,
             model_config => #{},
             tool_policy => #{allowed_tools => [echo]},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    RawProposal = #{kind => reply, text => <<"here is your answer">>},
    Llm = #{directive => proposal, output => RawProposal},
    TaskId = <<"task-mock-config">>,
    CorrelationId = <<"corr-mock-config">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{text => <<"answer me">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => Llm},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    %% Same task result as v0.5: the normalized reply proposal.
    {ok, Result} = soma_actor:get_task_result(ActorPid, TaskId),
    #{kind := reply, text := <<"here is your answer">>} = Result,
    %% Same events as v0.5: the mock proposal trail, no run started.
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    Types = [maps:get(event_type, E, undefined) || E <- Events],
    true = lists:any(fun(T) -> has_prefix(T, <<"actor.">>) end, Types),
    true = lists:any(fun(T) -> has_prefix(T, <<"llm.">>) end, Types),
    true = lists:member(<<"proposal.created">>, Types),
    true = lists:member(<<"proposal.approved">>, Types),
    false = lists:member(<<"run.started">>, Types),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 6: the `api_key' carried in a real-provider `model_config' appears
%% in no event the actor emits for that task. The actor is started with a
%% real-provider `model_config' whose `api_key' is a known sentinel binary and an
%% `llm' task driven to completion through the fixed `response' seam (no socket).
%% After the task completes the test pulls every event under the task's
%% `correlation_id' through by_correlation/2 and asserts the sentinel appears in
%% none of their payloads.
api_key_appears_in_no_emitted_event(_Config) ->
    Store = event_store_pid(),
    Sentinel = <<"sk-secret-sentinel-do-not-leak">>,
    Content = <<"hello from the real provider">>,
    Body = iolist_to_binary(
             json:encode(#{<<"choices">> =>
                               [#{<<"message">> =>
                                      #{<<"content">> => Content}}]})),
    %% Scheme-less host literal -- never dialed (the `response' seam); criterion 7.
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    api_key => Sentinel,
                    response => {200, Body}},
    Opts = #{actor_id => <<"actor-api-key">>,
             model_config => ModelConfig,
             tool_policy => #{allowed_tools => all},
             event_store => Store},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-api-key">>,
    CorrelationId = <<"corr-api-key">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{prompt => <<"say hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => #{}},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    Events = soma_event_store:by_correlation(Store, CorrelationId),
    true = length(Events) > 0,
    %% Scan the WHOLE event map -- every key and value, not just `payload' (actor
    %% events nest nothing under `payload', so the old payload-only scan was inert).
    %% The actor emits ids only -- never the api_key -- so the sentinel appears in
    %% no event field.
    false = lists:any(fun(E) -> term_contains(E, Sentinel) end, Events),
    true = is_process_alive(ActorPid),
    ok.

%% Criterion 5 (the "no rendered reply" half): the `api_key' carried in a
%% real-provider `model_config' appears nowhere in the CLI reply rendered from the
%% task result. The actor is started with a real-provider `model_config' whose
%% `api_key' is a known sentinel binary and an `llm' task is driven to completion
%% through the fixed `response' seam (no socket). The task result is the parsed
%% `reply' proposal (`#{kind => reply, text => Content}'); the CLI reply is built
%% from that result the way `soma_cli_server:handle_ask/2' does
%% (`#{status => completed, outputs => #{reply => Text}}') and rendered with
%% `soma_lisp:render/1'. The result carries the reply text only -- never the
%% api_key -- so the sentinel appears nowhere in the rendered s-expr.
test_rendered_reply_carries_no_api_key(_Config) ->
    Sentinel = <<"sk-secret-sentinel-do-not-leak">>,
    Content = <<"hello from the real provider">>,
    Body = iolist_to_binary(
             json:encode(#{<<"choices">> =>
                               [#{<<"message">> =>
                                      #{<<"content">> => Content}}]})),
    %% Scheme-less host literal -- never dialed (the `response' seam).
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"api.example.test/v1">>,
                    model => <<"deepseek-v4">>,
                    api_key => Sentinel,
                    response => {200, Body}},
    Opts = #{actor_id => <<"actor-rendered-reply">>,
             model_config => ModelConfig,
             tool_policy => #{allowed_tools => all},
             event_store => event_store_pid()},
    {ok, ActorPid} = soma_actor_sup:start_actor(Opts),
    TaskId = <<"task-rendered-reply">>,
    CorrelationId = <<"corr-rendered-reply">>,
    Envelope = #{type => <<"chat">>,
                 payload => #{prompt => <<"say hello">>},
                 task_id => TaskId,
                 correlation_id => CorrelationId,
                 llm => #{}},
    {ok, TaskId} = soma_actor:send(ActorPid, Envelope),
    ok = wait_for_status(ActorPid, TaskId, completed, 100),
    {ok, #{kind := reply, text := Text}} = soma_actor:get_task_result(ActorPid, TaskId),
    %% Build the CLI reply the same way handle_ask/2 does for a `reply' result,
    %% then render it -- the rendered s-expr is what the client receives.
    Result = #{status => completed,
               task_id => TaskId,
               correlation_id => CorrelationId,
               outputs => #{reply => Text}},
    Rendered = iolist_to_binary(soma_lisp:render(Result)),
    nomatch = binary:match(Rendered, Sentinel),
    true = is_process_alive(ActorPid),
    ok.

%% True when the sentinel binary appears anywhere inside Term (a payload map's
%% keys or values, however nested).
term_contains(Term, Sentinel) when is_binary(Term) ->
    binary:match(Term, Sentinel) =/= nomatch;
term_contains(Term, Sentinel) when is_map(Term) ->
    lists:any(fun({K, V}) ->
                      term_contains(K, Sentinel) orelse term_contains(V, Sentinel)
              end, maps:to_list(Term));
term_contains(Term, Sentinel) when is_list(Term) ->
    lists:any(fun(E) -> term_contains(E, Sentinel) end, Term);
term_contains(Term, Sentinel) when is_tuple(Term) ->
    term_contains(tuple_to_list(Term), Sentinel);
term_contains(_Term, _Sentinel) ->
    false.

%% True when binary T starts with binary Prefix.
has_prefix(T, Prefix) when is_binary(T) ->
    case T of
        <<Prefix:(byte_size(Prefix))/binary, _/binary>> -> true;
        _ -> false
    end;
has_prefix(_, _) ->
    false.

%% Polls get_task_status until the task reaches the given status.
wait_for_status(_ActorPid, TaskId, Status, 0) ->
    error({timeout, TaskId, Status});
wait_for_status(ActorPid, TaskId, Status, N) ->
    case maps:get(status, soma_actor:get_task_status(ActorPid, TaskId)) of
        Status ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_status(ActorPid, TaskId, Status, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
