-module(soma_lfe_task_doc_tests).

-include_lib("eunit/include/eunit.hrl").

read_doc(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

section(Doc, Heading) ->
    case binary:match(Doc, Heading) of
        {Start, _Len} ->
            AfterStart = binary:part(Doc, Start, byte_size(Doc) - Start),
            find_section_end(AfterStart);
        nomatch ->
            erlang:error({missing_section, Heading})
    end.

find_section_end(SectionAndRest) ->
    case binary:match(SectionAndRest, <<"\n## ">>) of
        {0, _Len} ->
            SectionAndRest;
        {End, _Len} ->
            binary:part(SectionAndRest, 0, End);
        nomatch ->
            SectionAndRest
    end.

before(Haystack, Left, Right) ->
    case {binary:match(Haystack, Left), binary:match(Haystack, Right)} of
        {{LeftAt, _}, {RightAt, _}} -> LeftAt < RightAt;
        _ -> false
    end.

test_readme_quick_start_uses_task_example() ->
    QuickStart = section(read_doc("README.md"), <<"## Quick start">>),
    ?assert(contains(QuickStart, <<"soma run">>)),
    ?assert(contains(QuickStart, <<"(task">>)),
    ?assert(before(QuickStart, <<"(task">>, <<"soma run">>)),
    ?assertNot(before(QuickStart, <<"(run">>, <<"soma run">>)).

readme_quick_start_uses_task_example_test() ->
    test_readme_quick_start_uses_task_example().

test_lfe_dsl_documents_task_as_public_static_form() ->
    Doc = read_doc("docs/lfe-dsl.md"),
    ?assert(contains(Doc, <<"(task ...)">>)),
    ?assert(contains(Doc, <<"public static task form">>)).

lfe_dsl_documents_task_as_public_static_form_test() ->
    test_lfe_dsl_documents_task_as_public_static_form().

test_lfe_dsl_documents_run_as_compatibility_core_form() ->
    Doc = read_doc("docs/lfe-dsl.md"),
    ?assert(contains(Doc, <<"(run ...)">>)),
    ?assert(contains(Doc, <<"compatibility/core run form">>)).

lfe_dsl_documents_run_as_compatibility_core_form_test() ->
    test_lfe_dsl_documents_run_as_compatibility_core_form().

test_lfe_dsl_includes_dynamic_need_sentence() ->
    Doc = read_doc("docs/lfe-dsl.md"),
    ?assert(contains(
        Doc,
        <<"When a need is dynamic, keep the dynamic decision in the actor/planner layer and submit a new bounded static Soma Lisp task for each execution attempt.">>
    )).

lfe_dsl_includes_dynamic_need_sentence_test() ->
    test_lfe_dsl_includes_dynamic_need_sentence().

test_design_documents_soma_lisp_boundary() ->
    Doc = read_doc("docs/design.md"),
    ?assert(contains(
        Doc,
        <<"Soma Lisp source -> soma_lfe:compile/2 -> validated maps -> OTP execution">>
    )).

design_documents_soma_lisp_boundary_test() ->
    test_design_documents_soma_lisp_boundary().

test_usage_doc_says_run_file_reads_soma_lisp_source() ->
    Doc = read_doc("docs/usage.md"),
    ?assert(contains(
        Doc,
        <<"soma run FILE reads Soma Lisp source">>
    )).

usage_doc_says_run_file_reads_soma_lisp_source_test() ->
    test_usage_doc_says_run_file_reads_soma_lisp_source().

test_cli_doc_says_run_file_reads_soma_lisp_source() ->
    Doc = read_doc("docs/cli.md"),
    ?assert(contains(
        Doc,
        <<"soma run FILE reads Soma Lisp source">>
    )).

cli_doc_says_run_file_reads_soma_lisp_source_test() ->
    test_cli_doc_says_run_file_reads_soma_lisp_source().
