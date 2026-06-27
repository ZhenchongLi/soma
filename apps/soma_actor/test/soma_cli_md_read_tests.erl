-module(soma_cli_md_read_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #124 (CLI.3) criterion 9: `docs/cli.md' documents `soma status' and
%% `soma trace' over the Lisp wire — the `(trace ...)' and `(status ...)'
%% requests and their replies. This test reads the doc and asserts that prose is
%% present.

-define(CLI_DOC, "docs/cli.md").

read_doc(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 9: `docs/cli.md' documents status + trace over the wire.
test_cli_md_documents_status_trace_and_defers_cancel_detach() ->
    Cli = read_doc(?CLI_DOC),
    ?assert(byte_size(Cli) > 0),
    %% The `(trace ...)' request and its `(trace ...)' / `(event ...)' reply.
    ?assert(contains(Cli, <<"(trace \"">>)),
    ?assert(contains(Cli, <<"(event ">>)),
    %% The `(status ...)' request and its `(status (state ...))' reply.
    ?assert(contains(Cli, <<"(status \"">>)),
    ?assert(contains(Cli, <<"(state ">>)).

cli_md_documents_status_trace_and_defers_cancel_detach_test() ->
    test_cli_md_documents_status_trace_and_defers_cancel_detach().

%% Criterion #17 (CLI.4): `docs/cli.md' documents detached runs and cancel-by-id
%% as implemented behavior, not as CLI.3-deferred work.
test_cli_md_documents_detach_and_cancel_not_deferred() ->
    Cli = read_doc(?CLI_DOC),
    ?assert(byte_size(Cli) > 0),
    ?assert(contains(Cli, <<"--detach">>)),
    ?assert(contains(Cli, <<"soma cancel <task-id>">>)),
    ?assert(contains(Cli, <<"(accepted ">>)),
    ?assert(contains(Cli, <<"(cancel \"">>)),
    ?assertEqual(false, contains(Cli, <<"### Deferred in CLI.3">>)),
    ?assertEqual(false, contains(Cli, <<"are **deferred**">>)),
    ?assertEqual(false, contains(Cli, <<"nor `--detach` is implemented">>)).

cli_md_documents_detach_and_cancel_not_deferred_test() ->
    test_cli_md_documents_detach_and_cancel_not_deferred().
