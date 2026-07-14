-module(soma_as4_contract_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(USAGE_DOC, "docs/usage.md").

test_usage_documents_explore_settings_and_docmod_registration() ->
    Doc = read_file(?USAGE_DOC),
    ?assert(contains(Doc, <<"explore = true">>)),
    ?assert(contains(Doc, <<"max_explore_rounds =">>)),
    ?assert(contains(Doc, <<"max_observation_bytes =">>)),
    ?assert(contains(Doc, <<"positive integers">>)),
    ?assert(contains(Doc, <<"all three explore settings">>)),
    ?assert(contains(Doc, <<"examples/docmod-tools/docmod_help.lisp">>)),
    ?assert(contains(Doc, <<"examples/docmod-tools/docmod_read.lisp">>)),
    ?assert(contains(Doc, <<"examples/docmod-tools/docmod_edit.lisp">>)),
    ?assert(contains(Doc, <<"/REPLACE/WITH/PATH/TO/docmod">>)),
    ?assert(contains(Doc,
                     <<"cp docmod_help.lisp ~/.soma/tools/docmod_help.lisp">>)),
    ?assert(contains(Doc,
                     <<"cp docmod_read.lisp ~/.soma/tools/docmod_read.lisp">>)),
    ?assert(contains(Doc,
                     <<"cp docmod_edit.lisp ~/.soma/tools/docmod_edit.lisp">>)).

usage_documents_explore_settings_and_docmod_registration_test() ->
    test_usage_documents_explore_settings_and_docmod_registration().

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).
