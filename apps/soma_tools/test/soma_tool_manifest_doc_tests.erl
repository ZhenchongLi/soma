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

%% Criterion 4: exactly two adapter types are defined — `erlang_module` and
%% `cli` — each on a line that also says what it runs.
test_manifest_doc_defines_two_adapters() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    [?assert(contains(Lower, A)) || A <- [<<"erlang_module">>, <<"cli">>]],
    %% each adapter name appears on a line that also describes what it runs
    ?assert(adapter_describes_run(Lower, <<"erlang_module">>)),
    ?assert(adapter_describes_run(Lower, <<"cli">>)).

%% An adapter "says what it runs" when its name shares a line with the word
%% "run" plus enough prose to be a description, not just a bare mention.
adapter_describes_run(Lower, Adapter) ->
    Lines = binary:split(Lower, <<"\n">>, [global]),
    AdapterLines = [L || L <- Lines, contains(L, Adapter)],
    lists:any(fun(L) ->
                  contains(L, <<"run">>)
                      andalso byte_size(L) > byte_size(Adapter) + 12
              end, AdapterLines).

manifest_doc_defines_two_adapters_test() ->
    test_manifest_doc_defines_two_adapters().

%% Criterion 5: the `cli` adapter schema specifies an executable plus a
%% separate argv list, and states that a shell command string is never a
%% valid form. The schema lives in its own section so the rule is part of
%% the schema, not just an aside on the adapter-types list.
test_manifest_doc_cli_schema_no_shell() ->
    Doc = read_doc(),
    Lower = string:lowercase(Doc),
    %% a dedicated heading introduces the cli adapter schema
    ?assert(has_cli_schema_heading(Lower)),
    %% the schema names a separate executable and argv list
    ?assert(contains(Lower, <<"executable">>)),
    ?assert(contains(Lower, <<"argv">>)),
    %% and states a shell command string is never a valid form
    ?assert(contains(Lower, <<"shell command string">>)),
    ?assert(contains(Lower, <<"never a valid form">>)).

%% A heading line that names the cli adapter schema.
has_cli_schema_heading(Lower) ->
    Lines = binary:split(Lower, <<"\n">>, [global]),
    lists:any(fun(L) ->
                  is_heading(L) andalso contains(L, <<"cli">>)
                      andalso contains(L, <<"schema">>)
              end, Lines).

is_heading(<<"#", _/binary>>) -> true;
is_heading(_) -> false.

manifest_doc_cli_schema_no_shell_test() ->
    test_manifest_doc_cli_schema_no_shell().
