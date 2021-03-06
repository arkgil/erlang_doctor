-module(tr).

-compile(export_all).

-behaviour(gen_server).

-record(tr, {pid, event, mfarity, data, ts}).

%% mem_usage() ->
%%     Ps = processes(),
%%     Stat = [{F, Mem, Count, Mem * Count}
%%             || {{F, Mem}, Count} <- maps:to_list(stat(Ps, fun mem_usage_key/1))],
%%     lists:reverse(lists:keysort(4, Stat)).

mem_usage_key(Pid) ->
    list_to_tuple([element(2, process_info(Pid, Attr)) || Attr <- key_attrs()]).

key_attrs() ->
    [current_function, memory].

trace_calls(Modules) ->
    gen_server:call(?MODULE, {start_trace, call, Modules}).

stop_tracing_calls() ->
    gen_server:call(?MODULE, {stop_trace, call}).

clean() ->
    gen_server:call(?MODULE, clean).

%% called_functions() ->
%%     ets_stat(trace, fun({_Pid, call, MFA, _TS}) -> mfarity(MFA) end).

%% calling_pids() ->
%%     ets_stat(trace, fun({Pid, call, _MFA, _TS}) -> Pid end).

%% calls() ->
%%     ets_stat(trace, fun({Pid, call, MFA, _TS}) -> {Pid, mfarity(MFA)} end).

flat_call_times_by_function() ->
    [{F,lists:foldl(fun({_Pid, Count, _, Time}, {TotalCount, TotalTime}) ->
                            {TotalCount + Count, TotalTime + Time}
                    end, {0, 0}, CallTimes)}
     || {F, {call_time, CallTimes}} <- raw_call_times_by_function()].

raw_call_times_by_function() ->
    [{F,erlang:trace_info(F, call_time)} || {F,_} <- maps:to_list(?MODULE:called_functions())].

%% gen_server callbacks

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec start() -> {ok, pid()}.
start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

-spec init(list()) -> {ok, map()}.
init(_Opts) ->
    ets:new(trace, [named_table, public, duplicate_bag, {keypos, 2}]),
    {ok, #{}}.

-spec handle_call(any(), {pid(), any()}, map()) -> {reply, ok, map()}.
handle_call({start_trace, call, Modules}, _From, State) ->
    [enable_trace_pattern(Mod) || Mod <- Modules],
    erlang:trace(all, true, [call, timestamp]),
    {reply, ok, State};
handle_call({stop_trace, call}, _From, State) ->
    erlang:trace_pattern({'_', '_', '_'}, false, []),
    erlang:trace(all, false, [call, timestamp]),
    {reply, ok, State};
handle_call(clean, _From, State) ->
    ets:delete_all_objects(trace),
    {reply, ok, State};
handle_call(Req, From, State) ->
    error_logger:error_msg("Unexpected call ~p from ~p.", [Req, From]),
    {reply, ok, State}.

-spec handle_cast(any(), map()) -> {noreply, map()}.
handle_cast(Msg, State) ->
    error_logger:error_msg("Unexpected message ~p.", [Msg]),
    {noreply, State}.

-spec handle_info(any(), map()) -> {noreply, map()}.
handle_info({trace_ts, Pid, call, MFA = {_, _, Args}, TS}, State) ->
    ets:insert(trace, #tr{pid = Pid, event = call, mfarity = mfarity(MFA), data = Args,
                          ts = usec:from_now(TS)}),
    {noreply, State};
handle_info({trace_ts, Pid, return_from, MFArity, Res, TS}, State) ->
    ets:insert(trace, #tr{pid = Pid, event = return_from, mfarity = MFArity, data = Res,
                          ts = usec:from_now(TS)}),
    {noreply, State};
handle_info({trace_ts, Pid, exception_from, MFArity, {Class, Value}, TS}, State) ->
    ets:insert(trace, #tr{pid = Pid, event = exception_from, mfarity = MFArity, data = {Class, Value},
                          ts = usec:from_now(TS)}),
    {noreply, State};
handle_info(Msg, State) ->
    error_logger:error_msg("Unexpected message ~p.", [Msg]),
    {noreply, State}.

-spec terminate(any(), map()) -> ok.
terminate(_Reason, #{}) ->
    ok.

-spec code_change(any(), map(), any()) -> {ok, map()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

enable_trace_pattern(Mod) when is_atom(Mod) ->
    enable_trace_pattern({Mod, '_', '_'});
enable_trace_pattern({_, _, _} = MFA) ->
    enable_trace_pattern({MFA, [local, call_time]});
enable_trace_pattern({Mod, Opts}) when is_atom(Mod) ->
    enable_trace_pattern({{Mod, '_', '_'}, Opts});
enable_trace_pattern({{M, F, A}, Opts}) ->
    code:load_file(M),
    erlang:trace_pattern({M, F, A},
                         [{'_', [], [{exception_trace}]}],
                         Opts).

%% Call stat

print_sorted_call_stat(KeyF, Length) ->
    pretty_print_tuple_list(sorted_call_stat(KeyF), Length).

sorted_call_stat(KeyF) ->
    lists:reverse(sort_by_time(call_stat(KeyF))).

call_stat(KeyF) ->
    {#{}, #{}, Stat} = ets:foldl(pa:bind(fun process_trace/3, KeyF), {#{}, #{}, #{}}, trace),
    Stat.

sort_by_time(MapStat) ->
    lists:keysort(3, [{Key, Count, AccTime, OwnTime} || {Key, {Count, AccTime, OwnTime}} <- maps:to_list(MapStat)]).

%% Trace inside function calls

trace_inside_calls(PredF) ->
    {Traces, #{}} = ets:foldl(pa:bind(fun trace_inside_call/3, PredF), {[], #{}}, trace),
    lists:reverse(Traces).

trace_inside_call(PredF, T = #tr{pid = Pid}, {Traces, State}) ->
    PidState = maps:get(Pid, State, no_state),
    case trace_pid_inside_call(PredF, T, PidState) of
        {complete, Trace} -> {[{Pid, Trace}|Traces], maps:remove(Pid, State)};
        {incomplete, NewPidState} -> {Traces, State#{Pid => NewPidState}};
        none -> {Traces, State}
    end.

trace_pid_inside_call(_PredF, T = #tr{event = call, mfarity = MFArity}, State = #{depth := Depth,
                                                                                  mfarity := MFArity,
                                                                                  trace := Trace}) ->
    {incomplete, State#{depth => Depth + 1, trace => [T|Trace]}};
trace_pid_inside_call(_PredF, T = #tr{event = call}, State = #{trace := Trace}) ->
    {incomplete, State#{trace => [T|Trace]}};
trace_pid_inside_call(PredF, T = #tr{pid = Pid, event = call, mfarity = MFArity, data = Args}, no_state) ->
    case catch PredF(Pid, MFArity, Args) of
        true -> {incomplete, #{depth => 1, mfarity => MFArity, trace => [T]}};
        _ -> none
    end;
trace_pid_inside_call(_PredF, T = #tr{event = Event, mfarity = MFArity}, #{depth := 1,
                                                                           mfarity := MFArity,
                                                                           trace := Trace})
  when Event =:= return_from;
       Event =:= exception_from ->
    {complete, lists:reverse([T|Trace])};
trace_pid_inside_call(_PredF, T = #tr{event = Event, mfarity = MFArity}, State = #{depth := Depth,
                                                                                   mfarity := MFArity,
                                                                                   trace := Trace})
  when Event =:= return_from;
       Event =:= exception_from ->
    {incomplete, State#{depth => Depth - 1, trace => [T|Trace]}};
trace_pid_inside_call(_PredF, T = #tr{event = Event}, State = #{trace := Trace})
  when Event =:= return_from;
       Event =:= exception_from ->
    {incomplete, State#{trace := [T|Trace]}};
trace_pid_inside_call(_PredF, #tr{event = Event}, no_state)
  when Event =:= return_from;
       Event =:= exception_from ->
    none.

%% Helpers

%% stat(Items, KeyF) ->
%%     lists:foldl(pa:bind(fun count_item/3, KeyF), #{}, Items).

%% ets_stat(Items, KeyF) ->
%%     ets:foldl(pa:bind(fun count_item/3, KeyF), #{}, Items).

process_item(UpdateF, KeyF, Init, ItemK, ItemV, Stat) ->
    process_item(UpdateF, KeyF, Init, {ItemK, ItemV}, Stat).

ets_stat(Tab, KeyF, UpdateF, Init) ->
    ets:foldl(pa:bind(fun process_item/5, UpdateF, KeyF, Init), #{}, Tab).

process_item(UpdateF, KeyF, Init, Item, Stat) ->
    case KeyF(Item) of
        {ok, Key} ->
            V = maps:get(Key, Stat, Init),
            Stat#{Key => UpdateF(V, Item)};
        ignore ->
            Stat
    end.

process_trace(KeyF, Tr = #tr{pid = Pid}, {ProcessStates, TmpStat, Stat}) ->
    {LastTr, LastKey, Stack} = maps:get(Pid, ProcessStates, {#tr{pid = Pid}, no_key, []}),
    {NewStack, Key} = get_key_and_update_stack(KeyF, Stack, Tr),
    TmpValue = maps:get(Key, TmpStat, none),
    ProcessStates1 = ProcessStates#{Pid => {Tr, Key, NewStack}},
    TmpStat1 = update_tmp(TmpStat, Tr, Key, TmpValue),
    Stat1 = update_stat(Stat, LastTr, LastKey, Tr, Key, TmpValue),
    {ProcessStates1, TmpStat1, Stat1}.

-define(is_return(Event), (Event =:= return_from orelse Event =:= exception_from)).

get_key_and_update_stack(KeyF, Stack, #tr{event = call, pid = Pid, mfarity = MFArity, data = Args}) ->
    MFA = mfa(MFArity, Args),
    Key = try KeyF(Pid, MFA)
          catch _:_ -> no_key
          end,
    {[Key | Stack], Key};
get_key_and_update_stack(_KeyF, [Key | Rest], #tr{event = Event}) when ?is_return(Event) ->
    {Rest, Key}.

update_tmp(TmpStat, #tr{event = call, ts = TS}, Key, none) ->
    TmpStat#{Key => {TS, 0}};
update_tmp(TmpStat, #tr{event = call}, Key, {OrigTS, N}) ->
    TmpStat#{Key => {OrigTS, N+1}};
update_tmp(TmpStat, #tr{event = Event}, Key, {OrigTS, N}) when ?is_return(Event), N > 0 ->
    TmpStat#{Key => {OrigTS, N-1}};
update_tmp(TmpStat, #tr{event = Event}, Key, {_OrigTS, 0}) when ?is_return(Event) ->
    maps:remove(Key, TmpStat).

update_stat(Stat, LastTr, LastKey, Tr, Key, TmpVal) ->
    Stat1 = update_count(Tr, Key, Stat),
    Stat2 = update_acc_time(TmpVal, Tr, Key, TmpVal, Stat1),
    update_own_time(LastTr, LastKey, Tr, Key, Stat2).

update_count(Tr, Key, Stat) ->
    case count_key(Tr, Key) of
        no_key ->
            Stat;
        KeyToUpdate ->
            {Count, AccTime, OwnTime} = maps:get(KeyToUpdate, Stat, {0, 0, 0}),
            Stat#{KeyToUpdate => {Count + 1, AccTime, OwnTime}}
    end.

update_acc_time(TmpVal, Tr, Key, TmpVal, Stat) ->
    case acc_time_key(TmpVal, Tr, Key) of
        no_key ->
            Stat;
        KeyToUpdate ->
            {Count, AccTime, OwnTime} = maps:get(KeyToUpdate, Stat, {0, 0, 0}),
            {OrigTS, _N} = TmpVal,
            NewAccTime = AccTime + Tr#tr.ts - OrigTS,
            Stat#{KeyToUpdate => {Count, NewAccTime, OwnTime}}
    end.

update_own_time(LastTr, LastKey, Tr, Key, Stat) ->
    case own_time_key(LastTr, LastKey, Tr, Key) of
        no_key ->
            Stat;
        KeyToUpdate ->
            {Count, AccTime, OwnTime} = maps:get(KeyToUpdate, Stat, {0, 0, 0}),
            NewOwnTime = OwnTime + Tr#tr.ts - LastTr#tr.ts,
            Stat#{KeyToUpdate => {Count, AccTime, NewOwnTime}}
    end.

count_key(#tr{event = call}, Key) when Key =/= no_key -> Key;
count_key(#tr{}, _) -> no_key.

acc_time_key({_, 0}, #tr{event = Event}, Key) when ?is_return(Event), Key =/= no_key -> Key;
acc_time_key(_, #tr{}, _) -> no_key.

own_time_key(#tr{event = call}, LastKey, #tr{}, _) when LastKey =/= no_key -> LastKey;
own_time_key(#tr{}, _, #tr{event = Event}, Key) when ?is_return(Event), Key =/= no_key -> Key;
own_time_key(#tr{}, _, #tr{}, _) -> no_key.

mfarity({M, F, A}) -> {M, F, maybe_length(A)}.

mfa({M, F, Arity}, Args) when length(Args) =:= Arity -> {M, F, Args}.

maybe_length(L) when is_list(L) -> length(L);
maybe_length(I) when is_integer(I) -> I.

app_modules(AppName) ->
    AppNameStr = atom_to_list(AppName),
    [P]=lists:filter(fun(Path) -> string:str(Path, AppNameStr) > 0 end, code:get_path()),
    {ok, FileNames} = file:list_dir(P),
    [list_to_atom(lists:takewhile(fun(C) -> C =/= $. end, Name)) || Name <- FileNames].

pretty_print_tuple_list(TList, MaxRows) ->
    Head = lists:sublist(TList, MaxRows),
    MaxSize = lists:max([tuple_size(T) || T <- Head]),
    L = [pad([lists:flatten(io_lib:format("~p", [Item])) || Item <- tuple_to_list(T)], MaxSize) || T <- Head],
    Widths = lists:foldl(fun(T, CurWidths) ->
                                 [max(W, length(Item)+2) || {W, Item} <- lists:zip(CurWidths, T)]
                         end, lists:duplicate(MaxSize, 2), L),
    [begin
         X = [[Item, lists:duplicate(W-length(Item), $ )] || {W, Item} <- lists:zip(Widths, T)],
         io:format("~s~n", [X])
     end || T<- L],
    ok.

pad(L, Size) when length(L) < Size -> L ++ lists:duplicate(Size-length(L), "");
pad(L, _) -> L.
