-module(eccsim_ms_metrics).

-moduledoc "Time-series metrics builder and CSV exporter for multi-skill simulations.
Buckets completed call records by interval snapshot, computes per-type metrics
with cumulative arrival/completion counters, and renders them as CSV rows.".

-export([build/4, ma_to_csv/1]).

-include("eccsim.hrl").

-opaque ms_metric_point() :: #{
    time := float(),
    call_type := atom(),
    arrivals := non_neg_integer(),
    completions := non_neg_integer(),
    mean_wait_time := float(),
    mean_service_time := float(),
    queue_length := float(),
    in_service := float()
}.

-export_type([ms_metric_point/0, ms_snapshot/0, ms_call_record/0]).

-doc "Build time-series metric points from snapshots and completed call records.".
-spec build([ms_snapshot()], [ms_call_record()], number(), [atom()]) ->
    [ms_metric_point()].
build(Snapshots, Completed, Interval, TypeNames) ->
    BucketMap = bucket_calls(Completed, Interval),
    InitCum = maps:from_keys(TypeNames, {0, 0, 0.0, 0.0}),
    build_points(Snapshots, BucketMap, Interval, TypeNames, 0, InitCum, []).

%%% Multi-account CSV
%%% =================

-define(MA_CSV_HEADER, "time,account,call_type,arrivals,completions,mean_wait_time,"
    "mean_service_time,queue_length,in_service\n").

-doc "Convert multi-account time-series data to CSV iodata.".
-spec ma_to_csv([{term(), [ms_metric_point()]}]) -> iodata().
ma_to_csv(AccountTimeSeries) ->
    Tagged = [{maps:get(time, P), AccountId, maps:get(call_type, P),
               ma_point_to_csv_row(AccountId, P)}
              || {AccountId, TS} <- AccountTimeSeries, P <- TS],
    Sorted = lists:sort(Tagged),
    [?MA_CSV_HEADER | [Row || {_, _, _, Row} <- Sorted]].

-spec ma_point_to_csv_row(term(), ms_metric_point()) -> iodata().
ma_point_to_csv_row(AccountId, P) ->
    io_lib:format("~.2f,~w,~s,~B,~B,~.6f,~.6f,~.2f,~.2f~n", [
        maps:get(time, P),
        AccountId,
        maps:get(call_type, P),
        maps:get(arrivals, P),
        maps:get(completions, P),
        maps:get(mean_wait_time, P),
        maps:get(mean_service_time, P),
        maps:get(queue_length, P),
        maps:get(in_service, P)
    ]).

%%% Internal — time-series build
%%% ============================

-type cum() :: #{atom() => {non_neg_integer(), non_neg_integer(), float(), float()}}.

-spec build_points([ms_snapshot()], map(), number(), [atom()],
                   non_neg_integer(), cum(), [ms_metric_point()]) ->
    [ms_metric_point()].
build_points([], _BucketMap, _Interval, _TypeNames, _PrevKey, _Cum, Acc) ->
    lists:reverse(Acc);
build_points([Snap | Rest], BucketMap, Interval, TypeNames, PrevKey, Cum, Acc) ->
    BucketKey = bucket_key(Snap#ms_snapshot.time, Interval),
    %% Accumulate only fully elapsed buckets [PrevKey, BucketKey).
    %% The current bucket is still in progress at snapshot time.
    Cum1 = accumulate_buckets(PrevKey, BucketKey, TypeNames, BucketMap, Cum),
    TypePoints = build_type_points(Snap, TypeNames, Cum1),
    build_points(Rest, BucketMap, Interval, TypeNames, BucketKey, Cum1, TypePoints ++ Acc).

%% Accumulate arrival/completion counts and wait/service sums from
%% buckets [From, To) that fall between two consecutive snapshots.
-spec accumulate_buckets(non_neg_integer(), non_neg_integer(), [atom()], map(), cum()) -> cum().
accumulate_buckets(From, To, _TypeNames, _BucketMap, Cum) when From >= To ->
    Cum;
accumulate_buckets(From, To, TypeNames, BucketMap, Cum) ->
    Cum1 = lists:foldl(fun(T, CumAcc) ->
        {BArr, BComp, BWait, BSvc} = get_bucket(From, T, BucketMap),
        {PrevArr, PrevComp, PrevWait, PrevSvc} = maps:get(T, CumAcc),
        CumAcc#{T := {PrevArr + BArr, PrevComp + BComp,
                      PrevWait + BWait, PrevSvc + BSvc}}
    end, Cum, TypeNames),
    accumulate_buckets(From + 1, To, TypeNames, BucketMap, Cum1).

-spec build_type_points(ms_snapshot(), [atom()], cum()) -> [ms_metric_point()].
build_type_points(Snap, TypeNames, Cum) ->
    lists:map(fun(T) ->
        {CumArr, CumComp, CumWait, CumSvc} = maps:get(T, Cum),
        QLens = maps:get(T, Snap#ms_snapshot.queue_lens, 0),
        InSvc = maps:get(T, Snap#ms_snapshot.in_service, 0),
        #{
            time => float(Snap#ms_snapshot.time),
            call_type => T,
            arrivals => CumArr,
            completions => CumComp,
            mean_wait_time => safe_div(CumWait, CumComp),
            mean_service_time => safe_div(CumSvc, CumComp),
            queue_length => float(QLens),
            in_service => float(InSvc)
        }
    end, TypeNames).

-spec get_bucket(non_neg_integer(), atom(), map()) ->
    {non_neg_integer(), non_neg_integer(), float(), float()}.
get_bucket(BucketKey, CallType, BucketMap) ->
    maps:get({BucketKey, CallType}, BucketMap, {0, 0, 0.0, 0.0}).

-spec bucket_calls([ms_call_record()], number()) -> map().
bucket_calls(Completed, Interval) ->
    lists:foldl(fun(Rec, Acc) ->
        #ms_call_record{call_type = T, arrival_time = A, service_start = S, service_end = E} = Rec,
        ArrBucket = bucket_key(A, Interval),
        CompBucket = bucket_key(E, Interval),
        Wait = S - A,
        Service = E - S,
        ArrKey = {ArrBucket, T},
        CompKey = {CompBucket, T},
        Acc1 = maps:update_with(ArrKey, fun({Ar, Co, W, Sv}) ->
            {Ar + 1, Co, W, Sv}
        end, {1, 0, 0.0, 0.0}, Acc),
        maps:update_with(CompKey, fun({Ar, Co, W, Sv}) ->
            {Ar, Co + 1, W + Wait, Sv + Service}
        end, {0, 1, Wait, Service}, Acc1)
    end, #{}, Completed).

-spec bucket_key(number(), number()) -> non_neg_integer().
bucket_key(Time, Interval) ->
    trunc(Time / Interval).

-spec safe_div(float(), non_neg_integer()) -> float().
safe_div(_Num, 0) -> 0.0;
safe_div(Num, Den) -> Num / Den.
