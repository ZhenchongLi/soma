%% @doc CLI.5 command brain. `dispatch/1' takes an argv list, routes the
%% subcommand to the matching `soma_cli:*' thin client, and returns an integer
%% exit code. It parses argv into the same map shape the `soma_cli' functions
%% already take, resolves the socket path, and calls them -- the wire and Lisp
%% rendering stay in `soma_cli'. The `ask' intent is run through
%% `soma_cli_intent:escape/1' so an intent containing `"' or `\\' still emits a
%% valid s-expr the daemon parses, reaching it intact.
-module(soma_cli_main).

-export([dispatch/1, socket/1]).

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
    %% Escape `"' / `\\' in the user intent so the `(ask (intent "..."))' request
    %% `soma_cli:ask/1' renders is a valid s-expr the daemon parses, and the
    %% original string reaches the daemon intact.
    soma_cli:ask(maps:merge(#{intent => soma_cli_intent:escape(Intent),
                              socket => socket(Opts)},
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

%% The socket the subcommand connects to. Both override and fallback go through
%% the shared `soma_cli:resolve_socket/1' so a separately-launched client lands
%% on the exact path `soma_cli:daemon/1' resolves for the same user: a `--socket'
%% override wins, else `$XDG_RUNTIME_DIR/soma.sock', else a per-user
%% `/tmp/soma-<user>.sock'.
socket(Opts) ->
    soma_cli:resolve_socket(Opts).

%% The `detach => true' fragment to merge in when `--detach' was given, else empty.
detach_opt(#{detach := true}) ->
    #{detach => true};
detach_opt(_Opts) ->
    #{}.
