% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_mrview).

-export([query_all_docs/2, query_all_docs/4]).
-export([query_view/3, query_view/4, query_view/6]).
-export([view_changes_since/5, view_changes_since/6, view_changes_since/7]).
-export([get_last_seq/4]).
-export([get_info/2]).
-export([refresh/2]).
-export([subscribe/2, unsubscribe/2, notify/3]).
-export([compact/2, compact/3, cancel_compaction/2]).
-export([cleanup/1]).

-include_lib("couch/include/couch_db.hrl").
-include("couch_mrview.hrl").

-record(mracc, {
    db,
    meta_sent=false,
    total_rows,
    offset,
    limit,
    skip,
    group_level,
    doc_info,
    callback,
    user_acc,
    last_go=ok,
    reduce_fun,
    update_seq,
    args
}).


query_all_docs(Db, Args) ->
    query_all_docs(Db, Args, fun default_cb/2, []).


query_all_docs(Db, Args, Callback, Acc) when is_list(Args) ->
    query_all_docs(Db, to_mrargs(Args), Callback, Acc);
query_all_docs(Db, Args0, Callback, Acc) ->
    Sig = couch_util:with_db(Db, fun(WDb) ->
        {ok, Info} = couch_db:get_db_info(WDb),
        couch_index_util:hexsig(couch_util:md5(term_to_binary(Info)))
    end),
    Args1 = Args0#mrargs{view_type=map},
    Args2 = couch_mrview_util:validate_args(Args1),
    {ok, Acc1} = case Args2#mrargs.preflight_fun of
        PFFun when is_function(PFFun, 2) -> PFFun(Sig, Acc);
        _ -> {ok, Acc}
    end,
    all_docs_fold(Db, Args2, Callback, Acc1).


query_view(Db, DDoc, VName) ->
    query_view(Db, DDoc, VName, #mrargs{}).


query_view(Db, DDoc, VName, Args) when is_list(Args) ->
    query_view(Db, DDoc, VName, to_mrargs(Args), fun default_cb/2, []);
query_view(Db, DDoc, VName, Args) ->
    query_view(Db, DDoc, VName, Args, fun default_cb/2, []).


query_view(Db, DDoc, VName, Args, Callback, Acc) when is_list(Args) ->
    query_view(Db, DDoc, VName, to_mrargs(Args), Callback, Acc);
query_view(Db, DDoc, VName, Args0, Callback, Acc0) ->
    {ok, VInfo, _State, Sig, Args} = couch_mrview_util:get_view(Db, DDoc,
                                                        VName, Args0),
    {ok, Acc1} = case Args#mrargs.preflight_fun of
        PFFun when is_function(PFFun, 2) -> PFFun(Sig, Acc0);
        _ -> {ok, Acc0}
    end,
    query_view(Db, VInfo, Args, Callback, Acc1).


query_view(Db, {Type, View, Ref}, Args, Callback, Acc) ->
    try
        case Type of
            map -> map_fold(Db, View, Args, Callback, Acc);
            red -> red_fold(Db, View, Args, Callback, Acc)
        end
    after
        erlang:demonitor(Ref, [flush])
    end.

view_changes_since(Db, DDoc, VName, StartSeq, Callback) ->
    view_changes_since(Db, DDoc, VName, StartSeq, Callback, #mrargs{}, []).

view_changes_since(Db, DDoc, VName, StartSeq, Callback, Args) ->
    view_changes_since(Db, DDoc, VName, StartSeq, Callback, Args, []).

view_changes_since(Db, DDoc, VName, StartSeq, Callback, Args, Acc)
        when is_list(Args) ->
    view_changes_since(Db, DDoc, VName, StartSeq, Callback,
                       to_mrargs(Args), Acc);
view_changes_since(Db, DDoc, VName, StartSeq, Callback, Args0, Acc) ->
    {ok, VInfo,  State, _Sig, Args} = couch_mrview_util:get_view(Db, DDoc,
                                                        VName, Args0),

    {_Type, View, Ref} = VInfo,
    case View#mrview.seq_indexed of
        true ->
            try
                get_view_changes(View, State, StartSeq, Callback,
                                 Args, Acc)
            after
                erlang:demonitor(Ref, [flush])
            end;

        _ ->
            erlang:demonitor(Ref, [flush]),
            {error, seqs_not_indexed}
    end.


get_last_seq(Db, DDoc, VName, Args) when is_list(Args) ->
    get_last_seq(Db, DDoc, VName, to_mrargs(Args));
get_last_seq(Db, DDoc, VName, Args) ->
    {ok, {_, View, Ref}, State, _, _} = couch_mrview_util:get_view(Db, DDoc,
                                                             VName, Args),
    LastSeq = View#mrview.update_seq,
    case View#mrview.seq_indexed of
        true ->
            try
                get_last_seq1(View, State, LastSeq, Args)
            after
                erlang:demonitor(Ref, [flush])
            end;
        _ ->
            erlang:demonitor(Ref, [flush]),
            {ok, LastSeq}
    end.

get_info(Db, DDoc) ->
    {ok, Pid} = couch_index_server:get_index(couch_mrview_index, Db, DDoc),
    couch_index:get_info(Pid).

refresh(#db{name=DbName}, DDoc) ->
    refresh(DbName, DDoc);

refresh(Db, DDoc) ->
    UpdateSeq = couch_util:with_db(Db, fun(WDb) ->
                    couch_db:get_update_seq(WDb)
            end),

    case couch_index_server:get_index(couch_mrview_index, Db, DDoc) of
        {ok, Pid} ->
            case catch couch_index:get_state(Pid, UpdateSeq) of
                {ok, _} -> ok;
                Error -> {error, Error}
            end;
        Error ->
            {error, Error}
    end.


subscribe(DbName, DDoc) ->
    couch_mrview_events:subscribe(DbName, DDoc).

unsubscribe(DbName, DDoc) ->
    couch_mrview_events:unsubscribe(DbName, DDoc).

notify(DbName, DDoc, Event) ->
    couch_mrview_events:notify(DbName, DDoc, Event).

compact(Db, DDoc) ->
    compact(Db, DDoc, []).

compact(Db, DDoc, Opts) ->
    {ok, Pid} = couch_index_server:get_index(couch_mrview_index, Db, DDoc),
    couch_index:compact(Pid, Opts).


cancel_compaction(Db, DDoc) ->
    {ok, IPid} = couch_index_server:get_index(couch_mrview_index, Db, DDoc),
    {ok, CPid} = couch_index:get_compactor_pid(IPid),
    ok = couch_index_compactor:cancel(CPid),

    % Cleanup the compaction file if it exists
    {ok, #mrst{sig=Sig, db_name=DbName}} = couch_index:get_state(IPid, 0),
    couch_mrview_util:delete_compaction_file(DbName, Sig),
    ok.


cleanup(Db) ->
    couch_mrview_cleanup:run(Db).


all_docs_fold(Db, #mrargs{keys=undefined}=Args, Callback, UAcc) ->
    {ok, Info} = couch_db:get_db_info(Db),
    Total = couch_util:get_value(doc_count, Info),
    UpdateSeq = couch_db:get_update_seq(Db),
    Acc = #mracc{
        db=Db,
        total_rows=Total,
        limit=Args#mrargs.limit,
        skip=Args#mrargs.skip,
        callback=Callback,
        user_acc=UAcc,
        reduce_fun=fun couch_mrview_util:all_docs_reduce_to_count/1,
        update_seq=UpdateSeq,
        args=Args
    },
    [Opts] = couch_mrview_util:all_docs_key_opts(Args),
    {ok, Offset, FinalAcc} = couch_db:enum_docs(Db, fun map_fold/3, Acc, Opts),
    finish_fold(FinalAcc, [{total, Total}, {offset, Offset}]);
all_docs_fold(Db, #mrargs{direction=Dir, keys=Keys0}=Args, Callback, UAcc) ->
    {ok, Info} = couch_db:get_db_info(Db),
    Total = couch_util:get_value(doc_count, Info),
    UpdateSeq = couch_db:get_update_seq(Db),
    Acc = #mracc{
        db=Db,
        total_rows=Total,
        limit=Args#mrargs.limit,
        skip=Args#mrargs.skip,
        callback=Callback,
        user_acc=UAcc,
        reduce_fun=fun couch_mrview_util:all_docs_reduce_to_count/1,
        update_seq=UpdateSeq,
        args=Args
    },
    % Backwards compatibility hack. The old _all_docs iterates keys
    % in reverse if descending=true was passed. Here we'll just
    % reverse the list instead.
    Keys = if Dir =:= fwd -> Keys0; true -> lists:reverse(Keys0) end,

    FoldFun = fun(Key, Acc0) ->
        DocInfo = (catch couch_db:get_doc_info(Db, Key)),
        {Doc, Acc1} = case DocInfo of
            {ok, #doc_info{id=Id, revs=[RevInfo | _RestRevs]}=DI} ->
                Rev = couch_doc:rev_to_str(RevInfo#rev_info.rev),
                Props = [{rev, Rev}] ++ case RevInfo#rev_info.deleted of
                    true -> [{deleted, true}];
                    false -> []
                end,
                {{{Id, Id}, {Props}}, Acc0#mracc{doc_info=DI}};
            not_found ->
                {{{Key, error}, not_found}, Acc0}
        end,
        {_, Acc2} = map_fold(Doc, {[], [{0, 0, 0}]}, Acc1),
        Acc2
    end,
    FinalAcc = lists:foldl(FoldFun, Acc, Keys),
    finish_fold(FinalAcc, [{total, Total}]).


map_fold(Db, View, Args, Callback, UAcc) ->
    {ok, Total} = couch_mrview_util:get_row_count(View),
    Acc = #mracc{
        db=Db,
        total_rows=Total,
        limit=Args#mrargs.limit,
        skip=Args#mrargs.skip,
        callback=Callback,
        user_acc=UAcc,
        reduce_fun=fun couch_mrview_util:reduce_to_count/1,
        update_seq=View#mrview.update_seq,
        args=Args
    },
    OptList = couch_mrview_util:key_opts(Args),
    {Reds, Acc2} = lists:foldl(fun(Opts, {_, Acc0}) ->
        {ok, R, A} = couch_mrview_util:fold(View, fun map_fold/3, Acc0, Opts),
        {R, A}
    end, {nil, Acc}, OptList),
    Offset = couch_mrview_util:reduce_to_count(Reds),
    finish_fold(Acc2, [{total, Total}, {offset, Offset}]).


map_fold(#full_doc_info{} = FullDocInfo, OffsetReds, Acc) ->
    % matches for _all_docs and translates #full_doc_info{} -> KV pair
    case couch_doc:to_doc_info(FullDocInfo) of
        #doc_info{id=Id, revs=[#rev_info{deleted=false, rev=Rev}|_]} = DI ->
            Value = {[{rev, couch_doc:rev_to_str(Rev)}]},
            map_fold({{Id, Id}, Value}, OffsetReds, Acc#mracc{doc_info=DI});
        #doc_info{revs=[#rev_info{deleted=true}|_]} ->
            {ok, Acc}
    end;
map_fold(_KV, _Offset, #mracc{skip=N}=Acc) when N > 0 ->
    {ok, Acc#mracc{skip=N-1, last_go=ok}};
map_fold(KV, OffsetReds, #mracc{offset=undefined}=Acc) ->
    #mracc{
        total_rows=Total,
        callback=Callback,
        user_acc=UAcc0,
        reduce_fun=Reduce,
        update_seq=UpdateSeq,
        args=Args
    } = Acc,
    Offset = Reduce(OffsetReds),
    Meta = make_meta(Args, UpdateSeq, [{total, Total}, {offset, Offset}]),
    {Go, UAcc1} = Callback(Meta, UAcc0),
    Acc1 = Acc#mracc{meta_sent=true, offset=Offset, user_acc=UAcc1, last_go=Go},
    case Go of
        ok -> map_fold(KV, OffsetReds, Acc1);
        stop -> {stop, Acc1}
    end;
map_fold(_KV, _Offset, #mracc{limit=0}=Acc) ->
    {stop, Acc};
map_fold({{Key, Id}, Val}, _Offset, Acc) ->
    #mracc{
        db=Db,
        limit=Limit,
        doc_info=DI,
        callback=Callback,
        user_acc=UAcc0,
        args=Args
    } = Acc,
    Doc = case DI of
        #doc_info{} -> couch_mrview_util:maybe_load_doc(Db, DI, Args);
        _ -> couch_mrview_util:maybe_load_doc(Db, Id, Val, Args)
    end,
    Row = [{id, Id}, {key, Key}, {value, Val}] ++ Doc,
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{
        limit=Limit-1,
        doc_info=undefined,
        user_acc=UAcc1,
        last_go=Go
    }}.


red_fold(Db, {_Nth, _Lang, View}=RedView, Args, Callback, UAcc) ->
    Acc = #mracc{
        db=Db,
        total_rows=null,
        limit=Args#mrargs.limit,
        skip=Args#mrargs.skip,
        group_level=Args#mrargs.group_level,
        callback=Callback,
        user_acc=UAcc,
        update_seq=View#mrview.update_seq,
        args=Args
    },
    GroupFun = group_rows_fun(Args#mrargs.group_level),
    OptList = couch_mrview_util:key_opts(Args, [{key_group_fun, GroupFun}]),
    Acc2 = lists:foldl(fun(Opts, Acc0) ->
        {ok, Acc1} =
            couch_mrview_util:fold_reduce(RedView, fun red_fold/3,  Acc0, Opts),
        Acc1
    end, Acc, OptList),
    finish_fold(Acc2, []).

red_fold(_Key, _Red, #mracc{skip=N}=Acc) when N > 0 ->
    {ok, Acc#mracc{skip=N-1, last_go=ok}};
red_fold(Key, Red, #mracc{meta_sent=false}=Acc) ->
    #mracc{
        args=Args,
        callback=Callback,
        user_acc=UAcc0,
        update_seq=UpdateSeq
    } = Acc,
    Meta = make_meta(Args, UpdateSeq, []),
    {Go, UAcc1} = Callback(Meta, UAcc0),
    Acc1 = Acc#mracc{user_acc=UAcc1, meta_sent=true, last_go=Go},
    case Go of
        ok -> red_fold(Key, Red, Acc1);
        _ -> {Go, Acc1}
    end;
red_fold(_Key, _Red, #mracc{limit=0} = Acc) ->
    {stop, Acc};
red_fold(_Key, Red, #mracc{group_level=0} = Acc) ->
    #mracc{
        limit=Limit,
        callback=Callback,
        user_acc=UAcc0
    } = Acc,
    Row = [{key, null}, {value, Red}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc=UAcc1, limit=Limit-1, last_go=Go}};
red_fold(Key, Red, #mracc{group_level=exact} = Acc) ->
    #mracc{
        limit=Limit,
        callback=Callback,
        user_acc=UAcc0
    } = Acc,
    Row = [{key, Key}, {value, Red}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc=UAcc1, limit=Limit-1, last_go=Go}};
red_fold(K, Red, #mracc{group_level=I} = Acc) when I > 0, is_list(K) ->
    #mracc{
        limit=Limit,
        callback=Callback,
        user_acc=UAcc0
    } = Acc,
    Row = [{key, lists:sublist(K, I)}, {value, Red}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc=UAcc1, limit=Limit-1, last_go=Go}};
red_fold(K, Red, #mracc{group_level=I} = Acc) when I > 0 ->
    #mracc{
        limit=Limit,
        callback=Callback,
        user_acc=UAcc0
    } = Acc,
    Row = [{key, K}, {value, Red}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc=UAcc1, limit=Limit-1, last_go=Go}}.


finish_fold(#mracc{last_go=ok, update_seq=UpdateSeq}=Acc,  ExtraMeta) ->
    #mracc{callback=Callback, user_acc=UAcc, args=Args}=Acc,
    % Possible send meta info
    Meta = make_meta(Args, UpdateSeq, ExtraMeta),
    {Go, UAcc1} = case Acc#mracc.meta_sent of
        false -> Callback(Meta, UAcc);
        _ -> {ok, Acc#mracc.user_acc}
    end,
    % Notify callback that the fold is complete.
    {_, UAcc2} = case Go of
        ok -> Callback(complete, UAcc1);
        _ -> {ok, UAcc1}
    end,
    {ok, UAcc2};
finish_fold(#mracc{user_acc=UAcc}, _ExtraMeta) ->
    {ok, UAcc}.


get_view_changes(View, State, StartSeq, Callback, #mrargs{direction=Dir}=Args,
                 Acc) ->
    EndSeq = case Dir of
        fwd -> 16#10000000;
        rev -> 0
    end,
    Acc0 = {Dir, StartSeq, Acc},
    WrapperFun = fun
        ({{_ViewId, Seq}, {DocId, Key, Val}}, _Reds, {_, _, Acc2}) ->
            {ok, Acc3} = Callback({{Key, Seq}, {DocId, Val}}, Acc2),
            {ok, {fwd, Seq, Acc3}};
        ({{_Key, Seq}, _DocId}=KV, _Reds, {fwd, LastSeq, Acc2})
                when Seq > LastSeq, Seq =< EndSeq ->
            {ok, Acc3} = Callback(KV, Acc2),
            {ok, {fwd, Seq, Acc3}};
        ({{_Key, Seq}, _DocId}=KV, _Reds, {D, LastSeq, Acc2})
                when Seq < LastSeq, Seq >= EndSeq ->
            {ok, Acc3} = Callback(KV, Acc2),
            {ok, {D, Seq, Acc3}};
        (_, _, Acc2) ->
            {ok, Acc2}
    end,
    {Btree, Opts} = case {Args#mrargs.start_key, Args#mrargs.end_key} of
        {undefined, undefined} ->
            #mrst{seq_btree=SeqBtree} = State,
            #mrview{id_num=Id}=View,
            {SeqBtree, [{start_key, {Id, StartSeq+1}},
                        {end_key, {Id, EndSeq}}]};
        {SK, undefined} ->
            {View#mrview.seq_btree, [{start_key, {SK, StartSeq+1}},
                                     {end_key, {SK, EndSeq}}]};
        {undefined, EK} ->
            {View#mrview.seq_btree, [{start_key, {EK, StartSeq+1}},
                                     {end_key, {EK, EndSeq}}]};
        {SK, EK} ->
            {View#mrview.seq_btree, [{start_key, {SK, StartSeq+1}},
                                     {end_key, {EK, EndSeq}}]}
    end,
    Opts2 = [{dir, Dir} | Opts],
    {ok, _R, {_, _, AccOut}} = couch_btree:fold(Btree, WrapperFun,
                                                Acc0, Opts2),
    {ok, AccOut}.

get_last_seq1(View, State, LastSeq, Args) ->
    {Btree, Opts} = case {Args#mrargs.start_key, Args#mrargs.end_key} of
        {undefined, undefined} ->
            #mrst{seq_btree=SeqBtree} = State,
            #mrview{id_num=Id}=View,
            {SeqBtree, [{start_key, {Id, LastSeq}},
                        {end_key, {Id, 0}}]};
        {SK, undefined} ->
            {View#mrview.seq_btree, [{start_key, {SK, LastSeq}},
                                     {end_key, {SK, 0}}]};
        {undefined, EK} ->
            {View#mrview.seq_btree, [{start_key, {EK, LastSeq}},
                                     {end_key, {EK, 0}}]};
        {SK, EK} ->
            {View#mrview.seq_btree, [{start_key, {SK, LastSeq}},
                                     {end_key, {EK, 0}}]}
    end,
    Opts2 = [{dir, rev} | Opts],

    WrapperFun = fun
        ({{_, Seq}, _}, _, _) ->
            {stop, Seq};
        (_, _, Acc2) ->
            {ok, Acc2}
    end,
    {ok, _R, AccOut} = couch_btree:fold(Btree, WrapperFun,
                                                LastSeq, Opts2),
    {ok, AccOut}.


make_meta(Args, UpdateSeq, Base) ->
    case Args#mrargs.update_seq of
        true -> {meta, Base ++ [{update_seq, UpdateSeq}]};
        _ -> {meta, Base}
    end.


group_rows_fun(exact) ->
    fun({Key1,_}, {Key2,_}) -> Key1 == Key2 end;
group_rows_fun(0) ->
    fun(_A, _B) -> true end;
group_rows_fun(GroupLevel) when is_integer(GroupLevel) ->
    fun({[_|_] = Key1,_}, {[_|_] = Key2,_}) ->
        lists:sublist(Key1, GroupLevel) == lists:sublist(Key2, GroupLevel);
    ({Key1,_}, {Key2,_}) ->
        Key1 == Key2
    end.


default_cb(complete, Acc) ->
    {ok, lists:reverse(Acc)};
default_cb({final, Info}, []) ->
    {ok, [Info]};
default_cb({final, _}, Acc) ->
    {ok, Acc};
default_cb(Row, Acc) ->
    {ok, [Row | Acc]}.


to_mrargs(KeyList) ->
    lists:foldl(fun({Key, Value}, Acc) ->
                case lookup_index(couch_util:to_existing_atom(Key)) of
                    undefined ->
                        Acc;
                    Index ->
                        setelement(Index, Acc, Value)
                end
    end, #mrargs{}, KeyList).


lookup_index(Key) ->
    Index = lists:zip(
        record_info(fields, mrargs), lists:seq(2, record_info(size, mrargs))
    ),
    couch_util:get_value(Key, Index).
