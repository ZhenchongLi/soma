%% @doc Strict production boundary for delegated-task requests. Only bounded,
%% task-local data crosses into coordinator ownership.
-module(soma_delegate_request).

-define(MAX_DEPTH, 64).
-define(MAX_ID_BYTES, 256).
-define(MAX_REQUEST_BYTES, 65536).

-export([normalize/1]).

normalize(Request) when is_map(Request) ->
    case valid_top_level_keys(Request) andalso
         valid_request_id(Request) andalso
         valid_correlation_id(Request) andalso
         valid_field_shapes(Request) andalso
         safe_term(Request) andalso
         encoded_bytes(Request) =< ?MAX_REQUEST_BYTES of
        true ->
            {ok, Request};
        false ->
            invalid_request()
    end;
normalize(_Request) ->
    invalid_request().

valid_top_level_keys(Request) ->
    Allowed =
        [request_id, correlation_id, objective, output_contract,
         capability_scope, resource_handles, artifacts, budgets],
    lists:all(
      fun(Key) -> lists:member(Key, Allowed) end,
      maps:keys(Request)).

valid_request_id(#{request_id := RequestId}) ->
    valid_id(RequestId);
valid_request_id(_Request) ->
    false.

valid_correlation_id(Request) ->
    case maps:find(correlation_id, Request) of
        {ok, CorrelationId} -> valid_id(CorrelationId);
        error -> true
    end.

valid_id(Id) when is_binary(Id),
                  byte_size(Id) > 0,
                  byte_size(Id) =< ?MAX_ID_BYTES ->
    true;
valid_id(_Id) ->
    false.

valid_field_shapes(Request) ->
    valid_optional_map(budgets, Request) andalso
        valid_capability_scope(
          maps:get(capability_scope, Request, #{})) andalso
        valid_resource_handles(
          maps:get(resource_handles, Request, #{})) andalso
        valid_artifacts(maps:get(artifacts, Request, [])).

valid_optional_map(Key, Request) ->
    case maps:find(Key, Request) of
        {ok, Value} -> is_map(Value);
        error -> true
    end.

valid_capability_scope(Scope) when is_map(Scope) ->
    valid_capability_tools(maps:get(tools, Scope, []));
valid_capability_scope(_InvalidScope) ->
    false.

valid_capability_tools(all) ->
    true;
valid_capability_tools(Tools) when is_list(Tools) ->
    lists:all(fun valid_external_name/1, Tools);
valid_capability_tools(_InvalidTools) ->
    false.

valid_external_name(Name) when is_atom(Name) ->
    true;
valid_external_name(Name) when is_binary(Name) ->
    byte_size(Name) > 0;
valid_external_name(Name) when is_list(Name), Name =/= [] ->
    try unicode:characters_to_binary(Name) of
        Binary when is_binary(Binary) -> byte_size(Binary) > 0;
        _InvalidText -> false
    catch
        error:badarg -> false
    end;
valid_external_name(_InvalidName) ->
    false.

valid_resource_handles(Handles) when is_map(Handles) ->
    maps:fold(
      fun(Name, Handle, Valid) ->
              Valid andalso valid_external_name(Name) andalso
                  valid_handle(Handle)
      end,
      true, Handles);
valid_resource_handles(_InvalidHandles) ->
    false.

valid_artifacts(Artifacts) when is_list(Artifacts) ->
    lists:all(fun valid_artifact/1, Artifacts);
valid_artifacts(_InvalidArtifacts) ->
    false.

valid_artifact(Artifact = #{handle := Handle}) when is_map(Artifact) ->
    lists:all(
      fun(Key) ->
              lists:member(Key, [handle, bytes, excerpt, truncated])
      end,
      maps:keys(Artifact)) andalso
        valid_handle(Handle) andalso
        valid_optional_non_neg_integer(bytes, Artifact) andalso
        valid_optional_binary(excerpt, Artifact) andalso
        valid_optional_boolean(truncated, Artifact);
valid_artifact(_InvalidArtifact) ->
    false.

valid_handle(Handle) when is_binary(Handle) ->
    byte_size(Handle) > 0;
valid_handle(_InvalidHandle) ->
    false.

valid_optional_non_neg_integer(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> is_integer(Value) andalso Value >= 0;
        error -> true
    end.

valid_optional_binary(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> is_binary(Value);
        error -> true
    end.

valid_optional_boolean(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> is_boolean(Value);
        error -> true
    end.

safe_term(Term) ->
    safe_term(Term, ?MAX_DEPTH).

safe_term(_Term, 0) ->
    false;
safe_term(Term, _Depth)
  when is_atom(Term); is_binary(Term); is_integer(Term); is_float(Term) ->
    true;
safe_term([], _Depth) ->
    true;
safe_term([_Value | _Remaining] = List, Depth) ->
    safe_list(List, Depth - 1);
safe_term(Map, Depth) when is_map(Map) ->
    maps:fold(
      fun(Key, Value, Safe) ->
              Safe andalso safe_key(Key, Depth - 1) andalso
                  safe_term(Value, Depth - 1)
      end,
      true, Map);
safe_term(Tuple, Depth) when is_tuple(Tuple) ->
    safe_tuple_tag(Tuple) andalso
        safe_tuple(1, tuple_size(Tuple), Tuple, Depth - 1);
safe_term(_ProcessLocalOrUnsupported, _Depth) ->
    false.

safe_list([], _Depth) ->
    true;
safe_list([Value | Remaining], Depth) ->
    safe_term(Value, Depth) andalso safe_list(Remaining, Depth);
safe_list(_ImproperTail, _Depth) ->
    false.

safe_key(Key, Depth) ->
    not forbidden_field_name(Key) andalso safe_term(Key, Depth).

safe_tuple_tag(Tuple) when tuple_size(Tuple) > 0 ->
    not forbidden_field_name(element(1, Tuple));
safe_tuple_tag(_Tuple) ->
    true.

safe_tuple(Index, Size, _Tuple, _Depth) when Index > Size ->
    true;
safe_tuple(Index, Size, Tuple, Depth) ->
    safe_term(element(Index, Tuple), Depth) andalso
        safe_tuple(Index + 1, Size, Tuple, Depth).

forbidden_field_name(Name) ->
    case text_name(Name) of
        {ok, Text} -> forbidden_canonical_name(canonical_name(Text));
        error -> false
    end.

text_name(Name) when is_atom(Name) ->
    {ok, atom_to_binary(Name, utf8)};
text_name(Name) when is_binary(Name) ->
    {ok, Name};
text_name(Name) when is_list(Name) ->
    try unicode:characters_to_binary(Name) of
        Text when is_binary(Text) -> {ok, Text};
        _IncompleteOrInvalid -> error
    catch
        error:badarg -> error
    end;
text_name(_Name) ->
    error.

canonical_name(Text) ->
    list_to_binary(
      [lower_ascii(Byte) || <<Byte>> <= Text,
                            ascii_name_byte(Byte)]).

ascii_name_byte(Byte) ->
    (Byte >= $A andalso Byte =< $Z) orelse
        (Byte >= $a andalso Byte =< $z) orelse
        (Byte >= $0 andalso Byte =< $9).

lower_ascii(Byte) when Byte >= $A, Byte =< $Z ->
    Byte + ($a - $A);
lower_ascii(Byte) ->
    Byte.

forbidden_canonical_name(Name) ->
    lists:member(
      Name,
      [<<"pid">>, <<"workerpid">>, <<"coordinatorpid">>,
       <<"resourcemanagerpid">>, <<"leaseguardpid">>,
       <<"monitorref">>, <<"mref">>, <<"ref">>, <<"reference">>,
       <<"port">>, <<"function">>, <<"callback">>,
       <<"authentication">>, <<"authenticationstate">>, <<"auth">>,
       <<"authorization">>, <<"bearer">>, <<"credentials">>,
       <<"providercredentials">>, <<"apikey">>, <<"secret">>,
       <<"password">>, <<"provider">>, <<"providerconfig">>,
       <<"modelconfig">>, <<"productconversation">>,
       <<"productconversationdata">>, <<"productconversationhistory">>,
       <<"conversationhistory">>, <<"producthistory">>,
       <<"productuser">>, <<"productuserid">>, <<"useridentity">>,
       <<"userid">>, <<"productsession">>, <<"productsessionid">>,
       <<"sessionidentity">>, <<"sessionid">>, <<"rawlease">>,
       <<"rawleases">>, <<"leaserequests">>, <<"leaseguard">>,
       <<"roundsequence">>, <<"roundsnapshot">>, <<"priorsnapshot">>])
        orelse contains_forbidden_fragment(Name).

contains_forbidden_fragment(Name) ->
    lists:any(
      fun(Fragment) -> binary:match(Name, Fragment) =/= nomatch end,
      [<<"workerpid">>, <<"coordinatorpid">>, <<"resourcemanagerpid">>,
       <<"leaseguardpid">>, <<"monitorref">>, <<"authentication">>,
       <<"authorization">>, <<"credential">>, <<"apikey">>,
       <<"secret">>, <<"password">>, <<"bearer">>, <<"provider">>,
       <<"productconversation">>, <<"conversationhistory">>,
       <<"producthistory">>, <<"productuser">>, <<"useridentity">>,
       <<"productsession">>, <<"sessionidentity">>, <<"rawlease">>,
       <<"leaserequests">>, <<"leaseguard">>, <<"roundsequence">>,
       <<"roundsnapshot">>, <<"priorsnapshot">>]) orelse
        raw_lease_name(Name).

raw_lease_name(Name) ->
    binary:match(Name, <<"raw">>) =/= nomatch andalso
        binary:match(Name, <<"lease">>) =/= nomatch.

encoded_bytes(Term) ->
    byte_size(term_to_binary(Term, [deterministic])).

invalid_request() ->
    {error, invalid_delegate_request}.
