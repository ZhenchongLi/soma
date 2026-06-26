%% @doc EUnit proofs for the pure parts of `soma_cli_server' (CLI.1).
-module(soma_cli_server_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion 1: term->JSON encoding of a map with atom, binary, number, and list
%% values produces the matching JSON object -- atoms and binaries become
%% strings, numbers stay numbers, lists become arrays, maps become objects.
test_encode_map_atoms_binaries_numbers_lists() ->
    Term = #{status => completed,
             name => <<"echo">>,
             count => 3,
             items => [1, two, <<"three">>]},
    Json = soma_cli_server:encode_response(Term),
    Decoded = json:decode(iolist_to_binary(Json)),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Decoded)),
    ?assertEqual(<<"echo">>, maps:get(<<"name">>, Decoded)),
    ?assertEqual(3, maps:get(<<"count">>, Decoded)),
    ?assertEqual([1, <<"two">>, <<"three">>], maps:get(<<"items">>, Decoded)).

encode_map_atoms_binaries_numbers_lists_test() ->
    test_encode_map_atoms_binaries_numbers_lists().

%% Criterion 2: term->JSON encoding of the reason tuple `{budget_exceeded,
%% max_steps}' produces `{"tag":"budget_exceeded","detail":["max_steps"]}' --
%% so a caller switches on `tag' without parsing a string.
test_encode_reason_tuple_to_tag_detail() ->
    Json = soma_cli_server:encode_response({budget_exceeded, max_steps}),
    Decoded = json:decode(iolist_to_binary(Json)),
    ?assertEqual(<<"budget_exceeded">>, maps:get(<<"tag">>, Decoded)),
    ?assertEqual([<<"max_steps">>], maps:get(<<"detail">>, Decoded)).

encode_reason_tuple_to_tag_detail_test() ->
    test_encode_reason_tuple_to_tag_detail().
