%% @doc Pure validation boundary for runtime service invocation envelopes.
-module(soma_service_envelope).

-export([normalize/1]).

-type envelope() :: map().
-type diagnostic() :: map().

-define(ALLOWED_FIELDS,
        [kind, api_version, request_id, operation, scope, deadline_ms,
         max_output_bytes, correlation_id, artifacts]).

-spec normalize(term()) -> {ok, envelope()} | {error, [diagnostic()]}.
normalize(#{kind := invoke} = Candidate) ->
    normalize_api_version(Candidate);
normalize(_Candidate) ->
    invalid_operation().

normalize_api_version(Candidate) ->
    case maps:find(api_version, Candidate) of
        error ->
            fixed_error(
                missing_api_version,
                <<"invoke api version is required">>
            );
        {ok, <<"1">>} ->
            normalize_request_id(Candidate);
        {ok, _Unsupported} ->
            fixed_error(
                unsupported_api_version,
                <<"invoke api version is unsupported">>
            )
    end.

normalize_request_id(Candidate) ->
    case maps:find(request_id, Candidate) of
        error ->
            fixed_error(
                missing_request_id,
                <<"invoke request id is required">>
            );
        {ok, RequestId} when is_binary(RequestId) ->
            normalize_allowed_fields(Candidate, RequestId);
        {ok, _Invalid} ->
            fixed_error(
                invalid_request_id,
                <<"invoke request id is invalid">>
            )
    end.

normalize_allowed_fields(Candidate, RequestId) ->
    case map_size(maps:without(?ALLOWED_FIELDS, Candidate)) of
        0 ->
            normalize_operation(Candidate, RequestId);
        _UnknownFields ->
            fixed_error(unknown_field, <<"invoke field is unknown">>)
    end.

normalize_operation(Candidate, RequestId) ->
    case maps:find(operation, Candidate) of
        {ok, Operation} ->
            case normalize_operation_value(Operation, RequestId) of
                {ok, CanonicalOperation} ->
                    normalize_optional_fields(
                        Candidate,
                        RequestId,
                        CanonicalOperation
                    );
                {error, _Diags} = Error ->
                    Error
            end;
        error ->
            invalid_operation()
    end.

normalize_operation_value(
    #{kind := tool, step := Step} = Operation,
    RequestId
) when map_size(Operation) =:= 2 ->
    case Step of
        #{id := RequestId, tool := Tool, args := Args}
                when map_size(Step) =:= 3,
                     is_atom(Tool) ->
            case valid_canonical_args(Args) of
                true ->
                    {ok,
                     #{kind => tool,
                       step =>
                           #{id => RequestId, tool => Tool, args => Args}}};
                false ->
                    invalid_operation()
            end;
        _InvalidStep ->
            invalid_operation()
    end;
normalize_operation_value(
    #{kind := steps, steps := Steps} = Operation,
    _RequestId
) when map_size(Operation) =:= 2, is_list(Steps) ->
    case valid_steps(Steps) of
        true -> {ok, #{kind => steps, steps => Steps}};
        false -> invalid_operation()
    end;
normalize_operation_value(_Operation, _RequestId) ->
    invalid_operation().

normalize_optional_fields(Candidate, RequestId, Operation) ->
    case valid_budgets(Candidate) of
        false ->
            fixed_error(invalid_budget, <<"invoke budget is invalid">>);
        true ->
            normalize_scope(Candidate, RequestId, Operation)
    end.

normalize_scope(Candidate, RequestId, Operation) ->
    case valid_scope(Candidate) of
        false ->
            fixed_error(
                scope_entry_too_large,
                <<"invoke scope entry is too large">>
            );
        true ->
            normalize_artifacts(Candidate, RequestId, Operation)
    end.

normalize_artifacts(Candidate, RequestId, Operation) ->
    case valid_artifacts(Candidate) of
        false ->
            fixed_error(
                invalid_artifacts,
                <<"invoke artifacts are invalid">>
            );
        true ->
            normalize_correlation_id(Candidate, RequestId, Operation)
    end.

normalize_correlation_id(Candidate, RequestId, Operation) ->
    case valid_correlation_id(Candidate) of
        false ->
            fixed_error(
                invalid_correlation_id,
                <<"invoke correlation id is invalid">>
            );
        true ->
            Optional = maps:with(
                [scope, deadline_ms, max_output_bytes,
                 correlation_id, artifacts],
                Candidate
            ),
            Required =
                #{kind => invoke,
                  api_version => <<"1">>,
                  request_id => RequestId,
                  operation => Operation},
            {ok, maps:merge(Required, Optional)}
    end.

valid_budgets(Candidate) ->
    valid_positive_optional(deadline_ms, Candidate) andalso
        valid_positive_optional(max_output_bytes, Candidate).

valid_positive_optional(Key, Candidate) ->
    case maps:find(Key, Candidate) of
        error -> true;
        {ok, Value} when is_integer(Value), Value > 0 -> true;
        {ok, _Invalid} -> false
    end.

valid_scope(Candidate) ->
    case maps:find(scope, Candidate) of
        error ->
            true;
        {ok, Scope} when is_list(Scope) ->
            lists:all(fun valid_scope_entry/1, Scope);
        {ok, _Invalid} ->
            false
    end.

valid_scope_entry(Entry) when is_binary(Entry) ->
    byte_size(Entry) =< 255;
valid_scope_entry(_Entry) ->
    false.

valid_artifacts(Candidate) ->
    case maps:find(artifacts, Candidate) of
        error ->
            true;
        {ok, Artifacts} when is_list(Artifacts) ->
            lists:all(fun is_binary/1, Artifacts);
        {ok, _Invalid} ->
            false
    end.

valid_correlation_id(Candidate) ->
    case maps:find(correlation_id, Candidate) of
        error -> true;
        {ok, CorrelationId} when is_binary(CorrelationId) -> true;
        {ok, _Invalid} -> false
    end.

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
       is_integer(TimeoutMs),
       TimeoutMs > 0 ->
    valid_canonical_args(Args);
valid_step(#{id := Id, tool := Tool, args := Args} = Step)
        when map_size(Step) =:= 3,
             is_atom(Id),
             is_atom(Tool) ->
    valid_canonical_args(Args);
valid_step(_Step) ->
    false.

valid_canonical_args(#{from_step := _Reference} = Args) ->
    map_size(Args) =:= 1;
valid_canonical_args(Args) ->
    is_map(Args).

invalid_operation() ->
    fixed_error(invalid_operation, <<"invoke operation is invalid">>).

fixed_error(Code, Message) ->
    {error, [#{code => Code, message => Message}]}.
