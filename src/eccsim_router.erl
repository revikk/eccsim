-module(eccsim_router).

-export([find_agent/3, find_next_call/3]).

-opaque agent() :: tuple().
-export_type([agent/0]).

-callback find_agent(atom(), [agent()]) -> {ok, agent()} | none.
-callback find_next_call(agent(), #{atom() => queue:queue()}) -> {ok, atom()} | none.

-spec find_agent(module(), atom(), [agent()]) -> {ok, agent()} | none.
find_agent(Router, CallType, IdleAgents) ->
    Router:find_agent(CallType, IdleAgents).

-spec find_next_call(module(), agent(), #{atom() => queue:queue()}) -> {ok, atom()} | none.
find_next_call(Router, Agent, Queues) ->
    Router:find_next_call(Agent, Queues).
