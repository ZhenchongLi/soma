%% @doc Documentation proof for criterion 13: `docs/usage.md' documents
%% configuring a real OpenAI-compatible provider (the API key from an
%% environment variable, `base_url' and `model' from config) and how to run the
%% opt-in smoke test. This reads the doc file and asserts the substrings that
%% prove the criterion is documented; it opens no socket and starts no app.
-module(soma_usage_docs_tests).

-include_lib("eunit/include/eunit.hrl").

usage_md_path() ->
    filename:join([code:lib_dir(soma_runtime), "..", "..", "..", "..",
                   "docs", "usage.md"]).

read_usage_md() ->
    {ok, Bin} = file:read_file(usage_md_path()),
    Bin.

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.

test_usage_docs_real_provider_and_smoke_test() ->
    Doc = read_usage_md(),
    %% The real OpenAI-compatible provider is documented.
    ?assert(contains(Doc, <<"openai_compat">>)),
    %% The API key comes from an environment variable.
    ?assert(contains(Doc, <<"SOMA_LLM_API_KEY">>)),
    %% base_url and model come from config.
    ?assert(contains(Doc, <<"base_url">>)),
    ?assert(contains(Doc, <<"model">>)),
    %% Running the opt-in smoke test is documented.
    ?assert(contains(Doc, <<"soma_llm_smoke:run()">>)).

usage_docs_real_provider_and_smoke_test_test() ->
    test_usage_docs_real_provider_and_smoke_test().
