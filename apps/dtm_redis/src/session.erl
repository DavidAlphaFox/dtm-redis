%% Copyright (C) 2011-2012 IMVU Inc.
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy of
%% this software and associated documentation files (the "Software"), to deal in
%% the Software without restriction, including without limitation the rights to
%% use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
%% of the Software, and to permit persons to whom the Software is furnished to do
%% so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.

-module(session).
-export([start/3]).

-include("protocol.hrl").

-record(transaction, {current, buckets}).
-record(state, {txn_id=none, buckets, monitors, transaction=none, watches=none, stream}).

start(shell, BucketMap, Monitors) ->
    io:format("starting shell session with pid ~p~n", [self()]),
    loop(shell, #state{buckets=BucketMap, monitors=Monitors});
start(Client, BucketMap, Monitors) ->
    loop(Client, #state{buckets=BucketMap, monitors=Monitors, stream=redis_protocol:init()}),
    gen_tcp:close(Client).

loop(Client, State) ->
    receive
        {tcp, Client, Data} ->
            {NewStream, Result} = redis_protocol:parse_stream(State#state.stream, Data),
            NewState = State#state{stream=NewStream},
            if
                is_record(Result, command) ->
                    loop(Client, handle_tcp_command(Client, NewState, Result));
                Result == protocol_error ->
                    io:format("unexpected data received from client connection, aborting~n", []);
                Result == incomplete ->
                    loop(Client, NewState)
            end;
        {tcp_closed, Client} ->
            none;
        {From, watch, Key} ->
            loop(Client, handle_watch(State, From, Key));
        {From, unwatch} ->
            loop(Client, handle_unwatch(State, From));
        {From, multi} ->
            loop(Client, handle_multi(State, From));
        {From, exec} ->
            loop(Client, handle_exec(State, From));
        {From, Key, Operation} ->
            loop(Client, handle_operation(State, From, Key, Operation));
        stop ->
            io:format("dtm-redis shell halting after receiving stop message~n");
        Any ->
            io:format("session received message ~p~n", [Any]),
            loop(Client, State)
    end.

get_txn_id(#state{txn_id=none, monitors=Monitors}=State) ->
    TransactionId = txn_monitor:allocate(Monitors),
    {TransactionId, State#state{txn_id=TransactionId}};
get_txn_id(#state{txn_id=TransactionId}=State) ->
    {TransactionId, State}.

handle_tcp_command(Client, State, {command, Name, Parameters}) ->
    Lower = string:to_lower(binary_to_list(Name)),
    case Lower of
        "get" ->
            [GetKey] = Parameters,
            handle_operation(State, Client, GetKey, #get{key=GetKey});
        "set" ->
            [SetKey, SetValue] = Parameters,
            handle_operation(State, Client, SetKey, #set{key=SetKey, value=SetValue});
        "del" ->
            [DeleteKey] = Parameters,
            handle_operation(State, Client, DeleteKey, #delete{key=DeleteKey});
        "watch" ->
            [WatchKey] = Parameters,
            handle_watch(State, Client, WatchKey);
        "unwatch" ->
            handle_unwatch(State, Client);
        "multi" ->
            handle_multi(State, Client);
        "exec" ->
            handle_exec(State, Client);
        Any ->
            io:format("tcp command ~p not implemented~n", [Any])
    end.

handle_watch(State, From, Key) ->
    {TransactionId, NewState} = get_txn_id(State),
    Bucket = hash:worker_for_key(Key, NewState#state.buckets),
    Bucket ! #watch{txn_id=TransactionId, session=self(), key=Key},
    receive
        {Bucket, ok} -> send_watch_response(From)
    end,
    NewState#state{watches=add_watch(NewState#state.watches, Bucket)}.

add_watch(none, Bucket) ->
    sets:add_element(Bucket, sets:new());
add_watch(Watches, Bucket) ->
    sets:add_element(Bucket, Watches).

send_watch_response(From) when is_pid(From) ->
    From ! {self(), ok};
send_watch_response(From) ->
    gen_tcp:send(From, redis_protocol:format_response(ok)).

send_unwatch_response(From, Result) when is_pid(From) ->
    From ! {self(), Result};
send_unwatch_response(From, Result) ->
    gen_tcp:send(From, redis_protocol:format_response(Result)).

handle_unwatch(State, From) ->
    {Result, NewState} = send_unwatch(State),
    send_unwatch_response(From, Result),
    NewState#state{watches=none}.

send_unwatch(#state{watches=none}=State) ->
    {ok, State};
send_unwatch(#state{watches=Watches}=State) ->
    {TransactionId, NewState} = get_txn_id(State),
    sets:fold(fun(Bucket, NotUsed) -> Bucket ! #unwatch{txn_id=TransactionId, session=self()}, NotUsed end, not_used, Watches),
    {loop_unwatch(Watches, sets:size(Watches)), NewState}.

loop_unwatch(_, 0) ->
    ok;
loop_unwatch(Watches, _) ->
    receive
        {Bucket, ok} ->
            NewWatches = sets:del_element(Bucket, Watches),
            loop_unwatch(NewWatches, sets:size(NewWatches))
    end.

send_multi_response(From, Result) when is_pid(From) ->
    From ! {self(), Result};
send_multi_response(From, Result) ->
    gen_tcp:send(From, redis_protocol:format_response(Result)).

handle_multi(State, From) ->
    case State#state.transaction of
        none ->
            send_multi_response(From, ok),
            {_TransactionId, NewState} = get_txn_id(State),
            NewState#state{transaction=#transaction{current=0, buckets=sets:new()}};
        #transaction{} ->
            send_multi_response(From, error),
            State
    end.

send_exec_response(From, Result) when is_pid(From) ->
    From ! {self(), Result};
send_exec_response(From, {ok, Result}) ->
    gen_tcp:send(From, redis_protocol:format_response(Result));
send_exec_response(From, Result) ->
    gen_tcp:send(From, redis_protocol:format_response(Result)).

handle_exec(#state{txn_id=TransactionId}=State, From) ->
    case State#state.transaction of
        none ->
            send_exec_response(From, undefined),
            State;
        #transaction{buckets=Buckets} ->
            send_exec_response(From, commit_transaction(TransactionId, Buckets)),
            State#state{txn_id=none, transaction=none}
    end.

send_operation_response(From, Message) when is_pid(From) ->
    From ! Message;
send_operation_response(From, {_Self, {ok, Response}}) ->
    gen_tcp:send(From, redis_protocol:format_response(Response));
send_operation_response(From, {_Self, Response}) ->
    gen_tcp:send(From, redis_protocol:format_response(Response)).

handle_operation(#state{transaction=none}=State, From, Key, Operation) ->
    Bucket = hash:worker_for_key(Key, State#state.buckets),
    Bucket ! #command{session=self(), operation=Operation},
    receive
        {Bucket, Response} -> send_operation_response(From, {self(), Response});
        Any -> io:format("session got an unexpected message ~p~n", [Any])
    end,
    State;
handle_operation(#state{txn_id=TransactionId, transaction=Transaction}=State, From, Key, Operation) ->
    Bucket = hash:worker_for_key(Key, State#state.buckets),
    Bucket ! #transact{txn_id=TransactionId, session=self(), operation_id=Transaction#transaction.current, operation=Operation},
    receive
        {Bucket, Response} -> send_operation_response(From, {self(), Response});
        Any -> io:format("session got an unexpected message ~p~n", [Any])
    end,
    Current = Transaction#transaction.current + 1,
    Buckets = sets:add_element(Bucket, Transaction#transaction.buckets),
    NewTransaction = Transaction#transaction{current=Current, buckets=Buckets},
    State#state{transaction=NewTransaction}.

commit_transaction(TransactionId, Buckets) ->
    sets:fold(fun(Bucket, NotUsed) -> Bucket ! #lock_transaction{txn_id=TransactionId, session=self()}, NotUsed end, not_used, Buckets),
    case loop_transaction_lock(Buckets, sets:size(Buckets), false) of
        error ->
            sets:fold(fun(Bucket, NotUsed) -> Bucket ! #rollback_transaction{txn_id=TransactionId, session=self()}, NotUsed end, not_used, Buckets),
            undefined;
        ok ->
	    txn_monitor:persist(TransactionId, Buckets),
            sets:fold(fun(Bucket, NotUsed) -> Bucket ! #commit_transaction{txn_id=TransactionId, session=self()}, NotUsed end, not_used, Buckets),
            {ok, loop_transaction_commit(Buckets, [], sets:size(Buckets))}
    end.

loop_transaction_lock(_Buckets, 0, false) ->
    ok;
loop_transaction_lock(_Buckets, 0, true) ->
    error;
loop_transaction_lock(Buckets, _Size, Failure) ->
    receive
        #transaction_locked{bucket=Bucket, status=Status} ->
            NewBuckets = sets:del_element(Bucket, Buckets),
            loop_transaction_lock(NewBuckets, sets:size(NewBuckets), Failure or (Status =:= error));
        Any ->
            io:format("session got an unexpected message ~p~n", [Any])
    end.

loop_transaction_commit(_Buckets, Results, 0) ->
    [Result || {_, Result} <- lists:sort(fun({Lhs, _}, {Rhs, _}) -> Lhs =< Rhs end, lists:flatten(Results))];
loop_transaction_commit(Buckets, ResultsSoFar, _) ->
    receive
        {Bucket, Results} ->
            NewBuckets = sets:del_element(Bucket, Buckets),
            NewResultsSoFar = [Results|ResultsSoFar],
            loop_transaction_commit(NewBuckets, NewResultsSoFar, sets:size(NewBuckets));
        Any ->
            io:format("session got an unexpected message ~p~n", [Any])
    end.
