-module(soma_cli_md_read_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #124 (CLI.3) criterion 9: `docs/cli.md' documents `soma status' and
%% `soma trace' over the Lisp wire — the `(trace ...)' and `(status ...)'
%% requests and their replies — and records that `soma cancel <id>' and
%% `--detach' are deferred. This test reads the doc and asserts that prose is
%% present.

-define(CLI_DOC, "docs/cli.md").

read_doc(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 9: `docs/cli.md' documents status + trace over the wire and the
%% cancel / --detach deferral.
test_cli_md_documents_status_trace_and_defers_cancel_detach() ->
    Cli = read_doc(?CLI_DOC),
    ?assert(byte_size(Cli) > 0),
    %% The `(trace ...)' request and its `(trace ...)' / `(event ...)' reply.
    ?assert(contains(Cli, <<"(trace \"">>)),
    ?assert(contains(Cli, <<"(event ">>)),
    %% The `(status ...)' request and its `(status (state ...))' reply.
    ?assert(contains(Cli, <<"(status \"">>)),
    ?assert(contains(Cli, <<"(state ">>)),
    %% The deferral of `soma cancel <id>' and `--detach'.
    %% STAGED-RED: deliberately-wrong sentinel so the assertion fires before the
    %% doc is updated; corrected to the real deferral wording in the green commit.
    ?assert(contains(Cli, <<"DELIBERATELY_WRONG_SENTINEL_124">>)),
    ?assert(contains(Cli, <<"soma cancel">>)),
    ?assert(contains(Cli, <<"--detach">>)).

cli_md_documents_status_trace_and_defers_cancel_detach_test() ->
    test_cli_md_documents_status_trace_and_defers_cancel_detach().
