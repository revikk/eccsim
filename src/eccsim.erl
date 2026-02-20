-module(eccsim).

-export([run/1]).

-include("eccsim.hrl").
-include_lib("etiq/include/etiq.hrl").

-opaque mq_config() :: #{
    queues := #{atom() => #{lambda := float(), mu := float(), c := pos_integer()}},
    max_time := number(),
    seed => rand:seed(),
    interval => number()
}.

-opaque ms_config_input() :: #{
    call_types := #{atom() => #{lambda := float(), mu := float()}},
    agent_groups := [#{id := term(), count := pos_integer(), skills := [atom()]}],
    routing := atom(),
    max_time := number(),
    seed => rand:seed(),
    interval => number()
}.

-opaque results() :: #{
    total_calls := non_neg_integer(),
    mean_wait_time := float(),
    mean_service_time := float(),
    mean_system_time := float(),
    mean_queue_length := float(),
    mean_system_length := float(),
    server_utilization := float()
}.

-opaque mq_results() :: #{
    per_queue := #{atom() => results()},
    aggregate := results()
}.

-opaque ms_results() :: #{
    per_type := #{atom() => results()},
    aggregate := results()
}.

-type run_result() ::
    {ok, mq_results()} |
    {ok, #{results := mq_results(), time_series := [eccsim_metrics:mq_metric_point()]}} |
    {ok, ms_results()} |
    {ok, #{results := ms_results(), time_series := [eccsim_ms_metrics:ms_metric_point()]}}.

-export_type([mq_config/0, ms_config_input/0, results/0, mq_results/0, ms_results/0, run_result/0]).

-spec run(mq_config() | ms_config_input()) -> run_result().
run(#{call_types := _} = Config) ->
    run_multi_skill(Config);
run(#{queues := _} = Config) ->
    run_multi_queue(Config).

%%% Multi-queue M/M/c
%%% =================

-spec run_multi_queue(mq_config()) -> run_result().
run_multi_queue(Config) ->
    #{queues := Queues, max_time := MaxTime} = Config,
    BaseSeed = maps:get(seed, Config, default_seed()),
    Interval = maps:get(interval, Config, undefined),
    QueueNames = lists:sort(maps:keys(Queues)),
    Seeds = derive_seeds(BaseSeed, QueueNames),
    Sims = start_sims(QueueNames, Queues, Seeds, MaxTime, Interval),
    FinalStates = run_sims_parallel(Sims),
    stop_sims(Sims),
    PerQueue = build_per_queue_results(QueueNames, FinalStates, Queues),
    Aggregate = build_aggregate(PerQueue, MaxTime, Queues),
    MqResults = #{per_queue => PerQueue, aggregate => Aggregate},
    format_mq_result(MqResults, QueueNames, FinalStates, Interval, Queues).

-spec derive_seeds(rand:seed(), [atom()]) -> #{atom() => rand:seed()}.
derive_seeds(BaseSeed, QueueNames) ->
    {Seeds, _} = lists:foldl(fun(Name, {Acc, Idx}) ->
        Seed = offset_seed(BaseSeed, Idx),
        {maps:put(Name, Seed, Acc), Idx + 1}
    end, {#{}, 0}, QueueNames),
    Seeds.

-spec offset_seed(rand:seed(), non_neg_integer()) -> rand:seed().
offset_seed({S1, S2, S3}, Offset) ->
    {S1 + Offset, S2, S3}.

-spec start_sims([atom()], map(), #{atom() => rand:seed()}, number(), number() | undefined) ->
    [{atom(), pid()}].
start_sims(QueueNames, Queues, Seeds, MaxTime, Interval) ->
    lists:map(fun(Name) ->
        #{lambda := Lambda, mu := Mu, c := C} = maps:get(Name, Queues),
        Rho = Lambda / (C * Mu),
        true = Rho < 1.0,
        QConfig = #eccsim_config{lambda = Lambda, mu = Mu, c = C, max_time = MaxTime},
        State = init_queue_state(QConfig, maps:get(Name, Seeds), Interval),
        SimConfig = #sim_config{handler = eccsim_handler, handler_state = State, max_time = MaxTime},
        {ok, Pid} = etiq_sup:start_sim(SimConfig),
        ok = etiq_gen:schedule(Pid, #event{time = 0, type = customer_arrival}),
        {Name, Pid}
    end, QueueNames).

-spec init_queue_state(eccsim_config(), rand:seed(), number() | undefined) -> eccsim_state().
init_queue_state(Config, Seed, Interval) ->
    NextSnapshot = case Interval of undefined -> undefined; _ -> Interval end,
    #eccsim_state{
        config = Config,
        queue = queue:new(),
        queue_len = 0,
        in_service = #{},
        completed = [],
        rand_state = rand:seed_s(exsss, Seed),
        last_event_time = 0.0,
        queue_area = 0.0,
        system_area = 0.0,
        interval = Interval,
        next_snapshot = NextSnapshot,
        snapshots = []
    }.

-spec run_sims_parallel([{atom(), pid()}]) -> #{atom() => eccsim_state()}.
run_sims_parallel(Sims) ->
    Parent = self(),
    Runners = lists:map(fun({Name, Pid}) ->
        Ref = make_ref(),
        spawn_link(fun() ->
            {ok, FinalState} = etiq_gen:run(Pid),
            Parent ! {Ref, Name, FinalState}
        end),
        {Ref, Name}
    end, Sims),
    collect_results(Runners, #{}).

-spec collect_results([{reference(), atom()}], #{atom() => eccsim_state()}) ->
    #{atom() => eccsim_state()}.
collect_results([], Acc) ->
    Acc;
collect_results(Runners, Acc) ->
    receive
        {Ref, Name, State} ->
            case lists:keymember(Ref, 1, Runners) of
                true ->
                    Remaining = lists:keydelete(Ref, 1, Runners),
                    collect_results(Remaining, maps:put(Name, assert_eccsim_state(State), Acc));
                false ->
                    collect_results(Runners, Acc)
            end
    after 600_000 ->
        error(timeout)
    end.

-spec stop_sims([{atom(), pid()}]) -> ok.
stop_sims(Sims) ->
    lists:foreach(fun({_Name, Pid}) -> ok = etiq_sup:stop_sim(Pid) end, Sims).

-spec build_per_queue_results([atom()], #{atom() => eccsim_state()}, map()) ->
    #{atom() => results()}.
build_per_queue_results(QueueNames, FinalStates, Queues) ->
    maps:from_list(lists:map(fun(Name) ->
        State = maps:get(Name, FinalStates),
        {Name, queue_results(State, maps:get(Name, Queues))}
    end, QueueNames)).

-spec queue_results(eccsim_state(), map()) -> results().
queue_results(#eccsim_state{completed = []}, _QueueDef) ->
    empty_results();
queue_results(State, _QueueDef) ->
    #eccsim_state{completed = Completed, config = Config} = State,
    MaxTime = Config#eccsim_config.max_time,
    C = Config#eccsim_config.c,
    {WaitSum, ServiceSum, SystemSum} = sum_times(Completed),
    N = length(Completed),
    #{
        total_calls => N,
        mean_wait_time => WaitSum / N,
        mean_service_time => ServiceSum / N,
        mean_system_time => SystemSum / N,
        mean_queue_length => State#eccsim_state.queue_area / MaxTime,
        mean_system_length => State#eccsim_state.system_area / MaxTime,
        server_utilization => ServiceSum / (C * MaxTime)
    }.

-spec build_aggregate(#{atom() => results()}, number(), map()) -> results().
build_aggregate(PerQueue, MaxTime, Queues) ->
    Items = maps:to_list(PerQueue),
    TotalCalls = lists:sum([maps:get(total_calls, R) || {_, R} <- Items]),
    case TotalCalls of
        0 -> empty_results();
        _ ->
            TotalServers = lists:sum([maps:get(c, maps:get(Q, Queues)) || {Q, _} <- Items]),
            WaitSum = weighted_sum(Items, mean_wait_time),
            SvcSum = weighted_sum(Items, mean_service_time),
            SysSum = weighted_sum(Items, mean_system_time),
            TotalServiceTime = lists:sum([
                maps:get(mean_service_time, R) * maps:get(total_calls, R) || {_, R} <- Items
            ]),
            #{
                total_calls => TotalCalls,
                mean_wait_time => WaitSum / TotalCalls,
                mean_service_time => SvcSum / TotalCalls,
                mean_system_time => SysSum / TotalCalls,
                mean_queue_length => lists:sum([maps:get(mean_queue_length, R) || {_, R} <- Items]),
                mean_system_length => lists:sum([maps:get(mean_system_length, R) || {_, R} <- Items]),
                server_utilization => TotalServiceTime / (TotalServers * MaxTime)
            }
    end.

-spec weighted_sum([{atom(), results()}], atom()) -> float().
weighted_sum(Items, Key) ->
    lists:sum([maps:get(Key, R) * maps:get(total_calls, R) || {_, R} <- Items]).

-spec format_mq_result(mq_results(), [atom()], #{atom() => eccsim_state()},
    number() | undefined, map()) -> run_result().
format_mq_result(MqResults, _QueueNames, _FinalStates, undefined, _Queues) ->
    {ok, MqResults};
format_mq_result(MqResults, QueueNames, FinalStates, Interval, Queues) ->
    PerQueueData = lists:map(fun(Name) ->
        State = maps:get(Name, FinalStates),
        #eccsim_state{snapshots = Snaps, completed = Completed, config = Cfg} = State,
        C = Cfg#eccsim_config.c,
        Series = eccsim_metrics:build(lists:reverse(Snaps), Completed, Interval, C),
        {Name, Series}
    end, QueueNames),
    TotalAgents = lists:sum([maps:get(c, maps:get(Q, Queues)) || Q <- QueueNames]),
    TimeSeries = eccsim_metrics:build_mq(PerQueueData, TotalAgents),
    {ok, #{results => MqResults, time_series => TimeSeries}}.

-spec sum_times([call_record()]) -> {float(), float(), float()}.
sum_times(Records) ->
    sum_call_times(fun(#call_record{arrival_time = A, service_start = S, service_end = E}) ->
        {A, S, E}
    end, Records).

-spec empty_results() -> results().
empty_results() ->
    #{
        total_calls => 0, mean_wait_time => 0.0, mean_service_time => 0.0,
        mean_system_time => 0.0, mean_queue_length => 0.0,
        mean_system_length => 0.0, server_utilization => 0.0
    }.

-spec default_seed() -> {pos_integer(), pos_integer(), pos_integer()}.
default_seed() ->
    {12345, 67890, 11121}.

-spec assert_eccsim_state(term()) -> eccsim_state().
assert_eccsim_state(State) when is_record(State, eccsim_state) ->
    State.

%%% Multi-skill internals
%%% =====================

-spec run_multi_skill(ms_config_input()) -> run_result().
run_multi_skill(Config) ->
    MsConfig = parse_ms_config(Config),
    Seed = maps:get(seed, Config, default_seed()),
    Interval = maps:get(interval, Config, undefined),
    State = init_ms_state(MsConfig, Seed, Interval),
    SimConfig = #sim_config{
        handler = eccsim_ms_handler,
        handler_state = State,
        max_time = MsConfig#ms_config.max_time
    },
    {ok, Pid} = etiq_sup:start_sim(SimConfig),
    SeedEvents = [#event{time = 0, type = ms_call_arrival, data = T} || T <- maps:keys(MsConfig#ms_config.call_types)],
    ok = etiq_gen:schedule(Pid, SeedEvents),
    {ok, FinalState0} = etiq_gen:run(Pid),
    ok = etiq_sup:stop_sim(Pid),
    FinalState = assert_ms_state(FinalState0),
    format_ms_result(FinalState).

-spec parse_ms_config(ms_config_input()) -> ms_config().
parse_ms_config(#{call_types := RawTypes, agent_groups := Groups, routing := Routing, max_time := MaxTime}) ->
    CallTypes = maps:map(fun(Name, #{lambda := L, mu := M}) ->
        #call_type_config{name = Name, lambda = L, mu = M}
    end, RawTypes),
    Agents = expand_agent_groups(Groups, maps:keys(CallTypes)),
    Router = router_module(Routing),
    #ms_config{call_types = CallTypes, agents = Agents, router = Router, max_time = MaxTime}.

-spec router_module(atom()) -> module().
router_module(longest_idle) -> eccsim_router_longest_idle.

-spec expand_agent_groups([map()], [atom()]) -> [agent()].
expand_agent_groups(Groups, AllTypes) ->
    lists:flatmap(fun(Group) -> expand_one_group(Group, AllTypes) end, Groups).

-spec expand_one_group(map(), [atom()]) -> [agent()].
expand_one_group(#{id := Id, count := Count, skills := Skills} = Group, AllTypes) ->
    Priority = maps:get(priority, Group, default_priority(Skills, AllTypes)),
    [#agent{
        id = {Id, N},
        skills = Skills,
        priority = Priority,
        idle_since = 0.0
    } || N <- lists:seq(1, Count)].

-spec default_priority([atom()], [atom()]) -> [atom()].
default_priority(Skills, AllTypes) ->
    [T || T <- AllTypes, lists:member(T, Skills)].

-spec init_ms_state(ms_config(), rand:seed(), number() | undefined) -> ms_state().
init_ms_state(Config, Seed, Interval) ->
    TypeNames = maps:keys(Config#ms_config.call_types),
    Queues = maps:from_list([{T, queue:new()} || T <- TypeNames]),
    QueueLens = maps:from_list([{T, 0} || T <- TypeNames]),
    QueueAreas = maps:from_list([{T, 0.0} || T <- TypeNames]),
    NextSnapshot = case Interval of undefined -> undefined; _ -> Interval end,
    #ms_state{
        config = Config,
        queues = Queues,
        queue_lens = QueueLens,
        idle_agents = Config#ms_config.agents,
        busy_agents = #{},
        completed = [],
        rand_state = rand:seed_s(exsss, Seed),
        last_event_time = 0.0,
        queue_areas = QueueAreas,
        system_area = 0.0,
        interval = Interval,
        next_snapshot = NextSnapshot,
        snapshots = []
    }.

-spec assert_ms_state(term()) -> ms_state().
assert_ms_state(State) when is_record(State, ms_state) ->
    State.

-spec format_ms_result(ms_state()) -> run_result().
format_ms_result(#ms_state{interval = undefined} = State) ->
    {ok, ms_results(State)};
format_ms_result(State) ->
    Results = ms_results(State),
    #ms_state{snapshots = Snaps, completed = Completed} = State,
    Interval = State#ms_state.interval,
    TypeNames = maps:keys(State#ms_state.config#ms_config.call_types),
    TimeSeries = eccsim_ms_metrics:build(lists:reverse(Snaps), Completed, Interval, TypeNames, agent_count(State)),
    {ok, #{results => Results, time_series => TimeSeries}}.

-spec ms_results(ms_state()) -> ms_results().
ms_results(State) ->
    #ms_state{completed = Completed, config = Config} = State,
    MaxTime = Config#ms_config.max_time,
    TotalAgents = length(Config#ms_config.agents),
    PerType = ms_per_type_results(Completed, State),
    Aggregate = ms_aggregate_results(Completed, MaxTime, TotalAgents, State),
    #{per_type => PerType, aggregate => Aggregate}.

-spec ms_per_type_results([ms_call_record()], ms_state()) -> #{atom() => results()}.
ms_per_type_results(Completed, State) ->
    #ms_state{config = Config} = State,
    MaxTime = Config#ms_config.max_time,
    Grouped = group_by_type(Completed),
    TypeNames = maps:keys(Config#ms_config.call_types),
    maps:from_list(lists:map(fun(T) ->
        Records = maps:get(T, Grouped, []),
        QueueArea = maps:get(T, State#ms_state.queue_areas, 0.0),
        {T, type_results(Records, QueueArea, MaxTime)}
    end, TypeNames)).

-spec type_results([ms_call_record()], float(), number()) -> results().
type_results([], _QueueArea, _MaxTime) ->
    empty_results();
type_results(Records, QueueArea, MaxTime) ->
    {WaitSum, ServiceSum, SystemSum} = ms_sum_times(Records),
    N = length(Records),
    #{
        total_calls => N,
        mean_wait_time => WaitSum / N,
        mean_service_time => ServiceSum / N,
        mean_system_time => SystemSum / N,
        mean_queue_length => QueueArea / MaxTime,
        mean_system_length => 0.0,
        server_utilization => ServiceSum / MaxTime
    }.

-spec ms_aggregate_results([ms_call_record()], number(), pos_integer(), ms_state()) -> results().
ms_aggregate_results([], _MaxTime, _TotalAgents, _State) ->
    empty_results();
ms_aggregate_results(Completed, MaxTime, TotalAgents, State) ->
    {WaitSum, ServiceSum, SystemSum} = ms_sum_times(Completed),
    N = length(Completed),
    #{
        total_calls => N,
        mean_wait_time => WaitSum / N,
        mean_service_time => ServiceSum / N,
        mean_system_time => SystemSum / N,
        mean_queue_length => total_queue_area(State) / MaxTime,
        mean_system_length => State#ms_state.system_area / MaxTime,
        server_utilization => ServiceSum / (TotalAgents * MaxTime)
    }.

-spec ms_sum_times([ms_call_record()]) -> {float(), float(), float()}.
ms_sum_times(Records) ->
    sum_call_times(fun(#ms_call_record{arrival_time = A, service_start = S, service_end = E}) ->
        {A, S, E}
    end, Records).

-spec sum_call_times(fun((term()) -> {float(), float(), float()}), [term()]) ->
    {float(), float(), float()}.
sum_call_times(Extract, Records) ->
    lists:foldl(fun(Rec, {W, Sv, Sy}) ->
        {A, S, E} = Extract(Rec),
        {W + (S - A), Sv + (E - S), Sy + (E - A)}
    end, {0.0, 0.0, 0.0}, Records).

-spec group_by_type([ms_call_record()]) -> #{atom() => [ms_call_record()]}.
group_by_type(Records) ->
    lists:foldl(fun(#ms_call_record{call_type = T} = R, Acc) ->
        maps:update_with(T, fun(L) -> [R | L] end, [R], Acc)
    end, #{}, Records).

-spec total_queue_area(ms_state()) -> float().
total_queue_area(State) ->
    maps:fold(fun(_K, V, Acc) -> Acc + V end, 0.0, State#ms_state.queue_areas).

-spec agent_count(ms_state()) -> pos_integer().
agent_count(State) ->
    length(State#ms_state.config#ms_config.agents).
