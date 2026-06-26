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

all() ->
    [real_provider_actor_completes_llm_task_through_openai_no_socket,
     mock_model_config_completes_llm_task_same_result_and_events].

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
    ModelConfig = #{provider => openai_compat,
                    base_url => <<"https://api.example.test/v1">>,
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
