-module(soma_cli_1_5_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/contracts/cli-test-contract.md").

%% Issue #105 criterion 5: `docs/contracts/cli-test-contract.md` gains a
%% cancel-on-disconnect proof section that maps each new assertion to its CT
%% case. The three new CT cases live in `soma_cli_server_SUITE`. The contract
%% must name a cancel-on-disconnect (CLI.1.5) section, the server CT suite, and
%% each of the three new case names.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 5: the contract names the cancel-on-disconnect section, the server
%% CT suite, and each of the three new cases.
test_doc_names_cancel_on_disconnect_section_and_cases() ->
    Doc = read_doc(),
    ?assert(byte_size(Doc) > 0),
    %% The cancel-on-disconnect (CLI.1.5) proof section marker
    ?assert(contains(Doc, <<"Cancel-on-disconnect">>)),
    ?assert(contains(Doc, <<"CLI.1.5">>)),
    %% The server CT suite that holds the three new cases
    ?assert(contains(Doc, <<"soma_cli_server_SUITE">>)),
    %% Criterion 1: disconnect drives the run to cancelled
    ?assert(contains(Doc, <<"test_run_cancelled_on_client_disconnect">>)),
    %% Criterion 2: the cancelled run's worker is dead
    ?assert(contains(Doc, <<"test_worker_dead_after_client_disconnect">>)),
    %% Criterion 3: the server serves a fresh connection after a disconnect
    ?assert(contains(Doc, <<"test_server_serves_after_client_disconnect">>)).

doc_names_cancel_on_disconnect_section_and_cases_test() ->
    test_doc_names_cancel_on_disconnect_section_and_cases().
