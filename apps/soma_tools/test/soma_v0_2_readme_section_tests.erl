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

%% The README is written as one current-state document (no v0.1-vs-v0.2 split),
%% so these checks scan the whole README rather than a versioned section: the
%% manifest / descriptor-registry / cli capabilities, the cli adapter's
%% load-bearing properties, the out-of-scope boundary, and the contract-doc link
%% must all be documented somewhere in it.

readme_names_manifests_registry_and_cli_test() ->
    Lower = string:lowercase(read_doc()),
    ?assert(contains(Lower, <<"tool manifest">>)),
    ?assert(contains(Lower, <<"descriptor registry">>)),
    ?assert(contains(Lower, <<"cli">>)).

readme_names_cli_adapter_properties_test() ->
    Lower = string:lowercase(read_doc()),
    ?assert(contains(Lower, <<"lifecycle">>)),
    ?assert(contains(Lower, <<"failure normalization">>)),
    ?assert(contains(Lower, <<"argv">>)),
    ?assert(contains(Lower, <<"env">>)),
    ?assert(contains(Lower, <<"cwd">>)).

readme_states_out_of_scope_test() ->
    Lower = string:lowercase(read_doc()),
    ?assert(contains(Lower, <<"out of scope">>)),
    %% the still-open release packaging names both architectures
    ?assert(contains(Lower, <<"x86_64">>)),
    ?assert(contains(Lower, <<"arm64">>)),
    %% representative later roadmap layers
    ?assert(contains(Lower, <<"dag">>)),
    ?assert(contains(Lower, <<"llm">>)).

readme_links_contract_doc_test() ->
    ?assert(contains(read_doc(), <<"docs/v0.2-test-contract.md">>)).
