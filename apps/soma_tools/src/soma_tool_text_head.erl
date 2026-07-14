%% @doc The text_head tool: returns the leading portion of binary text.
%% Effect is reader.
-module(soma_tool_text_head).

-behaviour(soma_tool).

-export([describe/0, manifest/0, invoke/2]).

-define(DEFAULT_LINES, 10).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => text_head,
      effect => reader,
      idempotent => true,
      timeout_ms => 1000}.

-spec manifest() -> map().
manifest() ->
    (describe())#{adapter => erlang_module,
                  module => ?MODULE}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
invoke(Input, _Ctx) ->
    case validate_input(Input) of
        {ok, Text, Lines} ->
            {LinePrefix, LinesTruncated} =
                soma_tool_text:prefix_lines(Text, Lines),
            {Prefix, BytesTruncated} = soma_tool_text:cap_prefix(LinePrefix),
            {ok, #{text => Prefix,
                   truncated => LinesTruncated orelse BytesTruncated}};
        {error, _Reason} = Error ->
            Error
    end.

validate_input(Input) ->
    case soma_tool_text:required_binary(Input, text) of
        {ok, Text} ->
            validate_lines(Input, Text);
        {error, _Reason} = Error ->
            Error
    end.

validate_lines(Input, Text) ->
    case soma_tool_text:positive_integer(Input, lines, ?DEFAULT_LINES) of
        {ok, Lines} ->
            {ok, Text, Lines};
        {error, _Reason} = Error ->
            Error
    end.
