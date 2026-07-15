%% @doc Structural boundary for task-only delegate state. It accepts bounded
%% immutable data and rejects process-local terms plus reserved product,
%% credential, provider, lease, and process-control field namespaces.
-module(soma_delegate_task_data).

-define(MAX_DEPTH, 64).

-export([valid_initial_task/1, valid_snapshot/1, safe_term/1]).

valid_initial_task(TaskSpec) when is_map(TaskSpec) ->
    lists:all(
      fun(Field) -> valid_optional_field(Field, TaskSpec) end,
      [objective, output_contract, checkpoint, context_checkpoint,
       budgets]);
valid_initial_task(_TaskSpec) ->
    false.

valid_snapshot(
  #{task_id := TaskId,
    correlation_id := CorrelationId} = Snapshot)
  when is_binary(TaskId), is_binary(CorrelationId) ->
    lists:all(
      fun(Field) -> valid_optional_field(Field, Snapshot) end,
      [objective, output_contract, context_checkpoint, budgets, usage,
       mutation_ledger, unknown_outcome_ledger]);
valid_snapshot(_Snapshot) ->
    false.

safe_term(Term) ->
    safe_term(Term, ?MAX_DEPTH).

valid_optional_field(Field, Data) ->
    case maps:find(Field, Data) of
        {ok, Value} -> safe_term(Value);
        error -> true
    end.

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
    not reserved_field_name(Key) andalso safe_term(Key, Depth).

safe_tuple_tag(Tuple) when tuple_size(Tuple) > 0 ->
    not reserved_field_name(element(1, Tuple));
safe_tuple_tag(_Tuple) ->
    true.

safe_tuple(Index, Size, _Tuple, _Depth) when Index > Size ->
    true;
safe_tuple(Index, Size, Tuple, Depth) ->
    safe_term(element(Index, Tuple), Depth) andalso
        safe_tuple(Index + 1, Size, Tuple, Depth).

reserved_field_name(Name) ->
    case text_name(Name) of
        {ok, Text} -> reserved_canonical_name(canonical_name(Text));
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

reserved_canonical_name(Name) ->
    lists:member(
      Name,
      [<<"pid">>, <<"workerpid">>, <<"coordinatorpid">>,
       <<"resourcemanagerpid">>, <<"leaseguardpid">>,
       <<"monitorref">>, <<"mref">>, <<"ref">>, <<"port">>,
       <<"function">>, <<"authentication">>,
       <<"authenticationstate">>, <<"auth">>,
       <<"authorization">>, <<"bearer">>, <<"credentials">>,
       <<"apikey">>, <<"secret">>, <<"password">>,
       <<"providerconfig">>, <<"modelconfig">>,
       <<"productconversation">>, <<"productconversationdata">>,
       <<"conversationhistory">>, <<"producthistory">>,
       <<"productuser">>, <<"productuserid">>, <<"useridentity">>,
       <<"userid">>, <<"productsession">>, <<"productsessionid">>,
       <<"sessionidentity">>, <<"sessionid">>, <<"rawlease">>,
       <<"rawleases">>, <<"leaseguard">>, <<"roundsnapshot">>,
       <<"priorsnapshot">>]) orelse
        contains_reserved_fragment(Name) orelse raw_lease_name(Name).

contains_reserved_fragment(Name) ->
    lists:any(
      fun(Fragment) -> binary:match(Name, Fragment) =/= nomatch end,
      [<<"workerpid">>, <<"coordinatorpid">>,
       <<"resourcemanagerpid">>, <<"leaseguardpid">>,
       <<"monitorref">>, <<"authentication">>, <<"authorization">>,
       <<"apikey">>, <<"providerconfig">>, <<"modelconfig">>,
       <<"productconversation">>, <<"conversationhistory">>,
       <<"producthistory">>, <<"productuser">>, <<"useridentity">>,
       <<"productsession">>, <<"sessionidentity">>, <<"rawlease">>,
       <<"leaseguard">>, <<"roundsnapshot">>, <<"priorsnapshot">>]).

raw_lease_name(Name) ->
    binary:match(Name, <<"raw">>) =/= nomatch andalso
        binary:match(Name, <<"lease">>) =/= nomatch.
