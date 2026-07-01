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

zh_actor_md_path() ->
    filename:join([code:lib_dir(soma_actor), "..", "..", "..", "..",
                   "docs", "zh", "soma-actor.zh.md"]).

read_zh_actor_md() ->
    {ok, Bin} = file:read_file(zh_actor_md_path()),
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

test_usage_documents_actor_message_to_stable_name() ->
    Doc = read_usage_md(),
    %% Binary stable names are documented as valid `actor_message.to' values.
    ?assert(contains(Doc, <<"actor_message.to">>)),
    ?assert(contains(Doc, <<"stable name">>)).

usage_documents_actor_message_to_stable_name_test() ->
    test_usage_documents_actor_message_to_stable_name().

test_usage_documents_unknown_to_fails_sender_task() ->
    Doc = read_usage_md(),
    %% An unknown `actor_message.to' name is documented as a delivery failure
    %% that fails the sender's task while the sender actor stays alive.
    ?assert(contains(Doc, <<"fails the sender's task">>)),
    ?assert(contains(Doc, <<"sender actor stays alive">>)).

usage_documents_unknown_to_fails_sender_task_test() ->
    test_usage_documents_unknown_to_fails_sender_task().

test_usage_documents_same_name_restart_replaces_entry() ->
    Doc = read_usage_md(),
    %% A same-name actor restart is documented as replacing the registry entry.
    ?assert(contains(Doc, <<"same name">>)),
    ?assert(contains(Doc, <<"replaces the registry entry">>)).

usage_documents_same_name_restart_replaces_entry_test() ->
    test_usage_documents_same_name_restart_replaces_entry().

test_usage_documents_dead_pid_lookup_not_found() ->
    Doc = read_usage_md(),
    %% Looking up a dead registered pid is documented as returning
    %% `{error, not_found}'.
    ?assert(contains(Doc, <<"dead registered pid">>)),
    ?assert(contains(Doc, <<"{error, not_found}">>)).

usage_documents_dead_pid_lookup_not_found_test() ->
    test_usage_documents_dead_pid_lookup_not_found().

test_usage_documents_pid_addressing_still_supported() ->
    Doc = read_usage_md(),
    %% Pid-based actor addressing is documented as still supported: a pid
    %% remains an accepted actor reference alongside binary stable names.
    ?assert(contains(Doc, <<"pid-based actor addressing remains supported">>)).

usage_documents_pid_addressing_still_supported_test() ->
    test_usage_documents_pid_addressing_still_supported().

test_zh_documents_stable_name_start_option() ->
    Doc = read_zh_actor_md(),
    %% The Chinese actor design doc documents `stable_name' as an actor start
    %% option (启动选项).
    ?assert(contains(Doc, <<"stable_name">>)),
    ?assert(contains(Doc, <<"启动选项"/utf8>>)).

zh_documents_stable_name_start_option_test() ->
    test_zh_documents_stable_name_start_option().
