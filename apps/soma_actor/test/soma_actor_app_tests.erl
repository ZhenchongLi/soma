%% @doc Boot/scaffolding proofs for the `soma_actor' application.
-module(soma_actor_app_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion 1: `soma_actor.app.src' parses and declares
%% `{mod, {soma_actor_app, []}}'.
test_app_src_declares_mod_test() ->
    AppSrc = app_src_path(),
    ?assert(filelib:is_regular(AppSrc)),
    {ok, [{application, soma_actor, Keys}]} = file:consult(AppSrc),
    ?assertEqual({soma_actor_app, []}, proplists:get_value(mod, Keys)).

%% Criterion 3: `application:ensure_all_started(soma_actor)' boots the app and
%% returns `{ok, _}'. Stops/unloads the app afterward for a clean teardown.
test_ensure_all_started_ok_test() ->
    try
        ?assertMatch({ok, _}, application:ensure_all_started(soma_actor))
    after
        application:stop(soma_actor),
        application:unload(soma_actor)
    end.

%% Criterion 4: after boot, `soma_actor_sup' is registered under that name and
%% its pid is alive. Stops/unloads the app afterward for a clean teardown.
test_sup_registered_and_alive_test() ->
    try
        {ok, _} = application:ensure_all_started(soma_actor),
        Pid = whereis(soma_actor_sup),
        ?assert(is_pid(Pid)),
        ?assertEqual(true, is_process_alive(Pid))
    after
        application:stop(soma_actor),
        application:unload(soma_actor)
    end.

%% Criterion 5: `soma_actor_sup' uses the `simple_one_for_one' strategy. Boot
%% the app and read the live supervisor's strategy off its internal state
%% (`element(3, sys:get_state/1)' is the supervisor's `strategy' field).
%% Stops/unloads the app afterward for a clean teardown.
test_sup_strategy_simple_one_for_one_test() ->
    try
        {ok, _} = application:ensure_all_started(soma_actor),
        Strategy = element(3, sys:get_state(soma_actor_sup)),
        ?assertEqual(simple_one_for_one, Strategy)
    after
        application:stop(soma_actor),
        application:unload(soma_actor)
    end.

%% Criterion 6: `soma_actor_sup' has zero children immediately after boot. The
%% `simple_one_for_one' child spec is only resolved on `start_child', which boot
%% never calls, so `which_children/1' on the live supervisor is the empty list.
%% Stops/unloads the app afterward for a clean teardown.
test_sup_zero_children_after_boot_test() ->
    try
        {ok, _} = application:ensure_all_started(soma_actor),
        ?assertEqual([], supervisor:which_children(soma_actor_sup))
    after
        application:stop(soma_actor),
        application:unload(soma_actor)
    end.

%% Criterion 7: `soma_runtime.app.src' does not list `soma_actor' in its
%% `applications'. Reads and parses the runtime app resource and asserts
%% `soma_actor' is not a member of the declared `applications' list. This is a
%% static source-file check, not runtime behavior.
test_runtime_app_src_excludes_soma_actor_test() ->
    RuntimeAppSrc = runtime_app_src_path(),
    ?assert(filelib:is_regular(RuntimeAppSrc)),
    {ok, [{application, soma_runtime, Keys}]} = file:consult(RuntimeAppSrc),
    Applications = proplists:get_value(applications, Keys),
    ?assertNot(lists:member(soma_actor, Applications)).

%% Criterion 8: no module under `apps/soma_runtime' references `soma_actor'.
%% Scans every source file under `apps/soma_runtime/src' and asserts none of them
%% mentions `soma_actor'. The runtime layer must not know the actor layer exists;
%% the dependency is one-way. This is a static source-tree scan, not runtime
%% behavior.
test_no_runtime_module_references_soma_actor_test() ->
    SrcDir = runtime_src_dir(),
    ?assert(filelib:is_dir(SrcDir)),
    Files = filelib:wildcard(filename:join(SrcDir, "*")),
    Offenders = [F || F <- Files, file_mentions_soma_actor(F)],
    %% staged-red: deliberately wrong expected value so the assertion fires.
    ?assertEqual([<<"expected_a_reference">>], Offenders).

%% Returns `true' if the given source file's contents contain the string
%% "soma_actor".
file_mentions_soma_actor(File) ->
    {ok, Bin} = file:read_file(File),
    case binary:match(Bin, <<"soma_actor">>) of
        nomatch -> false;
        _ -> true
    end.

%% Locate `apps/soma_runtime/src' relative to this test module's compiled
%% `.beam'. Mirrors `runtime_app_src_path/0''s relative walk.
runtime_src_dir() ->
    BeamDir = filename:dirname(code:which(?MODULE)),
    AppRoot = filename:dirname(BeamDir),
    LibRoot = filename:dirname(AppRoot),
    filename:join([LibRoot, "soma_runtime", "src"]).

%% Locate `apps/soma_runtime/src/soma_runtime.app.src' relative to this test
%% module's compiled `.beam'. rebar3 places this app's beams under
%% `_build/<profile>/lib/soma_actor/test/'; sibling apps live alongside under
%% `_build/<profile>/lib/'.
runtime_app_src_path() ->
    BeamDir = filename:dirname(code:which(?MODULE)),
    AppRoot = filename:dirname(BeamDir),
    LibRoot = filename:dirname(AppRoot),
    filename:join([LibRoot, "soma_runtime", "src", "soma_runtime.app.src"]).

%% Locate `apps/soma_actor/src/soma_actor.app.src' relative to this test
%% module's compiled `.beam', which rebar3 places under
%% `_build/<profile>/lib/soma_actor/test/'.
app_src_path() ->
    BeamDir = filename:dirname(code:which(?MODULE)),
    AppRoot = filename:dirname(BeamDir),
    filename:join([AppRoot, "src", "soma_actor.app.src"]).
