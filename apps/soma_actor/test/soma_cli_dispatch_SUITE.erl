-module(soma_cli_dispatch_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_dispatch_run_file_completed_exit_zero/1]).

all() ->
    [test_dispatch_run_file_completed_exit_zero].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    %% The ask path drives the decision loop through an actor under
    %% soma_actor_sup; keep the sup up so every dispatch case is self-contained
    %% even though criterion 1 only exercises `run'. Tolerate an already-running
    %% sup.
    Sup = case soma_actor_sup:start_link() of
              {ok, Pid} -> Pid;
              {error, {already_started, Pid}} -> Pid
          end,
    %% Point the resolver at a unique per-run XDG_RUNTIME_DIR so a separately
    %% resolved client and the server we boot land on the same socket without a
    %% `--socket' override. The dir name is uniquified by os:getpid() (stable
    %% within a BEAM run, distinct across runs -- see the cross-BEAM path
    %% collision note) plus a per-call unique integer; we restore the prior env
    %% in teardown.
    PrevXdg = os:getenv("XDG_RUNTIME_DIR"),
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    XdgDir = filename:join(Tmp,
                           "soma_cli_dispatch_" ++ os:getpid() ++ "_"
                           ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(XdgDir, "x")),
    Path = filename:join(XdgDir, "soma.sock"),
    _ = file:delete(Path),
    os:putenv("XDG_RUNTIME_DIR", XdgDir),
    [{started_apps, Started}, {actor_sup, Sup},
     {prev_xdg, PrevXdg}, {xdg_dir, XdgDir}, {socket_path, Path} | Config].

end_per_testcase(_Case, Config) ->
    case ?config(prev_xdg, Config) of
        false -> os:unsetenv("XDG_RUNTIME_DIR");
        Prev -> os:putenv("XDG_RUNTIME_DIR", Prev)
    end,
    _ = file:delete(?config(socket_path, Config)),
    ok.

%% Criterion 1 (CLI.5): `soma_cli_main:dispatch(["run", File])' runs the workflow
%% file through the daemon on the resolved socket, prints the `(result ...)' reply
%% to stdout, and returns the same exit code as `soma_cli:run/1' -- 0 only when
%% the reply carries `(status completed)'. The full chain runs against a real
%% `soma_cli_server' on a unique per-run socket; the dispatcher resolves that
%% socket itself (no `--socket' override). Process survival is asserted: after the
%% dispatch returns, the same server still serves a fresh client request.
test_dispatch_run_file_completed_exit_zero(Config) ->
    Path = ?config(socket_path, Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    File = filename:join(?config(priv_dir, Config), "dispatch_echo.lfe"),
    ok = file:write_file(File, <<"(run (step s1 echo (args (value \"hi\"))))">>),

    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["run", File]),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),

    %% The printed reply is the completed echo `(result ...)' s-expr, proving the
    %% dispatcher resolved the socket and drove the full run through the daemon.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    %% A completed run returns exit code 0 (mirroring `soma_cli:run/1').
    0 = Exit,

    %% Process survival: the server still serves a subsequent request after the
    %% dispatch returned.
    {ok, Sock} = gen_tcp:connect({local, Path}, 0,
                                 [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(Sock, <<"(run (step s2 echo (args (value \"again\"))))">>),
    {ok, Reply2} = gen_tcp:recv(Sock, 0, 60000),
    ok = gen_tcp:close(Sock),
    match = re:run(Reply2, "\\(status completed\\)", [{capture, none}]).
