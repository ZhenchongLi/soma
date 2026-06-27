-module(soma_cli_md_ask_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #122 (CLI.2) criterion 8: `docs/cli.md' documents the finalized
%% `soma ask' flow — the Lisp `(ask ...)' request (with `(intent ...)',
%% `(allow ...)', `(budget-llm N)', `(budget-steps N)'), the `(result ...)'
%% reply carrying the reply text under `(outputs ...)', the `rejected' and
%% `budget_exceeded' outcomes, and that the mock `model_config' is the gate
%% default while the real provider is configured at the daemon
%% (mock-on-gate vs real-provider-by-config). This test reads the doc and
%% asserts that prose is present.

-define(CLI_DOC, "docs/cli.md").

read_doc(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 8: `docs/cli.md' documents the finalized `soma ask' flow.
test_cli_md_documents_ask_flow() ->
    Cli = read_doc(?CLI_DOC),
    ?assert(byte_size(Cli) > 0),
    %% The `(ask ...)' request form and its sub-forms.
    ?assert(contains(Cli, <<"(ask ">>)),
    ?assert(contains(Cli, <<"(intent ">>)),
    ?assert(contains(Cli, <<"(allow ">>)),
    ?assert(contains(Cli, <<"(budget-llm ">>)),
    ?assert(contains(Cli, <<"(budget-steps ">>)),
    %% The `(result ...)' reply with reply text under `(outputs ...)'.
    ?assert(contains(Cli, <<"(result ">>)),
    ?assert(contains(Cli, <<"(outputs ">>)),
    %% The `rejected' and `budget_exceeded' outcomes.
    ?assert(contains(Cli, <<"rejected">>)),
    ?assert(contains(Cli, <<"budget_exceeded">>)),
    %% Mock-on-gate vs real-provider-by-config.
    ?assert(contains(Cli, <<"mock-on-gate">>)),
    ?assert(contains(Cli, <<"real-provider-by-config">>)).

cli_md_documents_ask_flow_test() ->
    test_cli_md_documents_ask_flow().
