-module(soma_lfe_proposal_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion 1 — (reply (text "hi")) parses through soma_lfe:compile/2 into a
%% proposal map that soma_proposal:normalize/1 tags kind => reply with the text
%% as a binary. The real parser boundary is exercised end to end; no layer is
%% bypassed.
test_reply_form_normalizes_to_reply_kind() ->
    Source = <<"(reply (text \"hi\"))">>,
    {ok, ProposalMap} = soma_lfe:compile(Source, #{}),
    {ok, Normalized} = soma_proposal:normalize(ProposalMap),
    ?assertEqual(reply, maps:get(kind, Normalized)),
    ?assertEqual(<<"hi">>, maps:get(text, Normalized)).

reply_form_normalizes_to_reply_kind_test() ->
    test_reply_form_normalizes_to_reply_kind().

%% Criterion 2 — (run-steps (step (id s1) (tool echo) (args (value "hi"))))
%% parses through soma_lfe:compile/2 into a proposal map that
%% soma_proposal:normalize/1 tags kind => run_steps with the equivalent step
%% list (an echo step with id s1 and the "hi" arg). The real parser boundary is
%% exercised end to end; the step parser is the same one the run path uses.
test_run_steps_form_normalizes_with_equivalent_steps() ->
    Source = <<"(run-steps (step (id s1) (tool echo) (args (value \"hi\"))))">>,
    {ok, ProposalMap} = soma_lfe:compile(Source, #{}),
    ?assertEqual(run_steps, maps:get(kind, ProposalMap)),
    [Step] = maps:get(steps, ProposalMap),
    ?assertEqual(s1, maps:get(id, Step)),
    ?assertEqual(echo, maps:get(tool, Step)),
    ?assertEqual(#{value => <<"hi">>}, maps:get(args, Step)),
    {ok, Normalized} = soma_proposal:normalize(ProposalMap),
    ?assertEqual(run_steps, maps:get(kind, Normalized)),
    ?assertEqual([Step], maps:get(steps, Normalized)).

run_steps_form_normalizes_with_equivalent_steps_test() ->
    test_run_steps_form_normalizes_with_equivalent_steps().
