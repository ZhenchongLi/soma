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
normalize(
    #{kind := invoke,
      api_version := <<"1">>,
      request_id := RequestId,
      operation := #{kind := steps, steps := Steps}} = Candidate
) when is_binary(RequestId), is_list(Steps) ->
    case valid_steps(Steps) of
        true ->
            Optional = maps:with(
                [scope, deadline_ms, max_output_bytes, correlation_id, artifacts],
                Candidate
            ),
            Required =
                #{kind => invoke,
                  api_version => <<"1">>,
                  request_id => RequestId,
                  operation => #{kind => steps, steps => Steps}},
            {ok, maps:merge(Required, Optional)};
        false ->
            invalid_operation()
    end;
normalize(_Candidate) ->
    invalid_operation().

valid_steps(Steps) ->
    lists:all(fun valid_step/1, Steps).

valid_step(
    #{id := Id,
      tool := Tool,
      args := Args,
      timeout_ms := TimeoutMs} = Step
) when map_size(Step) =:= 4,
       is_atom(Id),
       is_atom(Tool),
       is_map(Args),
       is_integer(TimeoutMs),
       TimeoutMs > 0 ->
    true;
valid_step(#{id := Id, tool := Tool, args := Args} = Step)
        when map_size(Step) =:= 3,
             is_atom(Id),
             is_atom(Tool),
             is_map(Args) ->
    true;
valid_step(_Step) ->
    false.

invalid_operation() ->
    {error, [#{code => invalid_operation,
               message => <<"invoke operation is invalid">>}]}.
