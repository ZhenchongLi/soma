-module(soma_cli_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_run_echo_file_prints_result_exit_zero/1]).
-export([test_run_failed_workflow_exit_nonzero/1]).

all() ->
    [test_run_echo_file_prints_result_exit_zero,
     test_run_failed_workflow_exit_nonzero].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    ok.

%% Criterion 8 (CLI.1b): `soma_cli:run/1', pointed at a server on a temp socket,
%% reads a one-step echo `.lfe' file, prints the `(result ...)' reply, and returns
%% exit code 0. The client reads the file's s-expr, connects to the temp socket
%% served by a real `soma_cli_server', frames + sends the bytes, reads the framed
%% `(result ...)' reply, prints it, and returns 0 when the reply's status sub-form
%% is `completed'.
test_run_echo_file_prints_result_exit_zero(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    File = filename:join(?config(priv_dir, Config), "echo_flow.lfe"),
    ok = file:write_file(File, <<"(run (step s1 echo (args (value \"hi\"))))">>),
    ct:capture_start(),
    Exit = soma_cli:run(#{file => File, socket => Path}),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),
    %% The printed reply must be the `(result ...)' s-expr whose status sub-form is
    %% `completed' and whose outputs carry s1's echo value.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Printed, "\\(s1 \\(value \"hi\"\\)\\)", [{capture, none}]),
    %% A completed run returns exit code 0.
    0 = Exit.

%% Criterion 9 (CLI.1b): `soma_cli:run/1' returns a non-zero exit code when the
%% workflow's run does not reach `completed'. The client reads a one-step `.lfe'
%% file whose only step uses the `fail' tool, connects to the temp socket served
%% by a real `soma_cli_server', frames + sends the bytes, and reads the framed
%% `(result ...)' reply whose status sub-form is not `completed'. The behavior
%% under test is the exit code: a non-completed run returns non-zero.
test_run_failed_workflow_exit_nonzero(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    File = filename:join(?config(priv_dir, Config), "fail_flow.lfe"),
    ok = file:write_file(File, <<"(run (step s1 fail (args (mode error))))">>),
    ct:capture_start(),
    Exit = soma_cli:run(#{file => File, socket => Path}),
    ct:capture_stop(),
    Printed = iolist_to_binary(ct:capture_get()),
    %% The printed reply is a `(result ...)' s-expr whose status is not `completed'.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    nomatch = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    %% A run that does not reach `completed' returns a non-zero exit code.
    true = (Exit =/= 0).

%% AF_UNIX socket paths are bounded by sun_path (~104 bytes on macOS), so the long
%% CT priv_dir cannot hold a bindable socket. Use a short unique path under the
%% system temp dir; os:getpid() makes it unique across BEAM runs (see
%% soma_cli_server_SUITE for the full rationale), and the pre-delete clears any
%% leftover at the unique path.
socket_path(_Config) ->
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Name = "soma_cli_c_" ++ os:getpid() ++ "_"
           ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock",
    Path = filename:join(Tmp, Name),
    _ = file:delete(Path),
    Path.
