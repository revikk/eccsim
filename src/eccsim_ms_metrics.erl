-module(eccsim_ms_metrics).

-moduledoc "Time-series metrics builder and CSV exporter for multi-skill simulations.
Combines snapshot-captured arrival counts with bucketed completion metrics
to produce per-type cumulative time-series, rendered as CSV rows.".

-export([build/5, ma_to_csv/2, agent_counts/2]).

-include("eccsim.hrl").

-opaque ms_metric_point() :: #{
    time := float(),
    call_type := atom(),
    arrivals := non_neg_integer(),
    completions := non_neg_integer(),
    mean_wait_time := float(),
    mean_service_time := float(),
    queue_length := non_neg_integer(),
    in_service := non_neg_integer(),
    exclusive_agents := non_neg_integer(),
    shared_agents := non_neg_integer()
}.

-export_type([ms_metric_point/0, ms_snapshot/0, ms_call_record/0, agent_counts/0, agent/0]).

-opaque agent_counts() :: #{atom() => {non_neg_integer(), non_neg_integer()}}.

-doc "Compute exclusive and shared agent counts per call type.
Exclusive agents have only one skill; shared agents have multiple skills.".
-spec agent_counts([agent()], [atom()]) -> agent_counts().
agent_counts(Agents, TypeNames) ->
    Init = maps:from_keys(TypeNames, {0, 0}),
    lists:foldl(fun(#agent{skills = Skills}, Acc) ->
        IsShared = length(Skills) > 1,
        lists:foldl(fun(T, InnerAcc) ->
            {Excl, Shr} = maps:get(T, InnerAcc, {0, 0}),
            case IsShared of
                true -> InnerAcc#{T := {Excl, Shr + 1}};
                false -> InnerAcc#{T := {Excl + 1, Shr}}
            end
        end, Acc, Skills)
    end, Init, Agents).

-doc "Build time-series metric points from snapshots and completed call records.
AgentCounts maps call_type to {ExclusiveAgents, SharedAgents}.".
-spec build([ms_snapshot()], [ms_call_record()], number(), [atom()], agent_counts()) ->
    [ms_metric_point()].
build(Snapshots, Completed, Interval, TypeNames, AgentCounts) ->
    BucketMap = bucket_calls(Completed, Interval),
    InitCum = maps:from_keys(TypeNames, {0, 0.0, 0.0}),
    build_points(Snapshots, BucketMap, Interval, TypeNames, AgentCounts, 0, InitCum, []).

%%% Multi-account CSV
%%% =================

-define(MA_CSV_HEADER, "time,account,call_type,arrivals,completions,mean_wait_time,"
    "mean_service_time,queue_length,in_service,exclusive_agents,shared_agents\n").

-doc "Convert multi-account time-series data to CSV iodata.
StartTime is a Unix timestamp (seconds) used as the base for the time column.".
-spec ma_to_csv([{term(), [ms_metric_point()]}], integer()) -> iodata().
ma_to_csv(AccountTimeSeries, StartTime) ->
    Tagged = [{maps:get(time, P), AccountId, maps:get(call_type, P),
               ma_point_to_csv_row(AccountId, P, StartTime)}
              || {AccountId, TS} <- AccountTimeSeries, P <- TS],
    Sorted = lists:sort(Tagged),
    [?MA_CSV_HEADER | [Row || {_, _, _, Row} <- Sorted]].

-spec ma_point_to_csv_row(term(), ms_metric_point(), integer()) -> iodata().
ma_point_to_csv_row(AccountId, P, StartTime) ->
    Timestamp = StartTime + round(maps:get(time, P)),
    io_lib:format("~B,~w,~s,~B,~B,~.6f,~.6f,~B,~B,~B,~B~n", [
        Timestamp,
        AccountId,
        maps:get(call_type, P),
        maps:get(arrivals, P),
        maps:get(completions, P),
        maps:get(mean_wait_time, P),
        maps:get(mean_service_time, P),
        maps:get(queue_length, P),
        maps:get(in_service, P),
        maps:get(exclusive_agents, P),
        maps:get(shared_agents, P)
    ]).

%%% Internal — time-series build
%%% ============================

-type cum() :: #{atom() => {non_neg_integer(), float(), float()}}.

-spec build_points([ms_snapshot()], map(), number(), [atom()], agent_counts(),
                   non_neg_integer(), cum(), [ms_metric_point()]) ->
    [ms_metric_point()].
build_points([], _BucketMap, _Interval, _TypeNames, _AgentCounts, _PrevKey, _Cum, Acc) ->
    lists:reverse(Acc);
build_points([Snap | Rest], BucketMap, Interval, TypeNames, AgentCounts, PrevKey, Cum, Acc) ->
    BucketKey = bucket_key(Snap#ms_snapshot.time, Interval),
    %% Accumulate only fully elapsed buckets [PrevKey, BucketKey).
    %% The current bucket is still in progress at snapshot time.
    Cum1 = accumulate_buckets(PrevKey, BucketKey, TypeNames, BucketMap, Cum),
    TypePoints = build_type_points(Snap, TypeNames, Cum1, AgentCounts),
    build_points(Rest, BucketMap, Interval, TypeNames, AgentCounts, BucketKey, Cum1, TypePoints ++ Acc).

%% Accumulate arrival/completion counts and wait/service sums from
%% buckets [From, To) that fall between two consecutive snapshots.
-spec accumulate_buckets(non_neg_integer(), non_neg_integer(), [atom()], map(), cum()) -> cum().
accumulate_buckets(From, To, _TypeNames, _BucketMap, Cum) when From >= To ->
    Cum;
accumulate_buckets(From, To, TypeNames, BucketMap, Cum) ->
    Cum1 = lists:foldl(fun(T, CumAcc) ->
        {BComp, BWait, BSvc} = get_bucket(From, T, BucketMap),
        {PrevComp, PrevWait, PrevSvc} = maps:get(T, CumAcc),
        CumAcc#{T := {PrevComp + BComp, PrevWait + BWait, PrevSvc + BSvc}}
    end, Cum, TypeNames),
    accumulate_buckets(From + 1, To, TypeNames, BucketMap, Cum1).

-spec build_type_points(ms_snapshot(), [atom()], cum(), agent_counts()) -> [ms_metric_point()].
build_type_points(Snap, TypeNames, Cum, AgentCounts) ->
    lists:map(fun(T) ->
        {CumComp, CumWait, CumSvc} = maps:get(T, Cum),
        QLens = maps:get(T, Snap#ms_snapshot.queue_lens, 0),
        InSvc = maps:get(T, Snap#ms_snapshot.in_service, 0),
        CumArr = maps:get(T, Snap#ms_snapshot.arrivals, 0),
        {Exclusive, Shared} = maps:get(T, AgentCounts, {0, 0}),
        #{
            time => float(Snap#ms_snapshot.time),
            call_type => T,
            arrivals => CumArr,
            completions => CumComp,
            mean_wait_time => safe_div(CumWait, CumComp),
            mean_service_time => safe_div(CumSvc, CumComp),
            queue_length => QLens,
            in_service => InSvc,
            exclusive_agents => Exclusive,
            shared_agents => Shared
        }
    end, TypeNames).

-spec get_bucket(non_neg_integer(), atom(), map()) ->
    {non_neg_integer(), float(), float()}.
get_bucket(BucketKey, CallType, BucketMap) ->
    maps:get({BucketKey, CallType}, BucketMap, {0, 0.0, 0.0}).

-spec bucket_calls([ms_call_record()], number()) -> map().
bucket_calls(Completed, Interval) ->
    lists:foldl(fun(Rec, Acc) ->
        #ms_call_record{call_type = T, service_start = S, service_end = E} = Rec,
        CompBucket = bucket_key(E, Interval),
        Wait = S - Rec#ms_call_record.arrival_time,
        Service = E - S,
        CompKey = {CompBucket, T},
        maps:update_with(CompKey, fun({Co, W, Sv}) ->
            {Co + 1, W + Wait, Sv + Service}
        end, {1, Wait, Service}, Acc)
    end, #{}, Completed).

-spec bucket_key(number(), number()) -> non_neg_integer().
bucket_key(Time, Interval) ->
    trunc(Time / Interval).

-spec safe_div(float(), non_neg_integer()) -> float().
safe_div(_Num, 0) -> 0.0;
safe_div(Num, Den) -> Num / Den.
