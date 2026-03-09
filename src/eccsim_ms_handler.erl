-module(eccsim_ms_handler).

-moduledoc "etiq_handler implementation for multi-skill call center simulation.
Processes ms_call_arrival and ms_service_end events, maintaining queues,
agent state, and time-area accumulators for Little's Law metrics.".

-behaviour(etiq_handler).

-export([handle_event/3]).

%% Dialyzer: the etiq_handler callback spec uses etiq_handler:event() (opaque),
%% but our implementation returns concrete #event{} records (from etiq.hrl).
%% etiq provides no event constructor — direct record use is the intended API.
-dialyzer({no_opaque, handle_event/3}).

-include("eccsim.hrl").
-include_lib("etiq/include/etiq.hrl").

-export_type([ms_state/0, sim_event/0]).

%% Local alias for the etiq event record type, used in internal specs.
%% etiq_handler:event() is opaque externally, but etiq.hrl exposes the record
%% for construction. Using a local type avoids record syntax in specs.
-opaque sim_event() :: #event{}.

-spec handle_event(etiq_handler:event(), number(), ms_state()) ->
    {[sim_event()], ms_state()}.
handle_event(#event{type = ms_call_arrival, data = CallType}, Clock, State) ->
    handle_arrival(assert_atom(CallType), Clock, State);
handle_event(#event{type = ms_service_end, data = Data}, Clock, State) ->
    {CallType, AgentId} = assert_service_end_data(Data),
    handle_service_end(CallType, AgentId, Clock, State).

%%% Arrival handling
%%% ================

-spec handle_arrival(atom(), number(), ms_state()) ->
    {[sim_event()], ms_state()}.
handle_arrival(CallType, Clock, State0) ->
    State1 = update_areas(Clock, State0),
    ArrCounts = maps:update_with(CallType, fun(V) -> V + 1 end, State1#ms_state.arrival_counts),
    Config = State1#ms_state.config,
    TypeCfg = maps:get(CallType, Config#ms_config.call_types),
    {InterArrival, Rand1} = exponential(TypeCfg#call_type_config.lambda, State1#ms_state.rand_state),
    NextArrival = #event{time = Clock + InterArrival, type = ms_call_arrival, data = CallType},
    State2 = State1#ms_state{arrival_counts = ArrCounts, rand_state = Rand1},
    Router = Config#ms_config.router,
    case eccsim_router:find_agent(Router, CallType, State2#ms_state.idle_agents) of
        {ok, Agent} ->
            assign_to_agent(Agent, CallType, Clock, Clock, NextArrival, State2);
        none ->
            State3 = enqueue_call(CallType, Clock, State2),
            {[NextArrival], State3}
    end.

-spec assign_to_agent(agent(), atom(), number(), number(), sim_event(), ms_state()) ->
    {[sim_event()], ms_state()}.
assign_to_agent(Agent, CallType, ArrivalTime, Clock, NextArrival, State) ->
    Config = State#ms_state.config,
    TypeCfg = maps:get(CallType, Config#ms_config.call_types),
    {ServiceDur, Rand1} = exponential(TypeCfg#call_type_config.mu, State#ms_state.rand_state),
    AgentId = Agent#agent.id,
    ServiceEnd = #event{time = Clock + ServiceDur, type = ms_service_end, data = {CallType, AgentId}},
    IdleAgents = lists:delete(Agent, State#ms_state.idle_agents),
    BusyAgents = maps:put(AgentId, {Agent, CallType, ArrivalTime, float(Clock)}, State#ms_state.busy_agents),
    NewState = State#ms_state{
        idle_agents = IdleAgents,
        busy_agents = BusyAgents,
        rand_state = Rand1
    },
    {[NextArrival, ServiceEnd], NewState}.

-spec enqueue_call(atom(), number(), ms_state()) -> ms_state().
enqueue_call(CallType, Clock, State) ->
    Queue = maps:get(CallType, State#ms_state.queues),
    NewQueue = queue:in({Clock, make_ref()}, Queue),
    QueueLens = maps:update_with(CallType, fun(V) -> V + 1 end, State#ms_state.queue_lens),
    State#ms_state{
        queues = maps:put(CallType, NewQueue, State#ms_state.queues),
        queue_lens = QueueLens
    }.

%%% Service end handling
%%% ====================

-spec handle_service_end(atom(), term(), number(), ms_state()) ->
    {[sim_event()], ms_state()}.
handle_service_end(CallType, AgentId, Clock, State0) ->
    State1 = update_areas(Clock, State0),
    {Agent, _Type, ArrivalTime, ServiceStart} = maps:get(AgentId, State1#ms_state.busy_agents),
    BusyAgents = maps:remove(AgentId, State1#ms_state.busy_agents),
    Record = #ms_call_record{
        call_type = CallType,
        arrival_time = ArrivalTime,
        service_start = ServiceStart,
        service_end = float(Clock),
        agent_id = AgentId
    },
    State2 = State1#ms_state{
        busy_agents = BusyAgents,
        completed = [Record | State1#ms_state.completed]
    },
    try_serve_next(Agent, Clock, State2).

-spec try_serve_next(agent(), number(), ms_state()) ->
    {[sim_event()], ms_state()}.
try_serve_next(Agent, Clock, State) ->
    Router = State#ms_state.config#ms_config.router,
    case eccsim_router:find_next_call(Router, Agent, State#ms_state.queues) of
        {ok, NextType} ->
            start_from_queue(Agent, NextType, Clock, State);
        none ->
            IdleAgent = Agent#agent{idle_since = float(Clock)},
            IdleAgents = insert_idle(IdleAgent, State#ms_state.idle_agents),
            {[], State#ms_state{idle_agents = IdleAgents}}
    end.

-spec start_from_queue(agent(), atom(), number(), ms_state()) ->
    {[sim_event()], ms_state()}.
start_from_queue(Agent, CallType, Clock, State) ->
    Queue = maps:get(CallType, State#ms_state.queues),
    {{value, {WaitArrival, _Ref}}, NewQueue} = queue:out(Queue),
    Config = State#ms_state.config,
    TypeCfg = maps:get(CallType, Config#ms_config.call_types),
    {ServiceDur, Rand1} = exponential(TypeCfg#call_type_config.mu, State#ms_state.rand_state),
    AgentId = Agent#agent.id,
    ServiceEnd = #event{time = Clock + ServiceDur, type = ms_service_end, data = {CallType, AgentId}},
    QueueLens = maps:update_with(CallType, fun(V) -> V - 1 end, State#ms_state.queue_lens),
    BusyAgents = maps:put(AgentId, {Agent, CallType, WaitArrival, float(Clock)}, State#ms_state.busy_agents),
    NewState = State#ms_state{
        queues = maps:put(CallType, NewQueue, State#ms_state.queues),
        queue_lens = QueueLens,
        busy_agents = BusyAgents,
        rand_state = Rand1
    },
    {[ServiceEnd], NewState}.

%%% Area tracking and snapshots
%%% ===========================

-spec update_areas(number(), ms_state()) -> ms_state().
update_areas(Clock, State) ->
    DeltaT = Clock - State#ms_state.last_event_time,
    QueueAreas = maps:map(fun(Type, Area) ->
        Area + maps:get(Type, State#ms_state.queue_lens) * DeltaT
    end, State#ms_state.queue_areas),
    TotalInSystem = total_queue_len(State) + map_size(State#ms_state.busy_agents),
    State1 = State#ms_state{
        queue_areas = QueueAreas,
        system_area = State#ms_state.system_area + TotalInSystem * DeltaT,
        last_event_time = Clock
    },
    maybe_snapshot(Clock, State1).

-spec maybe_snapshot(number(), ms_state()) -> ms_state().
maybe_snapshot(Clock, #ms_state{next_snapshot = Next, interval = Interval} = State)
  when is_number(Next), is_number(Interval), Clock >= Next ->
    InService = count_busy_by_type(State#ms_state.busy_agents),
    Snap = #ms_snapshot{
        time = Next,
        queue_lens = State#ms_state.queue_lens,
        in_service = InService,
        arrivals = State#ms_state.arrival_counts
    },
    State1 = State#ms_state{
        snapshots = [Snap | State#ms_state.snapshots],
        next_snapshot = Next + Interval
    },
    maybe_snapshot(Clock, State1);
maybe_snapshot(_Clock, State) ->
    State.

%%% Helpers
%%% =======

-spec exponential(float(), rand:state()) -> {float(), rand:state()}.
exponential(Rate, RandState) ->
    {U, NewRandState} = rand:uniform_s(RandState),
    {-math:log(U) / Rate, NewRandState}.

-spec total_queue_len(ms_state()) -> non_neg_integer().
total_queue_len(State) ->
    maps:fold(fun(_K, V, Acc) -> Acc + V end, 0, State#ms_state.queue_lens).

-spec count_busy_by_type(#{term() => {agent(), atom(), float(), float()}}) ->
    #{atom() => non_neg_integer()}.
count_busy_by_type(BusyAgents) ->
    maps:fold(fun(_Id, {_Agent, CallType, _Arrival, _Start}, Acc) ->
        maps:update_with(CallType, fun(V) -> V + 1 end, 1, Acc)
    end, #{}, BusyAgents).

-spec insert_idle(agent(), [agent()]) -> [agent()].
insert_idle(Agent, []) ->
    [Agent];
insert_idle(Agent, [H | _T] = List) when Agent#agent.idle_since =< H#agent.idle_since ->
    [Agent | List];
insert_idle(Agent, [H | T]) ->
    [H | insert_idle(Agent, T)].

-spec assert_atom(term()) -> atom().
assert_atom(A) when is_atom(A) -> A.

-spec assert_service_end_data(term()) -> {atom(), term()}.
assert_service_end_data({CallType, AgentId}) when is_atom(CallType) ->
    {CallType, AgentId}.
