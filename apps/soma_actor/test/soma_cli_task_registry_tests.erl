%% @doc CLI.4 live-task registry proofs.
-module(soma_cli_task_registry_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion #4: a task entry registered by a short-lived process remains owned
%% by, and readable from, the registry after the registering process exits.
test_registered_task_survives_registering_process_exit() ->
    {ok, Registry} = soma_cli_task_registry:start_link(),
    try
        TaskId = <<"task-registry-survival">>,
        Task = #{pid => self(),
                 status => running,
                 correlation_id => <<"corr-registry-survival">>},
        Parent = self(),
        {Registrar, Ref} = spawn_monitor(
                             fun() ->
                                     Result = soma_cli_task_registry:register(TaskId, Task),
                                     Parent ! {registered, self(), Result}
                             end),

        receive
            {registered, Registrar, ok} ->
                ok
        after 1000 ->
                ?assert(false)
        end,
        receive
            {'DOWN', Ref, process, Registrar, normal} ->
                ok;
            {'DOWN', Ref, process, Registrar, Reason} ->
                ?assertEqual(normal, Reason)
        after 1000 ->
                ?assert(false)
        end,

        ?assertEqual({ok, Task}, soma_cli_task_registry:lookup(TaskId))
    after
        unlink(Registry),
        exit(Registry, shutdown)
    end.

registered_task_survives_registering_process_exit_test() ->
    test_registered_task_survives_registering_process_exit().
