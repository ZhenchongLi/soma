%% @doc CT proofs for the socket tool-management verbs (#220): `soma tool
%% register|list|remove'. The client-side wire cases (a verb renders and sends
%% the right s-expr over the socket) use `soma_cli_request_capture' standing in
%% for the daemon so the test reads the exact bytes sent. The server-side cases
%% boot a real daemon over a temp socket + tools dir.
-module(soma_tool_management_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_register_sends_manifest_over_socket/1]).

all() ->
    [test_register_sends_manifest_over_socket].

init_per_testcase(_Case, Config) ->
    %% A unique per-run socket path in a temp dir the client verb and the
    %% capture both use, so the client's connect lands on the capture's listener.
    Tmp = case os:getenv("TMPDIR") of
              false -> "/tmp";
              Dir -> Dir
          end,
    Base = filename:join(Tmp,
                         "soma_tool_mgmt_" ++ os:getpid() ++ "_"
                         ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Base, "x")),
    SocketPath = filename:join(Base, "soma.sock"),
    _ = file:delete(SocketPath),
    [{base_dir, Base}, {socket_path, SocketPath} | Config].

end_per_testcase(_Case, Config) ->
    _ = file:delete(?config(socket_path, Config)),
    ok.

%% Criterion 1 (#220): `soma_cli_main:dispatch(["tool", "register", File])' reads
%% the `(tool ...)' manifest file and sends it over the local socket wrapped as a
%% `(tool-register (tool ...))' frame -- the client renders the request, the
%% daemon is the only parser. A `soma_cli_request_capture' stands in for the
%% daemon on the resolved socket so the test reads the exact wire bytes the
%% client sent; the `--socket' override points the client at the capture's path.
test_register_sends_manifest_over_socket(Config) ->
    Path = ?config(socket_path, Config),
    Manifest = <<"(tool\n"
                 "  (name \"cfg_upper\")\n"
                 "  (effect reader) (idempotent true) (timeout-ms 5000)\n"
                 "  (adapter cli)\n"
                 "  (executable \"/bin/echo\")\n"
                 "  (argv \"hello\" \"world\"))\n">>,
    File = filename:join(?config(base_dir, Config), "cfg_upper.lisp"),
    ok = file:write_file(File, Manifest),
    Capture = soma_cli_request_capture:start(
                Path, <<"(tool-registered (name \"cfg_upper\"))">>),

    ct:capture_start(),
    Exit = soma_cli_main:dispatch(["tool", "register", File, "--socket", Path]),
    ct:capture_stop(),
    _ = ct:capture_get(),
    Request = soma_cli_request_capture:request(Capture),

    %% The emitted request is a `(tool-register (tool ...))' frame carrying the
    %% manifest's declared name, proving the client read the file and wrapped it.
    match = re:run(Request, "^\\(tool-register ", [{capture, none}]),
    match = re:run(Request, "\\(tool", [{capture, none}]),
    match = re:run(Request, "\\(name \"cfg_upper\"\\)", [{capture, none}]),
    0 = Exit.
