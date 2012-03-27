%%%-------------------------------------------------------------------
%%% @Copyright (C) 2010 VoIP INC
%%% @doc
%%% Whistle API Helpers
%%%
%%% Most API functions take a proplist, filter it against required headers
%%% and optional headers, and return either the JSON string if all
%%% required headers (default AND API-call-specific) are present, or an
%%% error if some headers are missing.
%%%
%%% To only check the validity, use the api call's corresponding *_v/1 function.
%%% This will parse the proplist and return a boolean()if the proplist is valid
%%% for creating a JSON message.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(wh_api).

%% API
-export([default_headers/2, default_headers/3, default_headers/4, default_headers/5]).
-export([prepare_api_payload/3, set_missing_values/2, remove_empty_values/1, extract_defaults/1]).
-export([disambiguate_and_publish/3]).
-export([error_resp/1]).
-export([error_resp_v/1]).

%% Other AMQP API validators can use these helpers
-export([build_message/3, build_message_specific/3, build_message_specific_headers/3
         ,validate/4, validate_message/4]).

-include("wh_api.hrl").
-include("../include/wh_log.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc Default Headers in all messages - see wiki
%% Creates the seed proplist for the eventual message to be sent
%% All fields are required general headers.
%% @end
%%--------------------------------------------------------------------
-spec default_headers/2 :: (ne_binary(), ne_binary()) -> proplist().
-spec default_headers/3 :: (binary(), ne_binary(), ne_binary()) -> proplist().
-spec default_headers/4 :: (ne_binary(), ne_binary(), ne_binary(), ne_binary()) -> proplist().
-spec default_headers/5 :: (binary(), ne_binary(), ne_binary(), ne_binary(), ne_binary()) -> proplist().

default_headers(AppName, AppVsn) ->
    default_headers(<<>>, AppName, AppVsn).

default_headers(ServerID, AppName, AppVsn) ->
    [{<<"Server-ID">>, ServerID}
     ,{<<"App-Name">>, AppName}
     ,{<<"App-Version">>, AppVsn}].

default_headers(EvtCat, EvtName, AppName, AppVsn) ->
    default_headers(<<>>, EvtCat, EvtName, AppName, AppVsn).

default_headers(ServerID, EvtCat, EvtName, AppName, AppVsn) ->
    [{<<"Server-ID">>, ServerID}
     ,{<<"Event-Category">>, EvtCat}
     ,{<<"Event-Name">>, EvtName}
     ,{<<"App-Name">>, AppName}
     ,{<<"App-Version">>, AppVsn}].

disambiguate_and_publish(ReqJObj, RespJObj, Binding) ->
    Wapi = list_to_binary([<<"wapi_">>, wh_util:to_binary(Binding)]),
    lager:debug("Wapi mod: ~s", [Wapi]),
    ApiMod = wh_util:to_atom(Wapi),
    ApiMod:disambiguate_and_publish(ReqJObj, RespJObj).

%%--------------------------------------------------------------------
%% @doc
%% Set any missing defaults with the values defined in the by the
%% validation definitions and remove any empty values
%% @end
%%--------------------------------------------------------------------
-spec prepare_api_payload/3 :: (api_terms(), proplist(), fun((api_terms()) -> api_formatter_return())) -> api_formatter_return().
prepare_api_payload(Prop, HeaderValues, ValidateFun) when is_list(Prop) ->
    CleanupFuns = [fun (P) -> remove_empty_values(P) end
                   ,fun (P) -> set_missing_values(P, HeaderValues) end],
    ValidateFun(lists:foldr(fun(F, P) -> F(P) end, Prop, CleanupFuns));
prepare_api_payload(JObj, HeaderValues, ValidateFun) ->
    prepare_api_payload(wh_json:to_proplist(JObj), HeaderValues, ValidateFun).

%%--------------------------------------------------------------------
%% @doc
%% Set any missing defaults with the values defined in the by the
%% validation definitions
%% @end
%%--------------------------------------------------------------------
-spec set_missing_values/2 :: (api_terms(), proplist()) -> api_terms().
set_missing_values(Prop, HeaderValues) when is_list(Prop) ->
    Missing = [{K, V} || {K,V} <- HeaderValues
                             ,not is_list(V)
                             ,is_empty(props:get_value(K, Prop))],
    Prop ++ Missing;
set_missing_values(JObj, HeaderValues) ->
    wh_json:from_list(set_missing_values(wh_json:to_proplist(JObj), HeaderValues)).

%%--------------------------------------------------------------------
%% @doc
%% Recursively cleans a proplist or json object, returning the same
%% type given
%% @end
%%--------------------------------------------------------------------
-spec remove_empty_values/1 :: (api_terms()) -> api_terms().
remove_empty_values(Prop) when is_list(Prop) ->
    do_empty_value_removal(Prop, []);
remove_empty_values(JObj) ->
    Prop = remove_empty_values(wh_json:to_proplist(JObj)),
    wh_json:from_list(Prop).

do_empty_value_removal([], Acc) ->
    lists:reverse(Acc);
do_empty_value_removal([{<<"Server-ID">>,_}=KV|T], Acc) ->
    do_empty_value_removal(T, [KV|Acc]);
do_empty_value_removal([{<<"Msg-ID">>,_}=KV|T], Acc) ->
    do_empty_value_removal(T, [KV|Acc]);
do_empty_value_removal([{K,V}=KV|T], Acc) ->
    case is_empty(V) of
        true -> do_empty_value_removal(T, Acc);
        false ->
            case wh_json:is_json_object(V) orelse
                wh_util:is_proplist(V) of
                true ->
                    SubElm = {K, remove_empty_values(V)},
                    do_empty_value_removal(T, [SubElm|Acc]);
                false ->
                    do_empty_value_removal(T, [KV|Acc])
            end
    end.

-spec is_empty/1 :: (term()) -> boolean().
is_empty(undefined) -> true;
is_empty([]) -> true;
is_empty(<<>>) -> true;
is_empty(_) -> false.


%%--------------------------------------------------------------------
%% @doc Extract just the default headers from a message
%% @end
%%--------------------------------------------------------------------
-spec extract_defaults/1 :: (api_terms()) -> proplist().
extract_defaults(Prop) when is_list(Prop) ->
    %% not measurable faster over the foldl, but cleaner (imo)
    [ {H, V} || H <- ?DEFAULT_HEADERS ++ ?OPTIONAL_DEFAULT_HEADERS,
                (V = props:get_value(H, Prop)) =/= undefined
    ];
extract_defaults(JObj) ->
    extract_defaults(wh_json:to_proplist(JObj)).

%%--------------------------------------------------------------------
%% @doc Format an error event
%% Takes proplist, creates JSON string or error
%% @end
%%--------------------------------------------------------------------
-spec error_resp/1 :: (api_terms()) -> api_formatter_return().
error_resp(Prop) when is_list(Prop) ->
    case error_resp_v(Prop) of
        true -> build_message(Prop, ?ERROR_RESP_HEADERS, ?OPTIONAL_ERROR_RESP_HEADERS);
        false -> {error, "Proplist failed validation for error_resp"}
    end;
error_resp(JObj) ->
    error_resp(wh_json:to_proplist(JObj)).

-spec error_resp_v/1 :: (api_terms()) -> boolean().
error_resp_v(Prop) when is_list(Prop) ->
    validate(Prop, ?ERROR_RESP_HEADERS, ?ERROR_RESP_VALUES, ?ERROR_RESP_TYPES);
error_resp_v(JObj) ->
    error_resp_v(wh_json:to_proplist(JObj)).

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec validate/4 :: (api_terms(), api_headers(), proplist(), proplist()) -> boolean().
validate(Prop, ReqH, Vals, Types) when is_list(Prop) ->
    case has_all(Prop, ?DEFAULT_HEADERS) andalso validate_message(Prop, ReqH, Vals, Types) of
        true ->
            true;
        false ->
            lager:debug("failing API JSON: ~s", [list_to_binary(wh_json:encode(wh_json:from_list(Prop)))]),
            false
    end;
validate(JObj, ReqH, Vals, Types) ->
    validate(wh_json:to_proplist(JObj), ReqH, Vals, Types).

-spec validate_message/4 :: (api_terms(), api_headers(), proplist(), proplist()) -> boolean().
validate_message(Prop, ReqH, Vals, Types) when is_list(Prop) ->
    has_all(Prop, ReqH) andalso
        values_check(Prop, Vals) andalso
        type_check(Prop, Types);
validate_message(JObj, ReqH, Vals, Types) ->
    validate_message(wh_json:to_proplist(JObj), ReqH, Vals, Types).

-spec build_message/3 :: (api_terms(), api_headers(), api_headers()) -> api_formatter_return().
build_message(Prop, ReqH, OptH) when is_list(Prop) ->
    case defaults(Prop) of
        {error, _Reason}=Error ->
            lager:debug("API message does not have the default headers ~s: ~p"
                 ,[string:join([wh_util:to_list(H) || H <- ReqH], ","), Error]),
            Error;
        HeadAndProp ->
            case build_message_specific_headers(HeadAndProp, ReqH, OptH) of
                {ok, FinalHeaders} -> headers_to_json(FinalHeaders);
                Err -> Err
            end
    end;
build_message(JObj, ReqH, OptH) ->
    build_message(wh_json:to_proplist(JObj), ReqH, OptH).

-spec build_message_specific_headers/3 :: (Msg, ReqHeaders, OptHeaders) -> {'ok', proplist()} | {'error', string()} when
      Msg :: proplist() | {api_headers(), proplist()},
      ReqHeaders :: api_headers(),
      OptHeaders :: api_headers().
build_message_specific_headers({Headers, Prop}, ReqH, OptH) ->
    case update_required_headers(Prop, ReqH, Headers) of
        {error, _Reason} = Error ->
            lager:debug("API message does not have the required headers ~s: ~p"
                 ,[string:join([wh_util:to_list(H) || H <- ReqH], ","), Error]),
            Error;
        {Headers1, Prop1} ->
            {Headers2, _Prop2} = update_optional_headers(Prop1, OptH, Headers1),
            {ok, Headers2}
    end;
build_message_specific_headers(Prop, ReqH, OptH) ->
    build_message_specific_headers({[], Prop}, ReqH, OptH).

-spec build_message_specific/3 :: (Msg, ReqHeaders, OptHeaders) -> api_formatter_return() when
      Msg :: proplist() | {api_headers(), proplist()},
      ReqHeaders :: api_headers(),
      OptHeaders :: api_headers().
build_message_specific({Headers, Prop}, ReqH, OptH) ->
    case update_required_headers(Prop, ReqH, Headers) of
        {error, _Reason} = Error ->
            lager:debug("API message does not have the required headers ~s: ~p"
                 ,[string:join([wh_util:to_list(H) || H <- ReqH], ","), Error]),
            Error;
        {Headers1, Prop1} ->
            {Headers2, _Prop2} = update_optional_headers(Prop1, OptH, Headers1),
            headers_to_json(Headers2)
    end;
build_message_specific(Prop, ReqH, OptH) ->
    build_message_specific({[], Prop}, ReqH, OptH).

-spec headers_to_json/1 :: (HeadersProp) -> api_formatter_return() when
      HeadersProp :: proplist().
headers_to_json(HeadersProp) ->
    try
        {ok, mochijson2:encode({struct, HeadersProp})}
    catch
        _What:_Why -> {error, io_lib:format("WHISTLE TO_JSON ERROR(~p): ~p~n~p", [_What, _Why, HeadersProp])}
    end.

%% Checks Prop for all default headers, throws error if one is missing
%% defaults(PassedProps) -> { Headers, NewPropList } | {error, Reason}
-spec defaults/1 :: (Prop) -> {proplist(), proplist()} | {'error', string()} when
      Prop :: api_terms().
defaults(Prop) ->
    defaults(Prop, []).
defaults(Prop, Headers) ->
    case update_required_headers(Prop, ?DEFAULT_HEADERS, Headers) of
        {error, _Reason} = Error ->
            Error;
        {Headers1, Prop1} ->
            update_optional_headers(Prop1, ?OPTIONAL_DEFAULT_HEADERS, Headers1)
    end.

-spec update_required_headers/3 :: (Prop, Fields, Headers) -> {proplist(), proplist()} | {'error', string()} when
      Prop :: proplist(),
      Fields :: api_headers(),
      Headers :: proplist().
update_required_headers(Prop, Fields, Headers) ->
    case has_all(Prop, Fields) of
        true ->
            add_headers(Prop, Fields, Headers);
        false ->
            {error, "All required headers not defined"}
    end.

-spec update_optional_headers/3 :: (Prop, Fields, Headers) -> {proplist(), proplist()} when
      Prop :: proplist(),
      Fields :: api_headers(),
      Headers :: proplist().
update_optional_headers(Prop, Fields, Headers) ->
    case has_any(Prop, Fields) of
        true ->
            add_optional_headers(Prop, Fields, Headers);
        false ->
            {Headers, Prop}
    end.

%% add [Header] from Prop to HeadProp
-spec add_headers/3 :: (Prop, Fields, Headers) -> {proplist(), proplist()} when
      Prop :: proplist(),
      Fields :: api_headers(),
      Headers :: proplist().
add_headers(Prop, Fields, Headers) ->
    lists:foldl(fun(K, {Headers1, KVs}) ->
                        {[{K, props:get_value(K, KVs)} | Headers1], props:delete(K, KVs)}
                end, {Headers, Prop}, Fields).

-spec add_optional_headers/3 :: (Prop, Fields, Headers) -> {proplist(), proplist()} when
      Prop :: proplist(),
      Fields :: api_headers(),
      Headers :: proplist().
add_optional_headers(Prop, Fields, Headers) ->
    lists:foldl(fun(K, {Headers1, KVs}) ->
                        case props:get_value(K, KVs) of
                            undefined ->
                                {Headers1, KVs};
                            V ->
                                {[{K, V} | Headers1], props:delete(K, KVs)}
                        end
                end, {Headers, Prop}, Fields).

%% Checks Prop against a list of required headers, returns true | false
-spec has_all/2 :: (proplist(), api_headers()) -> boolean().
has_all(Prop, Headers) ->
    lists:all(fun(Header) ->
                      case props:is_defined(Header, Prop) of
                          true -> true;
                          false ->
                              lager:debug("failed to find key '~s' on API message", [Header]),
                              false
                      end
              end, Headers).

%% Checks Prop against a list of optional headers, returns true | false if at least one if found
-spec has_any/2 :: (proplist(), api_headers()) -> boolean().
has_any(Prop, Headers) ->
    lists:any(fun(Header) -> props:is_defined(Header, Prop) end, Headers).

%% checks Prop against a list of values to ensure known key/value pairs are correct (like Event-Category
%% and Event-Name). We don't care if a key is defined in Values and not in Prop; that is handled by has_all/1
values_check(Prop, Values) ->
    lists:all(fun({Key, Vs}) when is_list(Vs) ->
                      case props:get_value(Key, Prop) of
                          undefined -> true; % isn't defined in Prop, has_all will error if req'd
                          V -> case lists:member(V, Vs) of
                                   true -> true;
                                   false ->
                                       lager:debug("API key '~s' value '~p' is not one of the values: ~p"
                                            ,[Key, V, Vs]),
                                       false
                               end
                      end;
                 ({Key, V}) ->
                      case props:get_value(Key, Prop) of
                          undefined -> true; % isn't defined in Prop, has_all will error if req'd
                          V -> true;
                          _Val ->
                              lager:debug("API key '~s' value '~p' is not '~p'"
                                   ,[Key, _Val, V]),
                              false
                      end
              end, Values).

%% checks Prop against a list of {Key, Fun}, running the value of Key through Fun, which returns a
%% boolean.
type_check(Prop, Types) ->
    lists:all(fun({Key, Fun}) ->
                      case props:get_value(Key, Prop) of
                          undefined -> true; % isn't defined in Prop, has_all will error if req'd
                          Value -> try case Fun(Value) of % returns boolean
                                           true -> true;
                                           false ->
                                               lager:debug("API key '~s' value '~p' failed validation fun", [Key, Value]),
                                               false
                                       end
                                   catch 
                                       _:R -> 
                                           lager:debug("API key '~s' value '~p' caused validation fun exception: ~p", [Key, Value, R]),
                                           false
                                   end
                      end
              end, Types).

%% EUNIT TESTING

-include_lib("eunit/include/eunit.hrl").
-ifdef(TEST).

has_all_test() ->
    Prop = [{<<"k1">>, <<"v1">>}
            ,{<<"k2">>, <<"v2">>}
            ,{<<"k3">>, <<"v3">>}
            ],
    Headers = [<<"k1">>, <<"k2">>, <<"k3">>],
    ?assertEqual(true, has_all(Prop, Headers)),
    ?assertEqual(false, has_all(Prop, [<<"k4">> | Headers])),
    ok.

has_any_test() ->
    Prop = [{<<"k1">>, <<"v1">>}
            ,{<<"k2">>, <<"v2">>}
            ,{<<"k3">>, <<"v3">>}
           ],
    Headers = [<<"k1">>, <<"k2">>, <<"k3">>],
    ?assertEqual(true, has_any(Prop, Headers)),
    ?assertEqual(false, has_any(Prop, [<<"k4">>])),
    ok.

-endif.
