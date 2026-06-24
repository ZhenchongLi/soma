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

%% Locate `apps/soma_actor/src/soma_actor.app.src' relative to this test
%% module's compiled `.beam', which rebar3 places under
%% `_build/<profile>/lib/soma_actor/test/'.
app_src_path() ->
    BeamDir = filename:dirname(code:which(?MODULE)),
    AppRoot = filename:dirname(BeamDir),
    filename:join([AppRoot, "src", "soma_actor.app.src"]).
