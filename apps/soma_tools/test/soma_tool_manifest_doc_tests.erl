-module(soma_tool_manifest_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/tool-manifest.md").

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

%% Criterion 1: a top-level heading names the v0.2 tool manifest contract.
test_manifest_doc_has_heading() ->
    Doc = read_doc(),
    Lines = binary:split(Doc, <<"\n">>, [global]),
    Headings = [L || L <- Lines, is_top_level_heading(L)],
    ?assert(lists:any(fun names_manifest_contract/1, Headings)).

is_top_level_heading(<<"# ", _/binary>>) -> true;
is_top_level_heading(_) -> false.

names_manifest_contract(Line) ->
    Lower = string:lowercase(Line),
    contains(Lower, <<"manifest">>) andalso contains(Lower, <<"contract">>).

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

manifest_doc_has_heading_test() ->
    test_manifest_doc_has_heading().
