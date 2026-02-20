-module(eccsim_ms_metrics).

-export([build/5, to_csv/1]).

-include("eccsim.hrl").

-opaque ms_metric_point() :: #{
    time := float(),
    call_type := atom() | aggregate,
    arrivals := non_neg_integer(),
    completions := non_neg_integer(),
    mean_wait_time := float(),
    mean_service_time := float(),
    queue_length := float(),
    in_service := float(),
    utilization := float()
}.

-export_type([ms_metric_point/0, ms_snapshot/0, ms_call_record/0]).

-spec build([ms_snapshot()], [ms_call_record()], number(), [atom()], pos_integer()) ->
    [ms_metric_point()].
build(Snapshots, Completed, Interval, TypeNames, TotalAgents) ->
    BucketMap = bucket_calls(Completed, Interval),
    build_points(Snapshots, BucketMap, Interval, TypeNames, TotalAgents, []).

%%% Internal
%%% ========

-spec build_points([ms_snapshot()], map(), number(), [atom()], pos_integer(), [ms_metric_point()]) ->
    [ms_metric_point()].
build_points([], _BucketMap, _Interval, _TypeNames, _TotalAgents, Acc) ->
    lists:reverse(Acc);
build_points([Snap | Rest], BucketMap, Interval, TypeNames, TotalAgents, Acc) ->
    BucketKey = bucket_key(Snap#ms_snapshot.time, Interval),
    TypePoints = build_type_points(Snap, BucketKey, BucketMap, TypeNames),
    AggPoint = build_aggregate_point(Snap, TypePoints, TotalAgents),
    build_points(Rest, BucketMap, Interval, TypeNames, TotalAgents, [AggPoint | TypePoints] ++ Acc).

-spec build_type_points(ms_snapshot(), non_neg_integer(), map(), [atom()]) -> [ms_metric_point()].
build_type_points(Snap, BucketKey, BucketMap, TypeNames) ->
    lists:map(fun(T) ->
        {Arrivals, Completions, WaitSum, ServiceSum} = get_bucket(BucketKey, T, BucketMap),
        QLens = maps:get(T, Snap#ms_snapshot.queue_lens, 0),
        InSvc = maps:get(T, Snap#ms_snapshot.in_service, 0),
        #{
            time => float(Snap#ms_snapshot.time),
            call_type => T,
            arrivals => Arrivals,
            completions => Completions,
            mean_wait_time => safe_div(WaitSum, Completions),
            mean_service_time => safe_div(ServiceSum, Completions),
            queue_length => float(QLens),
            in_service => float(InSvc),
            utilization => 0.0
        }
    end, TypeNames).

-spec build_aggregate_point(ms_snapshot(), [ms_metric_point()], pos_integer()) -> ms_metric_point().
build_aggregate_point(Snap, TypePoints, TotalAgents) ->
    {TotalArr, TotalComp, TotalWait, TotalSvc} = lists:foldl(fun(P, {A, C, W, S}) ->
        Comp = maps:get(completions, P),
        {A + maps:get(arrivals, P), C + Comp,
         W + maps:get(mean_wait_time, P) * Comp,
         S + maps:get(mean_service_time, P) * Comp}
    end, {0, 0, 0.0, 0.0}, TypePoints),
    TotalQLens = maps:fold(fun(_K, V, Acc) -> Acc + V end, 0, Snap#ms_snapshot.queue_lens),
    TotalInSvc = maps:fold(fun(_K, V, Acc) -> Acc + V end, 0, Snap#ms_snapshot.in_service),
    #{
        time => float(Snap#ms_snapshot.time),
        call_type => aggregate,
        arrivals => TotalArr,
        completions => TotalComp,
        mean_wait_time => safe_div(TotalWait, TotalComp),
        mean_service_time => safe_div(TotalSvc, TotalComp),
        queue_length => float(TotalQLens),
        in_service => float(TotalInSvc),
        utilization => TotalInSvc / (TotalAgents * 1.0)
    }.

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

-define(CSV_HEADER, "time,call_type,arrivals,completions,mean_wait_time,mean_service_time,"
    "queue_length,in_service,utilization\n").

-spec to_csv([ms_metric_point()]) -> iodata().
to_csv(TimeSeries) ->
    [?CSV_HEADER | lists:map(fun point_to_csv_row/1, TimeSeries)].

-spec point_to_csv_row(ms_metric_point()) -> iodata().
point_to_csv_row(P) ->
    io_lib:format("~.2f,~s,~B,~B,~.6f,~.6f,~.2f,~.2f,~.6f~n", [
        maps:get(time, P),
        maps:get(call_type, P),
        maps:get(arrivals, P),
        maps:get(completions, P),
        maps:get(mean_wait_time, P),
        maps:get(mean_service_time, P),
        maps:get(queue_length, P),
        maps:get(in_service, P),
        maps:get(utilization, P)
    ]).
