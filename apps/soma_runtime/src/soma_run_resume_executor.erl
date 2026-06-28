%% @doc Resume executor: turns a resume plan into a running `soma_run' child.
%%
%% `resume/3' plans the durable trail (read-only via `soma_run_resume_plan'),
%% and on a `{resume, _}' verdict starts a fresh `soma_run' child under
%% `soma_run_sup' that continues from the not-yet-committed suffix. The new run
%% is a distinct process from the interrupted original: the original is gone, so
%% resume means a new attempt over the same `run_id', seeded with the committed
%% outputs and the pending steps the plan reconstructed.
-module(soma_run_resume_executor).

-export([resume/3]).

resume(RunId, Owner, Store) ->
    case soma_run_resume_plan:plan(Store, RunId) of
        {resume, #{steps := Steps,
                   pending := Pending,
                   outputs := Outputs,
                   run_options := RunOptions}} ->
            Opts = #{run_id => maps:get(run_id, RunOptions, RunId),
                     session_id => maps:get(session_id, RunOptions, undefined),
                     event_store => Store,
                     session_pid => Owner,
                     steps => Steps,
                     pending => Pending,
                     outputs => Outputs},
            soma_run_sup:start_run(Opts)
    end.
