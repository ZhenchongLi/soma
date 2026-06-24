%% -*- coding: utf-8 -*-
-module(doc_compression_tests).

-include_lib("eunit/include/eunit.hrl").

-define(WHAT_IS_SOMA_PATH, "docs/zh/what-is-soma.zh.md").
-define(DESIGN_PATH, "docs/design.md").
-define(LFE_DSL_PATH, "docs/lfe-dsl.md").

read_doc(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

contains(Haystack, Needle) ->
    nomatch =/= binary:match(Haystack, Needle).

u(Str) ->
    unicode:characters_to_binary(Str, utf8).

%% Criterion 1: the five removed headings are absent from what-is-soma.zh.md.
what_is_soma_removed_headings_absent_test() ->
    Doc = read_doc(?WHAT_IS_SOMA_PATH),
    RemovedHeadings = [
        u("## 一次 run 如何执行"),
        u("## 工具系统"),
        u("## 超时、取消和失败隔离"),
        u("## 事件日志"),
        u("## 当前状态")
    ],
    lists:foreach(fun(H) -> ?assertNot(contains(Doc, H)) end, RemovedHeadings).

%% Criterion 2: the required headings and intro text are retained.
what_is_soma_required_headings_present_test() ->
    Doc = read_doc(?WHAT_IS_SOMA_PATH),
    RequiredContent = [
        u("## Soma 解决什么问题"),
        u("## `soma_actor` 与当前 runtime 的关系"),
        u("## Soma 不是什么"),
        u("## 如何继续阅读"),
        u("Soma 是一个 Erlang/OTP 原生的 agent runtime")
    ],
    lists:foreach(fun(H) -> ?assert(contains(Doc, H)) end, RequiredContent).

%% Criterion 3: ## Steps heading present in design.md; no code block in that section.
design_steps_section_no_code_block_test() ->
    Doc = read_doc(?DESIGN_PATH),
    ?assert(contains(Doc, <<"## Steps">>)),
    {Start, _} = binary:match(Doc, <<"## Steps">>),
    After = binary:part(Doc, Start + byte_size(<<"## Steps">>),
                        byte_size(Doc) - Start - byte_size(<<"## Steps">>)),
    SectionBody = case binary:match(After, <<"\n## ">>) of
        nomatch -> After;
        {NextStart, _} -> binary:part(After, 0, NextStart)
    end,
    ?assertNot(contains(SectionBody, <<"```">>)).

%% Criterion 4: ## Tool Runtime heading present in design.md; no code block in that section.
design_tool_runtime_section_no_code_block_test() ->
    Doc = read_doc(?DESIGN_PATH),
    ?assert(contains(Doc, <<"## Tool Runtime">>)),
    {Start, _} = binary:match(Doc, <<"## Tool Runtime">>),
    After = binary:part(Doc, Start + byte_size(<<"## Tool Runtime">>),
                        byte_size(Doc) - Start - byte_size(<<"## Tool Runtime">>)),
    SectionBody = case binary:match(After, <<"\n## ">>) of
        nomatch -> After;
        {NextStart, _} -> binary:part(After, 0, NextStart)
    end,
    ?assertNot(contains(SectionBody, <<"```">>)).

%% Criterion 5: ## External Processes heading present in design.md; no code block.
design_external_processes_section_no_code_block_test() ->
    Doc = read_doc(?DESIGN_PATH),
    ?assert(contains(Doc, <<"## External Processes">>)),
    {Start, _} = binary:match(Doc, <<"## External Processes">>),
    After = binary:part(Doc, Start + byte_size(<<"## External Processes">>),
                        byte_size(Doc) - Start - byte_size(<<"## External Processes">>)),
    SectionBody = case binary:match(After, <<"\n## ">>) of
        nomatch -> After;
        {NextStart, _} -> binary:part(After, 0, NextStart)
    end,
    ?assertNot(contains(SectionBody, <<"```">>)).

%% Criterion 6: ## Non-goals section in docs/lfe-dsl.md has no version-pinned phrases.
lfe_dsl_non_goals_no_version_pins_test() ->
    Doc = read_doc(?LFE_DSL_PATH),
    ?assert(contains(Doc, <<"## Non-goals">>)),
    {Start, _} = binary:match(Doc, <<"## Non-goals">>),
    After = binary:part(Doc, Start + byte_size(<<"## Non-goals">>),
                        byte_size(Doc) - Start - byte_size(<<"## Non-goals">>)),
    SectionBody = case binary:match(After, <<"\n## ">>) of
        nomatch -> After;
        {NextStart, _} -> binary:part(After, 0, NextStart)
    end,
    ?assertNot(contains(SectionBody, <<"v0.3">>)).
