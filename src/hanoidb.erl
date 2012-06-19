%% ----------------------------------------------------------------------------
%%
%% hanoidb: LSM-trees (Log-Structured Merge Trees) Indexed Storage
%%
%% Copyright 2011-2012 (c) Trifork A/S.  All Rights Reserved.
%% http://trifork.com/ info@trifork.com
%%
%% Copyright 2012 (c) Basho Technologies, Inc.  All Rights Reserved.
%% http://basho.com/ info@basho.com
%%
%% This file is provided to you under the Apache License, Version 2.0 (the
%% "License"); you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
%% License for the specific language governing permissions and limitations
%% under the License.
%%
%% ----------------------------------------------------------------------------

-module(hanoidb).
-author('Kresten Krab Thorup <krab@trifork.com>').


-behavior(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([open/1, open/2, transact/2, close/1, get/2, lookup/2, delete/2, put/3, put/4,
         fold/3, fold_range/4, destroy/1]).

-export([get_opt/2, get_opt/3]).

-include("hanoidb.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("include/hanoidb.hrl").
-include_lib("include/plain_rpc.hrl").

-record(state, { top, nursery, dir, opt, max_level }).

%% 0 means never expire
-define(DEFAULT_EXPIRY_SECS, 0).

-ifdef(DEBUG).
-define(log(Fmt,Args),io:format(user,Fmt,Args)).
-else.
-define(log(Fmt,Args),ok).
-endif.


%% PUBLIC API

-type hanoidb() :: pid().
-type key_range() :: #key_range{}.
-type config_option() :: {compress, none | gzip | snappy} %lz4
                       | {page_size, pos_integer()}
                       | {read_buffer_size, pos_integer()}
                       | {write_buffer_size, pos_integer()}
                       | {merge_strategy, fast | predictable }
                       | {sync_strategy, none | sync | {seconds, pos_integer()}}
                       | {expiry_secs, non_neg_integer()}
                       .

% @doc
% Create or open a hanoidb store.  Argument `Dir' names a
% directory in which to keep the data files.  By convention, we
% name hanoidb data directories with extension ".hanoidb".
% @spec open(Dir::string()) -> hanoidb()
- spec open(Dir::string()) -> hanoidb().
open(Dir) ->
    open(Dir, []).

% @doc Create or open a hanoidb store.
% @spec open(Dir::string(), Options::[config_option()]) -> hanoidb()
- spec open(Dir::string(), Opts::[config_option()]) -> hanoidb().
open(Dir, Opts) ->
    ok = start_app(),
    gen_server:start(?MODULE, [Dir, Opts], []).

% @doc
% Close a Hanoi data store.
% @spec close(Ref::pid()) -> ok
- spec close(Ref::pid()) -> ok.
close(Ref) ->
    try
        gen_server:call(Ref, close, infinity)
    catch
        exit:{noproc,_} -> ok;
        exit:noproc -> ok;
        %% Handle the case where the monitor triggers
        exit:{normal, _} -> ok
    end.

-spec destroy(Ref::pid()) -> ok.
destroy(Ref) ->
    try
        gen_server:call(Ref, destroy, infinity)
    catch
        exit:{noproc,_} -> ok;
        exit:noproc -> ok;
        %% Handle the case where the monitor triggers
        exit:{normal, _} -> ok
    end.

get(Ref,Key) when is_binary(Key) ->
    gen_server:call(Ref, {get, Key}, infinity).

%% for compatibility with original code
lookup(Ref,Key) when is_binary(Key) ->
    gen_server:call(Ref, {get, Key}, infinity).

-spec delete(hanoidb(), binary()) ->
                    ok | {error, term()}.
delete(Ref,Key) when is_binary(Key) ->
    gen_server:call(Ref, {delete, Key}, infinity).

-spec put(hanoidb(), binary(), binary()) ->
                 ok | {error, term()}.
put(Ref,Key,Value) when is_binary(Key), is_binary(Value) ->
    gen_server:call(Ref, {put, Key, Value, infinity}, infinity).

-spec put(hanoidb(), binary(), binary(), integer()) ->
                 ok | {error, term()}.
put(Ref,Key,Value,infinity) when is_binary(Key), is_binary(Value) ->
    gen_server:call(Ref, {put, Key, Value, infinity}, infinity);
put(Ref,Key,Value,Expiry) when is_binary(Key), is_binary(Value) ->
    gen_server:call(Ref, {put, Key, Value, Expiry}, infinity).

-type transact_spec() :: {put, binary(), binary()} | {delete, binary()}.
-spec transact(hanoidb(), [transact_spec()]) ->
                 ok | {error, term()}.
transact(Ref, TransactionSpec) ->
    gen_server:call(Ref, {transact, TransactionSpec}, infinity).

-type kv_fold_fun() ::  fun((binary(),binary(),any())->any()).

-spec fold(hanoidb(),kv_fold_fun(),any()) -> any().
fold(Ref,Fun,Acc0) ->
    fold_range(Ref,Fun,Acc0,#key_range{from_key= <<>>, to_key=undefined}).

-spec fold_range(hanoidb(),kv_fold_fun(),any(),key_range()) -> any().
fold_range(Ref,Fun,Acc0,#key_range{limit=Limit}=Range) ->
    RangeType = case Limit < 10 of
                    true -> blocking_range;
                    false -> snapshot_range
                end,
    {ok, FoldWorkerPID} = hanoidb_fold_worker:start(self()),
    ?log("fold_range begin: self=~p, worker=~p~n", [self(), FoldWorkerPID]),
    ok = gen_server:call(Ref, {RangeType, FoldWorkerPID, Range}, infinity),
    MRef = erlang:monitor(process, FoldWorkerPID),
    Result = receive_fold_range(MRef, FoldWorkerPID, Fun, Acc0, Limit),
    ?log("fold_range done: self:~p, result=~P~n", [self(), Result]),
    Result.

receive_fold_range(MRef,PID,_,Acc0, 0) ->
    erlang:exit(PID, shutdown),
    drain_worker_and_return(MRef,PID,Acc0);

receive_fold_range(MRef,PID,Fun,Acc0, Limit) ->
    ?log("receive_fold_range:~p,~P~n", [PID,Acc0,10]),
    receive

        %% receive one K/V from fold_worker
        ?CALL(From, {fold_result, PID, K,V}) ->
            plain_rpc:send_reply(From, ok),
            case
                try
                    {ok, Fun(K,V,Acc0)}
                catch
                    Class:Exception ->
                        % TODO ?log("Exception in hanoidb fold: ~p ~p", [Exception, erlang:get_stacktrace()]),
                        {'EXIT', Class, Exception, erlang:get_stacktrace()}
                end
            of
                {ok, Acc1} ->
                    receive_fold_range(MRef, PID, Fun, Acc1, decr(Limit));
                Exit ->
                    %% kill the fold worker ...
                    erlang:exit(PID, shutdown),
                    drain_worker_and_throw(MRef,PID,Exit)
            end;

        ?CAST(_,{fold_limit, PID, _}) ->
            ?log("> fold_limit pid=~p, self=~p~n", [PID, self()]),
            erlang:demonitor(MRef, [flush]),
            Acc0;
        ?CAST(_,{fold_done, PID}) ->
            ?log("> fold_done pid=~p, self=~p~n", [PID, self()]),
            erlang:demonitor(MRef, [flush]),
            Acc0;
        {'DOWN', MRef, _, _PID, normal} ->
            ?log("> fold worker ~p ENDED~n", [_PID]),
            Acc0;
        {'DOWN', MRef, _, _PID, Reason} ->
            ?log("> fold worker ~p DOWN reason:~p~n", [_PID, Reason]),
            error({fold_worker_died, Reason})
    end.

decr(undefined) ->
    undefined;
decr(N) ->
    N-1.

%%
%% Just calls erlang:raise with appropriate arguments
%%
raise({'EXIT', Class, Exception, Trace}) ->
    erlang:raise(Class, Exception, Trace).

%%
%% When an exception has happened in the fold function, we use
%% this to drain messages coming from the fold_worker before
%% re-throwing the exception.
%%
drain_worker_and_throw(MRef, PID, ExitTuple) ->
    receive
        ?CALL(_From,{fold_result, PID, _, _}) ->
            drain_worker_and_throw(MRef, PID, ExitTuple);
        {'DOWN', MRef, _, _, _} ->
            raise(ExitTuple);
        ?CAST(_,{fold_limit, PID, _}) ->
            erlang:demonitor(MRef, [flush]),
            raise(ExitTuple);
        ?CAST(_,{fold_done, PID}) ->
            erlang:demonitor(MRef, [flush]),
            raise(ExitTuple)
    after 0 ->
            raise(ExitTuple)
    end.

drain_worker_and_return(MRef, PID, Value) ->
    receive
        ?CALL(_From,{fold_result, PID, _, _}) ->
            drain_worker_and_return(MRef, PID, Value);
        {'DOWN', MRef, _, _, _} ->
            Value;
        ?CAST(_,{fold_limit, PID, _}) ->
            erlang:demonitor(MRef, [flush]),
            Value;
        ?CAST(_,{fold_done, PID}) ->
            erlang:demonitor(MRef, [flush]),
            Value
    after 0 ->
            Value
    end.


init([Dir, Opts0]) ->
    %% ensure expory_secs option is set in config
    case get_opt(expiry_secs, Opts0) of
        undefined ->
            Opts = [{expiry_secs, ?DEFAULT_EXPIRY_SECS}|Opts0];
        N when is_integer(N), N >= 0 ->
            Opts = [{expiry_secs, N}|Opts0]
    end,

    hanoidb_util:ensure_expiry(Opts),

    case file:read_file_info(Dir) of
        {ok, #file_info{ type=directory }} ->
            {ok, TopLevel, MaxLevel} = open_levels(Dir,Opts),
            {ok, Nursery} = hanoidb_nursery:recover(Dir, TopLevel, MaxLevel, Opts);

        {error, E} when E =:= enoent ->
            ok = file:make_dir(Dir),
            {ok, TopLevel} = hanoidb_level:open(Dir, ?TOP_LEVEL, undefined, Opts, self()),
            MaxLevel = ?TOP_LEVEL,
            {ok, Nursery} = hanoidb_nursery:new(Dir, MaxLevel, Opts)
    end,

    {ok, #state{ top=TopLevel, dir=Dir, nursery=Nursery, opt=Opts, max_level=MaxLevel }}.



open_levels(Dir,Options) ->
    {ok, Files} = file:list_dir(Dir),

    %% parse file names and find max level
    {MinLevel,MaxLevel} =
        lists:foldl(fun(FileName, {MinLevel,MaxLevel}) ->
                            case parse_level(FileName) of
                                {ok, Level} ->
                                    { erlang:min(MinLevel, Level),
                                      erlang:max(MaxLevel, Level) };
                                _ ->
                                    {MinLevel,MaxLevel}
                            end
                    end,
                    {?TOP_LEVEL, ?TOP_LEVEL},
                    Files),

%    error_logger:info_msg("found level files ... {~p,~p}~n", [MinLevel, MaxLevel]),

    %% remove old nursery file
    file:delete(filename:join(Dir,"nursery.data")),

    %%
    %% Do enough incremental merge to be sure we won't deadlock in insert
    %%
    {TopLevel, MaxMerge} =
        lists:foldl( fun(LevelNo, {NextLevel, MergeWork0}) ->
                             {ok, Level} = hanoidb_level:open(Dir,LevelNo,NextLevel,Options,self()),

                             MergeWork = MergeWork0 + hanoidb_level:unmerged_count(Level),

                             {Level, MergeWork}
                     end,
                     {undefined, 0},
                     lists:seq(MaxLevel, min(?TOP_LEVEL, MinLevel), -1)),

    WorkPerIter = (MaxLevel-MinLevel+1)*?IDX_LEVEL_SIZE(?TOP_LEVEL),
    do_merge(TopLevel, WorkPerIter, MaxMerge),

    {ok, TopLevel, MaxLevel}.

do_merge(TopLevel, _Inc, N) when N =< 0 ->
    ok = hanoidb_level:await_incremental_merge(TopLevel);

do_merge(TopLevel, Inc, N) ->
    ok = hanoidb_level:begin_incremental_merge(TopLevel, ?IDX_LEVEL_SIZE(?TOP_LEVEL)),
    do_merge(TopLevel, Inc, N-Inc).



parse_level(FileName) ->
    case re:run(FileName, "^[^\\d]+-(\\d+)\\.data$", [{capture,all_but_first,list}]) of
        {match,[StringVal]} ->
            {ok, list_to_integer(StringVal)};
        _ ->
            nomatch
    end.


handle_info({bottom_level, N}, #state{ nursery=Nursery, top=TopLevel }=State)
  when N > State#state.max_level ->
    State2 = State#state{ max_level = N,
                          nursery= hanoidb_nursery:set_max_level(Nursery, N) },

    hanoidb_level:set_max_level(TopLevel, N),

    {noreply, State2};

handle_info(Info,State) ->
    error_logger:error_msg("Unknown info ~p~n", [Info]),
    {stop,bad_msg,State}.

handle_cast(Info,State) ->
    error_logger:error_msg("Unknown cast ~p~n", [Info]),
    {stop,bad_msg,State}.


%% premature delete -> cleanup
terminate(normal,_State) ->
    ok;
terminate(_Reason,_State) ->
    error_logger:info_msg("got terminate(~p,~p)~n", [_Reason,_State]),
    % flush_nursery(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



handle_call({snapshot_range, FoldWorkerPID, Range}, _From, State=#state{ top=TopLevel, nursery=Nursery }) ->
    hanoidb_nursery:do_level_fold(Nursery, FoldWorkerPID, Range),
    Result = hanoidb_level:snapshot_range(TopLevel, FoldWorkerPID, Range),
    {reply, Result, State};

handle_call({blocking_range, FoldWorkerPID, Range}, _From, State=#state{ top=TopLevel, nursery=Nursery }) ->
    hanoidb_nursery:do_level_fold(Nursery, FoldWorkerPID, Range),
    Result = hanoidb_level:blocking_range(TopLevel, FoldWorkerPID, Range),
    {reply, Result, State};

handle_call({put, Key, Value, Expiry}, _From, State) when is_binary(Key), is_binary(Value) ->
    {ok, State2} = do_put(Key, Value, Expiry, State),
    {reply, ok, State2};

handle_call({transact, TransactionSpec}, _From, State) ->
    {ok, State2} = do_transact(TransactionSpec, State),
    {reply, ok, State2};

handle_call({delete, Key}, _From, State) when is_binary(Key) ->
    {ok, State2} = do_put(Key, ?TOMBSTONE, infinity, State),
    {reply, ok, State2};

handle_call({get, Key}, From, State=#state{ top=Top, nursery=Nursery } ) when is_binary(Key) ->
    case hanoidb_nursery:lookup(Key, Nursery) of
        {value, ?TOMBSTONE} ->
            {reply, not_found, State};
        {value, Value} when is_binary(Value) ->
            {reply, {ok, Value}, State};
        none ->
            hanoidb_level:lookup(Top, Key, fun(Reply) -> gen_server:reply(From, Reply) end),
            {noreply, State}
    end;

handle_call(close, _From, State=#state{top=Top}) ->
    try
        {ok, State2} = flush_nursery(State),
        ok = hanoidb_level:close(Top),
        {stop, normal, ok, State2}
    catch
        E:R ->
            error_logger:info_msg("exception from close ~p:~p~n", [E,R]),
            {stop, normal, ok, State}
    end;

handle_call(destroy, _From, State=#state{top=Top, nursery=Nursery }) ->
    ok = hanoidb_nursery:destroy(Nursery),
    ok = hanoidb_level:destroy(Top),
    {stop, normal, ok, State#state{ top=undefined, nursery=undefined, max_level=?TOP_LEVEL }}.


do_put(Key, Value, Expiry, State=#state{ nursery=Nursery, top=Top }) ->
    {ok, Nursery2} = hanoidb_nursery:add(Key, Value, Expiry, Nursery, Top),
    {ok, State#state{nursery=Nursery2}}.

do_transact([{put, Key, Value}], State) ->
    do_put(Key, Value, infinity, State);
do_transact([{delete, Key}], State) ->
    do_put(Key, ?TOMBSTONE, infinity, State);
do_transact([], State) ->
    {ok, State};
do_transact(TransactionSpec, State=#state{ nursery=Nursery, top=Top }) ->
    {ok, Nursery2} = hanoidb_nursery:transact(TransactionSpec, Nursery, Top),
    {ok, State#state{ nursery=Nursery2 }}.

flush_nursery(State=#state{nursery=Nursery, top=Top, dir=Dir, max_level=MaxLevel, opt=Config }) ->
    ok = hanoidb_nursery:finish(Nursery, Top),
    {ok, Nursery2} = hanoidb_nursery:new(Dir, MaxLevel, Config),
    {ok, State#state{ nursery=Nursery2 }}.

start_app() ->
    case application:start(?MODULE) of
        ok ->
            ok;
        {error, {already_started, ?MODULE}} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

get_opt(Key, Opts) ->
    get_opt(Key, Opts, undefined).

get_opt(Key, Opts, Default) ->
    case proplists:get_value(Key, Opts) of
        undefined ->
            case application:get_env(?MODULE, Key) of
                {ok, Value} -> Value;
                undefined -> Default
            end;
        Value ->
            Value
    end.
