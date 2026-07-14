%% @doc The text_grep tool: returns source lines whose bodies match a regular
%% expression. Effect is reader.
-module(soma_tool_text_grep).

-behaviour(soma_tool).

-export([describe/0, manifest/0, invoke/2]).

-spec describe() -> soma_tool:spec().
describe() ->
    #{name => text_grep,
      effect => reader,
      idempotent => true,
      timeout_ms => 1000}.

-spec manifest() -> map().
manifest() ->
    (describe())#{adapter => erlang_module,
                  module => ?MODULE}.

-spec invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()}.
invoke(#{text := Text, pattern := Pattern}, _Ctx) ->
    {ok, CompiledPattern} = re:compile(Pattern),
    {MatchingLines, MatchCount} = matching_lines(Text, CompiledPattern, [], 0),
    {ok, #{text => iolist_to_binary(lists:reverse(MatchingLines)),
           match_count => MatchCount,
           truncated => false}}.

matching_lines(<<>>, _CompiledPattern, Acc, MatchCount) ->
    {Acc, MatchCount};
matching_lines(Text, CompiledPattern, Acc, MatchCount) ->
    {LineBody, ReturnedLine, Rest} = next_line(Text),
    case re:run(LineBody, CompiledPattern, [{capture, none}]) of
        match ->
            matching_lines(Rest, CompiledPattern,
                           [ReturnedLine | Acc], MatchCount + 1);
        nomatch ->
            matching_lines(Rest, CompiledPattern, Acc, MatchCount)
    end.

next_line(Text) ->
    case binary:match(Text, <<"\n">>) of
        {NewlineAt, 1} ->
            LineSize = NewlineAt + 1,
            <<ReturnedLine:LineSize/binary, Rest/binary>> = Text,
            <<LineBody:NewlineAt/binary, "\n">> = ReturnedLine,
            {LineBody, ReturnedLine, Rest};
        nomatch ->
            {Text, Text, <<>>}
    end.
