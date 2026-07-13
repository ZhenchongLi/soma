%% @doc Reader-level unicode proofs (#205 review): non-ASCII input classes a
%% user's tool/task file will hit must come back as bounded diagnostics or
%% parsed forms — never a scan crash (function_clause / badarg) that takes
%% the caller down with it.
-module(soma_lfe_reader_tests).

-include_lib("eunit/include/eunit.hrl").

%% Valid UTF-8 string content above code point 255 (an em-dash, an accent,
%% Chinese text) parses to the exact UTF-8 binary.
test_non_ascii_string_content_parses() ->
    Source = <<"(tool (description \"Résumé formatter — 大写\"))"/utf8>>,
    {ok, [[tool, [description, Description]]]} =
        soma_lfe_reader:read_forms(Source),
    ?assertEqual(<<"Résumé formatter — 大写"/utf8>>, Description).

non_ascii_string_content_parses_test() ->
    test_non_ascii_string_content_parses().

%% Invalid UTF-8 bytes (a Latin-1-saved file, a stray BOM pair) return a
%% named diagnostic instead of crashing characters_to_list's consumer.
test_invalid_utf8_returns_diagnostic() ->
    Source = <<"(tool (name \"x", 16#ff, 16#fe, "\"))">>,
    ?assertEqual(
        {error, [#{message => <<"source is not valid UTF-8">>, line => 0}]},
        soma_lfe_reader:read_forms(Source)).

invalid_utf8_returns_diagnostic_test() ->
    test_invalid_utf8_returns_diagnostic().

%% A code point above 255 outside a string is an unrecognised character —
%% a diagnostic naming it, not a badarg while rendering the message.
test_non_ascii_outside_string_is_diagnostic() ->
    Source = <<"(tool —)"/utf8>>,
    {error, [#{message := Message, line := 1}]} =
        soma_lfe_reader:read_forms(Source),
    ?assertEqual(<<"unrecognised character: —"/utf8>>, Message).

non_ascii_outside_string_is_diagnostic_test() ->
    test_non_ascii_outside_string_is_diagnostic().

test_parser_cleanup_preserves_reader_results() ->
    ?assertEqual({ok, []}, soma_lfe_reader:read_forms(<<>>)),
    ?assertEqual(
        {ok, [alpha, 42, <<"beta">>]},
        soma_lfe_reader:read_forms(<<"alpha 42 \"beta\"">>)),
    ?assertEqual(
        {error, [#{message => <<"unexpected close parenthesis">>, line => 1}]},
        soma_lfe_reader:read_forms(<<")">>)),
    ?assertEqual(
        {error, [#{message => <<"unclosed parenthesis">>, line => 0}]},
        soma_lfe_reader:read_forms(<<"(alpha">>)).

parser_cleanup_preserves_reader_results_test() ->
    test_parser_cleanup_preserves_reader_results().
