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
