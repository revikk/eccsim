-module(eccsim).

-export([run/1]).

-include("eccsim.hrl").
-include_lib("etiq/include/etiq.hrl").

-opaque config() :: #{
    lambda := float(),
    mu := float(),
    c := pos_integer(),
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

-type run_result() ::
    {ok, results()} |
    {ok, #{results := results(), time_series := [eccsim_metrics:metric_point()]}}.

-export_type([config/0, results/0, run_result/0]).

-spec run(config()) -> run_result().
run(Config) ->
    EccsimConfig = parse_config(Config),
    Seed = maps:get(seed, Config, default_seed()),
    Interval = maps:get(interval, Config, undefined),
    State = init_state(EccsimConfig, Seed, Interval),
    SimConfig = #sim_config{
        handler = eccsim_handler,
        handler_state = State,
        max_time = EccsimConfig#eccsim_config.max_time
    },
    {ok, Pid} = etiq_sup:start_sim(SimConfig),
    ok = etiq_gen:schedule(Pid, #event{time = 0, type = customer_arrival}),
    {ok, FinalState0} = etiq_gen:run(Pid),
    ok = etiq_sup:stop_sim(Pid),
    FinalState = assert_eccsim_state(FinalState0),
    format_result(FinalState).

%%% Internal
%%% ========

-spec parse_config(config()) -> eccsim_config().
parse_config(#{lambda := Lambda, mu := Mu, c := C, max_time := MaxTime}) ->
    Rho = Lambda / (C * Mu),
    true = Rho < 1.0,
    #eccsim_config{lambda = Lambda, mu = Mu, c = C, max_time = MaxTime}.

-spec init_state(eccsim_config(), rand:seed(), number() | undefined) -> eccsim_state().
init_state(Config, Seed, Interval) ->
    NextSnapshot = case Interval of
        undefined -> undefined;
        _ -> Interval
    end,
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

-spec default_seed() -> {pos_integer(), pos_integer(), pos_integer()}.
default_seed() ->
    {12345, 67890, 11121}.

-spec results(eccsim_state()) -> results().
results(#eccsim_state{completed = []}) ->
    #{
        total_calls => 0,
        mean_wait_time => 0.0,
        mean_service_time => 0.0,
        mean_system_time => 0.0,
        mean_queue_length => 0.0,
        mean_system_length => 0.0,
        server_utilization => 0.0
    };
results(State) ->
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

-spec format_result(eccsim_state()) -> run_result().
format_result(#eccsim_state{interval = undefined} = State) ->
    {ok, results(State)};
format_result(State) ->
    Results = results(State),
    #eccsim_state{snapshots = Snaps, completed = Completed, config = Cfg} = State,
    C = Cfg#eccsim_config.c,
    Interval = State#eccsim_state.interval,
    TimeSeries = eccsim_metrics:build(lists:reverse(Snaps), Completed, Interval, C),
    {ok, #{results => Results, time_series => TimeSeries}}.

-spec sum_times([call_record()]) -> {float(), float(), float()}.
sum_times(Records) ->
    lists:foldl(fun(#call_record{arrival_time = A, service_start = S, service_end = E}, {W, Sv, Sy}) ->
        {W + (S - A), Sv + (E - S), Sy + (E - A)}
    end, {0.0, 0.0, 0.0}, Records).

-spec assert_eccsim_state(term()) -> eccsim_state().
assert_eccsim_state(State) when is_record(State, eccsim_state) ->
    State.
