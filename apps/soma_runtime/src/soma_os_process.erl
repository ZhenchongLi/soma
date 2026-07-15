%% @doc Bounded teardown for an external process started by a tool-call port.
%% The caller supplies only the OS pid reported by the BEAM port driver; no
%% user-authored command text reaches this module.
-module(soma_os_process).

-export([kill/1]).

kill(undefined) ->
    ok;
kill(OsPid) when is_integer(OsPid) ->
    case os:find_executable("kill") of
        false ->
            ok;
        Kill ->
            Port = open_port(
                     {spawn_executable, Kill},
                     [{args, ["-KILL", integer_to_list(OsPid)]},
                      exit_status, binary, use_stdio, stderr_to_stdout]),
            wait_done(Port)
    end.

wait_done(Port) ->
    receive
        {Port, {exit_status, _}} ->
            ok;
        {Port, {data, _}} ->
            wait_done(Port)
    after 1000 ->
        try erlang:port_close(Port) catch _:_ -> ok end,
        ok
    end.
