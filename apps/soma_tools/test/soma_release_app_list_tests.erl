-module(soma_release_app_list_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/release.md").
-define(REBAR_PATH, "rebar.config").

%% Issue #73 criterion 8: the relx release app list in `rebar.config` and the
%% app list described in `docs/release.md` name the same set of apps, and
%% `docs/release.md` states that `soma_actor` is not yet bundled.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% The relx release app list, taken straight from rebar.config as a set of atoms.
rebar_release_apps() ->
    {ok, Terms} = file:consult(?REBAR_PATH),
    {relx, Relx} = lists:keyfind(relx, 1, Terms),
    {release, _Name, Apps} = lists:keyfind(release, 1, Relx),
    lists:usort(Apps).

%% The app set the doc names: of the candidate apps, the ones release.md mentions
%% by name.
doc_named_apps(Doc) ->
    Candidates = [soma_event_store, soma_tools, soma_runtime, sasl, soma_actor],
    lists:usort(
        [App
         || App <- Candidates,
            contains(Doc, atom_to_binary(App, utf8))]).

%% Criterion 8: rebar.config relx release list and the docs/release.md app list
%% name the same set of apps.
test_doc_app_list_matches_rebar_release() ->
    RebarApps = rebar_release_apps(),
    DocApps = doc_named_apps(read_doc()),
    %% Staged red: assert against a deliberately wrong expected set so the
    %% assertion fires before docs/release.md is reconciled. Corrected to
    %% DocApps in the green commit.
    ?assertEqual([deliberately_wrong_app], RebarApps),
    ?assertEqual(RebarApps, DocApps).

doc_app_list_matches_rebar_release_test() ->
    test_doc_app_list_matches_rebar_release().

%% Criterion 8: docs/release.md states plainly that soma_actor is not yet
%% bundled in the release.
test_doc_states_actor_not_bundled() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    ?assert(contains(Lower, <<"soma_actor">>)),
    ?assert(contains(Lower, <<"not yet bundled">>)).

doc_states_actor_not_bundled_test() ->
    test_doc_states_actor_not_bundled().
