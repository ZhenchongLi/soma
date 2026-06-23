%% @doc Shared sandbox-containment logic for the file tools. Both file_read and
%% file_write resolve their input path against the sandbox root through this
%% module so they enforce the same rule: a path that escapes the root through
%% `..` traversal is rejected before the filesystem is touched.
-module(soma_tool_file).

-export([resolve_under_root/2]).

%% @doc Resolve `Path' against `Root' and confirm the result still sits under
%% the root once `..' segments are accounted for. Returns `{ok, Full}' with the
%% joined path when contained, `{error, escapes_root}' when the path climbs out.
-spec resolve_under_root(file:name_all(), file:name_all()) ->
    {ok, file:filename_all()} | {error, escapes_root}.
resolve_under_root(Root, Path) ->
    case filelib:safe_relative_path(Path, Root) of
        unsafe ->
            {error, escapes_root};
        Safe ->
            {ok, filename:join(Root, Safe)}
    end.
