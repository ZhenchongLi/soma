-module(soma_release_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/release.md").

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 5: docs/release.md documents the release-relative location where a
%% packaged CLI helper lives in an unpacked release
%% (`lib/soma_tools-<vsn>/priv/...`).
test_release_doc_states_priv_location() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    %% the release-relative directory a packaged helper lives under
    ?assert(contains(Lower, <<"lib/soma_tools-">>)),
    ?assert(contains(Lower, <<"priv">>)).

release_doc_states_priv_location_test() ->
    test_release_doc_states_priv_location().

%% Criterion 6: docs/release.md documents that a tool names its packaged
%% executable by a release-relative path resolved through `code:priv_dir/1`,
%% instead of an absolute build path baked in at registration.
test_release_doc_states_priv_dir_convention() ->
    Doc = read_doc(),
    %% the runtime resolution function the doc must name
    ?assert(contains(Doc, <<"code:priv_dir/1">>)),
    %% and the doc must contrast it against baking in an absolute build path
    Lower = string:lowercase(Doc),
    ?assert(contains(Lower, <<"absolute build path">>)).

release_doc_states_priv_dir_convention_test() ->
    test_release_doc_states_priv_dir_convention().
