-module(soma_lfe_cli_4_tests).

-include_lib("eunit/include/eunit.hrl").

test_cancel_compiles_to_cancel_command() ->
    Source = <<"(cancel \"task-id\")">>,
    Expected = {ok, #{cancel => #{task_id => <<"task-id">>}}},
    ?assertEqual(Expected, soma_lfe:compile(Source, #{})).

cancel_compiles_to_cancel_command_test() ->
    test_cancel_compiles_to_cancel_command().

test_run_detach_marker_sets_detach_true() ->
    Source = <<"(run (detach) (step s1 echo (args (text \"hi\"))))">>,
    Expected = {ok, #{run => #{steps => [#{id => s1,
                                           tool => echo,
                                           args => #{text => <<"hi">>}}],
                                detach => true}}},
    ?assertEqual(Expected, soma_lfe:compile(Source, #{})).

run_detach_marker_sets_detach_true_test() ->
    test_run_detach_marker_sets_detach_true().

test_task_detach_marker_sets_detach_true() ->
    Source = <<"(task (detach) (let* ((wait (tool sleep (ms 10)))) (return wait)))">>,
    Expected = {ok, #{run => #{steps => [#{id => wait,
                                           tool => sleep,
                                           args => #{ms => 10}}],
                                detach => true}}},
    ?assertEqual(Expected, soma_lfe:compile(Source, #{})).

task_detach_marker_sets_detach_true_test() ->
    test_task_detach_marker_sets_detach_true().
