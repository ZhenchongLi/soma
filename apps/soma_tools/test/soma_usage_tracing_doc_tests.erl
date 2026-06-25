-module(soma_usage_tracing_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/usage.md").

%% Issue #93 criterion 10: `docs/usage.md` gains a "Tracing" section that shows
%% calling `soma_trace:render/2` with a `correlation_id`.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 10: docs/usage.md has a Tracing section heading and shows a
%% soma_trace:render/2 call with a correlation_id.
test_doc_has_tracing_section_with_render_call() ->
    Doc = read_doc(),
    %% Staged-red: a deliberately wrong expected heading so the assertion fires.
    ?assert(contains(Doc, <<"## DELIBERATELY_WRONG_Tracing">>)),
    ?assert(contains(Doc, <<"soma_trace:render(">>)).

doc_has_tracing_section_with_render_call_test() ->
    test_doc_has_tracing_section_with_render_call().
