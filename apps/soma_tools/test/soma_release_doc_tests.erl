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
