%% @doc Boot-time coordinator for durable interrupted run resume.
-module(soma_run_auto_resume).

-export([resume_interrupted/1]).

resume_interrupted(StorePid) ->
    RunIds = soma_event_store:interrupted_runs(StorePid),
    [soma_run_resume_executor:resume(RunId, undefined, StorePid)
     || RunId <- RunIds],
    ok.
