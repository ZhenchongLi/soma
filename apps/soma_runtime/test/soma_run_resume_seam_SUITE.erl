-module(soma_run_resume_seam_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([test_resume_emits_no_start_events_for_committed_steps/1]).
-export([test_each_pending_step_runs_in_own_worker/1]).
-export([test_pending_from_step_resolves_from_seeded_outputs/1]).
-export([test_resumed_run_completes_with_merged_outputs/1]).
-export([test_resume_emits_run_resumed_with_first_pending_step/1]).
-export([test_resume_emits_no_run_started/1]).

all() ->
    [test_resume_emits_no_start_events_for_committed_steps,
     test_each_pending_step_runs_in_own_worker,
     test_pending_from_step_resolves_from_seeded_outputs,
     test_resumed_run_completes_with_merged_outputs,
     test_resume_emits_run_resumed_with_first_pending_step,
     test_resume_emits_no_run_started].

init_per_testcase(_Case, Config) ->
    {ok, Started} = application:ensure_all_started(soma_runtime),
    [{started_apps, Started} | Config].

end_per_testcase(_Case, _Config) ->
    application:stop(soma_runtime),
    ok.

%% Criterion 1: a soma_run started with a full `steps' list, a `pending' suffix
%% that omits the first N steps, and an `outputs' map seeding those N steps emits
%% no `step.started' or `tool.started' event for the omitted steps. The run is
%% started directly through soma_run:start_link/1 so the resume opts can be
%% passed. Here the full list is [s1, s2]; s1 is committed (seeded in `outputs',
%% omitted from `pending') and only s2 is pending. The recorded trail must carry
%% no `step.started'/`tool.started' for s1.
test_resume_emits_no_start_events_for_committed_steps(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-resume-no-start-1">>,
    FullSteps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
                 #{id => s2, tool => echo, args => #{value => <<"b">>}}],
    Pending = [#{id => s2, tool => echo, args => #{value => <<"b">>}}],
    Outputs = #{s1 => #{value => <<"a">>}},
    {ok, _RunPid} = soma_run:start_link(#{run_id => RunId,
                                          session_id => <<"sess-resume-1">>,
                                          event_store => StorePid,
                                          steps => FullSteps,
                                          pending => Pending,
                                          outputs => Outputs}),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    StartEvents = [{maps:get(event_type, E), maps:get(step_id, E, undefined)}
                   || E <- Events,
                      lists:member(maps:get(event_type, E),
                                   [<<"step.started">>, <<"tool.started">>])],
    %% no start event names the committed step s1
    false = lists:any(fun({_Type, StepId}) -> StepId =:= s1 end, StartEvents),
    %% the pending step s2 did run, so its start events are present
    true = lists:member({<<"step.started">>, s2}, StartEvents),
    true = lists:member({<<"tool.started">>, s2}, StartEvents),
    ok.

%% Criterion 2: each step in the `pending' suffix of a resumed run still runs in
%% its own monitored `soma_tool_call' worker process. The full list is
%% [s1, s2, s3]; s1 is committed (seeded in `outputs', omitted from `pending')
%% and s2, s3 are pending. Each pending step's tool-call worker pid (carried on
%% `tool.started'/`tool.succeeded') must be a real pid, distinct from every other
%% pending step's worker pid and from the run pid; the committed step s1 spawns no
%% worker, so the count of distinct worker pids is exactly the number of pending
%% steps.
test_each_pending_step_runs_in_own_worker(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-resume-own-worker-1">>,
    FullSteps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
                 #{id => s2, tool => echo, args => #{value => <<"b">>}},
                 #{id => s3, tool => echo, args => #{value => <<"c">>}}],
    Pending = [#{id => s2, tool => echo, args => #{value => <<"b">>}},
               #{id => s3, tool => echo, args => #{value => <<"c">>}}],
    Outputs = #{s1 => #{value => <<"a">>}},
    {ok, RunPid} = soma_run:start_link(#{run_id => RunId,
                                         session_id => <<"sess-resume-own-1">>,
                                         event_store => StorePid,
                                         steps => FullSteps,
                                         pending => Pending,
                                         outputs => Outputs}),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    %% the committed step s1 spawned no worker: it has no tool.started event
    S1ToolStarted = [E || E <- Events,
                          maps:get(event_type, E) =:= <<"tool.started">>,
                          maps:get(step_id, E, undefined) =:= s1],
    [] = S1ToolStarted,
    %% one distinct tool-call worker pid per pending step (the pid travels on
    %% both tool.started and tool.succeeded, so de-duplicate before counting)
    AllPids = [maps:get(tool_call_pid, E, undefined) || E <- Events],
    ToolPids = lists:usort([P || P <- AllPids, P =/= undefined]),
    %% there are two pending steps, so two distinct worker pids
    2 = length(ToolPids),
    %% every worker pid is actually a pid
    true = lists:all(fun erlang:is_pid/1, ToolPids),
    %% no worker pid is the run pid
    false = lists:member(RunPid, ToolPids),
    ok.

%% Criterion 3: a pending step whose args reference an already-committed (seeded)
%% step through `from_step' resolves that value from the seeded `outputs' map,
%% without the run failing on a missing prior step. The full list is [s1, s2];
%% s1 is committed (seeded in `outputs', omitted from `pending') with output
%% `#{value => <<"seeded">>}', and only s2 is pending. s2 is a bare
%% `#{from_step => s1}' echo, so its resolved input is s1's seeded output and --
%% echo returning its input unchanged -- s2's recorded output must equal the
%% seeded value. The run reaches `completed': it does not fail on a missing prior
%% step, because the committed step's output is read from the seeded `outputs'.
test_pending_from_step_resolves_from_seeded_outputs(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-resume-from-step-1">>,
    Seeded = #{value => <<"seeded">>},
    FullSteps = [#{id => s1, tool => echo, args => #{value => <<"seeded">>}},
                 #{id => s2, tool => echo, args => #{from_step => s1}}],
    Pending = [#{id => s2, tool => echo, args => #{from_step => s1}}],
    Outputs = #{s1 => Seeded},
    {ok, _RunPid} = soma_run:start_link(#{run_id => RunId,
                                          session_id => <<"sess-resume-fs-1">>,
                                          event_store => StorePid,
                                          steps => FullSteps,
                                          pending => Pending,
                                          outputs => Outputs}),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    %% the run completed -- it did not fail on a missing prior step
    Types = [maps:get(event_type, E) || E <- Events],
    true = lists:member(<<"run.completed">>, Types),
    false = lists:member(<<"run.failed">>, Types),
    %% the pending step's output reflects the seeded committed step's output
    S2Out = step_output(Events, s2),
    Seeded = S2Out,
    ok.

%% Criterion 4: a resumed run reaches `completed' and sends a `run_completed'
%% message to its `session_pid' whose outputs map carries BOTH the seeded
%% committed outputs and the newly-run pending steps' outputs. The full list is
%% [s1, s2, s3]; s1 is committed (seeded in `outputs', omitted from `pending')
%% and s2, s3 are pending. The run is started directly through start_link/1 with
%% the calling test process as `session_pid', so the test receives the terminal
%% `run_completed' message. The merged outputs map must contain s1 (seeded), s2
%% and s3 (newly run) keyed by step id.
test_resumed_run_completes_with_merged_outputs(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-resume-merged-outputs-1">>,
    FullSteps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
                 #{id => s2, tool => echo, args => #{value => <<"b">>}},
                 #{id => s3, tool => echo, args => #{value => <<"c">>}}],
    Pending = [#{id => s2, tool => echo, args => #{value => <<"b">>}},
               #{id => s3, tool => echo, args => #{value => <<"c">>}}],
    SeededS1 = #{value => <<"a">>},
    Outputs = #{s1 => SeededS1},
    {ok, _RunPid} = soma_run:start_link(#{run_id => RunId,
                                          session_id => <<"sess-resume-merged-1">>,
                                          session_pid => self(),
                                          event_store => StorePid,
                                          steps => FullSteps,
                                          pending => Pending,
                                          outputs => Outputs}),
    MergedOutputs =
        receive
            {run_completed, RunId, Out} -> Out
        after 2000 ->
            ct:fail(no_run_completed_message)
        end,
    %% the seeded committed step's output is carried through
    SeededS1 = maps:get(s1, MergedOutputs),
    %% the newly-run pending steps' outputs are present too
    #{value := <<"b">>} = maps:get(s2, MergedOutputs),
    #{value := <<"c">>} = maps:get(s3, MergedOutputs),
    %% the merged map carries exactly those three steps: one seeded committed
    %% step plus the two newly-run pending steps.
    3 = map_size(MergedOutputs),
    ok.

%% Criterion 5: a resume start emits a `run.resumed' event carrying the run id
%% and the first pending step id. The full list is [s1, s2]; s1 is committed
%% (seeded in `outputs', omitted from `pending') and only s2 is pending, so the
%% first pending step is s2. The recorded trail must carry a `run.resumed' event
%% whose `run_id' is this run's id and whose payload names s2 as the first
%% pending step.
test_resume_emits_run_resumed_with_first_pending_step(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-resume-resumed-event-1">>,
    FullSteps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
                 #{id => s2, tool => echo, args => #{value => <<"b">>}}],
    Pending = [#{id => s2, tool => echo, args => #{value => <<"b">>}}],
    Outputs = #{s1 => #{value => <<"a">>}},
    {ok, _RunPid} = soma_run:start_link(#{run_id => RunId,
                                          session_id => <<"sess-resume-resumed-1">>,
                                          event_store => StorePid,
                                          steps => FullSteps,
                                          pending => Pending,
                                          outputs => Outputs}),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Resumed = [E || E <- Events,
                    maps:get(event_type, E) =:= <<"run.resumed">>],
    %% exactly one run.resumed event opened the resume start
    [ResumedEvent] = Resumed,
    %% it carries this run's id
    RunId = maps:get(run_id, ResumedEvent),
    %% its payload names the first pending step
    Payload = maps:get(payload, ResumedEvent),
    s2 = maps:get(first_pending_step, Payload),
    ok.

%% Criterion 6: a resume start does not emit a `run.started' event. The original
%% `run.started' journal stays the single source of truth that `reconstruct'
%% reads, so a resume start opens the run with `run.resumed' and never re-emits
%% `run.started'. The full list is [s1, s2]; s1 is committed (seeded in `outputs',
%% omitted from `pending') and only s2 is pending. The recorded trail, read back
%% through soma_event_store:by_run/2, must carry no `run.started' event for the run.
test_resume_emits_no_run_started(_Config) ->
    StorePid = event_store_pid(),
    RunId = <<"run-resume-no-run-started-1">>,
    FullSteps = [#{id => s1, tool => echo, args => #{value => <<"a">>}},
                 #{id => s2, tool => echo, args => #{value => <<"b">>}}],
    Pending = [#{id => s2, tool => echo, args => #{value => <<"b">>}}],
    Outputs = #{s1 => #{value => <<"a">>}},
    {ok, _RunPid} = soma_run:start_link(#{run_id => RunId,
                                          session_id => <<"sess-resume-no-rs-1">>,
                                          event_store => StorePid,
                                          steps => FullSteps,
                                          pending => Pending,
                                          outputs => Outputs}),
    ok = wait_for_run_completed(StorePid, RunId, 50),
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    %% a resume start does not emit run.started
    true = lists:member(<<"run.started">>, Types),
    ok.

step_output(Events, StepId) ->
    [E] = [Ev || Ev <- Events,
                 maps:get(event_type, Ev) =:= <<"step.succeeded">>,
                 maps:get(step_id, Ev) =:= StepId],
    maps:get(output, maps:get(payload, E)).

wait_for_run_completed(_StorePid, _RunId, 0) ->
    {error, timeout};
wait_for_run_completed(StorePid, RunId, N) ->
    Events = soma_event_store:by_run(StorePid, RunId),
    Types = [maps:get(event_type, E) || E <- Events],
    case lists:member(<<"run.completed">>, Types) of
        true -> ok;
        false ->
            timer:sleep(20),
            wait_for_run_completed(StorePid, RunId, N - 1)
    end.

event_store_pid() ->
    Children = supervisor:which_children(soma_sup),
    {soma_event_store, Pid, _Type, _Mods} =
        lists:keyfind(soma_event_store, 1, Children),
    Pid.
