%% @doc Shared validation helpers for the built-in text readers.
-module(soma_tool_text).

-export([required_binary/2, positive_integer/3]).

-spec required_binary(term(), atom()) ->
    {ok, binary()} | {error, term()}.
required_binary(Input, _Field) when not is_map(Input) ->
    {error, {invalid_input, map}};
required_binary(Input, Field) ->
    case maps:find(Field, Input) of
        error ->
            {error, {missing_field, Field}};
        {ok, Value} when is_binary(Value) ->
            {ok, Value};
        {ok, _Value} ->
            {error, {invalid_field_type, Field, binary}}
    end.

-spec positive_integer(term(), atom(), pos_integer()) ->
    {ok, pos_integer()} | {error, term()}.
positive_integer(Input, _Field, _Default) when not is_map(Input) ->
    {error, {invalid_input, map}};
positive_integer(Input, Field, Default) ->
    case maps:find(Field, Input) of
        error ->
            {ok, Default};
        {ok, Value} when is_integer(Value), Value > 0 ->
            {ok, Value};
        {ok, _Value} ->
            {error, {invalid_limit, Field, positive_integer}}
    end.
