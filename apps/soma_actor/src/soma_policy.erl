%% soma_policy gives a normalized proposal an allow/reject verdict.
%%
%% Pure module, mirroring soma_proposal: no processes, no events, no execution.
%% The policy is a tool-name allowlist `#{allowed_tools => [atom()] | all}`. A
%% run_steps proposal is allowed when every step's tool is in the allowlist.
%% Membership is a plain value comparison (no binary<->atom normalization).
-module(soma_policy).

-export([check/2, allows_tool/2]).

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
check(#{kind := run_steps, steps := Steps}, Policy) when is_map(Policy) ->
    Tools = [maps:get(tool, Step) || Step <- Steps],
    case lists:all(fun(Tool) -> allows_tool(Tool, Policy) end, Tools) of
        true ->
            allow;
        false ->
            Disallowed =
                [Tool || Tool <- Tools,
                         not allows_tool(Tool, Policy)],
            {reject, {tools_not_allowed, Disallowed}}
    end.

-spec allows_tool(term(), policy()) -> boolean().
allows_tool(_Tool, #{allowed_tools := all}) ->
    true;
allows_tool(_Tool, Policy) when not is_map_key(allowed_tools, Policy) ->
    true;
allows_tool(Tool, #{allowed_tools := Allowed}) when is_list(Allowed) ->
    lists:member(Tool, Allowed);
allows_tool(_Tool, _Policy) ->
    false.
