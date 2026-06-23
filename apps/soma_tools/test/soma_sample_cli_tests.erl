-module(soma_sample_cli_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%% The committed sample CLI helper, addressed off disk relative to the
%% project root (the cwd for `rebar3 eunit`). The deliverable is the file at
%% this documented location, not a runtime-resolved path.
-define(HELPER_PATH, "apps/soma_tools/priv/cli/soma_sample_upper").

%% Criterion 1: a sample CLI helper executable is committed under the
%% soma_tools app's priv/ directory at a documented location, and it carries
%% the executable bit.
test_sample_helper_committed_and_executable() ->
    ?assert(filelib:is_regular(?HELPER_PATH)),
    {ok, #file_info{mode = Mode}} = file:read_file_info(?HELPER_PATH),
    %% the owner-execute bit (8#100) is set
    ?assertEqual(8#100, Mode band 8#100).

sample_helper_committed_and_executable_test() ->
    test_sample_helper_committed_and_executable().
