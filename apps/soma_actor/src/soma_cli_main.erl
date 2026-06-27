%% @doc CLI.5 command brain. `dispatch/1' takes an argv list, routes the
%% subcommand to the matching `soma_cli:*' thin client, and returns an integer
%% exit code. It parses argv into the same map shape the `soma_cli' functions
%% already take, resolves the socket path, and calls them -- the wire and Lisp
%% rendering stay in `soma_cli'. This slice implements only `run File'
%% (criterion 1); the other subcommands, flags, the shared resolver, and the
%% intent escaper arrive in later cycles.
-module(soma_cli_main).

-export([dispatch/1]).

%% `run File' resolves the socket and drives `soma_cli:run/1', returning its exit
%% code (0 only when the reply carries `(status completed)'). `ask Intent' resolves
%% the socket and drives `soma_cli:ask/1', returning its exit code. `status TaskId'
%% resolves the socket and drives `soma_cli:status/1', returning its exit code (0 on
%% a successful read -- not gated on `(status completed)'). `trace CorrId' resolves
%% the socket and drives `soma_cli:trace/1', returning its exit code (0 on a
%% successful read -- not gated on `(status completed)').
-spec dispatch([string()]) -> integer().
dispatch(["run", File]) ->
    soma_cli:run(#{file => File, socket => resolve_socket()});
dispatch(["ask", Intent]) ->
    soma_cli:ask(#{intent => Intent, socket => resolve_socket()});
dispatch(["status", TaskId]) ->
    soma_cli:status(#{task_id => TaskId, socket => resolve_socket()});
dispatch(["trace", CorrId]) ->
    soma_cli:trace(#{correlation_id => CorrId, socket => resolve_socket()}).

%% Resolve the listener socket path: `$XDG_RUNTIME_DIR/soma.sock' when set. The
%% full per-user fallback and the `--socket' override land in later criteria.
resolve_socket() ->
    case os:getenv("XDG_RUNTIME_DIR") of
        false ->
            "/tmp/soma.sock";
        Dir ->
            filename:join(Dir, "soma.sock")
    end.
