-module(eccsim_metrics).

-export([build/4, build_mq/2, to_csv/1, mq_to_csv/1]).

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

-opaque mq_metric_point() :: #{
    time := float(),
    queue := atom() | aggregate,
    arrivals := non_neg_integer(),
    completions := non_neg_integer(),
    mean_wait_time := float(),
    mean_service_time := float(),
    queue_length := float(),
    system_length := float(),
    utilization := float()
}.

-export_type([metric_point/0, mq_metric_point/0, snapshot/0, call_record/0]).

-spec build([snapshot()], [call_record()], number(), pos_integer()) -> [metric_point()].
build(Snapshots, Completed, Interval, C) ->
    BucketMap = bucket_calls(Completed, Interval),
    build_points(Snapshots, BucketMap, Interval, C, []).

-spec build_mq([{atom(), [metric_point()]}], pos_integer()) -> [mq_metric_point()].
build_mq(PerQueueData, TotalAgents) ->
    TimeMap = collect_by_time(PerQueueData),
    Times = lists:sort(maps:keys(TimeMap)),
    lists:flatmap(fun(Time) ->
        QueuePoints = maps:get(Time, TimeMap),
        Tagged = [tag_point(QName, P) || {QName, P} <- QueuePoints],
        AggPoint = build_mq_aggregate(Time, QueuePoints, TotalAgents),
        Tagged ++ [AggPoint]
    end, Times).

%%% Internal — single-queue build
%%% =============================

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

%%% Internal — multi-queue merge
%%% ============================

-spec collect_by_time([{atom(), [metric_point()]}]) ->
    #{float() => [{atom(), metric_point()}]}.
collect_by_time(PerQueueData) ->
    lists:foldl(fun({QName, Series}, Acc) ->
        lists:foldl(fun(Point, InnerAcc) ->
            Time = maps:get(time, Point),
            maps:update_with(Time, fun(L) -> [{QName, Point} | L] end, [{QName, Point}], InnerAcc)
        end, Acc, Series)
    end, #{}, PerQueueData).

-spec tag_point(atom(), metric_point()) -> mq_metric_point().
tag_point(QName, Point) ->
    Point#{queue => QName}.

-spec build_mq_aggregate(float(), [{atom(), metric_point()}], pos_integer()) -> mq_metric_point().
build_mq_aggregate(Time, QueuePoints, TotalAgents) ->
    {TotalArr, TotalComp, TotalWaitW, TotalSvcW, TotalQL, TotalSL, TotalInSvc} =
        lists:foldl(fun({_QName, P}, {Ar, Co, WW, SW, QL, SL, IS}) ->
            Comp = maps:get(completions, P),
            SysLen = maps:get(system_length, P),
            QLen = maps:get(queue_length, P),
            InSvc = SysLen - QLen,
            {Ar + maps:get(arrivals, P),
             Co + Comp,
             WW + maps:get(mean_wait_time, P) * Comp,
             SW + maps:get(mean_service_time, P) * Comp,
             QL + QLen,
             SL + SysLen,
             IS + InSvc}
        end, {0, 0, 0.0, 0.0, 0.0, 0.0, 0.0}, QueuePoints),
    #{
        time => Time,
        queue => aggregate,
        arrivals => TotalArr,
        completions => TotalComp,
        mean_wait_time => safe_div(TotalWaitW, TotalComp),
        mean_service_time => safe_div(TotalSvcW, TotalComp),
        queue_length => TotalQL,
        system_length => TotalSL,
        utilization => TotalInSvc / (TotalAgents * 1.0)
    }.

%%% CSV
%%% ===

-define(CSV_HEADER, "time,arrivals,completions,mean_wait_time,mean_service_time,"
    "queue_length,system_length,utilization\n").

-spec to_csv([metric_point()]) -> iodata().
to_csv(TimeSeries) ->
    [?CSV_HEADER | lists:map(fun point_to_csv_row/1, TimeSeries)].

-spec point_to_csv_row(metric_point()) -> iodata().
point_to_csv_row(P) ->
    format_csv_row("~.2f,", [maps:get(time, P)], P).

-define(MQ_CSV_HEADER, "time,queue,arrivals,completions,mean_wait_time,mean_service_time,"
    "queue_length,system_length,utilization\n").

-spec mq_to_csv([mq_metric_point()]) -> iodata().
mq_to_csv(TimeSeries) ->
    [?MQ_CSV_HEADER | lists:map(fun mq_point_to_csv_row/1, TimeSeries)].

-spec mq_point_to_csv_row(mq_metric_point()) -> iodata().
mq_point_to_csv_row(P) ->
    format_csv_row("~.2f,~s,", [maps:get(time, P), maps:get(queue, P)], P).

-spec format_csv_row(string(), [term()], map()) -> iodata().
format_csv_row(Prefix, PrefixArgs, P) ->
    io_lib:format(Prefix ++ "~B,~B,~.6f,~.6f,~.2f,~.2f,~.6f~n", PrefixArgs ++ [
        maps:get(arrivals, P),
        maps:get(completions, P),
        maps:get(mean_wait_time, P),
        maps:get(mean_service_time, P),
        maps:get(queue_length, P),
        maps:get(system_length, P),
        maps:get(utilization, P)
    ]).
