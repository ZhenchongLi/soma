%% soma_policy gives a normalized proposal an allow/reject verdict.
%%
%% Pure module, mirroring soma_proposal: no processes, no events, no execution.
%% The policy is a tool-name allowlist `#{allowed_tools => [atom()] | all}`. A
%% run_steps proposal is allowed when every step's tool is in the allowlist.
%% Membership is a plain value comparison (no binary<->atom normalization).
-module(soma_policy).

-export([check/2]).

-type proposal() :: map().
-type policy() :: map().
-type reason() :: term().

-spec check(proposal(), policy()) -> allow | {reject, reason()}.
check(#{kind := reply}, _Policy) ->
    allow;
check(#{kind := reject}, _Policy) ->
    allow;
check(#{kind := ask}, _Policy) ->
    allow;
check(#{kind := actor_message}, _Policy) ->
    allow;
check(#{kind := run_steps}, #{allowed_tools := all}) ->
    allow;
check(#{kind := run_steps} = Proposal, Policy) when not is_map_key(allowed_tools, Policy) ->
    check(Proposal, Policy#{allowed_tools => all});
check(#{kind := run_steps, steps := Steps}, #{allowed_tools := Allowed}) ->
    Tools = [maps:get(tool, Step) || Step <- Steps],
    case lists:all(fun(Tool) -> lists:member(Tool, Allowed) end, Tools) of
        true ->
            allow;
        false ->
            Disallowed = [Tool || Tool <- Tools, not lists:member(Tool, Allowed)],
            {reject, {tools_not_allowed, Disallowed}}
    end.
