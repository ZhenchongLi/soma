-module(soma_lfe_message_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion 1 — (msg ...) with type/payload/steps parses to the
%% hand-written envelope map.
test_msg_form_produces_envelope_map() ->
    Source = <<"(msg (type chat) (payload \"hi\") "
               "(steps (step (id s1) (tool echo) (args (value \"hi\")))))">>,
    {ok, Envelope} = soma_lfe:compile(Source, #{}),
    Expected = #{type => chat,
                 payload => <<"hi">>,
                 steps => [#{id => s1,
                             tool => echo,
                             args => #{value => <<"hi">>}}]},
    ?assertEqual(Expected, Envelope).

msg_form_produces_envelope_map_test() ->
    test_msg_form_produces_envelope_map().

%% Criterion 2 — (msg ...) carrying (correlation-id "c-1") and an (llm ...)
%% sub-form fills the envelope's correlation_id and llm fields.
test_msg_form_carries_correlation_id_and_llm() ->
    Source = <<"(msg (type chat) (payload \"hi\") "
               "(correlation-id \"c-1\") "
               "(llm (provider \"openai\") (model \"gpt-4\")))">>,
    {ok, Envelope} = soma_lfe:compile(Source, #{}),
    ?assertEqual(<<"c-1">>, maps:get(correlation_id, Envelope)),
    ?assertEqual(#{provider => <<"openai">>, model => <<"gpt-4">>},
                 maps:get(llm, Envelope)).

msg_form_carries_correlation_id_and_llm_test() ->
    test_msg_form_carries_correlation_id_and_llm().

%% Criterion 3 — a malformed (msg ...) form (an unknown sub-form, or a
%% missing required type/payload) returns {error, [Diagnostic]} in the
%% existing soma_lfe diagnostic shape, with no crash.
test_malformed_msg_returns_diagnostics() ->
    %% Unknown sub-form.
    UnknownSource = <<"(msg (type chat) (payload \"hi\") (bogus 1))">>,
    UnknownResult = soma_lfe:compile(UnknownSource, #{}),
    ?assertMatch({error, [_ | _]}, UnknownResult),
    {error, [UnknownDiag | _]} = UnknownResult,
    ?assert(maps:is_key(message, UnknownDiag)),
    ?assert(maps:is_key(line, UnknownDiag)),

    %% Missing required payload.
    MissingSource = <<"(msg (type chat))">>,
    MissingResult = soma_lfe:compile(MissingSource, #{}),
    ?assertMatch({error, [_ | _]}, MissingResult),
    {error, [MissingDiag | _]} = MissingResult,
    ?assert(maps:is_key(message, MissingDiag)),
    ?assert(maps:is_key(line, MissingDiag)).

malformed_msg_returns_diagnostics_test() ->
    test_malformed_msg_returns_diagnostics().

%% Criterion 4 — a top-level (run ...) form still returns
%% {ok, #{run => #{steps => Steps}}} in the pre-slice shape: the (msg ...)
%% path added in this slice is additive, not a replacement.
test_run_form_unchanged_after_msg_added() ->
    Source = <<"(run (step s1 echo (args (value \"hi\"))))">>,
    {ok, Compiled} = soma_lfe:compile(Source, #{}),
    Expected = #{run => #{steps => [#{id => s1,
                                      tool => echo,
                                      args => #{value => <<"WRONG">>}}]}},
    ?assertEqual(Expected, Compiled).

run_form_unchanged_after_msg_added_test() ->
    test_run_form_unchanged_after_msg_added().
