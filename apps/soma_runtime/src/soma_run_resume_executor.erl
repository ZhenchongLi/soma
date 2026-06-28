%% @doc Resume executor: turns a resume plan into a running `soma_run' child.
%%
%% `resume/3' plans the durable trail (read-only via `soma_run_resume_plan'),
%% and on a `{resume, _}' verdict starts a fresh `soma_run' child under
%% `soma_run_sup' that continues from the not-yet-committed suffix. The new run
%% is a distinct process from the interrupted original: the original is gone, so
%% resume means a new attempt over the same `run_id', seeded with the committed
%% outputs and the pending steps the plan reconstructed.
%%
%% On an `{unsafe, _}' verdict -- a run interrupted mid-execution of a
%% non-idempotent `state' tool, where re-running could double an external effect
%% -- resume is fail-safe: it lands the run as failed (appends `run.failed') and
%% starts no `soma_run' child.
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
            soma_run_sup:start_run(Opts);
        {unsafe, StepId} ->
            soma_event_store:append(
              Store,
              #{run_id => RunId,
                step_id => StepId,
                event_type => <<"run.failed">>,
                payload => #{reason => {resume_unsafe, StepId}}}),
            {error, {resume_unsafe, StepId}};
        %% A terminal event is already on the trail (a run that finished, or one a
        %% prior unsafe resume already landed as failed): start no run, append no
        %% event, return the terminal verdict. This is what makes a repeated unsafe
        %% resume idempotent -- the trail remembers the terminal, so the second
        %% call classifies {terminal, _} before it ever looks at next_step.
        {terminal, Status} ->
            {terminal, Status};
        %% Every journal step already committed step.succeeded, but no terminal
        %% event landed: there is no pending suffix to continue. Start no run,
        %% append no event, return nothing_to_do.
        nothing_to_do ->
            nothing_to_do
    end.
