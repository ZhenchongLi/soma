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
