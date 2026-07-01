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

test_usage_documents_send_accepts_stable_name() ->
    Doc = read_usage_md(),
    %% `soma_actor:send/2' is documented as accepting a binary stable name as
    %% the actor reference.
    ?assert(contains(Doc, <<"soma_actor:send">>)),
    ?assert(contains(Doc, <<"stable name">>)).

usage_documents_send_accepts_stable_name_test() ->
    test_usage_documents_send_accepts_stable_name().

test_usage_documents_send_unknown_name_not_found() ->
    Doc = read_usage_md(),
    %% An unknown stable name is documented as making `soma_actor:send/2'
    %% return `{error, not_found}'.
    ?assert(contains(Doc, <<"{error, not_found}">>)),
    ?assert(contains(Doc, <<"unknown">>)).

usage_documents_send_unknown_name_not_found_test() ->
    test_usage_documents_send_unknown_name_not_found().
