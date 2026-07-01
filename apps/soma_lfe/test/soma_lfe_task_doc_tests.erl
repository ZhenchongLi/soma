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

paragraph_starting_with(Doc, Anchor) ->
    case binary:split(Doc, Anchor) of
        [_Before, Rest] ->
            ParagraphAndRest = <<Anchor/binary, Rest/binary>>,
            case binary:split(ParagraphAndRest, <<"\n\n">>) of
                [Paragraph, _After] -> Paragraph;
                [Paragraph] -> Paragraph
            end;
        [_] ->
            erlang:error({missing_paragraph, Anchor})
    end.

starts_with(Bin, Prefix) when byte_size(Bin) >= byte_size(Prefix) ->
    binary:part(Bin, 0, byte_size(Prefix)) =:= Prefix;
starts_with(_Bin, _Prefix) ->
    false.

extract_pipeline_lfe(Doc) ->
    Start = <<"cat > /tmp/soma-demo/pipeline.lfe <<'EOF'\n">>,
    End = <<"\nEOF">>,
    case binary:split(Doc, Start) of
        [_Before, Rest] ->
            case binary:split(Rest, End) of
                [Source, _After] -> Source;
                [_] -> erlang:error({missing_heredoc_end, End})
            end;
        [_] ->
            erlang:error({missing_heredoc_start, Start})
    end.

test_site_quick_start_task_example_compiles() ->
    Source = extract_pipeline_lfe(read_doc("site/src/content/docs/start/quick-start.md")),
    ?assert(starts_with(Source, <<"(task">>)),
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    ?assertEqual(
        [
            #{id => read,
              tool => file_read,
              args => #{path => <<"input.txt">>, root => <<"/tmp/soma-demo">>}},
            #{id => process,
              tool => echo,
              args => #{from_step => read}},
            #{id => write,
              tool => file_write,
              args => #{path => <<"output.txt">>,
                        root => <<"/tmp/soma-demo">>,
                        bytes => {from_step, process}}}
        ],
        Steps
    ).

site_quick_start_task_example_compiles_test() ->
    test_site_quick_start_task_example_compiles().

test_site_quick_start_presents_soma_lisp_tasks() ->
    Doc = read_doc("site/src/content/docs/start/quick-start.md"),
    ?assert(contains(
        Doc,
        <<"description: Run Soma through the packaged CLI and Soma Lisp task files.">>
    )),
    ?assert(contains(
        Doc,
        <<"Soma's public edge is the `soma` command plus Soma Lisp task files.">>
    )),
    ?assert(contains(Doc, <<"## Run a task">>)),
    ?assert(contains(
        Doc,
        <<"A Soma Lisp task is the public source form for `soma run`.">>
    )),
    ?assertNot(contains(Doc, <<"Lisp workflow">>)),
    ?assertNot(contains(Doc, <<"Run a workflow">>)),
    ?assertNot(contains(Doc, <<"workflow syntax">>)).

site_quick_start_presents_soma_lisp_tasks_test() ->
    test_site_quick_start_presents_soma_lisp_tasks().

test_readme_quick_start_uses_task_example() ->
    QuickStart = section(read_doc("README.md"), <<"## Quick start">>),
    ?assert(contains(QuickStart, <<"soma run">>)),
    ?assert(contains(QuickStart, <<"(task">>)),
    ?assert(before(QuickStart, <<"(task">>, <<"soma run">>)),
    ?assertNot(before(QuickStart, <<"(run">>, <<"soma run">>)).

readme_quick_start_uses_task_example_test() ->
    test_readme_quick_start_uses_task_example().

test_readme_quick_start_names_soma_run_input_task_source() ->
    QuickStart = section(read_doc("README.md"), <<"## Quick start">>),
    ?assert(contains(QuickStart, <<"soma run">>)),
    ?assert(contains(QuickStart, <<"Soma Lisp task source">>)),
    ?assertNot(contains(QuickStart, <<"workflow language">>)).

readme_quick_start_names_soma_run_input_task_source_test() ->
    test_readme_quick_start_names_soma_run_input_task_source().

test_readme_docs_index_calls_usage_task_file_guide() ->
    Docs = section(read_doc("README.md"), <<"## Docs">>),
    Usage = paragraph_starting_with(
        Docs,
        <<"- **[docs/usage.md](docs/usage.md)**">>
    ),
    ?assert(contains(Usage, <<"running task files">>)),
    ?assertNot(contains(Usage, <<"running workflow files">>)).

readme_docs_index_calls_usage_task_file_guide_test() ->
    test_readme_docs_index_calls_usage_task_file_guide().

test_usage_doc_uses_task_wording_for_public_run_sections() ->
    Doc = read_doc("docs/usage.md"),
    Intro = paragraph_starting_with(
        Doc,
        <<"This guide is for using Soma from the packaged `soma` command:">>
    ),
    QuickStart = section(Doc, <<"## Quick Start: Run A ">>),
    RunFile = section(Doc, <<"`soma run FILE` reads Soma Lisp source">>),
    BuiltInTools = section(Doc, <<"## Built-In Tools">>),
    ManageTasks = section(Doc, <<"## Manage Tasks">>),
    ?assert(contains(Intro, <<"running task files">>)),
    ?assertNot(contains(Intro, <<"running workflow files">>)),
    ?assert(contains(QuickStart, <<"## Quick Start: Run A Task">>)),
    ?assertNot(contains(QuickStart, <<"Run A Workflow">>)),
    ?assert(contains(Doc, <<"## Task Files">>)),
    ?assertNot(contains(Doc, <<"## Workflow Files">>)),
    ?assert(contains(RunFile, <<"Soma Lisp task source">>)),
    ?assert(contains(RunFile, <<"inside this task">>)),
    ?assertNot(contains(RunFile, <<"inside this workflow">>)),
    ?assert(contains(RunFile, <<"after the task is compiled">>)),
    ?assertNot(contains(RunFile, <<"after the workflow is compiled">>)),
    ?assert(contains(BuiltInTools, <<"Task users still call them by tool name">>)),
    ?assertNot(contains(BuiltInTools, <<"Workflow users still call them by tool name">>)),
    ?assert(contains(ManageTasks, <<"The task finished successfully">>)),
    ?assertNot(contains(ManageTasks, <<"The workflow finished successfully">>)).

usage_doc_uses_task_wording_for_public_run_sections_test() ->
    test_usage_doc_uses_task_wording_for_public_run_sections().

test_usage_stdin_example_uses_task_form() ->
    Stdin = section(read_doc("docs/usage.md"), <<"### Run From Stdin">>),
    ?assert(contains(Stdin, <<"printf '(task">>)),
    ?assertNot(contains(Stdin, <<"printf '(run">>)).

usage_stdin_example_uses_task_form_test() ->
    test_usage_stdin_example_uses_task_form().

test_lfe_dsl_public_headings_use_task_wording() ->
    Doc = read_doc("docs/lfe-dsl.md"),
    ?assert(contains(Doc, <<"## Task Files">>)),
    ?assert(contains(Doc, <<"## Task Example">>)),
    ?assertNot(contains(Doc, <<"## Task Workflows">>)),
    ?assertNot(contains(Doc, <<"## Workflow Example">>)).

lfe_dsl_public_headings_use_task_wording_test() ->
    test_lfe_dsl_public_headings_use_task_wording().

test_public_task_docs_do_not_call_soma_run_inputs_workflows() ->
    Checks = [
        {"docs/lfe-dsl.md",
         <<"for `soma run` workflow files">>,
         <<"for `soma run` task files">>},
        {"docs/lfe-dsl.md",
         <<"bounded Soma Lisp workflows">>,
         <<"bounded Soma Lisp tasks">>},
        {"docs/usage.md",
         <<"Useful workflow files">>,
         <<"Useful task files">>},
        {"docs/usage.md",
         <<"workflow language syntax and diagnostics">>,
         <<"task source syntax and diagnostics">>},
        {"docs/cli.md",
         <<"Use `soma run` workflows for">>,
         <<"Use `soma run` tasks for">>},
        {"site/src/content/docs/guides/lfe-dsl.md",
         <<"bounded Soma Lisp workflows">>,
         <<"bounded Soma Lisp tasks">>}
    ],
    lists:foreach(
        fun({Path, Forbidden, Required}) ->
            Doc = read_doc(Path),
            ?assertNot(contains(Doc, Forbidden)),
            ?assert(contains(Doc, Required))
        end,
        Checks
    ).

public_task_docs_do_not_call_soma_run_inputs_workflows_test() ->
    test_public_task_docs_do_not_call_soma_run_inputs_workflows().

test_lfe_dsl_main_example_uses_task_form() ->
    Source = extract_pipeline_lfe(
        section(read_doc("docs/lfe-dsl.md"), <<"## Task Example">>)
    ),
    ?assert(starts_with(Source, <<"(task">>)),
    {ok, #{run := #{steps := Steps}}} = soma_lfe:compile(Source, #{}),
    ?assertEqual(
        [
            #{id => read,
              tool => file_read,
              args => #{path => <<"input.txt">>, root => <<"/tmp/soma-demo">>}},
            #{id => process,
              tool => echo,
              args => #{from_step => read}},
            #{id => write,
              tool => file_write,
              args => #{path => <<"output.txt">>,
                        root => <<"/tmp/soma-demo">>,
                        bytes => {from_step, process}}}
        ],
        Steps
    ).

lfe_dsl_main_example_uses_task_form_test() ->
    test_lfe_dsl_main_example_uses_task_form().

test_readme_links_task_form_contract() ->
    TestContracts = section(read_doc("README.md"), <<"**Test contracts**">>),
    ?assert(contains(
        TestContracts,
        <<"[docs/contracts/task-form-test-contract.md](docs/contracts/task-form-test-contract.md)">>
    )).

readme_links_task_form_contract_test() ->
    test_readme_links_task_form_contract().

test_lfe_dsl_documents_task_as_public_static_form() ->
    Doc = read_doc("docs/lfe-dsl.md"),
    ?assert(contains(Doc, <<"(task ...)">>)),
    ?assert(contains(Doc, <<"public static task form">>)).

lfe_dsl_documents_task_as_public_static_form_test() ->
    test_lfe_dsl_documents_task_as_public_static_form().

test_site_lfe_dsl_documents_task_as_public_static_form() ->
    Doc = read_doc("site/src/content/docs/guides/lfe-dsl.md"),
    ?assert(contains(Doc, <<"(task ...)">>)),
    ?assert(contains(Doc, <<"public static task form">>)).

site_lfe_dsl_documents_task_as_public_static_form_test() ->
    test_site_lfe_dsl_documents_task_as_public_static_form().

test_site_lfe_dsl_documents_run_as_compatibility_core_form() ->
    Doc = read_doc("site/src/content/docs/guides/lfe-dsl.md"),
    ?assert(contains(Doc, <<"(run ...)">>)),
    ?assert(contains(Doc, <<"compatibility/core run form">>)).

site_lfe_dsl_documents_run_as_compatibility_core_form_test() ->
    test_site_lfe_dsl_documents_run_as_compatibility_core_form().

test_site_lfe_dsl_mirrors_task_first_wording() ->
    Doc = read_doc("site/src/content/docs/guides/lfe-dsl.md"),
    ?assert(contains(Doc, <<"## Task Files">>)),
    ?assert(contains(Doc, <<"## Task Example">>)),
    ?assert(contains(Doc, <<"the preferred public static task surface">>)),
    ?assert(contains(
        Doc,
        <<"When a need is dynamic, keep the dynamic decision in the actor/planner layer and submit a new bounded static Soma Lisp task for each execution attempt.">>
    )),
    ?assert(contains(Doc, <<"cat > /tmp/soma-demo/pipeline.lfe <<'EOF'\n(task">>)),
    ?assertNot(contains(
        Doc,
        <<"A valid run workflow contains exactly one top-level `run` form">>
    )),
    ?assertNot(contains(Doc, <<"DSL source:\n\n```lisp\n(run">>)).

site_lfe_dsl_mirrors_task_first_wording_test() ->
    test_site_lfe_dsl_mirrors_task_first_wording().

test_lisp_messages_grammar_lists_task_form() ->
    Grammar = section(read_doc("docs/lisp-messages.md"), <<"## Grammar">>),
    ?assert(contains(Grammar, <<"(task ...)">>)),
    ?assert(contains(Grammar, <<"#{run => #{steps => [...]}}">>)).

lisp_messages_grammar_lists_task_form_test() ->
    test_lisp_messages_grammar_lists_task_form().

test_lisp_messages_records_bounded_soma_lisp_v1_slice() ->
    Slices = section(read_doc("docs/lisp-messages.md"), <<"## Slices">>),
    ?assert(contains(Slices, <<"bounded Soma Lisp v1">>)),
    ?assert(contains(Slices, <<"[done]">>)).

lisp_messages_records_bounded_soma_lisp_v1_slice_test() ->
    test_lisp_messages_records_bounded_soma_lisp_v1_slice().

test_lisp_messages_soma_run_input_is_task_source() ->
    Wire = section(read_doc("docs/lisp-messages.md"), <<"## The wire protocol speaks Lisp too">>),
    ?assert(contains(Wire, <<"`soma run` takes Soma Lisp task source">>)),
    ?assertNot(contains(Wire, <<".lfe` workflow">>)).

lisp_messages_soma_run_input_is_task_source_test() ->
    test_lisp_messages_soma_run_input_is_task_source().

test_release_sample_run_command_is_task_execution() ->
    Run = section(read_doc("docs/release.md"), <<"## Run">>),
    ?assert(contains(
        Run,
        <<"/opt/soma/bin/soma run flow.lfe  # run a task under supervision">>
    )),
    ?assertNot(contains(
        Run,
        <<"/opt/soma/bin/soma run flow.lfe  # run a workflow under supervision">>
    )).

release_sample_run_command_is_task_execution_test() ->
    test_release_sample_run_command_is_task_execution().

test_site_release_mirrors_task_wording() ->
    Run = section(read_doc("site/src/content/docs/guides/release.md"), <<"## Run">>),
    ?assert(contains(
        Run,
        <<"/opt/soma/bin/soma run flow.lfe  # run a task under supervision">>
    )),
    ?assertNot(contains(
        Run,
        <<"/opt/soma/bin/soma run flow.lfe  # run a workflow under supervision">>
    )).

site_release_mirrors_task_wording_test() ->
    test_site_release_mirrors_task_wording().

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

test_usage_wire_summary_names_task_run_requests() ->
    Wire = paragraph_starting_with(
        read_doc("docs/usage.md"),
        <<"The wire is length-prefixed Lisp s-expressions:">>
    ),
    ?assert(contains(Wire, <<"(task ...)">>)),
    ?assert(contains(Wire, <<"compatibility">>)),
    ?assert(contains(Wire, <<"(run ...)">>)).

usage_wire_summary_names_task_run_requests_test() ->
    test_usage_wire_summary_names_task_run_requests().

test_cli_request_reference_lists_task_before_run() ->
    Forms = section(read_doc("docs/cli.md"), <<"## Lisp Request Forms">>),
    ?assert(before(Forms, <<"(task">>, <<"(run">>)),
    ?assert(before(Forms, <<"(task">>, <<"(ask">>)).

cli_request_reference_lists_task_before_run_test() ->
    test_cli_request_reference_lists_task_before_run().

test_cli_opening_calls_input_task_files() ->
    Opening = paragraph_starting_with(
        read_doc("docs/cli.md"),
        <<"`soma` is the user command.">>
    ),
    ?assert(contains(Opening, <<"Soma Lisp task files">>)),
    ?assertNot(contains(Opening, <<"Lisp workflow files">>)).

cli_opening_calls_input_task_files_test() ->
    test_cli_opening_calls_input_task_files().

test_cli_stdin_section_names_dash_task_source_path() ->
    Stdin = section(read_doc("docs/cli.md"), <<"## Read From Stdin">>),
    ?assert(contains(Stdin, <<"Use `-` as the task source path">>)),
    ?assertNot(contains(Stdin, <<"workflow path">>)).

cli_stdin_section_names_dash_task_source_path_test() ->
    test_cli_stdin_section_names_dash_task_source_path().

test_cli_doc_says_run_file_reads_soma_lisp_source() ->
    Doc = read_doc("docs/cli.md"),
    ?assert(contains(
        Doc,
        <<"soma run FILE reads Soma Lisp source">>
    )).

cli_doc_says_run_file_reads_soma_lisp_source_test() ->
    test_cli_doc_says_run_file_reads_soma_lisp_source().

test_site_cli_mirrors_task_first_wording() ->
    Doc = read_doc("site/src/content/docs/guides/cli.md"),
    Commands = section(Doc, <<"## Commands">>),
    Run = section(Doc, <<"## `soma run`">>),
    ?assert(contains(Commands, <<"`soma run <task-file>`">>)),
    ?assert(contains(Commands, <<"Run a Soma Lisp task under supervision">>)),
    ?assertNot(contains(Commands, <<"`soma run <workflow>`">>)),
    ?assertNot(contains(Commands, <<"Run an LFE workflow under supervision">>)),
    ?assert(contains(Run, <<"soma run TASK_FILE [--detach]">>)),
    ?assert(contains(Run, <<"**TASK_FILE**: a task file, or `-` as the task source path">>)),
    ?assert(contains(Run, <<"Soma Lisp task source">>)),
    ?assertNot(contains(Run, <<"soma run WORKFLOW [--detach]">>)),
    ?assertNot(contains(Run, <<"**WORKFLOW**">>)).

site_cli_mirrors_task_first_wording_test() ->
    test_site_cli_mirrors_task_first_wording().

test_roadmap_marks_bounded_soma_lisp_v1_built() ->
    Track = paragraph_starting_with(
        section(read_doc("docs/roadmap.md"), <<"## Sequence">>),
        <<"Lisp    ">>
    ),
    ?assert(contains(Track, <<"bounded Soma Lisp v1">>)),
    ?assert(contains(Track, <<"public task surface">>)),
    ?assert(contains(Track, <<"[done]">>)).

roadmap_marks_bounded_soma_lisp_v1_built_test() ->
    test_roadmap_marks_bounded_soma_lisp_v1_built().

test_site_roadmap_marks_bounded_soma_lisp_v1_built() ->
    Track = paragraph_starting_with(
        section(read_doc("site/src/content/docs/reference/roadmap.md"), <<"## Sequence">>),
        <<"Lisp    ">>
    ),
    ?assert(contains(Track, <<"bounded Soma Lisp v1">>)),
    ?assert(contains(Track, <<"public task surface">>)),
    ?assert(contains(Track, <<"[done]">>)).

site_roadmap_marks_bounded_soma_lisp_v1_built_test() ->
    test_site_roadmap_marks_bounded_soma_lisp_v1_built().

test_zh_overview_links_task_form_contract() ->
    ReadingList = paragraph_starting_with(
        read_doc("docs/zh/what-is-soma.zh.md"),
        <<"- `../../README.md`">>
    ),
    ?assert(contains(ReadingList, <<"../contracts/task-form-test-contract.md">>)).

zh_overview_links_task_form_contract_test() ->
    test_zh_overview_links_task_form_contract().

test_agents_names_public_task_surface() ->
    LispState = paragraph_starting_with(
        section(read_doc("AGENTS.md"), <<"## Current State">>),
        <<"- Lisp edge language L.1-L.5 is built:">>
    ),
    ?assert(contains(LispState, <<"bounded Soma Lisp v1">>)),
    ?assert(contains(LispState, <<"public task surface">>)).

agents_names_public_task_surface_test() ->
    test_agents_names_public_task_surface().

test_cli_demo_lfe_files_compile_as_top_level_tasks() ->
    Paths = lists:sort(filelib:wildcard("examples/cli-demo/*.lfe")),
    ?assertMatch([_ | _], Paths),
    lists:foreach(
        fun(Path) ->
            Source = read_doc(Path),
            ?assertEqual({Path, true}, {Path, starts_with(Source, <<"(task">>)}),
            {ok, #{run := #{steps := [_ | _]}}} = soma_lfe:compile(Source, #{})
        end,
        Paths
    ).

cli_demo_lfe_files_compile_as_top_level_tasks_test() ->
    test_cli_demo_lfe_files_compile_as_top_level_tasks().

test_cli_demo_readme_describes_inputs_as_task_files() ->
    Doc = read_doc("examples/cli-demo/README.md"),
    ?assert(contains(Doc, <<"## The task files">>)),
    ?assert(contains(Doc, <<"Task files are Soma Lisp s-exprs">>)),
    ?assert(contains(
        Doc,
        <<"(task (let* ((id (tool name ...))) (return id)))">>
    )),
    ?assertNot(contains(Doc, <<"## The workflow files">>)),
    ?assertNot(contains(Doc, <<"Workflows are LFE s-exprs">>)),
    ?assertNot(contains(Doc, <<"(task (step <id> <tool>">>)).

cli_demo_readme_describes_inputs_as_task_files_test() ->
    test_cli_demo_readme_describes_inputs_as_task_files().

test_cli_demo_script_describes_task_run() ->
    Script = read_doc("examples/cli-demo/demo.sh"),
    ?assert(contains(
        Script,
        <<"title \"1. run a task: file_read -> echo -> file_write\"">>
    )),
    ?assertNot(contains(
        Script,
        <<"title \"1. run a workflow: file_read -> echo -> file_write\"">>
    )).

cli_demo_script_describes_task_run_test() ->
    test_cli_demo_script_describes_task_run().

test_cli_contract_describes_run_request_as_task_source() ->
    Builds = section(read_doc("docs/contracts/cli-test-contract.md"), <<"## What this slice builds">>),
    ?assert(contains(
        Builds,
        <<"The `soma run` request source is Soma Lisp task source.">>
    )).

cli_contract_describes_run_request_as_task_source_test() ->
    test_cli_contract_describes_run_request_as_task_source().

test_cli_1b_contract_describes_file_run_input_as_task_source() ->
    Doc = read_doc("docs/contracts/cli-1b-test-contract.md"),
    ?assert(contains(
        Doc,
        <<"| 8 | `soma_cli:run/1` reads Soma Lisp task source from a `.lfe` file">>
    )),
    ?assert(contains(
        Doc,
        <<"| 10 | `soma_cli:run/1` reads Soma Lisp task source from stdin when the path arg is `-`">>
    )),
    ?assertNot(contains(Doc, <<"reads the workflow from stdin">>)).

cli_1b_contract_describes_file_run_input_as_task_source_test() ->
    test_cli_1b_contract_describes_file_run_input_as_task_source().

test_cli_1b_contract_describes_stdin_run_input_as_task_source() ->
    Doc = read_doc("docs/contracts/cli-1b-test-contract.md"),
    [StdinRow] = [
        Row
     || Row <- binary:split(Doc, <<"\n">>, [global]),
        starts_with(Row, <<"| 10 |">>)
    ],
    ?assert(contains(
        StdinRow,
        <<"stdin `soma run` input is Soma Lisp task source">>
    )),
    ?assertNot(contains(StdinRow, <<"reads the workflow from stdin">>)).

cli_1b_contract_describes_stdin_run_input_as_task_source_test() ->
    test_cli_1b_contract_describes_stdin_run_input_as_task_source().
