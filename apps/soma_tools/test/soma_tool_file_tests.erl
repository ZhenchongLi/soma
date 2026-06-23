-module(soma_tool_file_tests).

-include_lib("eunit/include/eunit.hrl").

test_file_read_returns_bytes() ->
    Root = make_temp_root(),
    Bytes = <<"the bytes under the sandbox root">>,
    ok = file:write_file(filename:join(Root, "note.txt"), Bytes),
    Input = #{path => <<"note.txt">>},
    Ctx = #{root => Root},
    ?assertEqual({ok, Bytes}, soma_tool_file_read:invoke(Input, Ctx)).

file_read_returns_bytes_test() ->
    test_file_read_returns_bytes().

make_temp_root() ->
    Base = filename:basedir(user_cache, "soma_tool_file_tests"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Root = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Root, "x")),
    Root.
