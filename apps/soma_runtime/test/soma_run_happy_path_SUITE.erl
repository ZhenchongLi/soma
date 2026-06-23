-module(soma_run_happy_path_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_sup_has_four_live_children/1]).
-export([test_registry_seeded_with_v01_tools/1]).

all() ->
    [test_sup_has_four_live_children,
     test_registry_seeded_with_v01_tools].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% Criterion 1: booting the soma_runtime application brings up soma_sup with
%% four live children, in order: soma_event_store, soma_tool_registry,
%% soma_session_sup, soma_run_sup.
test_sup_has_four_live_children(_Config) ->
    SupPid = whereis(soma_sup),
    true = is_pid(SupPid),
    true = is_process_alive(SupPid),
    Children = supervisor:which_children(soma_sup),
    Ids = [Id || {Id, _Child, _Type, _Mods} <- Children],
    Expected = [soma_event_store, soma_tool_registry, soma_session_sup,
                soma_run_sup],
    true = lists:all(fun(Id) -> lists:member(Id, Ids) end, Expected),
    4 = length(Children),
    Pids = [Pid || {_Id, Pid, _Type, _Mods} <- Children],
    true = lists:all(fun(Pid) -> is_pid(Pid) andalso is_process_alive(Pid) end,
                     Pids),
    ok.

%% Criterion 2: the registry the booted runtime owns is seeded with the five
%% v0.1 tools, and each tool name resolves through soma_tool_registry:resolve/1
%% to its behaviour module.
test_registry_seeded_with_v01_tools(_Config) ->
    {ok, soma_tool_echo} = soma_tool_registry:resolve(echo),
    {ok, soma_tool_sleep} = soma_tool_registry:resolve(sleep),
    {ok, soma_tool_fail} = soma_tool_registry:resolve(fail),
    {ok, soma_tool_file_read} = soma_tool_registry:resolve(file_read),
    {ok, soma_tool_file_write} = soma_tool_registry:resolve(file_write),
    ok.
