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
