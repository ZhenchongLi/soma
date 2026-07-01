-module(soma_lfe_task_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

read_doc(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

test_contract_names_task_compile_cases() ->
    Doc = read_doc("docs/contracts/task-form-test-contract.md"),
    lists:foreach(
        fun(Token) ->
            ?assert(contains(Doc, Token))
        end,
        [
            <<"soma_lfe_task_tests">>,
            <<"test_task_compiles_to_run_steps">>,
            <<"test_bare_from_lowers_to_from_step">>,
            <<"test_field_from_lowers_to_from_step_tuple">>,
            <<"test_timeout_ms_lowers_to_step_timeout_ms">>,
            <<"test_duplicate_binding_returns_diagnostic">>,
            <<"test_forward_from_binding_returns_diagnostic">>,
            <<"test_unsupported_task_control_heads_return_diagnostic">>
        ]
    ).

contract_names_task_compile_cases_test() ->
    test_contract_names_task_compile_cases().

test_contract_names_task_doc_cases() ->
    Doc = read_doc("docs/contracts/task-form-test-contract.md"),
    lists:foreach(
        fun(Token) ->
            ?assert(contains(Doc, Token))
        end,
        [
            <<"soma_lfe_task_doc_tests">>,
            <<"test_site_quick_start_task_example_compiles">>,
            <<"test_readme_quick_start_uses_task_example">>,
            <<"test_lfe_dsl_documents_task_as_public_static_form">>,
            <<"test_lfe_dsl_documents_run_as_compatibility_core_form">>,
            <<"test_lfe_dsl_includes_dynamic_need_sentence">>,
            <<"test_design_documents_soma_lisp_boundary">>,
            <<"test_usage_doc_says_run_file_reads_soma_lisp_source">>,
            <<"test_usage_wire_summary_names_task_run_requests">>,
            <<"test_cli_request_reference_lists_task_before_run">>,
            <<"test_cli_doc_says_run_file_reads_soma_lisp_source">>,
            <<"test_roadmap_marks_bounded_soma_lisp_v1_built">>,
            <<"test_site_roadmap_marks_bounded_soma_lisp_v1_built">>,
            <<"test_lisp_messages_grammar_lists_task_form">>,
            <<"test_lisp_messages_records_bounded_soma_lisp_v1_slice">>,
            <<"test_zh_overview_links_task_form_contract">>,
            <<"test_agents_names_public_task_surface">>
        ]
    ).

contract_names_task_doc_cases_test() ->
    test_contract_names_task_doc_cases().

test_contract_names_task_wording_doc_cases() ->
    Doc = read_doc("docs/contracts/task-form-test-contract.md"),
    lists:foreach(
        fun(Token) ->
            ?assert(contains(Doc, Token))
        end,
        [
            <<"test_site_quick_start_presents_soma_lisp_tasks">>,
            <<"test_readme_quick_start_names_soma_run_input_task_source">>,
            <<"test_readme_docs_index_calls_usage_task_file_guide">>,
            <<"test_usage_doc_uses_task_wording_for_public_run_sections">>,
            <<"test_usage_stdin_example_uses_task_form">>,
            <<"test_lfe_dsl_public_headings_use_task_wording">>,
            <<"test_lfe_dsl_main_example_uses_task_form">>,
            <<"test_readme_links_task_form_contract">>,
            <<"test_site_lfe_dsl_documents_task_as_public_static_form">>,
            <<"test_site_lfe_dsl_documents_run_as_compatibility_core_form">>,
            <<"test_site_lfe_dsl_mirrors_task_first_wording">>,
            <<"test_lisp_messages_soma_run_input_is_task_source">>,
            <<"test_release_sample_run_command_is_task_execution">>,
            <<"test_site_release_mirrors_task_wording">>,
            <<"test_cli_opening_calls_input_task_files">>,
            <<"test_cli_stdin_section_names_dash_task_source_path">>,
            <<"test_site_cli_mirrors_task_first_wording">>,
            <<"test_cli_demo_lfe_files_compile_as_top_level_tasks">>,
            <<"test_cli_demo_readme_describes_inputs_as_task_files">>,
            <<"test_cli_demo_script_describes_task_run">>,
            <<"test_cli_contract_describes_run_request_as_task_source">>,
            <<"test_cli_1b_contract_describes_file_run_input_as_task_source">>,
            <<"test_cli_1b_contract_describes_stdin_run_input_as_task_source">>
        ]
    ).

contract_names_task_wording_doc_cases_test() ->
    test_contract_names_task_wording_doc_cases().

test_contract_names_cli_demo_task_case() ->
    Doc = read_doc("docs/contracts/task-form-test-contract.md"),
    ?assert(contains(
        Doc,
        <<"| CLI demo `.lfe` files use top-level `(task ...)` forms. | `test_cli_demo_lfe_files_compile_as_top_level_tasks` |">>
    )).

contract_names_cli_demo_task_case_test() ->
    test_contract_names_cli_demo_task_case().
