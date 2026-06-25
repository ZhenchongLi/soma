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

-export([perform_call/1]).

%% Run one mock call from its `llm' directive map and return the result. The
%% `success' directive returns the configured `output' verbatim; no network is
%% touched.
perform_call(#{directive := success, output := Output}) ->
    {ok, Output}.
