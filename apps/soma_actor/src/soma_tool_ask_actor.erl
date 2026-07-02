%% @doc Actor-owned ask_actor tool manifest.
-module(soma_tool_ask_actor).

-behaviour(soma_tool).

-export([describe/0, manifest/0, invoke/2]).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => ask_actor,
      effect => state,
      idempotent => false,
      timeout_ms => 60000}.

-spec manifest() -> map().
manifest() ->
    (describe())#{adapter => erlang_module,
                  module => ?MODULE,
                  description =>
                      <<"Ask a named Soma actor and return its task result.">>}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
invoke(Input, Ctx) ->
    case normalize_input(Input) of
        {ok, StableName, Envelope} ->
            case soma_actor_registry:lookup(StableName) of
                {ok, ActorPid} ->
                    ask_actor(ActorPid, with_parent_correlation(Envelope, Ctx));
                {error, Reason} ->
                    {error, {ask_actor_lookup_failed, Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

normalize_input(#{target := StableName, envelope := Envelope})
  when is_binary(StableName), is_map(Envelope) ->
    {ok, StableName, Envelope};
normalize_input(#{target := StableName}) when not is_binary(StableName) ->
    {error, {invalid_ask_actor_input, invalid_target}};
normalize_input(#{envelope := Envelope}) when not is_map(Envelope) ->
    {error, {invalid_ask_actor_input, invalid_envelope}};
normalize_input(Input) when is_map(Input) ->
    case maps:is_key(target, Input) of
        false -> {error, {invalid_ask_actor_input, missing_target}};
        true -> {error, {invalid_ask_actor_input, missing_envelope}}
    end;
normalize_input(_Input) ->
    {error, {invalid_ask_actor_input, non_map}}.

with_parent_correlation(Envelope, Ctx) ->
    case maps:get(correlation_id, Ctx, undefined) of
        undefined -> Envelope;
        CorrelationId -> Envelope#{correlation_id => CorrelationId}
    end.

ask_actor(ActorPid, Envelope) ->
    case soma_actor:ask(ActorPid, Envelope, ask_timeout_ms()) of
        {ok, Result} ->
            {ok, Result};
        {error, Reason} ->
            {error, Reason};
        timeout ->
            {error, timeout};
        Reply ->
            {ok, Reply}
    end.

ask_timeout_ms() ->
    maps:get(timeout_ms, describe()).
