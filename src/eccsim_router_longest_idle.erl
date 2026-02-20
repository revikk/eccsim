-module(eccsim_router_longest_idle).

-behaviour(eccsim_router).

-export([find_agent/2, find_next_call/2]).

-include("eccsim.hrl").

-export_type([agent/0]).

-doc "Find the longest-idle agent whose skills include CallType.
IdleAgents must be sorted by idle_since ascending (longest-idle first).
Returns {ok, Agent} or none.".
-spec find_agent(atom(), [agent()]) -> {ok, agent()} | none.
find_agent(_CallType, []) ->
    none;
find_agent(CallType, [Agent | Rest]) ->
    case lists:member(CallType, Agent#agent.skills) of
        true -> {ok, Agent};
        false -> find_agent(CallType, Rest)
    end.

-doc "Given a freed agent, find the next queued call to serve.
Checks per-type queues in the agent's priority order.
Returns {ok, CallType} or none.".
-spec find_next_call(agent(), #{atom() => queue:queue()}) -> {ok, atom()} | none.
find_next_call(Agent, Queues) ->
    find_in_priority(Agent#agent.priority, Queues).

-spec find_in_priority([atom()], #{atom() => queue:queue()}) -> {ok, atom()} | none.
find_in_priority([], _Queues) ->
    none;
find_in_priority([CallType | Rest], Queues) ->
    case maps:get(CallType, Queues, undefined) of
        undefined ->
            find_in_priority(Rest, Queues);
        Q ->
            case queue:is_empty(Q) of
                true -> find_in_priority(Rest, Queues);
                false -> {ok, CallType}
            end
    end.
