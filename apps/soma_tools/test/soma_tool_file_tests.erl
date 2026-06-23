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

test_file_write_then_read_roundtrips() ->
    Root = make_temp_root(),
    Bytes = <<"bytes written then read back">>,
    Path = <<"roundtrip.txt">>,
    Ctx = #{root => Root},
    {ok, _} = soma_tool_file_write:invoke(#{path => Path, bytes => Bytes}, Ctx),
    ?assertEqual({ok, Bytes}, soma_tool_file_read:invoke(#{path => Path}, Ctx)).

file_write_then_read_roundtrips_test() ->
    test_file_write_then_read_roundtrips().

test_file_dotdot_escape_rejected() ->
    Root = make_temp_root(),
    Ctx = #{root => Root},
    %% Write: a path that climbs out of the root must be rejected and must
    %% not create the file at its escaped destination (a sibling of Root).
    Escaped = filename:join(Root, "../escaped_write.txt"),
    ok = ensure_absent(Escaped),
    ?assertMatch({error, _},
                 soma_tool_file_write:invoke(
                   #{path => <<"../escaped_write.txt">>, bytes => <<"nope">>},
                   Ctx)),
    ?assertNot(filelib:is_regular(Escaped)),
    %% Read: a real file outside the root must not be reachable through `..`.
    Outside = filename:join(Root, "../escaped_read.txt"),
    ok = file:write_file(Outside, <<"secret outside the sandbox">>),
    ?assertMatch({error, _},
                 soma_tool_file_read:invoke(
                   #{path => <<"../escaped_read.txt">>}, Ctx)).

file_dotdot_escape_rejected_test() ->
    test_file_dotdot_escape_rejected().

ensure_absent(Path) ->
    case file:delete(Path) of
        ok -> ok;
        {error, enoent} -> ok;
        Other -> Other
    end.

make_temp_root() ->
    Base = filename:basedir(user_cache, "soma_tool_file_tests"),
    Unique = integer_to_list(erlang:unique_integer([positive])),
    Root = filename:join(Base, Unique),
    ok = filelib:ensure_dir(filename:join(Root, "x")),
    Root.
