-module(eccsim).

-moduledoc "Erlang Call Center Simulator — public API.
Call `run/1` with a multi-account configuration map to run a discrete-event
simulation and return per-account and aggregate performance metrics.".

-export([run/1, aggregate/1]).

-include("eccsim.hrl").
-include_lib("etiq/include/etiq.hrl").

%% Dialyzer: seed_events are constructed as #event{} records (etiq.hrl record),
%% which dialyzer sees as violating etiq_handler:event() opaque type.
%% etiq provides no constructor function; direct record use is the intended API.
-dialyzer({no_opaque, start_account_sims/6}).
%% Dialyzer: build_account_ts/2 undefined clause is reachable at runtime
%% (when interval is omitted from config) but dialyzer's success-typing misses it.
-dialyzer({no_match, build_account_ts/2}).

-opaque config() :: #{
    accounts := #{term() => #{
        queues := #{atom() => #{lambda := float(), mu := float(), agents := [atom()]}}
    }},
    routing := atom(),
    max_time := number(),
    interval => number(),
    output_dir => string(),
    seed => {pos_integer(), pos_integer(), pos_integer()}
}.

-opaque type_results() :: #{
    total_calls := non_neg_integer(),
    mean_wait_time := float(),
    mean_service_time := float(),
    mean_system_time := float(),
    mean_queue_length := float(),
    offered_load := float()
}.

-opaque results() :: #{
    total_calls := non_neg_integer(),
    mean_wait_time := float(),
    mean_service_time := float(),
    mean_system_time := float(),
    mean_queue_length := float(),
    mean_system_length := float(),
    agent_utilization := float()
}.

-opaque account_results() :: #{
    per_type := #{atom() => type_results()},
    aggregate := results()
}.

-opaque run_result() :: {ok, #{
    per_account := #{term() => account_results()},
    aggregate := results()
}}.

-export_type([config/0, type_results/0, results/0, account_results/0, run_result/0]).

-spec run(config()) -> run_result().
run(#{accounts := Accounts, routing := Routing, max_time := MaxTime} = Config) ->
    StartTime = os:system_time(second),
    BaseSeed = maps:get(seed, Config, default_seed()),
    Interval = maps:get(interval, Config, undefined),
    OutputDir = maps:get(output_dir, Config, undefined),
    AccountIds = lists:sort(maps:keys(Accounts)),
    Seeds = derive_seeds(BaseSeed, AccountIds),
    Sims = start_account_sims(AccountIds, Accounts, Seeds, Routing, MaxTime, Interval),
    FinalStates = run_sims_parallel(Sims),
    stop_sims(Sims),
    {PerAccount, AccountTS} = build_account_results(AccountIds, FinalStates, Interval),
    maybe_write_csv(AccountTS, OutputDir, StartTime),
    Aggregate = build_aggregate(PerAccount, MaxTime, Accounts),
    {ok, #{per_account => PerAccount, aggregate => Aggregate}}.

-doc "Extract the aggregate results from a run_result().".
-spec aggregate(run_result()) -> results().
aggregate({ok, #{aggregate := Agg}}) ->
    Agg.

%%% Account orchestration
%%% =====================

-spec derive_seeds({pos_integer(), pos_integer(), pos_integer()}, [term()]) ->
    #{term() => {pos_integer(), pos_integer(), pos_integer()}}.
derive_seeds(BaseSeed, AccountIds) ->
    {Seeds, _} = lists:foldl(fun(Id, {Acc, Idx}) ->
        Seed = offset_seed(BaseSeed, Idx),
        {Acc#{Id => Seed}, Idx + 1}
    end, {#{}, 0}, AccountIds),
    Seeds.

-spec offset_seed({pos_integer(), pos_integer(), pos_integer()}, non_neg_integer()) ->
    {pos_integer(), pos_integer(), pos_integer()}.
offset_seed({S1, S2, S3}, Offset) ->
    {S1 + Offset, S2, S3}.

-spec start_account_sims([term()], map(), map(), atom(), number(), number() | undefined) ->
    [{term(), pid()}].
start_account_sims(AccountIds, Accounts, Seeds, Routing, MaxTime, Interval) ->
    lists:map(fun(Id) ->
        Account = maps:get(Id, Accounts),
        MsInput = Account#{routing => Routing, max_time => MaxTime},
        MsConfig = parse_ms_config(MsInput),
        Seed = maps:get(Id, Seeds),
        State = init_ms_state(MsConfig, Seed, Interval),
        SimConfig = #sim_config{
            handler = eccsim_ms_handler,
            handler_state = State,
            max_time = MaxTime
        },
        SeedEvents = [#event{time = 0, type = ms_call_arrival, data = T}
                      || T <- maps:keys(MsConfig#ms_config.call_types)],
        Args = #{sim_config => SimConfig, seed_events => SeedEvents},
        {ok, Pid} = eccsim_sup:start_sim(Args),
        {Id, assert_pid(Pid)}
    end, AccountIds).

-spec run_sims_parallel([{term(), pid()}]) -> #{term() => ms_state()}.
run_sims_parallel(Sims) ->
    Parent = self(),
    Runners = lists:map(fun({Id, Pid}) ->
        Ref = make_ref(),
        spawn_link(fun() ->
            {ok, FinalState} = eccsim_sim:await(Pid, 600_000),
            Parent ! {Ref, Id, FinalState}
        end),
        {Ref, Id}
    end, Sims),
    collect_results(Runners, #{}).

-spec collect_results([{reference(), term()}], #{term() => ms_state()}) ->
    #{term() => ms_state()}.
collect_results([], Acc) ->
    Acc;
collect_results(Runners, Acc) ->
    receive
        {Ref, Id, State} ->
            case lists:keymember(Ref, 1, Runners) of
                true ->
                    Remaining = lists:keydelete(Ref, 1, Runners),
                    collect_results(Remaining, Acc#{Id => assert_ms_state(State)});
                false ->
                    collect_results(Runners, Acc)
            end
    after 600_000 ->
        error(timeout)
    end.

-spec stop_sims([{term(), pid()}]) -> ok.
stop_sims(Sims) ->
    lists:foreach(fun({_Id, Pid}) -> eccsim_sup:stop_sim(Pid) end, Sims).

%%% Results
%%% =======

-spec build_account_results([term()], #{term() => ms_state()}, number() | undefined) ->
    {#{term() => account_results()}, [{term(), [eccsim_ms_metrics:ms_metric_point()]}]}.
build_account_results(AccountIds, FinalStates, Interval) ->
    lists:foldl(fun(Id, {ResAcc, TsAcc}) ->
        State = maps:get(Id, FinalStates),
        AccountRes = ms_results(State),
        TS = build_account_ts(State, Interval),
        {ResAcc#{Id => AccountRes}, [{Id, TS} | TsAcc]}
    end, {#{}, []}, AccountIds).

-spec build_account_ts(ms_state(), number() | undefined) -> [eccsim_ms_metrics:ms_metric_point()].
build_account_ts(_State, undefined) ->
    [];
build_account_ts(State, Interval) ->
    #ms_state{snapshots = Snaps, completed = Completed, config = Config} = State,
    TypeNames = maps:keys(Config#ms_config.call_types),
    AgentCounts = eccsim_ms_metrics:agent_counts(Config#ms_config.agents, TypeNames),
    eccsim_ms_metrics:build(lists:reverse(Snaps), Completed, Interval, TypeNames, AgentCounts).

-spec build_aggregate(#{term() => account_results()}, number(), map()) -> results().
build_aggregate(PerAccount, MaxTime, Accounts) ->
    Items = maps:to_list(PerAccount),
    TotalCalls = lists:sum([maps:get(total_calls, maps:get(aggregate, R)) || {_, R} <- Items]),
    case TotalCalls of
        0 -> empty_results();
        _ ->
            TotalAgents = maps:fold(fun(_Id, Acct, Acc) ->
                Queues = maps:get(queues, Acct),
                AllAgents = lists:append([maps:get(agents, Q) || Q <- maps:values(Queues)]),
                Acc + length(lists:usort(AllAgents))
            end, 0, Accounts),
            Aggs = [{Id, maps:get(aggregate, R)} || {Id, R} <- Items],
            WaitSum = weighted_sum(Aggs, mean_wait_time),
            SvcSum = weighted_sum(Aggs, mean_service_time),
            SysSum = weighted_sum(Aggs, mean_system_time),
            TotalServiceTime = lists:sum([
                maps:get(mean_service_time, A) * maps:get(total_calls, A) || {_, A} <- Aggs
            ]),
            #{
                total_calls => TotalCalls,
                mean_wait_time => WaitSum / TotalCalls,
                mean_service_time => SvcSum / TotalCalls,
                mean_system_time => SysSum / TotalCalls,
                mean_queue_length => lists:sum([maps:get(mean_queue_length, A) || {_, A} <- Aggs]),
                mean_system_length => lists:sum([maps:get(mean_system_length, A) || {_, A} <- Aggs]),
                agent_utilization => TotalServiceTime / (TotalAgents * MaxTime)
            }
    end.

-spec weighted_sum([{term(), results()}], atom()) -> float().
weighted_sum(Items, Key) ->
    lists:sum([maps:get(Key, R) * maps:get(total_calls, R) || {_, R} <- Items]).

%%% CSV output
%%% ==========

-spec maybe_write_csv([{term(), [eccsim_ms_metrics:ms_metric_point()]}], string() | undefined, integer()) -> ok.
maybe_write_csv(_AccountTS, undefined, _StartTime) ->
    ok;
maybe_write_csv(AccountTS, OutputDir, StartTime) ->
    ok = filelib:ensure_dir(filename:join(OutputDir, "x")),
    Path = filename:join(OutputDir, "eccsim_metrics.csv"),
    CsvData = eccsim_ms_metrics:ma_to_csv(AccountTS, StartTime),
    ok = file:write_file(Path, CsvData).

%%% Multi-skill config parsing
%%% ==========================

-spec parse_ms_config(map()) -> ms_config().
parse_ms_config(#{queues := RawQueues, routing := Routing, max_time := MaxTime}) ->
    CallTypes = maps:map(fun(Name, #{lambda := L, mu := M}) ->
        #call_type_config{name = Name, lambda = L, mu = M}
    end, RawQueues),
    Agents = expand_queues(RawQueues, maps:keys(CallTypes)),
    Router = router_module(Routing),
    #ms_config{call_types = CallTypes, agents = Agents, router = Router, max_time = MaxTime}.

-spec router_module(atom()) -> module().
router_module(longest_idle) -> eccsim_router_longest_idle.

-spec expand_queues(#{atom() => #{agents := [atom()]}}, [atom()]) -> [agent()].
expand_queues(Queues, AllTypes) ->
    %% Invert queue -> [agent] to agent -> [skill]
    AgentSkills = maps:fold(fun(QueueName, #{agents := AgentIds}, Acc) ->
        lists:foldl(fun(AId, InnerAcc) ->
            maps:update_with(AId, fun(Skills) -> [QueueName | Skills] end, [QueueName], InnerAcc)
        end, Acc, AgentIds)
    end, #{}, Queues),
    maps:fold(fun(AId, Skills, Acc) ->
        SortedSkills = lists:sort(Skills),
        Priority = default_priority(SortedSkills, AllTypes),
        [#agent{id = AId, skills = SortedSkills, priority = Priority, idle_since = 0.0} | Acc]
    end, [], AgentSkills).

-spec default_priority([atom()], [atom()]) -> [atom()].
default_priority(Skills, AllTypes) ->
    [T || T <- AllTypes, lists:member(T, Skills)].

%%% Multi-skill state
%%% =================

-spec init_ms_state(ms_config(), {pos_integer(), pos_integer(), pos_integer()}, number() | undefined) -> ms_state().
init_ms_state(Config, Seed, Interval) ->
    TypeNames = maps:keys(Config#ms_config.call_types),
    {Queues, QueueLens, QueueAreas} = lists:foldl(fun(T, {QAcc, LAcc, AAcc}) ->
        {QAcc#{T => queue:new()}, LAcc#{T => 0}, AAcc#{T => 0.0}}
    end, {#{}, #{}, #{}}, TypeNames),
    NextSnapshot = Interval,
    #ms_state{
        config = Config,
        queues = Queues,
        queue_lens = QueueLens,
        idle_agents = Config#ms_config.agents,
        busy_agents = #{},
        completed = [],
        arrival_counts = maps:from_keys(TypeNames, 0),
        rand_state = rand:seed_s(exsss, Seed),
        last_event_time = 0.0,
        queue_areas = QueueAreas,
        system_area = 0.0,
        interval = Interval,
        next_snapshot = NextSnapshot,
        snapshots = []
    }.

%%% Multi-skill results
%%% ===================

-spec ms_results(ms_state()) -> account_results().
ms_results(State) ->
    #ms_state{completed = Completed, config = Config} = State,
    MaxTime = Config#ms_config.max_time,
    TotalAgents = length(Config#ms_config.agents),
    PerType = ms_per_type_results(Completed, State),
    Aggregate = ms_aggregate_results(Completed, MaxTime, TotalAgents, State),
    #{per_type => PerType, aggregate => Aggregate}.

-spec ms_per_type_results([ms_call_record()], ms_state()) -> #{atom() => type_results()}.
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

-spec type_results([ms_call_record()], float(), number()) -> type_results().
type_results([], _QueueArea, _MaxTime) ->
    empty_type_results();
type_results(Records, QueueArea, MaxTime) ->
    {WaitSum, ServiceSum, SystemSum} = ms_sum_times(Records),
    N = length(Records),
    #{
        total_calls => N,
        mean_wait_time => WaitSum / N,
        mean_service_time => ServiceSum / N,
        mean_system_time => SystemSum / N,
        mean_queue_length => QueueArea / MaxTime,
        offered_load => ServiceSum / MaxTime
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
        agent_utilization => ServiceSum / (TotalAgents * MaxTime)
    }.

%%% Helpers
%%% =======

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

-spec assert_pid(pid() | undefined) -> pid().
assert_pid(Pid) when is_pid(Pid) ->
    Pid.

-spec assert_ms_state(term()) -> ms_state().
assert_ms_state(State) when is_record(State, ms_state) ->
    State.

-spec empty_type_results() -> type_results().
empty_type_results() ->
    #{
        total_calls => 0, mean_wait_time => 0.0, mean_service_time => 0.0,
        mean_system_time => 0.0, mean_queue_length => 0.0, offered_load => 0.0
    }.

-spec empty_results() -> results().
empty_results() ->
    #{
        total_calls => 0, mean_wait_time => 0.0, mean_service_time => 0.0,
        mean_system_time => 0.0, mean_queue_length => 0.0,
        mean_system_length => 0.0, agent_utilization => 0.0
    }.

-spec default_seed() -> {pos_integer(), pos_integer(), pos_integer()}.
default_seed() ->
    {12345, 67890, 11121}.
