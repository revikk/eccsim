-module(eccsim_router).

-moduledoc "Behaviour and dispatcher for pluggable call routing strategies.
Implement find_agent/2 and find_next_call/2 to provide a custom strategy.".

-export([find_agent/3, find_next_call/3]).

-include("eccsim.hrl").

-export_type([agent/0]).

-callback find_agent(atom(), [agent()]) -> {ok, agent()} | none.
-callback find_next_call(agent(), #{atom() => queue:queue()}) -> {ok, atom()} | none.

-spec find_agent(module(), atom(), [agent()]) -> {ok, agent()} | none.
find_agent(Router, CallType, IdleAgents) ->
    Router:find_agent(CallType, IdleAgents).

-spec find_next_call(module(), agent(), #{atom() => queue:queue()}) -> {ok, atom()} | none.
find_next_call(Router, Agent, Queues) ->
    Router:find_next_call(Agent, Queues).
