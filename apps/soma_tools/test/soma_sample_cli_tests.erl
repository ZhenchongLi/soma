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

%% Criterion 2: the sample helper runs from a shell with no Erlang installed --
%% it is a self-contained shell script (a `#!/bin/sh` shebang), not an escript.
%% An escript carries either `#!/usr/bin/env escript` / `#!.../escript` on its
%% first line or a `%%! ` emulator-args header; a plain `#!/bin/sh` script has
%% neither, so it runs on a host with no Erlang.
test_sample_helper_is_shell_script_not_escript() ->
    {ok, Bin} = file:read_file(?HELPER_PATH),
    [FirstLine | _] = binary:split(Bin, <<"\n">>),
    ?assertEqual(<<"#!/usr/bin/env escript">>, FirstLine),
    ?assertEqual(nomatch, binary:match(Bin, <<"escript">>)),
    ?assertEqual(nomatch, binary:match(Bin, <<"%%!">>)).

sample_helper_is_shell_script_not_escript_test() ->
    test_sample_helper_is_shell_script_not_escript().
