%% @doc Shared validation and output-bound helpers for the built-in text
%% readers.
-module(soma_tool_text).

-export([required_binary/2, positive_integer/3,
         prefix_lines/2, cap_prefix/1, fits_output/2]).

-define(TEXT_OUTPUT_LIMIT, 65_536).

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

-spec prefix_lines(binary(), pos_integer()) -> {binary(), boolean()}.
prefix_lines(Text, Lines) ->
    case line_boundary(Text, Lines, 0) of
        eof ->
            {Text, false};
        Boundary when Boundary =:= byte_size(Text) ->
            {Text, false};
        Boundary ->
            <<Prefix:Boundary/binary, _/binary>> = Text,
            {Prefix, true}
    end.

line_boundary(_Text, 0, Offset) ->
    Offset;
line_boundary(<<>>, _Lines, _Offset) ->
    eof;
line_boundary(Text, Lines, Offset) ->
    case binary:match(Text, <<"\n">>) of
        {NewlineAt, 1} ->
            ChunkSize = NewlineAt + 1,
            <<_Chunk:ChunkSize/binary, Rest/binary>> = Text,
            line_boundary(Rest, Lines - 1, Offset + ChunkSize);
        nomatch ->
            eof
    end.

-spec cap_prefix(binary()) -> {binary(), boolean()}.
cap_prefix(Text) ->
    case fits_output(0, Text) of
        true ->
            {Text, false};
        false ->
            <<Prefix:?TEXT_OUTPUT_LIMIT/binary, _/binary>> = Text,
            {Prefix, true}
    end.

-spec fits_output(non_neg_integer(), binary()) -> boolean().
fits_output(OutputBytes, Chunk) ->
    OutputBytes + byte_size(Chunk) =< ?TEXT_OUTPUT_LIMIT.
