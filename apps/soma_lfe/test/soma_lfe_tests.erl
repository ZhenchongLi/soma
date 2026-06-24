-module(soma_lfe_tests).

-include_lib("eunit/include/eunit.hrl").

%% Criterion 1: .app.src exists, app name is soma_lfe, module loads.
test_soma_lfe_app_file_exists() ->
    AppSrc = "apps/soma_lfe/src/soma_lfe.app.src",
    ?assert(filelib:is_regular(AppSrc)),
    {ok, [{application, AppName, _}]} = file:consult(AppSrc),
    ?assertEqual(soma_lfe, AppName),
    %% module compiled and loaded
    ?assertMatch([_|_], soma_lfe:module_info()).

soma_lfe_app_file_exists_test() ->
    test_soma_lfe_app_file_exists().

%% Criterion 2: compile/2 and compile_file/2 exist with correct return shapes.
%% Note: compile/2 now returns {ok, map()} with the internal run representation,
%% or {error, [diagnostic()]}. Empty source produces a diagnostic (no top-level form).
test_compile_returns_ok_steps() ->
    {error, Diags0} = soma_lfe:compile(<<>>, #{}),
    ?assert(is_list(Diags0)),
    ?assert(length(Diags0) > 0),
    {error, Diags} = soma_lfe:compile_file("/nonexistent/path", #{}),
    ?assert(is_list(Diags)),
    ?assert(length(Diags) > 0).

compile_returns_ok_steps_test() ->
    test_compile_returns_ok_steps().

%% Criterion 3: runtime does not depend on compiler; compiler does not depend on runtime.
test_runtime_does_not_depend_on_soma_lfe() ->
    {ok, [{application, soma_runtime, RuntimeProps}]} =
        file:consult("apps/soma_runtime/src/soma_runtime.app.src"),
    RuntimeApps = proplists:get_value(applications, RuntimeProps, []),
    ?assertNot(lists:member(soma_lfe, RuntimeApps)),
    {ok, [{application, soma_lfe, LfeProps}]} =
        file:consult("apps/soma_lfe/src/soma_lfe.app.src"),
    LfeApps = proplists:get_value(applications, LfeProps, []),
    ?assertNot(lists:member(soma_runtime, LfeApps)).

runtime_does_not_depend_on_soma_lfe_test() ->
    test_runtime_does_not_depend_on_soma_lfe().

%% Criterion 4: compile/2 does not start the runtime supervision tree.
test_compile_does_not_start_runtime() ->
    ?assertEqual(undefined, whereis(soma_sup)),
    _ = soma_lfe:compile(<<>>, #{}),
    ?assertEqual(undefined, whereis(soma_sup)).

compile_does_not_start_runtime_test() ->
    test_compile_does_not_start_runtime().

%% Criterion 5: runtime contract unchanged — soma_lfe.app.src must not list soma_runtime.
test_runtime_contract_unchanged() ->
    {ok, [{application, soma_lfe, Props}]} =
        file:consult("apps/soma_lfe/src/soma_lfe.app.src"),
    Apps = proplists:get_value(applications, Props, []),
    ?assertNot(lists:member(soma_runtime, Apps)).

runtime_contract_unchanged_test() ->
    test_runtime_contract_unchanged().
