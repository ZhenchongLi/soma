-module(soma_lfe_reject_doc_tests).

-include_lib("eunit/include/eunit.hrl").

%% Issue #138 criterion 5: the (reject (reason ...)) proposal form is documented
%% in docs/contracts/L.3-test-contract.md, docs/lfe-dsl.md, and
%% docs/lisp-messages.md. Each file must name both the reject form and its
%% reject-kind result shape, mirroring how the reply / run-steps forms are
%% already documented.

read_doc(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 5: the L.3 contract, the DSL doc, and the Lisp message doc each
%% document the (reject (reason ...)) form and its reject-kind result.
test_docs_document_reject_form() ->
    Contract = read_doc("docs/contracts/L.3-test-contract.md"),
    ?assert(contains(Contract, <<"(reject (reason ...))">>)),
    ?assert(contains(Contract, <<"test_reject_form_compiles_to_reject_kind">>)),
    ?assert(contains(Contract, <<"test_reject_form_normalizes_to_reject_kind">>)),
    ?assert(contains(Contract, <<"test_malformed_reject_form_returns_diagnostic">>)),

    Dsl = read_doc("docs/lfe-dsl.md"),
    ?assert(contains(Dsl, <<"(reject (reason \"...\"))">>)),
    ?assert(contains(Dsl, <<"kind => reject">>)),

    Messages = read_doc("docs/lisp-messages.md"),
    ?assert(contains(Messages, <<"(reject (reason \"...\"))">>)).

docs_document_reject_form_test() ->
    test_docs_document_reject_form().
