%% @doc Boot-time coordinator for durable interrupted run resume.
-module(soma_run_auto_resume).

-export([resume_interrupted/1]).

resume_interrupted(StorePid) ->
    RunIds = soma_event_store:interrupted_runs(StorePid),
    ok = lists:foreach(
           fun(RunId) ->
                   maybe_resume(RunId, StorePid)
           end,
           RunIds),
    ok.

maybe_resume(RunId, StorePid) ->
    case soma_run_resume:reconstruct(StorePid, RunId) of
        {ok, #{run_options :=
                   #{run_origin := runtime_default,
                     auto_resume := true}}} ->
            resume_generic(RunId, StorePid);
        _LegacyOwnerManagedOrMalformed ->
            %% Undefined legacy ownership is intentionally not guessed. Older
            %% detached CLI and generic trails are indistinguishable, so only a
            %% new explicit generic origin plus an exact boolean opt-in may run.
            ok
    end.

resume_generic(RunId, StorePid) ->
    _ResumeResult = soma_run_resume_executor:resume(
                      RunId, undefined, StorePid),
    ok.
