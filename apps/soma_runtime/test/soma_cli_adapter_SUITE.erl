-module(soma_cli_adapter_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_cli_manifest_resolves_to_cli_descriptor/1]).

all() ->
    [test_cli_manifest_resolves_to_cli_descriptor].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% Criterion 1: a `cli' manifest (adapter cli, with an executable and an argv
%% list) registered in the running registry resolves through
%% soma_tool_registry:resolve_descriptor/1 to a `cli' descriptor.
test_cli_manifest_resolves_to_cli_descriptor(_Config) ->
    Manifest = #{name => cli_upper,
                 effect => reader,
                 idempotent => true,
                 timeout_ms => 5000,
                 adapter => cli,
                 executable => "/bin/echo",
                 argv => ["hello"]},
    ok = soma_tool_registry:register_tool(Manifest),
    {ok, Descriptor} = soma_tool_registry:resolve_descriptor(cli_upper),
    #{adapter := cli,
      executable := "/bin/echo",
      argv := ["hello"]} = Descriptor,
    ok.
