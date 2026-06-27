%% @doc CLI.1b thin client. `run/1' resolves a workflow source, sends it to a
%% `soma_cli_server' over a local Unix socket, prints the `(result ...)' reply,
%% and returns an exit code. The client does not parse Lisp -- it ships the
%% workflow source through unchanged; the daemon is the parser.
-module(soma_cli).

-export([run/1, ask/1, daemon/1]).

%% Resolve the workflow source (a file path, or stdin when the path arg is `-'),
%% connect to the resolved socket path with `{packet, 4}', frame + send the source
%% bytes, read the framed `(result ...)' reply, print it to stdout, and return an
%% exit code: 0 when the reply's status sub-form is `completed', non-zero otherwise.
-spec run(map()) -> non_neg_integer().
run(#{file := File, socket := Path}) ->
    Source = read_source(File),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~s~n", [Reply]),
    exit_code(Reply).

%% Build the `(ask (intent "..."))' source from the intent string client-side --
%% the daemon is the only parser -- then drive the same connect / frame+send /
%% read / print / exit-code path as `run/1'. The reply is the framed
%% `(result ...)' s-expr; exit 0 when its status sub-form is `completed'. The mock
%% (or a real provider) lives at the daemon's `model_config'; the client never
%% sends a model.
-spec ask(map()) -> non_neg_integer().
ask(#{intent := Intent, socket := Path}) ->
    Source = ask_source(Intent),
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, Source),
    {ok, Reply} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    io:format("~s~n", [Reply]),
    exit_code(Reply).

%% Wrap the intent string in an `(ask (intent "..."))' s-expr. The intent is a
%% quoted Lisp string, so it is the literal bytes between the quotes.
ask_source(Intent) ->
    iolist_to_binary(["(ask (intent \"", Intent, "\"))"]).

%% Boot the daemon: start the runtime, then a `soma_cli_server' listener on a
%% resolved socket path. A test-supplied `socket' override points both ends at a
%% temp path; absent it, resolve `$XDG_RUNTIME_DIR/soma.sock', else
%% `/tmp/soma-$UID.sock'. Returns `{ok, Path}' -- the listener runs in its own
%% linked process, so the daemon stays up without blocking the caller.
-spec daemon(map()) -> {ok, file:filename_all()}.
daemon(Args) ->
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    Path = socket_path(Args),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    {ok, Path}.

%% Resolve the listener socket path: a `socket' override (a temp path a test
%% points both ends at) wins; otherwise `$XDG_RUNTIME_DIR/soma.sock', else
%% `/tmp/soma-$UID.sock'.
socket_path(#{socket := Path}) ->
    Path;
socket_path(_Args) ->
    case os:getenv("XDG_RUNTIME_DIR") of
        false ->
            "/tmp/soma-" ++ os:getpid() ++ ".sock";
        Dir ->
            filename:join(Dir, "soma.sock")
    end.

%% Resolve the workflow bytes from the path arg: `-' reads stdin (the process
%% group leader) to EOF, any other value reads that file. The bytes are shipped to
%% the daemon unchanged -- the client does not parse the workflow.
read_source("-") ->
    read_stdin([]);
read_source(File) ->
    {ok, Source} = file:read_file(File),
    Source.

%% Read stdin to EOF via the IO protocol on the group leader, accumulating each
%% chunk; return the concatenated bytes as a binary.
read_stdin(Acc) ->
    case io:get_chars(standard_io, "", 65536) of
        eof ->
            iolist_to_binary(lists:reverse(Acc));
        {error, _} = Err ->
            error(Err);
        Data ->
            read_stdin([Data | Acc])
    end.

%% Exit 0 when the rendered reply carries `(status completed)', non-zero
%% otherwise -- the same substring check the CT cases use to read the status.
exit_code(Reply) ->
    case re:run(Reply, "\\(status completed\\)", [{capture, none}]) of
        match -> 0;
        nomatch -> 1
    end.
