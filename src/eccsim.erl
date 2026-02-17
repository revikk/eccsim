-module(eccsim).

-export([run/1]).

-include("eccsim.hrl").
-include_lib("etiq/include/etiq.hrl").

-opaque config() :: #{
    lambda := float(),
    mu := float(),
    c := pos_integer(),
    max_time := number(),
    seed => rand:seed()
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

-export_type([config/0, results/0]).

-spec run(config()) -> {ok, results()}.
run(Config) ->
    EccsimConfig = parse_config(Config),
    Seed = maps:get(seed, Config, default_seed()),
    State = init_state(EccsimConfig, Seed),
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
    {ok, results(FinalState)}.

%%% Internal
%%% ========

-spec parse_config(config()) -> eccsim_config().
parse_config(#{lambda := Lambda, mu := Mu, c := C, max_time := MaxTime}) ->
    Rho = Lambda / (C * Mu),
    true = Rho < 1.0,
    #eccsim_config{lambda = Lambda, mu = Mu, c = C, max_time = MaxTime}.

-spec init_state(eccsim_config(), rand:seed()) -> eccsim_state().
init_state(Config, Seed) ->
    #eccsim_state{
        config = Config,
        queue = queue:new(),
        queue_len = 0,
        in_service = #{},
        completed = [],
        rand_state = rand:seed_s(exsss, Seed),
        last_event_time = 0.0,
        queue_area = 0.0,
        system_area = 0.0
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

-spec sum_times([call_record()]) -> {float(), float(), float()}.
sum_times(Records) ->
    lists:foldl(fun(#call_record{arrival_time = A, service_start = S, service_end = E}, {W, Sv, Sy}) ->
        {W + (S - A), Sv + (E - S), Sy + (E - A)}
    end, {0.0, 0.0, 0.0}, Records).

-spec assert_eccsim_state(term()) -> eccsim_state().
assert_eccsim_state(State) when is_record(State, eccsim_state) ->
    State.
