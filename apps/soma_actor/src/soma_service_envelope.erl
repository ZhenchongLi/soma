%% @doc Pure validation boundary for runtime service invocation envelopes.
-module(soma_service_envelope).

-export([normalize/1]).

-type envelope() :: map().
-type diagnostic() :: map().

-spec normalize(term()) -> {ok, envelope()} | {error, [diagnostic()]}.
normalize(
    #{kind := invoke,
      api_version := <<"1">>,
      request_id := RequestId,
      operation :=
          #{kind := tool,
            step := #{id := RequestId, tool := Tool, args := Args}}} = Candidate
) when is_binary(RequestId), is_atom(Tool), is_map(Args) ->
    Optional = maps:with(
        [scope, deadline_ms, max_output_bytes, correlation_id, artifacts],
        Candidate
    ),
    Step = #{id => RequestId, tool => Tool, args => Args},
    Required =
        #{kind => invoke,
          api_version => <<"1">>,
          request_id => RequestId,
          operation => #{kind => tool, step => Step}},
    {ok, maps:merge(Required, Optional)};
normalize(_Candidate) ->
    {error, [#{code => invalid_operation,
               message => <<"invoke operation is invalid">>}]}.
