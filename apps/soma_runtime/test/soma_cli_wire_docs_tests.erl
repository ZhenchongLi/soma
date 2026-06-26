-module(soma_cli_wire_docs_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #110 criterion 13: neither `docs/cli.md' nor
%% `docs/contracts/cli-test-contract.md' describes a JSON wire for `soma run';
%% both describe the Lisp `(run ...)' request and `(result ...)' reply. CLI.1b
%% swapped the JSON wire for the all-Lisp wire — the request frame carries the
%% workflow's s-expr, the reply frame carries a rendered `(result ...)' s-expr.
%% These tests read the two docs and assert the Lisp wire is described and the
%% JSON-wire phrasing for the `soma run' wire is gone.

-define(CLI_DOC, "docs/cli.md").
-define(CONTRACT_DOC, "docs/contracts/cli-test-contract.md").

read_doc(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 13: both docs describe the Lisp `(run ...)' request and
%% `(result ...)' reply, and neither describes a length-prefixed JSON wire.
test_docs_describe_lisp_wire_not_json() ->
    Cli = read_doc(?CLI_DOC),
    Contract = read_doc(?CONTRACT_DOC),
    ?assert(byte_size(Cli) > 0),
    ?assert(byte_size(Contract) > 0),
    %% Both describe the Lisp request and reply.
    ?assert(contains(Cli, <<"(run ">>)),
    ?assert(contains(Cli, <<"(result ">>)),
    ?assert(contains(Contract, <<"(run ">>)),
    ?assert(contains(Contract, <<"(result ">>)),
    %% Neither describes a length-prefixed JSON wire for `soma run'.
    ?assertNot(contains(Cli, <<"length-prefixed JSON">>)),
    ?assertNot(contains(Contract, <<"length-prefixed JSON">>)),
    ?assertNot(contains(Cli, <<"JSON wire">>)),
    ?assertNot(contains(Contract, <<"JSON wire">>)).

docs_describe_lisp_wire_not_json_test() ->
    test_docs_describe_lisp_wire_not_json().
