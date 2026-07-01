%% @doc Documentation proofs for the actor stable-name addressing criteria
%% (issue #187). Each test reads a doc file and asserts the substrings that
%% prove the criterion is documented; it opens no socket and starts no app.
-module(soma_actor_naming_docs_tests).

-include_lib("eunit/include/eunit.hrl").

usage_md_path() ->
    filename:join([code:lib_dir(soma_actor), "..", "..", "..", "..",
                   "docs", "usage.md"]).

read_usage_md() ->
    {ok, Bin} = file:read_file(usage_md_path()),
    Bin.

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.

test_usage_documents_stable_name_start_option() ->
    Doc = read_usage_md(),
    %% `stable_name' is documented as a `soma_actor_sup:start_actor/1' option.
    ?assert(contains(Doc, <<"stable_name">>)),
    ?assert(contains(Doc, <<"start_actor">>)).

usage_documents_stable_name_start_option_test() ->
    test_usage_documents_stable_name_start_option().

test_usage_documents_registry_under_sup() ->
    Doc = read_usage_md(),
    %% `soma_actor_registry' is documented as the binary-name registry
    %% supervised under `soma_actor_sup'.
    ?assert(contains(Doc, <<"soma_actor_registry">>)),
    ?assert(contains(Doc, <<"soma_actor_sup">>)).

usage_documents_registry_under_sup_test() ->
    test_usage_documents_registry_under_sup().
