-module(soma_cli_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_run_echo_file_prints_result_exit_zero/1]).
-export([test_run_failed_workflow_exit_nonzero/1]).
-export([test_run_reads_workflow_from_stdin_dash/1]).

all() ->
    [test_run_echo_file_prints_result_exit_zero,
     test_run_failed_workflow_exit_nonzero,
     test_run_reads_workflow_from_stdin_dash].

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

%% Criterion 10 (CLI.1b): `soma_cli:run/1' reads the workflow from stdin when the
%% path arg is `-'. The workflow bytes are fed on a redirected stdin (the group
%% leader of the process that calls `run/1'); the client must read those bytes,
%% not a file, send them through the same server chain as a file run, print the
%% `(result ...)' reply, and return exit 0 for the completed echo run. A fake IO
%% server stands in for stdin: it answers the IO protocol with the workflow bytes,
%% then EOF, so the byte source under test is the redirected stdin -- not a file.
test_run_reads_workflow_from_stdin_dash(Config) ->
    Path = socket_path(Config),
    {ok, _Server} = soma_cli_server:start_link(#{socket => Path}),
    Workflow = <<"(run (step s1 echo (args (value \"hi\"))))">>,
    Parent = self(),
    %% A fake IO server stands in for the child's group leader: it feeds `Workflow'
    %% on `get_chars' (stdin) and records `put_chars' (stdout). Running `run/1' with
    %% the path arg `-' must therefore read the workflow from this stdin, not a file.
    IO = stdin_io_server(Workflow),
    Child = spawn(fun() ->
        group_leader(IO, self()),
        Exit = soma_cli:run(#{file => "-", socket => Path}),
        Parent ! {result, Exit}
    end),
    Exit =
        receive
            {result, E} -> E
        after 60000 ->
            exit(Child, kill),
            ct:fail(stdin_run_timed_out)
        end,
    Printed = iolist_to_binary(io_server_output(IO)),
    %% The reply printed must be the completed echo `(result ...)' s-expr, proving
    %% the workflow read from stdin reached the server and ran.
    match = re:run(Printed, "^\\(result ", [{capture, none}]),
    match = re:run(Printed, "\\(status completed\\)", [{capture, none}]),
    match = re:run(Printed, "\\(s1 \\(value \"hi\"\\)\\)", [{capture, none}]),
    0 = Exit.

%% A minimal IO server usable as a group leader: it answers `get_chars' / `get_line'
%% / `get_until' read requests by delivering `Bytes' once then EOF (so a reader
%% sees exactly `Bytes' as stdin), and accumulates `put_chars' writes so the test
%% can read back what `run/1' printed. `output' returns the accumulated stdout.
stdin_io_server(Bytes) ->
    spawn(fun() -> stdin_io_loop(Bytes, []) end).

io_server_output(IO) ->
    IO ! {output, self()},
    receive {output, Out} -> Out after 5000 -> ct:fail(io_server_no_output) end.

stdin_io_loop(Bytes, Out) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, Rest, Out1} = stdin_io_answer(Request, Bytes, Out),
            From ! {io_reply, ReplyAs, Reply},
            stdin_io_loop(Rest, Out1);
        {output, From} ->
            From ! {output, lists:reverse(Out)},
            stdin_io_loop(Bytes, Out);
        _Other ->
            stdin_io_loop(Bytes, Out)
    end.

%% A `put_chars' request is an output write: record it, reply `ok'. Any read
%% request delivers the remaining stdin bytes once, then EOF.
stdin_io_answer({put_chars, _Enc, Chars}, Bytes, Out) ->
    {ok, Bytes, [Chars | Out]};
stdin_io_answer({put_chars, _Enc, M, F, A}, Bytes, Out) ->
    {ok, Bytes, [apply(M, F, A) | Out]};
stdin_io_answer(_Read, <<>>, Out) ->
    {eof, <<>>, Out};
stdin_io_answer(_Read, Bytes, Out) ->
    {binary_to_list(Bytes), <<>>, Out}.

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
