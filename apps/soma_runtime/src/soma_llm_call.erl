%% @doc Disposable per-LLM-call worker. v0.5.1 stands up only the call seam: the
%% actual call lives in the single function `perform_call/1' so that when a real
%% provider lands, that one point grows the provider seam and mock logic does not
%% scatter across the worker.
%%
%% The mock is directive-driven. For v0.5.1 criterion 1 it handles the `success'
%% directive: it returns the configured output, and it opens no socket -- so there
%% is no network call to make. The `slow' / `crash' / `hang' directives and the
%% actor-facing start/reply mechanics are later cycles.
-module(soma_llm_call).

-export([start/1]).
-export([perform_call/1]).

%% Start a disposable worker process that runs one mock call and reports its
%% result back to the owner, mirroring how soma_run owns a soma_tool_call worker.
%% Opts carries the owner pid, the minted `llm_call_id', and the `llm' directive
%% map. The worker runs `perform_call/1' (the single call seam) and sends the
%% owner `{llm_result, LlmCallId, self(), Result}', then exits normally. Returns
%% `{ok, WorkerPid}' so the owner can monitor the worker -- the pid is distinct
%% from the owner because the call crosses a process boundary.
start(#{owner := Owner, llm_call_id := LlmCallId, llm := Llm}) ->
    WorkerPid = spawn(fun() ->
                              Result = perform_call(Llm),
                              Owner ! {llm_result, LlmCallId, self(), Result}
                      end),
    {ok, WorkerPid}.

%% Run one mock call from its `llm' directive map and return the result. The
%% `success' directive returns the configured `output' verbatim; no network is
%% touched.
perform_call(#{directive := success, output := Output}) ->
    {ok, Output};
%% The `slow' directive runs past the call timeout: it blocks indefinitely,
%% ignoring the actor's call-timeout timer entirely. This proves the owner, not
%% the worker, enforces the bound -- the actor's timer fires and kills the worker.
perform_call(#{directive := slow}) ->
    receive
        _ -> never
    end;
%% The `hang' directive blocks until the worker is killed, modelling a call that
%% is in flight when the owner cancels it. Like `slow' it never returns on its
%% own; the actor's cancel path kills the worker (exit(WorkerPid, kill)).
perform_call(#{directive := hang}) ->
    receive
        _ -> never
    end;
%% The `crash' directive makes the worker die abnormally, modelling a call that
%% blows up mid-flight (a provider client throwing, a bad decode). It never sends
%% the owner a result; the worker's non-`normal' exit reaches the actor as the
%% monitor's `'DOWN'', which the actor records as a `failed' task -- the call
%% crossing a process boundary turns a crash into data, not a stuck `running'.
perform_call(#{directive := crash}) ->
    exit(llm_call_crashed).
