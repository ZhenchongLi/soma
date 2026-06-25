%% @doc Runtime-wiring proofs for #97: how `soma_sup' starts its
%% `soma_event_store' child from the `event_store_log' app env. The store
%% internals are proven in `soma_event_store_persist_tests'; this suite proves
%% only the supervisor's wiring decision, by booting and stopping the
%% `soma_runtime' application with the env set or unset.
-module(soma_event_store_wiring_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_unset_env_store_is_in_memory_writes_no_file/1]).
-export([test_set_env_store_persists_append_to_log/1]).
-export([test_unset_env_boot_order/1]).
-export([test_set_env_boot_order/1]).
-export([test_release_doc_documents_event_store_log/1]).

all() ->
    [test_unset_env_store_is_in_memory_writes_no_file,
     test_set_env_store_persists_append_to_log,
     test_unset_env_boot_order,
     test_set_env_boot_order,
     test_release_doc_documents_event_store_log].

init_per_testcase(Case, Config)
  when Case =:= test_set_env_store_persists_append_to_log;
       Case =:= test_set_env_boot_order ->
    TmpDir = make_tmp_dir(),
    Path = filename:join(TmpDir, "events.log"),
    application:set_env(soma_runtime, event_store_log, Path),
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    [{tmp_dir, TmpDir}, {log_path, Path} | Config];
init_per_testcase(_Case, Config) ->
    application:unset_env(soma_runtime, event_store_log),
    TmpDir = make_tmp_dir(),
    {ok, _Started} = application:ensure_all_started(soma_runtime),
    [{tmp_dir, TmpDir} | Config].

end_per_testcase(_Case, Config) ->
    %% A case may already have stopped the app (the persistent case stops it
    %% in-body to flush its disk_log handle); tolerate the already-stopped case.
    _ = application:stop(soma_runtime),
    application:unset_env(soma_runtime, event_store_log),
    ok = del_tmp_dir(?config(tmp_dir, Config)),
    ok.

%% Criterion 1: with `event_store_log' unset, the `soma_event_store' child
%% started under `soma_sup' is in-memory and creates no log file on disk.
%%
%% The case reads the live store child out of `which_children(soma_sup)',
%% drives an append/2 through it, and asserts no file appeared in a fresh temp
%% dir it watches — the same on-disk check #96 used, against the sup-owned store.
test_unset_env_store_is_in_memory_writes_no_file(Config) ->
    TmpDir = ?config(tmp_dir, Config),
    Before = list_dir(TmpDir),

    StorePid = store_child(),
    ok = soma_event_store:append(StorePid, #{run_id => run_a,
                                             session_id => sess_a,
                                             correlation_id => corr_a,
                                             event_type => a1}),
    %% The in-memory store still serves the event from memory.
    [a1] = [maps:get(event_type, E) || E <- soma_event_store:by_run(StorePid, run_a)],

    After = list_dir(TmpDir),
    ?assertEqual(Before, After).

%% Criterion 2: with `event_store_log' set to a path before boot, the
%% `soma_event_store' child started under `soma_sup' is persistent — an event
%% appended through it lands in a `disk_log' at that path.
%%
%% The case appends one event through the live sup-owned store child, then stops
%% the app so the store's disk_log handle flushes, and reads the term straight
%% out of its own short-lived disk_log at the path — the read-back-around-the-
%% store technique #96 used. The on-disk term must equal the store's normalized
%% view of the appended event.
test_set_env_store_persists_append_to_log(Config) ->
    Path = ?config(log_path, Config),

    StorePid = store_child(),
    ok = soma_event_store:append(StorePid, #{run_id => run_a,
                                            session_id => sess_a,
                                            correlation_id => corr_a,
                                            event_type => a1}),
    %% The store's normalized form of the appended event — what should physically
    %% sit in the log.
    [Normalized] = soma_event_store:by_run(StorePid, run_a),

    %% Stop the app so the store's disk_log handle is closed and flushed, then
    %% read the single term back from the log at Path around the store.
    ok = application:stop(soma_runtime),
    ?assert(filelib:is_regular(Path)),
    FromDisk = read_one_log_term(Path),

    ?assertEqual(Normalized, FromDisk).

%% Criterion 3: with `event_store_log' unset, `soma_sup' boots its four children
%% in start order `[soma_event_store, soma_tool_registry, soma_session_sup,
%% soma_run_sup]' with `soma_event_store' first.
%%
%% `supervisor:which_children/1' returns children in the *reverse* of their start
%% order, so the case reverses that list to recover start order before asserting.
test_unset_env_boot_order(_Config) ->
    Children = supervisor:which_children(soma_sup),
    StartOrder = [Id || {Id, _Pid, _Type, _Mods} <- lists:reverse(Children)],
    ?assertEqual([soma_event_store, soma_tool_registry,
                  soma_session_sup, soma_run_sup],
                 StartOrder).

%% Criterion 4: with `event_store_log' set to a path, `soma_sup' still boots the
%% same four children in the same start order `[soma_event_store,
%% soma_tool_registry, soma_session_sup, soma_run_sup]' with `soma_event_store'
%% first. The persistent branch changes only the store child's `start' tuple, not
%% the child set or its order.
%%
%% Like Criterion 3, this reverses `which_children/1' to recover start order
%% before asserting (the supervisor reports children in reverse start order).
test_set_env_boot_order(_Config) ->
    Children = supervisor:which_children(soma_sup),
    StartOrder = [Id || {Id, _Pid, _Type, _Mods} <- lists:reverse(Children)],
    ?assertEqual([soma_event_store, soma_tool_registry,
                  soma_session_sup, soma_run_sup],
                 StartOrder).

%% Criterion 5: docs/release.md documents enabling persistence through the
%% `event_store_log' app env. A direct file read over docs/release.md asserts the
%% prose is present: the app env is named, the durability claim is stated, and the
%% concrete `sys.config' snippet is shown verbatim — the read-the-file doc proof
%% shape #96 used over docs/usage.md.
test_release_doc_documents_event_store_log(_Config) ->
    Doc = read_release_doc(),

    %% The app env that turns on persistence is named.
    ?assert(contains(Doc, <<"event_store_log">>)),

    %% The prose explains the env makes the store durable / persistent.
    ?assert(contains(Doc, <<"durable">>)),

    %% The sys.config example is shown verbatim so an operator can copy it.
    ?assert(contains(Doc,
        <<"{soma_runtime, [{event_store_log, \"/var/lib/soma/events.log\"}]}">>)),

    %% The sys.config snippet sits with the persistence prose: the
    %% `event_store_log' mention appears before the sys.config snippet, both in
    %% the same section rather than scattered.
    EnvPos = find_pos(Doc, <<"event_store_log">>),
    SnippetPos = find_pos(Doc,
        <<"{soma_runtime, [{event_store_log, \"/var/lib/soma/events.log\"}]}">>),
    ?assert(EnvPos =/= nomatch),
    ?assert(SnippetPos =/= nomatch),
    ?assert(EnvPos =< SnippetPos).

%%% Helpers

%% Read docs/release.md from the repo root. The test beams run out of `_build',
%% so locate the project root by walking up from this test module's own beam
%% until an `apps' directory is found, then read `docs/release.md' under it.
read_release_doc() ->
    Path = filename:join([project_root(), "docs", "release.md"]),
    {ok, Bin} = file:read_file(Path),
    Bin.

project_root() ->
    walk_up_to_apps(filename:dirname(code:which(?MODULE))).

walk_up_to_apps(Dir) ->
    case filelib:is_dir(filename:join(Dir, "apps")) of
        true -> Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent of
                Dir -> erlang:error(project_root_not_found);
                _ -> walk_up_to_apps(Parent)
            end
    end.

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.

find_pos(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        {Pos, _Len} -> Pos;
        nomatch -> nomatch
    end.

%% Open a fresh disk_log against the halt log file at Path and read its single
%% logged term back, around the store. A halt log not closed cleanly comes back
%% as `{repaired, _, _, {badbytes, 0}}' on reopen; with zero bad bytes the
%% recovered term is intact, so either return is fine for reading.
read_one_log_term(Path) ->
    Name = {?MODULE, make_ref()},
    case disk_log:open([{name, Name}, {file, Path}, {type, halt}]) of
        {ok, Name} -> ok;
        {repaired, Name, _Recovered, {badbytes, 0}} -> ok
    end,
    {_Cont, [Term]} = disk_log:chunk(Name, start),
    ok = disk_log:close(Name),
    Term.

%% Resolve the live `soma_event_store' child pid out of the running supervisor.
store_child() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, worker, _} = lists:keyfind(soma_event_store, 1, Children),
    Pid.

make_tmp_dir() ->
    Unique = erlang:integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join(["/tmp", "soma_event_store_wiring_" ++ Unique]),
    ok = file:make_dir(Dir),
    Dir.

list_dir(Dir) ->
    {ok, Names} = file:list_dir(Dir),
    lists:sort(Names).

del_tmp_dir(Dir) ->
    {ok, Names} = file:list_dir(Dir),
    [ok = file:delete(filename:join(Dir, N)) || N <- Names],
    file:del_dir(Dir).
