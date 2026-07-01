%% @doc The `soma_runtime' application callback. Starting the application boots
%% the supervision tree via `soma_sup'.
-module(soma_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case soma_sup:start_link() of
        {ok, _SupPid} = Started ->
            maybe_resume_interrupted(),
            Started;
        Error ->
            Error
    end.

stop(_State) ->
    ok.

maybe_resume_interrupted() ->
    case application:get_env(soma_runtime, event_store_log, undefined) of
        undefined ->
            ok;
        _Path ->
            soma_run_auto_resume:resume_interrupted(event_store_pid())
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
