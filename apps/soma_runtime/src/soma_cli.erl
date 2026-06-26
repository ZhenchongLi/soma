%% @doc CLI.1b thin client. `run/1' resolves a workflow source, sends it to a
%% `soma_cli_server' over a local Unix socket, prints the `(result ...)' reply,
%% and returns an exit code. The client does not parse Lisp -- it ships the
%% workflow source through unchanged; the daemon is the parser.
-module(soma_cli).

-export([run/1]).

%% Resolve the workflow source (a file path), connect to the resolved socket path
%% with `{packet, 4}', frame + send the source bytes, read the framed
%% `(result ...)' reply, print it to stdout, and return an exit code: 0 when the
%% reply's status sub-form is `completed', non-zero otherwise.
-spec run(map()) -> non_neg_integer().
run(#{file := File, socket := Path}) ->
    {ok, Source} = file:read_file(File),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~s~n", [Reply]),
    exit_code(Reply).

%% Exit 0 when the rendered reply carries `(status completed)', non-zero
%% otherwise -- the same substring check the CT cases use to read the status.
exit_code(Reply) ->
    case re:run(Reply, "\\(status completed\\)", [{capture, none}]) of
        match -> 0;
        nomatch -> 1
    end.
