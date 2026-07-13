-module(soma_baseline_cleanup_doc_tests).

-include_lib("eunit/include/eunit.hrl").

read_repo_file(Name) ->
    Path = filename:join([code:lib_dir(soma_runtime), "..", "..", "..", "..", Name]),
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Name, Reason})
    end.

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.

test_readme_and_agents_report_final_green_gate_totals() ->
    Readme = read_repo_file("README.md"),
    Agents = read_repo_file("AGENTS.md"),
    ?assert(contains(Readme, <<"EUnit 386, Common Test 425">>)),
    ?assert(contains(Agents, <<"EUnit 386 and Common Test 425">>)).

readme_and_agents_report_final_green_gate_totals_test() ->
    test_readme_and_agents_report_final_green_gate_totals().

test_claude_md_contains_only_agents_import() ->
    ?assertEqual(<<"@AGENTS.md\n">>, read_repo_file("CLAUDE.md")).

claude_md_contains_only_agents_import_test() ->
    test_claude_md_contains_only_agents_import().
