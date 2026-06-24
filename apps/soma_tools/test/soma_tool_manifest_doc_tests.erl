-module(soma_tool_manifest_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/tool-manifest.md").

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 1: a top-level heading names the tool manifest.
test_manifest_doc_has_heading() ->
    Doc = read_doc(),
    Lines = binary:split(Doc, <<"\n">>, [global]),
    Headings = [L || L <- Lines, is_top_level_heading(L)],
    ?assert(lists:any(fun names_manifest/1, Headings)).

is_top_level_heading(<<"# ", _/binary>>) -> true;
is_top_level_heading(_) -> false.

names_manifest(Line) ->
    contains(string:lowercase(Line), <<"manifest">>).

manifest_doc_has_heading_test() ->
    test_manifest_doc_has_heading().

%% Criterion 2: the four required metadata keys are listed and explained.
test_manifest_doc_lists_four_keys() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    [?assert(contains(Lower, K)) || K <- [<<"name">>, <<"effect">>,
                                          <<"idempotent">>, <<"timeout_ms">>]],
    %% each key is accompanied by an explanation of what it means
    [?assert(key_is_explained(Lower, K)) || K <- [<<"name">>, <<"effect">>,
                                                  <<"idempotent">>, <<"timeout_ms">>]].

%% A key is explained when it appears on a line that also carries prose
%% describing it (the line is longer than the bare key reference).
key_is_explained(Lower, Key) ->
    Lines = binary:split(Lower, <<"\n">>, [global]),
    KeyLines = [L || L <- Lines, contains(L, Key)],
    lists:any(fun(L) -> byte_size(L) > byte_size(Key) + 12 end, KeyLines).

manifest_doc_lists_four_keys_test() ->
    test_manifest_doc_lists_four_keys().

%% Criterion 3: the allowed values of `effect` are recorded as
%% `identity`, `reader`, or `state`.
test_manifest_doc_lists_effect_values() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    [?assert(contains(Lower, V)) || V <- [<<"identity">>, <<"reader">>,
                                          <<"state">>]].

manifest_doc_lists_effect_values_test() ->
    test_manifest_doc_lists_effect_values().

%% Criterion 4: two adapter types are defined — `erlang_module` and `cli` —
%% and the doc says what each one runs.
test_manifest_doc_defines_two_adapters() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    [?assert(contains(Lower, A)) || A <- [<<"erlang_module">>, <<"cli">>]],
    %% each adapter section opens by saying what it runs
    ?assert(contains(Lower, <<"runs a module">>)),
    ?assert(contains(Lower, <<"runs an external">>)).

manifest_doc_defines_two_adapters_test() ->
    test_manifest_doc_defines_two_adapters().

%% Criterion 5: the `cli` adapter is documented with a separate executable and
%% argv list, and states that no shell parsing is applied — arguments are
%% literal, never a shell command string.
test_manifest_doc_cli_schema_no_shell() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    ?assert(contains(Lower, <<"cli">>)),
    %% a separate executable and argv list
    ?assert(contains(Lower, <<"executable">>)),
    ?assert(contains(Lower, <<"argv">>)),
    %% and the no-shell rule is stated explicitly
    ?assert(contains(Lower, <<"no shell parsing">>)).

manifest_doc_cli_schema_no_shell_test() ->
    test_manifest_doc_cli_schema_no_shell().

%% Criterion 6: the five v0.1 built-in tools are named and all map to the
%% `erlang_module` adapter.
test_manifest_doc_v01_tools_map_to_erlang_module() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    [?assert(contains(Lower, T)) || T <- [<<"echo">>, <<"sleep">>, <<"fail">>,
                                          <<"file_read">>, <<"file_write">>]],
    ?assert(contains(Lower, <<"erlang_module">>)).

manifest_doc_v01_tools_map_to_erlang_module_test() ->
    test_manifest_doc_v01_tools_map_to_erlang_module().

%% Criterion 7: the doc carries at least one worked manifest example.
test_manifest_doc_has_example() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    ?assert(contains(Lower, <<"example">>)),
    ?assert(contains(Lower, <<"adapter => cli">>)).

manifest_doc_has_example_test() ->
    test_manifest_doc_has_example().

%% Criterion 8: the doc states a malformed manifest is rejected, not stored.
test_manifest_doc_rejects_malformed() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    ?assert(contains(Lower, <<"malformed">>)),
    ?assert(contains(Lower, <<"rejected">>)).

manifest_doc_rejects_malformed_test() ->
    test_manifest_doc_rejects_malformed().

%% Criterion 9: the doc documents the v0.2 `cli` execution protocol —
%% input delivered as the final argv argument, stdout captured as the step
%% output, and exit status 0 meaning success.
test_manifest_doc_describes_cli_execution_protocol() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    ?assert(contains(Lower, <<"final argv argument">>)),
    ?assert(contains(Lower, <<"stdout">>)),
    ?assert(contains(Lower, <<"step output">>)),
    ?assert(contains(Lower, <<"exit status 0">>)),
    ?assert(contains(Lower, <<"success">>)).

manifest_doc_describes_cli_execution_protocol_test() ->
    test_manifest_doc_describes_cli_execution_protocol().
