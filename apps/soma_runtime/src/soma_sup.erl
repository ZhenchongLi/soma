%% @doc The top-level supervisor. Runtime children are ordered by dependency.
%% The run-id index starts before `soma_run_sup', so it can fence any orphaned
%% run processes from a prior supervisor/application generation before new runs
%% are admitted. The established one-for-one failure isolation remains intact.
-module(soma_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 1,
                 period => 5},
    Children =
        [#{id => soma_event_store,
           start => event_store_start(),
           type => worker},
         #{id => soma_tool_registry,
           start => {soma_tool_registry, start_link, []},
           type => worker},
         #{id => soma_run_index,
           start => {soma_run_index, start_link, []},
           type => worker},
         #{id => soma_session_sup,
           start => {soma_session_sup, start_link, []},
           type => supervisor},
         #{id => soma_run_sup,
           start => {soma_run_sup, start_link, []},
           type => supervisor}],
    {ok, {SupFlags, Children}}.

%% Build the `soma_event_store' child's start tuple from the `event_store_log'
%% app env. A path opts the store into durable disk_log persistence
%% (`start_link/1'); the default (env unset) stays the in-memory `start_link/0',
%% byte for byte. The store mode is fixed at boot — a release config knob.
event_store_start() ->
    case application:get_env(soma_runtime, event_store_log, undefined) of
        undefined ->
            {soma_event_store, start_link,
             [#{name => soma_runtime_event_store}]};
        Path ->
            {soma_event_store, start_link,
             [#{name => soma_runtime_event_store, log => Path}]}
    end.
