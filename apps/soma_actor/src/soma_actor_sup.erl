%% @doc Root supervisor for the `soma_actor' application. It owns the actor-layer
%% registry, the permanent runtime and delegate ingress services, and dynamic
%% supervisors for delegated coordinators and actor instances.
-module(soma_actor_sup).

-behaviour(supervisor).

-export([start_link/0, start_actor/1]).
-export([init/1]).

-define(ACTOR_CHILD_SUP, soma_actor_child_sup).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Start one `soma_actor' child on demand. `Opts' carries the actor_id and
%% config. Mirrors `soma_run_sup:start_run/1'.
start_actor(Opts) when is_map(Opts) ->
    supervisor:start_child(?ACTOR_CHILD_SUP, [Opts]).

init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 1,
                 period => 5},
    Registry = #{id => soma_actor_registry,
                 start => {soma_actor_registry, start_link, []},
                 restart => permanent,
                 type => worker},
    Service = #{id => soma_service,
                start => {soma_service, start_link, []},
                restart => permanent,
                type => worker},
    DelegateCoordinatorSup =
        #{id => soma_delegate_coordinator_sup,
          start => {soma_delegate_coordinator_sup, start_link, []},
          restart => permanent,
          type => supervisor},
    Delegate = #{id => soma_delegate,
                 start => {soma_delegate, start_link, []},
                 restart => permanent,
                 type => worker},
    ActorChildSup = #{id => ?ACTOR_CHILD_SUP,
                      start => {supervisor, start_link,
                                [{local, ?ACTOR_CHILD_SUP}, ?MODULE,
                                 actor_children]},
                      restart => permanent,
                      type => supervisor},
    {ok, {SupFlags, [Registry, Service, DelegateCoordinatorSup,
                     Delegate, ActorChildSup]}};
init(actor_children) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 1,
                 period => 5},
    ChildSpec = #{id => soma_actor,
                  start => {soma_actor, start_link, []},
                  restart => temporary,
                  type => worker},
    {ok, {SupFlags, [ChildSpec]}}.
