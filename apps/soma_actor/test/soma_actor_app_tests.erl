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

%% Locate `apps/soma_actor/src/soma_actor.app.src' relative to this test
%% module's compiled `.beam', which rebar3 places under
%% `_build/<profile>/lib/soma_actor/test/'.
app_src_path() ->
    BeamDir = filename:dirname(code:which(?MODULE)),
    AppRoot = filename:dirname(BeamDir),
    filename:join([AppRoot, "src", "soma_actor.app.src"]).
