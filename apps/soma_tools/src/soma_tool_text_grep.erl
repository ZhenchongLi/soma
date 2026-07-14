%% @doc The text_grep tool: returns source lines whose bodies match a regular
%% expression. Effect is reader.
-module(soma_tool_text_grep).

-behaviour(soma_tool).

-export([describe/0, manifest/0, invoke/2]).

-define(DEFAULT_MAX_MATCHES, 100).
-define(REGEX_DIAGNOSTIC_LIMIT, 128).

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
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
invoke(Input, _Ctx) ->
    case validate_input(Input) of
        {ok, Text, Pattern, _MaxMatches} ->
            compile_and_grep(Text, Pattern);
        {error, _Reason} = Error ->
            Error
    end.

validate_input(Input) ->
    case soma_tool_text:required_binary(Input, text) of
        {ok, Text} ->
            validate_pattern(Input, Text);
        {error, _Reason} = Error ->
            Error
    end.

validate_pattern(Input, Text) ->
    case soma_tool_text:required_binary(Input, pattern) of
        {ok, Pattern} ->
            validate_max_matches(Input, Text, Pattern);
        {error, _Reason} = Error ->
            Error
    end.

validate_max_matches(Input, Text, Pattern) ->
    case soma_tool_text:positive_integer(Input, max_matches,
                                         ?DEFAULT_MAX_MATCHES) of
        {ok, MaxMatches} ->
            {ok, Text, Pattern, MaxMatches};
        {error, _Reason} = Error ->
            Error
    end.

compile_and_grep(Text, Pattern) ->
    case re:compile(Pattern) of
        {ok, CompiledPattern} ->
            grep(Text, CompiledPattern);
        {error, {Diagnostic, Offset}} ->
            {error, {invalid_pattern,
                     #{offset => Offset,
                       diagnostic => bounded_diagnostic(Diagnostic)}}}
    end.

grep(Text, CompiledPattern) ->
    {MatchingLines, MatchCount} = matching_lines(Text, CompiledPattern, [], 0),
    {ok, #{text => iolist_to_binary(lists:reverse(MatchingLines)),
           match_count => MatchCount,
           truncated => false}}.

bounded_diagnostic(Diagnostic) ->
    Binary = unicode:characters_to_binary(Diagnostic),
    case byte_size(Binary) =< ?REGEX_DIAGNOSTIC_LIMIT of
        true ->
            Binary;
        false ->
            binary:part(Binary, 0, ?REGEX_DIAGNOSTIC_LIMIT)
    end.

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
