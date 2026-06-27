-module(soma_lfe_read_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion 1 — (trace "c-1") compiles to a trace command carrying the
%% correlation id, in a shape distinct from the run and ask results.
test_trace_compiles_to_trace_command() ->
    Source = <<"(trace \"c-1\")">>,
    Result = soma_lfe:compile(Source, #{}),
    Expected = {ok, #{trace => #{correlation_id => <<"c-1">>}}},
    ?assertEqual(Expected, Result).

trace_compiles_to_trace_command_test() ->
    test_trace_compiles_to_trace_command().

%% Criterion 2 — (status "t-1") compiles to a status command carrying the
%% task id, in a shape distinct from the run and ask results.
test_status_compiles_to_status_command() ->
    Source = <<"(status \"t-1\")">>,
    Result = soma_lfe:compile(Source, #{}),
    Expected = {ok, #{status => #{task_id => <<"t-1">>}}},
    ?assertEqual(Expected, Result).

status_compiles_to_status_command_test() ->
    test_status_compiles_to_status_command().
