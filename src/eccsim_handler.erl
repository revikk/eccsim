-module(eccsim_handler).

-behaviour(etiq_handler).

-export([handle_event/3]).

-include("eccsim.hrl").
-include_lib("etiq/include/etiq.hrl").

-export_type([eccsim_state/0]).

-spec handle_event(etiq_handler:event(), number(), eccsim_state()) ->
    {[etiq_handler:event()], eccsim_state()}.
handle_event(#event{type = customer_arrival}, Clock, State) ->
    handle_arrival(Clock, State);
handle_event(#event{type = service_end, data = CallRef}, Clock, State) ->
    handle_service_end(assert_reference(CallRef), Clock, State).

%%% Internal
%%% ========

-spec handle_arrival(number(), eccsim_state()) ->
    {[etiq_handler:event()], eccsim_state()}.
handle_arrival(Clock, State0) ->
    State1 = update_areas(Clock, State0),
    #eccsim_config{lambda = Lambda, mu = Mu, c = C} = State1#eccsim_state.config,
    {InterArrival, Rand1} = exponential(Lambda, State1#eccsim_state.rand_state),
    NextArrival = #event{time = Clock + InterArrival, type = customer_arrival},
    FreeAgents = C - map_size(State1#eccsim_state.in_service),
    case FreeAgents > 0 of
        true ->
            {ServiceDur, Rand2} = exponential(Mu, Rand1),
            CallRef = make_ref(),
            InService = maps:put(CallRef, {Clock, Clock}, State1#eccsim_state.in_service),
            ServiceEnd = #event{time = Clock + ServiceDur, type = service_end, data = CallRef},
            {[NextArrival, ServiceEnd], State1#eccsim_state{in_service = InService, rand_state = Rand2}};
        false ->
            Queue = queue:in({Clock, make_ref()}, State1#eccsim_state.queue),
            State2 = State1#eccsim_state{
                queue = Queue,
                queue_len = State1#eccsim_state.queue_len + 1,
                rand_state = Rand1
            },
            {[NextArrival], State2}
    end.

-spec handle_service_end(reference(), number(), eccsim_state()) ->
    {[etiq_handler:event()], eccsim_state()}.
handle_service_end(CallRef, Clock, State0) ->
    State1 = update_areas(Clock, State0),
    {ArrivalTime, ServiceStart} = maps:get(CallRef, State1#eccsim_state.in_service),
    InService1 = maps:remove(CallRef, State1#eccsim_state.in_service),
    Record = #call_record{arrival_time = ArrivalTime, service_start = ServiceStart, service_end = Clock},
    Completed = [Record | State1#eccsim_state.completed],
    State2 = State1#eccsim_state{in_service = InService1, completed = Completed},
    case queue:is_empty(State2#eccsim_state.queue) of
        true ->
            {[], State2};
        false ->
            start_next_from_queue(Clock, State2)
    end.

-spec start_next_from_queue(number(), eccsim_state()) ->
    {[etiq_handler:event()], eccsim_state()}.
start_next_from_queue(Clock, State) ->
    {{value, {WaitArrival, _Ref}}, Queue} = queue:out(State#eccsim_state.queue),
    #eccsim_config{mu = Mu} = State#eccsim_state.config,
    {ServiceDur, Rand1} = exponential(Mu, State#eccsim_state.rand_state),
    NewCallRef = make_ref(),
    InService = maps:put(NewCallRef, {WaitArrival, Clock}, State#eccsim_state.in_service),
    ServiceEnd = #event{time = Clock + ServiceDur, type = service_end, data = NewCallRef},
    NewState = State#eccsim_state{
        queue = Queue,
        queue_len = State#eccsim_state.queue_len - 1,
        in_service = InService,
        rand_state = Rand1
    },
    {[ServiceEnd], NewState}.

-spec update_areas(number(), eccsim_state()) -> eccsim_state().
update_areas(Clock, State) ->
    DeltaT = Clock - State#eccsim_state.last_event_time,
    QLen = State#eccsim_state.queue_len,
    SLen = QLen + map_size(State#eccsim_state.in_service),
    State#eccsim_state{
        queue_area = State#eccsim_state.queue_area + QLen * DeltaT,
        system_area = State#eccsim_state.system_area + SLen * DeltaT,
        last_event_time = Clock
    }.

-spec exponential(float(), rand:state()) -> {float(), rand:state()}.
exponential(Rate, RandState) ->
    {U, NewRandState} = rand:uniform_s(RandState),
    {-math:log(U) / Rate, NewRandState}.

-spec assert_reference(term()) -> reference().
assert_reference(Ref) when is_reference(Ref) ->
    Ref.
