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
%% successful read -- not gated on `(status completed)'). `cancel TaskId' resolves
%% the socket and drives `soma_cli:cancel/1', returning its exit code (0 on a
%% successful cancel). A trailing `--detach' after `run File' or `ask Intent'
%% sets `detach => true' in the dispatched args, so the emitted request carries the
%% `(detach)' marker.
-spec dispatch([string()]) -> integer().
dispatch(["run", File | Flags]) ->
    Opts = parse_flags(Flags),
    soma_cli:run(maps:merge(#{file => File, socket => socket(Opts)},
                            detach_opt(Opts)));
dispatch(["ask", Intent | Flags]) ->
    Opts = parse_flags(Flags),
    soma_cli:ask(maps:merge(#{intent => Intent, socket => socket(Opts)},
                            detach_opt(Opts)));
dispatch(["status", TaskId | Flags]) ->
    Opts = parse_flags(Flags),
    soma_cli:status(#{task_id => TaskId, socket => socket(Opts)});
dispatch(["trace", CorrId | Flags]) ->
    Opts = parse_flags(Flags),
    soma_cli:trace(#{correlation_id => CorrId, socket => socket(Opts)});
dispatch(["cancel", TaskId | Flags]) ->
    Opts = parse_flags(Flags),
    soma_cli:cancel(#{task_id => TaskId, socket => socket(Opts)}).

%% Parse the trailing flags after a subcommand's positional: `--detach' (a marker)
%% and `--socket <path>' (the resolver override). Returns an options map.
parse_flags([]) ->
    #{};
parse_flags(["--detach" | Rest]) ->
    (parse_flags(Rest))#{detach => true};
parse_flags(["--socket", Path | Rest]) ->
    (parse_flags(Rest))#{socket => Path}.

%% The socket the subcommand connects to: a `--socket' override wins, else the
%% resolved path.
socket(#{socket := Path}) ->
    Path;
socket(_Opts) ->
    resolve_socket().

%% The `detach => true' fragment to merge in when `--detach' was given, else empty.
detach_opt(#{detach := true}) ->
    #{detach => true};
detach_opt(_Opts) ->
    #{}.

%% Resolve the listener socket path: `$XDG_RUNTIME_DIR/soma.sock' when set. The
%% full per-user fallback and the `--socket' override land in later criteria.
resolve_socket() ->
    case os:getenv("XDG_RUNTIME_DIR") of
        false ->
            "/tmp/soma.sock";
        Dir ->
            filename:join(Dir, "soma.sock")
    end.
