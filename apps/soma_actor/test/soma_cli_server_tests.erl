%% @doc EUnit proofs for the pure parts of `soma_cli_server' (CLI.1 / CLI.1c).
-module(soma_cli_server_tests).

-include_lib("eunit/include/eunit.hrl").

%% Length-prefix framing round-trips. `frame/1' prepends a 4-byte big-endian
%% length to the payload; `unframe/1' splits the prefix back off. The payload on
%% the wire is a Lisp s-expr.
test_frame_unframe_round_trips() ->
    Payload = <<"(run (step s1 echo (args (value \"hi\"))))">>,
    Framed = iolist_to_binary(soma_cli_server:frame(Payload)),
    Len = byte_size(Payload),
    ?assertEqual(<<Len:32/big, Payload/binary>>, Framed),
    ?assertEqual(Payload, soma_cli_server:unframe(Framed)),
    ?assertEqual(Framed,
                 iolist_to_binary(
                   soma_cli_server:frame(soma_cli_server:unframe(Framed)))).

frame_unframe_round_trips_test() ->
    test_frame_unframe_round_trips().

%% CLI.1c: the wire is Lisp only. `soma_cli_server' parses requests with
%% `soma_lfe' and renders replies with `soma_lisp', and calls neither
%% `json:decode' nor `json:encode' anywhere in the module -- the legacy JSON path
%% is gone. A source read proves it.
test_cli_server_source_is_json_free() ->
    Src = cli_server_source(),
    ?assert(binary:match(Src, <<"soma_lfe:compile">>) =/= nomatch),
    ?assert(binary:match(Src, <<"soma_lisp:render">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(Src, <<"json:decode">>)),
    ?assertEqual(nomatch, binary:match(Src, <<"json:encode">>)).

cli_server_source_is_json_free_test() ->
    test_cli_server_source_is_json_free().

cli_server_source() ->
    Path = filename:join([code:lib_dir(soma_actor), "src",
                          "soma_cli_server.erl"]),
    {ok, Src} = file:read_file(Path),
    Src.
