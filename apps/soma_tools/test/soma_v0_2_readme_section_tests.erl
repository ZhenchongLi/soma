-module(soma_v0_2_readme_section_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "README.md").

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

is_heading(<<"## ", _/binary>>) -> true;
is_heading(_) -> false.

names_v0_2(Line) ->
    contains(string:lowercase(Line), <<"v0.2">>).

%% The v0.2 section block: from the first "## " heading naming v0.2 up to the
%% next "## " heading.
v0_2_section_block(Doc) ->
    Lines = binary:split(Doc, <<"\n">>, [global]),
    case drop_until_v0_2_heading(Lines) of
        not_found -> erlang:error(v0_2_section_not_found);
        After -> iolist_to_binary(lists:join(<<"\n">>, take_until_next_section(After)))
    end.

drop_until_v0_2_heading([]) -> not_found;
drop_until_v0_2_heading([L | Rest]) ->
    case is_heading(L) andalso names_v0_2(L) of
        true -> Rest;
        false -> drop_until_v0_2_heading(Rest)
    end.

take_until_next_section([]) -> [];
take_until_next_section([L | Rest]) ->
    case is_heading(L) of
        true -> [];
        false -> [L | take_until_next_section(Rest)]
    end.

%% Criterion 13: the README has a v0.2 section that summarizes what v0.2 adds and
%% names each piece: tool manifests, the descriptor registry, and the one-shot
%% cli adapter.
test_readme_v0_2_section_names_what_v0_2_adds() ->
    Block = v0_2_section_block(read_doc()),
    Lower = string:lowercase(Block),
    ?assert(contains(Lower, <<"tool manifest">>)),
    ?assert(contains(Lower, <<"descriptor registry">>)),
    ?assert(contains(Lower, <<"cli">>)).

readme_v0_2_section_names_what_v0_2_adds_test() ->
    test_readme_v0_2_section_names_what_v0_2_adds().

%% Criterion 13: the cli adapter summary names its three load-bearing properties:
%% lifecycle teardown, failure normalization, and argv/env/cwd safety.
test_readme_v0_2_section_names_cli_adapter_properties() ->
    Block = v0_2_section_block(read_doc()),
    Lower = string:lowercase(Block),
    ?assert(contains(Lower, <<"lifecycle">>)),
    ?assert(contains(Lower, <<"failure normalization">>)),
    ?assert(contains(Lower, <<"argv">>)),
    ?assert(contains(Lower, <<"env">>)),
    ?assert(contains(Lower, <<"cwd">>)).

readme_v0_2_section_names_cli_adapter_properties_test() ->
    test_readme_v0_2_section_names_cli_adapter_properties().

%% Criterion 13: the section states what stays out of scope — the later roadmap
%% layers and the still-open Linux x86_64 + arm64 release packaging.
test_readme_v0_2_section_states_out_of_scope() ->
    Block = v0_2_section_block(read_doc()),
    Lower = string:lowercase(Block),
    ?assert(contains(Lower, <<"out of scope">>)),
    %% the still-open release packaging both architectures are named
    ?assert(contains(Lower, <<"x86_64">>)),
    ?assert(contains(Lower, <<"arm64">>)),
    %% representative later roadmap layers
    ?assert(contains(Lower, <<"dag">>)),
    ?assert(contains(Lower, <<"llm">>)).

readme_v0_2_section_states_out_of_scope_test() ->
    test_readme_v0_2_section_states_out_of_scope().

%% Criterion 13: the section links to the published contract doc.
test_readme_v0_2_section_links_contract_doc() ->
    Block = v0_2_section_block(read_doc()),
    ?assert(contains(Block, <<"docs/v0.2-test-contract.md">>)).

readme_v0_2_section_links_contract_doc_test() ->
    test_readme_v0_2_section_links_contract_doc().
