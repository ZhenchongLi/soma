-module(soma_usage_step_validation_doc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DOC_PATH, "docs/usage.md").

%% Issue #73 criterion 9: `docs/usage.md` no longer claims the actor validates a
%% `steps` list in vague terms. After decision 2b landed real up-front step
%% validation (each step must be a map carrying both `id' and `tool'), the doc
%% names what is actually checked, so the wording matches actual behavior.

read_doc() ->
    case file:read_file(?DOC_PATH) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, ?DOC_PATH, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

%% Criterion 9: the steps-validation sentence in docs/usage.md names the actual
%% checked shape — each step is a map with an `id' and a `tool' — rather than a
%% bare "the actor validates it".
test_doc_names_actual_step_validation() ->
    Doc = read_doc(),
    ?assert(contains(Doc, <<"each step is a map with `id` and `tool`">>)).

doc_names_actual_step_validation_test() ->
    test_doc_names_actual_step_validation().
