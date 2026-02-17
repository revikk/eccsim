-module(eccsim_metrics).

-export([build/4, to_csv/1]).

-include("eccsim.hrl").

-opaque metric_point() :: #{
    time := float(),
    arrivals := non_neg_integer(),
    completions := non_neg_integer(),
    mean_wait_time := float(),
    mean_service_time := float(),
    queue_length := float(),
    system_length := float(),
    utilization := float()
}.

-export_type([metric_point/0, snapshot/0, call_record/0]).

-spec build([snapshot()], [call_record()], number(), pos_integer()) -> [metric_point()].
build(Snapshots, Completed, Interval, C) ->
    BucketMap = bucket_calls(Completed, Interval),
    build_points(Snapshots, BucketMap, Interval, C, []).

%%% Internal
%%% ========

-spec build_points([snapshot()], map(), number(), pos_integer(), [metric_point()]) ->
    [metric_point()].
build_points([], _BucketMap, _Interval, _C, Acc) ->
    lists:reverse(Acc);
build_points([Snap | Rest], BucketMap, Interval, C, Acc) ->
    T = Snap#snapshot.time,
    BucketKey = bucket_key(T, Interval),
    {Arrivals, Completions, WaitSum, ServiceSum} = maps:get(BucketKey, BucketMap, {0, 0, 0.0, 0.0}),
    MeanWait = safe_div(WaitSum, Completions),
    MeanService = safe_div(ServiceSum, Completions),
    Point = #{
        time => float(T),
        arrivals => Arrivals,
        completions => Completions,
        mean_wait_time => MeanWait,
        mean_service_time => MeanService,
        queue_length => float(Snap#snapshot.queue_len),
        system_length => float(Snap#snapshot.queue_len + Snap#snapshot.in_service),
        utilization => Snap#snapshot.in_service / (C * 1.0)
    },
    build_points(Rest, BucketMap, Interval, C, [Point | Acc]).

-spec bucket_calls([call_record()], number()) -> map().
bucket_calls(Completed, Interval) ->
    lists:foldl(fun(Rec, Acc) ->
        #call_record{arrival_time = A, service_start = S, service_end = E} = Rec,
        ArrBucket = bucket_key(A, Interval),
        CompBucket = bucket_key(E, Interval),
        Wait = S - A,
        Service = E - S,
        Acc1 = maps:update_with(ArrBucket, fun({Ar, Co, W, Sv}) ->
            {Ar + 1, Co, W, Sv}
        end, {1, 0, 0.0, 0.0}, Acc),
        maps:update_with(CompBucket, fun({Ar, Co, W, Sv}) ->
            {Ar, Co + 1, W + Wait, Sv + Service}
        end, {0, 1, Wait, Service}, Acc1)
    end, #{}, Completed).

-spec bucket_key(number(), number()) -> non_neg_integer().
bucket_key(Time, Interval) ->
    trunc(Time / Interval).

-spec safe_div(float(), non_neg_integer()) -> float().
safe_div(_Num, 0) -> 0.0;
safe_div(Num, Den) -> Num / Den.

-define(CSV_HEADER, "time,arrivals,completions,mean_wait_time,mean_service_time,"
    "queue_length,system_length,utilization\n").

-spec to_csv([metric_point()]) -> iodata().
to_csv(TimeSeries) ->
    [?CSV_HEADER | lists:map(fun point_to_csv_row/1, TimeSeries)].

-spec point_to_csv_row(metric_point()) -> iodata().
point_to_csv_row(P) ->
    io_lib:format("~.2f,~B,~B,~.6f,~.6f,~.2f,~.2f,~.6f~n", [
        maps:get(time, P),
        maps:get(arrivals, P),
        maps:get(completions, P),
        maps:get(mean_wait_time, P),
        maps:get(mean_service_time, P),
        maps:get(queue_length, P),
        maps:get(system_length, P),
        maps:get(utilization, P)
    ]).
