%% @doc Real OpenAI-compatible LLM provider behind the `soma_llm_call' seam.
%% v0.6.x node B.1. `build_request/1' is the pure request-shaping function: it
%% takes a config-plus-opts map and returns the pieces of an HTTP POST (the url,
%% the headers, and the JSON-encoded body) -- it sends nothing. The url is
%% `{base_url}/chat/completions'. The impure `httpc' call and `parse_response/1'
%% are later cycles.
-module(soma_llm_openai).

-export([build_request/1, request_http_options/1, parse_response/1, chat/1]).

-define(DEFAULT_OPENAI_REQUEST_TIMEOUT_MS, 60000).

%% Build the pieces of the chat-completions POST from a config map. Pure: it
%% opens no socket. The url is the configured `base_url' with `/chat/completions'
%% appended; the body is `json:encode/1' of a map carrying `model' and
%% `messages'.
build_request(#{base_url := BaseUrl, api_key := ApiKey,
                model := Model, messages := Messages} = Config) ->
    Url = <<BaseUrl/binary, "/chat/completions">>,
    Headers = [{"Authorization", "Bearer " ++ binary_to_list(ApiKey)}],
    BodyMap0 = #{model => Model, messages => Messages},
    BodyMap = add_optional_opts(BodyMap0, Config),
    Body = iolist_to_binary(json:encode(BodyMap)),
    #{url => Url, headers => Headers, body => Body}.

%% Copy `enable_thinking' and `max_tokens' into the body map only when the
%% caller supplied them, leaving the body without those keys otherwise.
add_optional_opts(BodyMap, Config) ->
    lists:foldl(
      fun(Key, Acc) ->
              case maps:find(Key, Config) of
                  {ok, Value} -> Acc#{Key => Value};
                  error -> Acc
              end
      end,
      BodyMap,
      [enable_thinking, max_tokens]).

request_http_options(Config) ->
    TimeoutMs =
        maps:get(request_timeout_ms, Config,
                 ?DEFAULT_OPENAI_REQUEST_TIMEOUT_MS),
    [{timeout, TimeoutMs}].

%% Map a raw HTTP response (status plus body) to a reply proposal. On a 200 it
%% decodes the body and pulls `choices[0].message.content' as the reply text,
%% returning `{ok, #{kind => reply, text => Content}}'. Every other case maps to
%% a bounded, named `{error, Reason}' -- a non-200 status, a body that is not
%% valid JSON (`json:decode/1' can throw), and a 200 body that decodes but lacks
%% the `choices[0].message.content' path all stay inside the function rather than
%% escaping as a crash. The provider blob is never returned raw.
parse_response({200, Body}) ->
    try
        Decoded = json:decode(Body),
        #{<<"choices">> :=
              [#{<<"message">> := #{<<"content">> := Content}} | _]} = Decoded,
        {ok, #{kind => reply, text => Content}}
    catch
        error:{badmatch, _} ->
            {error, {unexpected_response_shape, missing_content}};
        _:_ ->
            {error, {malformed_response_body, undecodable}}
    end;
parse_response({Status, _Body}) ->
    {error, {http_status, Status}}.

%% The build-then-parse path the `soma_llm_call' seam routes to: it shapes the
%% request from the config and parses the chat-completions response into a reply
%% proposal (or a bounded error). The impure `httpc' call is isolated to one
%% spot. When the config carries a fixed `response' ({Status, Body}), that
%% response is parsed directly and no socket is opened -- this is the seam the
%% gate test for criterion 9 drives, so the routing proof never reaches the
%% network. Without a `response', `build_request/1' shapes the POST and
%% `httpc:request/4' sends it (the live path, exercised only by the opt-in smoke
%% test).
chat(#{response := Response}) ->
    parse_response(Response);
chat(Config) ->
    #{url := Url, headers := Headers, body := Body} = build_request(Config),
    HttpOptions = request_http_options(Config),
    case httpc:request(post,
                       {binary_to_list(Url), Headers,
                        "application/json", Body},
                       HttpOptions, [{body_format, binary}]) of
        {ok, {{_Version, Status, _Reason}, _RespHeaders, RespBody}} ->
            parse_response({Status, RespBody});
        {error, Reason} ->
            {error, {http_request_failed, Reason}}
    end.
