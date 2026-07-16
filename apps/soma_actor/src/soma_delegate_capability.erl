%% @doc Task-local capability admission for delegated model proposals. External
%% tool names are compared as binaries; this module never creates atoms. A
%% run_steps proposal is admitted only when every tool is in the task scope and
%% still resolves in the live registry.
-module(soma_delegate_capability).

-export([check/2, tool_schemas/2]).

-spec tool_schemas([map()], map()) -> [map()].
tool_schemas(
  Catalog,
  #{tool_policy := ToolPolicy,
    capability_scope := CapabilityScope})
  when is_list(Catalog), is_map(ToolPolicy) ->
    case normalized_scope(CapabilityScope) of
        {ok, AllowedNames} ->
            [Schema
             || Schema = #{name := Tool} <- Catalog,
                soma_policy:allows_tool(Tool, ToolPolicy),
                task_allows(Tool, AllowedNames)];
        error ->
            []
    end;
tool_schemas(_Catalog, _Scope) ->
    [].

-spec check(map(), map()) -> allow | {reject, term()}.
check(#{kind := reply}, _CapabilityScope) ->
    allow;
check(#{kind := reject}, _CapabilityScope) ->
    allow;
check(#{kind := ask}, _CapabilityScope) ->
    {reject, unsupported_delegate_proposal};
check(#{kind := actor_message}, _CapabilityScope) ->
    {reject, unsupported_delegate_proposal};
check(#{kind := run_steps, steps := Steps}, CapabilityScope) ->
    case normalized_scope(CapabilityScope) of
        {ok, AllowedNames} ->
            check_steps(Steps, AllowedNames);
        error ->
            {reject, invalid_capability_scope}
    end.

normalized_scope(#{tools := all}) ->
    {ok, all};
normalized_scope(#{tools := Tools}) when is_list(Tools) ->
    normalize_names(Tools, []);
normalized_scope(#{}) ->
    {ok, []};
normalized_scope(_InvalidScope) ->
    error.

normalize_names([], Acc) ->
    {ok, lists:usort(Acc)};
normalize_names([Name | Remaining], Acc) ->
    case external_name(Name) of
        {ok, BinaryName} ->
            normalize_names(Remaining, [BinaryName | Acc]);
        error ->
            error
    end;
normalize_names(_ImproperTail, _Acc) ->
    error.

check_steps([], _AllowedNames) ->
    allow;
check_steps([#{tool := Tool} | Remaining], AllowedNames) ->
    case task_allows(Tool, AllowedNames) of
        true ->
            case live_descriptor(Tool) of
                {ok, _Descriptor} ->
                    check_steps(Remaining, AllowedNames);
                {error, not_found} ->
                    {reject, {tool_not_found, Tool}}
            end;
        false ->
            {reject, {tool_not_in_capability_scope, Tool}}
    end.

task_allows(_Tool, all) ->
    true;
task_allows(Tool, AllowedNames) ->
    case external_name(Tool) of
        {ok, BinaryName} -> lists:member(BinaryName, AllowedNames);
        error -> false
    end.

live_descriptor(Tool) when is_atom(Tool); is_binary(Tool) ->
    soma_tool_registry:resolve_descriptor(Tool);
live_descriptor(_NonCanonicalTool) ->
    {error, not_found}.

external_name(Name) when is_atom(Name) ->
    {ok, atom_to_binary(Name, utf8)};
external_name(Name) when is_binary(Name), byte_size(Name) > 0 ->
    {ok, Name};
external_name(Name) when is_list(Name), Name =/= [] ->
    try unicode:characters_to_binary(Name) of
        BinaryName when is_binary(BinaryName), byte_size(BinaryName) > 0 ->
            {ok, BinaryName};
        _InvalidText ->
            error
    catch
        error:badarg -> error
    end;
external_name(_InvalidName) ->
    error.
