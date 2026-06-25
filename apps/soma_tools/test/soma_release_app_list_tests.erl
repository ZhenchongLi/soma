-module(soma_release_app_list_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/release.md").
-define(REBAR_PATH, "rebar.config").

%% The relx release app list in `rebar.config` and the app list described in
%% `docs/release.md` name the same set of apps, and `soma_actor` is bundled in
%% both (issue #75).

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

%% The bundled-app set the doc names: of the candidate apps, the ones release.md
%% lists as a backtick-wrapped bullet item (`- `app``) in its bundled-apps list.
%% Restricting to that shape keeps a prose mention (e.g. naming `soma_actor` to
%% say it is *excluded*) from being miscounted as a bundled app.
doc_named_apps(Doc) ->
    Candidates = [soma_event_store, soma_tools, soma_runtime, sasl, soma_actor],
    lists:usort(
        [App
         || App <- Candidates,
            contains(Doc, bullet_item(App))]).

bullet_item(App) ->
    AppBin = atom_to_binary(App, utf8),
    <<"- `", AppBin/binary, "`">>.

%% Criterion 8: rebar.config relx release list and the docs/release.md app list
%% name the same set of apps.
test_doc_app_list_matches_rebar_release() ->
    RebarApps = rebar_release_apps(),
    DocApps = doc_named_apps(read_doc()),
    ?assertEqual(RebarApps, DocApps).

doc_app_list_matches_rebar_release_test() ->
    test_doc_app_list_matches_rebar_release().

%% Issue #75 criterion 5: the equality test must still FAIL when the rebar.config
%% release set and the docs/release.md bundled set name different app sets. The
%% real comparison reads two files, so we exercise the same set-derivation logic
%% (doc_named_apps/1 against the real rebar release set) with drifted doc content
%% and assert the comparison flags the mismatch in either direction.
test_drift_between_lists_is_flagged() ->
    RebarApps = rebar_release_apps(),
    %% Doc that names a strict subset of the rebar set (an app dropped from the
    %% doc): comparison must NOT report equality.
    DroppedOne = [bullet_line(App) || App <- RebarApps, App =/= soma_actor],
    DocMissingActor = iolist_to_binary(DroppedOne),
    ?assertNotEqual(RebarApps, doc_named_apps(DocMissingActor)),
    %% Doc that names the rebar set as-is plus drift in the form of a different
    %% spelling for one app (the doc and rebar set point at different apps):
    %% comparison must NOT report equality.
    Swapped = [if App =:= soma_runtime -> soma_event_store; true -> App end
               || App <- RebarApps],
    DocSwapped = iolist_to_binary([bullet_line(App) || App <- Swapped]),
    ?assertNotEqual(RebarApps, doc_named_apps(DocSwapped)).

bullet_line(App) ->
    AppBin = atom_to_binary(App, utf8),
    <<"- `", AppBin/binary, "`\n">>.

drift_between_lists_is_flagged_test() ->
    test_drift_between_lists_is_flagged().

%% Issue #75 criteria 1, 2 & 4: soma_actor is bundled in the release — it is a
%% member of both the rebar.config relx release app set and the docs/release.md
%% bundled-app set.
test_actor_bundled_in_rebar_and_doc() ->
    ?assert(lists:member(soma_actor, rebar_release_apps())),
    ?assert(lists:member(soma_actor, doc_named_apps(read_doc()))).

actor_bundled_in_rebar_and_doc_test() ->
    test_actor_bundled_in_rebar_and_doc().

%% Issue #75 criterion 3: docs/release.md no longer contains the phrase
%% "not yet bundled" anywhere in the file.
test_doc_drops_not_yet_bundled() ->
    Doc = read_doc(),
    ?assertNot(contains(Doc, <<"not yet bundled">>)).

doc_drops_not_yet_bundled_test() ->
    test_doc_drops_not_yet_bundled().
