%% Date: 04.01.17 - 16:01
%% Ⓒ 2017 heyoka
-module(dfs).
-author("Alexander Minichmair").

%% API
-export([parse/1, parse/2, parse/4, parse_file/1, parse_file/2, parse_file/3, parse_file/4]).

-export([test/0
   , user_node/1, test/1, test_macro/1]).

test_macro(FileName) ->
   {ok, Data1} = file:read_file("src/ctc_module_condition.dfs"),
   StringData1 = binary_to_list(binary:replace(Data1, <<"\\">>, <<>>, [global])),
   {ok, Data2} = file:read_file("src/publish_macro.dfs"),
   StringData2 = binary_to_list(binary:replace(Data2, <<"\\">>, <<>>, [global])),
   parse_file(FileName, [], [], [{<<"ctc_module_condition">>, StringData1}, {<<"publish_macro">>, StringData2}]).

test(FileName) ->
   parse_file(FileName, [], [
      {<<"emit_every">>, <<"3s">>},
      {<<"emit_every_jitter">>, <<"248ms">>},
      {<<"debug_type">>, <<"notice">>},
      {<<"address_list">>, [<<"{{db}}X55.2">>, <<"{{db}}X55.3">>, <<"{{db}}X55.4">>]},
      {<<"function">>, <<"lambda: string(\"rate\" * 9)">>},
      {<<"fun">>, <<"lambda: string(\"rate\" * 10)">>}
   ]).

test() ->
   test("src/test_script.dfs").

-spec parse(list()) -> list().
parse_file(FileName) when is_list(FileName) ->
   parse_file(FileName, [], []).
parse_file(FileName, Libs) ->
   parse_file(FileName, Libs, []).
parse_file(FileName, Libs, Replacements) ->
   parse_file(FileName, Libs, Replacements, []).
parse_file(FileName, Libs, Replacements, Macros) ->
   {ok, Data} = file:read_file(FileName),
   StringData = binary_to_list(binary:replace(Data, <<"\\">>, <<>>, [global])),
   parse(StringData, Libs, Replacements, Macros).

parse(StringData) ->
   parse(StringData, [], [], []).

parse(D, Libs) ->
   parse(D, Libs, [], []).

-spec parse(binary()|list(), list(), list(), list()) -> {list(), {list(), list()}}.
parse(Binary, Libs, Replacements, Macros) when is_binary(Binary) ->
   parse(binary_to_list(Binary), Libs, Replacements, Macros);
parse(String, Libs, Replacements, Macros)
      when is_list(String) andalso is_list(Libs) andalso is_list(Macros) ->
   catch ets:delete(?MODULE),
   LambdaLibs = [dfs_std_lib, estr] ++ [Libs],
   FLibs = lists:flatten(LambdaLibs),
   %% ensure libs are there for us
   lists:foreach(fun(E) -> code:ensure_loaded(E) end, FLibs),
   ets:new(?MODULE, [set, public, named_table]),
   ets:insert(?MODULE, {lfunc, FLibs}),
   Rep = [{RName, prepare_replacement(RName, Repl)} || {RName, Repl} <- Replacements],
%%   logger:notice("all replacemens: ~p~n" ,[Rep]),
   ets:insert(?MODULE, {replace_def, Rep} ),
   Res =
   case dfs_lexer:string(String) of
      {ok, Tokens, _EndLine} ->
%%         io:format("~nTokens: ~p~n",[Tokens]),
         case dfs_parser:parse(Tokens) of
            {ok, Data} ->
%%               io:format("~nDATA: ~p~n",[Data]),
%%               try eval(Data) of
%%                  Result -> Result
%%               catch
%%                  throw:Error -> {error, Error}
%%               end;
               eval(Data);
            {error, {LN, dfs_parser, Message}} ->
               {{parser_error, line, LN}, Message};
            Error -> Error
         end;
      {error, {LN, dfs_lexer, Message}, _LN} -> {{lexer_error, line, LN}, Message};
      Err -> Err
   end,
   %% now maybe rewrite the DFS script with replacements
   TabList = ets:tab2list(?MODULE),
   NewDFS = dfs_rewriter:execute(Replacements, TabList, String),
   ets:delete(?MODULE),
   %% check for macros in the script
   {NewNodes, NewConns} = macros(Res, Macros),
   {NewDFS, {NewNodes, NewConns}}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% MACROs
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
macros({Nodes, Conns} = Res, []) when is_list(Nodes), is_list(Conns) ->
   Res;
macros({Nodes, Conns}, Macros) when is_list(Nodes), is_list(Conns), is_list(Macros) ->
   replace_macros(Nodes, Conns, Macros);
macros(_ = Res, []) ->
   Res.

replace_macros(Nodes, Connections, Macros) ->
%%   io:format("Conns: ~n~p~n",[Connections]),
   FNodes = fun
               ({{<<"||" , NodeName/binary>>, _}=MacroName, _NodeParams, Params}, {Ns, Cs}) ->
                  MacroDfs =
                  case proplists:get_value(NodeName, Macros) of
                     undefined -> throw("no dfs for macro named " ++ binary_to_list(NodeName));
                     Other -> Other
                  end,
%%                  io:format("Macro : ~p~n with params: ~p", [NodeName, Params]),
                  {_NewMacroDfs, {MacroNodes, MacroConns}} = prepare_macro(MacroDfs, Params, Macros),
%%                  io:format("macro nodes: ~p~n macro conns: ~p~n", [MacroNodes, MacroConns]),
                  [{FirstMacroNode, _, _}|_] = MacroNodes,
                  {LastMacroNode, _, _} = lists:last(MacroNodes),
%%                  io:format("First Macro Node: ~p~nLast Macro Node: ~p~n", [FirstMacroNode, LastMacroNode]),
                  NewNodes0 = proplists:delete(MacroName, Ns),
                  NewNodes = NewNodes0 ++ MacroNodes,
                  NewConns0 = Cs ++ MacroConns,
                  NewConns = rewrite_conns(NewConns0, MacroName, {FirstMacroNode, LastMacroNode}, []),
                  {NewNodes, NewConns}
               ;
               ({{_NodeName, _}, _NodeParams, _Params}, Acc) ->
%%                  io:format("non-macro node: ~p~n", [NodeName]),
                  Acc
            end,
   lists:foldl(FNodes, {Nodes, Connections}, Nodes).

prepare_macro(MacroDfs, Replacements, Macros) ->
   Vars = clean_replacements(Replacements, []),
%%   io:format("~nReplacements for macro: ~p : ~p",[MacroDfsFile, Vars]),
   parse(MacroDfs, [], Vars, Macros).

clean_replacements([], Out) ->
   Out;
clean_replacements([{Name, [{_Type, Val}]}|R], Out) ->
%%   io:format("replacement: ~p => ~p", [V, {Name, Val}]),
   clean_replacements(R, [{Name, Val}|Out]).

rewrite_conns([], _, _, Acc) -> Acc;
rewrite_conns([{MacroName, OtherNode} | R], MacroName, {First, Last}, Acc) ->
%%   NewAcc0 = proplists:delete(MacroName, Cs),
   rewrite_conns(R, MacroName, {First, Last}, [{First, OtherNode}|Acc]);
rewrite_conns([{OtherNode, MacroName} | R], MacroName, {First, Last}, Acc) ->
%%   NewAcc0 = proplists:delete(OtherNode, Cs),
   rewrite_conns(R, MacroName, {First, Last}, [{OtherNode, Last}|Acc]);
rewrite_conns([{_, _}=C | R], MacroName, {First, Last}, Acc) ->
   rewrite_conns(R, MacroName, {First, Last}, [C|Acc]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% declaration substitution
prepare_replacement(Name, <<"lambda:", _R/binary>> = BinString) ->
   parse_replacement(Name, binary_to_list(BinString));
prepare_replacement(Name, L) when is_list(L) ->
   check_list_types(Name, L);
prepare_replacement(_Name, Repl) ->
   Repl.
parse_replacement(_Name, ("lambda:" ++ _R) = String ) ->
   case dfs_lexer:string(String) of
      {ok, Tokens, _EndLine} ->
         case dfs_parser:parse(Tokens) of
            {ok, [{statement, Data}]}->
               param(Data);
            {error, {LN, dfs_parser, Message}} ->
               {{parser_error, line, LN}, Message};
            Error -> Error
         end;
      {error, {LN, dfs_lexer, Message}, _LN} -> {{lexer_error, line, LN}, Message};
      Err -> Err
   end;
parse_replacement(_Name, R) -> R.

check_list_types(Name, L) ->
   case list_type(L) of
      true -> L;
      false -> throw([<<"list_contains_mixed_types">>, Name, L])
   end.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


eval(Tree) when is_list(Tree) ->
   Data = lists:foldl(
      fun(E, {Ns, Cs}=A) ->
         case eval(E) of
            {{nodes, Nodes}, {connections, Connections}} -> {Ns++Nodes, Cs++Connections};
            _ -> A
         end
      end,
      {[],[]},
      Tree
   ),
   Data;

%% @doc chain declaration
eval({statement, {declarate, DecName, {chain, Chain}}}) ->
   {{nodes, ChainNodes}, {connections, _Connections}} = C = chain(Chain),
   save_chain_declaration(DecName, ChainNodes),
   C;
%% @doc chain statement without declaration
eval({statement, {chain, Chain}}) ->
   {{nodes, _ChainNodes}, {connections, _Connections}} = C = chain(Chain),
   C;
%% @doc chain declaration connected to previously declared identifier
eval({statement, {declarate, DecName, {ident_expr, Identifier, {chain, Chain}}}}) ->
   {{nodes, ChainNodes}, {connections, Connections}} = _Cs = chain(Chain),
   save_chain_declaration(DecName, ChainNodes),
   {Node,_,_} = hd(ChainNodes),
   NewConns =
      case get_declaration(Identifier) of
         nil -> throw("Undefined Identifier \"" ++ binary_to_list(Identifier) ++ "\" used in chain expression");
         {connect, Name} ->
            [{Node,Name}|Connections]
      end,
   {{nodes, ChainNodes}, {connections, NewConns}};
eval({statement, {declarate, DecName, {list, DecValues}}}) ->
   check_list_types(DecName, DecValues),
   NewValues = params(DecValues),
   save_declaration(DecName, NewValues);
eval({statement, {declarate, DecName, {lambda, _DecValue}=L}}) ->
   save_declaration(DecName, param(L));
eval({statement, {declarate, DecName, {text, LN, V}}}) ->
   Val = text_template(V),
   save_declaration(DecName, {text, LN, Val});
eval({statement, {declarate, DecName, {string, LN, V}}}) ->
   Val = text_template(V),
   save_declaration(DecName, {string, LN, Val});
eval({statement, {declarate, DecName, DecValue}}) ->
   save_declaration(DecName, DecValue);
eval({statement, {ident_expr, Identifier, {chain, Chain}}}) ->
   {{nodes, ChainNodes}, {connections, Connections}} = chain(Chain),
   {Node,_,_} = hd(ChainNodes),
   NewConns =
   case get_declaration(Identifier) of
          nil -> throw("Undefined Identifier \"" ++ binary_to_list(Identifier) ++ "\" used in chain expression");
          {connect, Name} -> [{Node,Name}|Connections]
         end,
   {{nodes, ChainNodes}, {connections, NewConns}};
eval({statement, [{_T, What}]}) ->
   erlang:error(iolist_to_binary([<<"Syntax error, illegal statement in script: ">>,io_lib:format("~p",[What])]));
eval({statement, {_T, LN, What}}) ->
   erlang:error(iolist_to_binary([<<"Syntax error near line ">>, integer_to_binary(LN),<<", illegal statement: ">>,io_lib:format("~p",[What])]));
eval({statement, What}) ->
   erlang:error(iolist_to_binary([<<"Syntax error, illegal statement in script: ">>,io_lib:format("~p",[What])])).
%%;
%%   {Identifier, chain(Chain, [])}.
chain(ChainElements) when is_list(ChainElements) ->
   #{nodes := Nodes, current := CurrentNode, conns := Connections} =
   lists:foldl(
      fun
         ({node, NodeName, {params, Params}}, #{nodes := [], current := {}}=Acc) ->
            Id = node_id(),
            Acc#{nodes => [], current => {{NodeName, Id}, params(Params), []}};
         ({node, NodeName, {params, Params}}, #{nodes := Ns, current := {Node, _NodePars, _Pas}=NP,
            conns := Cs}=Acc) ->
            %io:format("~nconnect node ~p to node ~p~n",[NodeName, _Node]),
            Id = node_id(),
            Acc#{nodes => (Ns ++ [NP]), current => {{NodeName, Id}, params(Params), []},
               conns => [{{NodeName, Id}, Node}|Cs]};
         ({node, NodeName}, #{nodes := [], current := {}}=Acc) ->
            Id = node_id(),
            Acc#{nodes => [], current => {{NodeName,Id}, [], []}};
         ({node, NodeName}, #{nodes := Ns, current := {Node, _NodeParams, _Params}=CN,
            conns := Cs}=Acc) ->
            Id = node_id(),
%%            io:format("~nconnect node ~p to node ~p~n",[NodeName, _Node]),
            Acc#{nodes => Ns++[CN], current => {{NodeName, Id}, [], []},
               conns => [{{NodeName,Id}, Node}|Cs]};

         ({user_node, NodeName, {params, Params}}, #{nodes := [], current := {}}=Acc) ->
            Id = node_id(),
            Acc#{nodes => [], current => {{user_node(NodeName), Id}, params(Params), []}};
         ({user_node, NodeName, {params, Params}}, #{nodes := Ns, current := {Node, _NodePars, _Pas}=NP,
            conns := Cs}=Acc) ->
            %io:format("~nconnect node ~p to node ~p~n",[NodeName, _Node]),
            Id = node_id(),
            %io:format("user_node_name: ~p~n",[NodeName]),
            Acc#{nodes => (Ns ++ [NP]), current => {{user_node(NodeName), Id},
               params(Params), []}, conns => [{{user_node(NodeName), Id}, Node}|Cs]};
         ({user_node, NodeName}, #{nodes := [], current := {}}=Acc) ->
            Id = node_id(),
            Acc#{nodes => [], current => {{user_node(NodeName),Id}, [], []}};
         ({user_node, NodeName}, #{nodes := Ns, current := {Node, _NodeParams, _Params}=CN,
            conns := Cs}=Acc) ->
            Id = node_id(),
%%            io:format("~nconnect node ~p to node ~p~n",[NodeName, _Node]),
            Acc#{nodes => Ns++[CN], current => {{user_node(NodeName), Id}, [], []},
               conns => [{{user_node(NodeName),Id}, Node}|Cs]};

         %% MACROs
         ({macro, NodeName, {params, Params}}, #{nodes := [], current := {}}=Acc) ->
            Id = node_id(),
            Acc#{nodes => [], current => {{macro_node(NodeName), Id}, params(Params), []}};
         ({macro, NodeName, {params, Params}}, #{nodes := Ns, current := {Node, _NodePars, _Pas}=NP,
            conns := Cs}=Acc) ->
            %io:format("~nconnect node ~p to node ~p~n",[NodeName, _Node]),
            Id = node_id(),
            %io:format("user_node_name: ~p~n",[NodeName]),
            Acc#{nodes => (Ns ++ [NP]), current => {{macro_node(NodeName), Id},
               params(Params), []}, conns => [{{macro_node(NodeName), Id}, Node}|Cs]};
         ({macro, NodeName}, #{nodes := [], current := {}}=Acc) ->
            Id = node_id(),
            Acc#{nodes => [], current => {{macro_node(NodeName),Id}, [], []}};
         ({macro, NodeName}, #{nodes := Ns, current := {Node, _NodeParams, _Params}=CN,
            conns := Cs}=Acc) ->
            Id = node_id(),
%%            io:format("~nconnect node ~p to node ~p~n",[NodeName, _Node]),
            Acc#{nodes => Ns++[CN], current => {{macro_node(NodeName), Id}, [], []},
               conns => [{{macro_node(NodeName),Id}, Node}|Cs]};

         ({func, Name, {params, Params}}, #{current := {Node, NodeParams, Ps}}=Acc) ->
            Acc#{current := {Node, NodeParams, Ps++[{Name, params(Params)}]}};
         ({func, Name}, #{current := {Node, NodeParams, Ps}}=Acc) ->
            Acc#{current := {Node, NodeParams, Ps ++ [{Name, []}]}}
      end,
      #{nodes => [], current => {}, conns => []},
      ChainElements
   ),
   AllNodes = Nodes ++ [CurrentNode],
%%   io:format(" Chain: ~p",[{{nodes, AllNodes}, {connections, Connections}}]),
   {{nodes, AllNodes}, {connections, Connections}}.

node_id() ->
   erlang:unique_integer([positive,monotonic]).

params(Params) when is_list(Params)->
   lists:flatten([param(P) || P <- Params]).

param({identifier, Ident}) ->
%%   io:format("~n(param) identifier lookup for: ~p found: ~p~n",[Ident, get_declaration(Ident)]),
   case get_declaration(Ident) of
      nil -> {identifier, Ident};
      {connect, _} = C -> C;
%%      {Type, _LN, Val} -> {Type, Val};
%%      {Type, Val} -> {Type, Val};
      List when is_list(List) -> [{Type, Val} || {Type, _LN, Val} <- List];
      {lambda, _, _, _} = Lambda -> Lambda;
      Other -> find_text_template(Other)
   end;
param({pfunc, {_N, {params, _Ps}}}=L) ->
   param({lambda, [L]});
param({pfunc, N}) ->
   param({lambda, [{pfunc, {N,{params,[]}}}]});
param({lambda, LambdaList}) ->
%%   io:format("param: lambda ~p~n",[LambdaList]),
   {Lambda, BinRefs} =
      lists:foldl(
         fun(E, {L, Rs}) ->
%%            io:format("~nElement lammbda: ~p~n",[E]),
            Refs0 =
            case E of
               {reference, _LN, Ref}=_R ->
                  [Ref|Rs];
               {pexp, Eles} ->
                  NewPs = extract_refs(Eles),
                  NewPs++Rs;
               {pfunc, {_FName, {params, Params}}}=_P ->

                  NewPs = extract_refs(Params),
                  NewPs++Rs;
               _ ->
%%                  io:format("~n NA: ~p~n", [Rs]),
                  Rs
            end,
%%            io:format("~nparam lexp(~p ++ ~p~n): ~n",[L, lexp(E)]),
            {L++[lexp(E)], Refs0}
         end,{[], []},LambdaList), %% foldl
   %% unique params
   BRefs = sets:to_list(sets:from_list(BinRefs)),
   Refs = lists:map(fun(E) -> param_from_ref(E) end, BRefs),
%%   io:format("~nLAMBDA ~p (~p)~n",[lists:concat(Lambda), BRefs]),
   {lambda, lists:concat(Lambda), BRefs, Refs}
;
param({regex, Regex}) ->
   {regex, Regex};
param({list, List}) ->
   List;
param({list, _LN, List}) ->
   List;
param({text, _T}=V) ->
   find_text_template(V);
param({text, _LN, _T}=V) ->
   {text, T} = find_text_template(V),
   {text, _LN, T};
param({string, S}=V) ->
   {text, T} = find_text_template({text, S}),
   {string, T};
param({string, LN, S}=_V) ->
   {text, T} = find_text_template({text, LN, S}),
   {string, LN, T};
param(P) ->
   P.


extract_refs(Elements) when is_list(Elements) ->
%%   io:format("~nExtract ref for : ~p~n",[Elements]),
   lists:foldl(
      fun(E1, Acc) ->
         case E1 of
            {reference, _Ln, Ref1} -> [Ref1|Acc];
            {reference, Ref1} -> [Ref1|Acc];
            {pfunc, {_FName, {params, Params}}} -> lists:flatten([extract_refs(Params)|Acc]);
            {pexp, Eles} -> lists:flatten([extract_refs(Eles)|Acc]);
            {paren, Exp} -> lists:flatten([extract_refs(Exp)|Acc]);
            {list, List} -> lists:flatten([extract_refs(List)|Acc]);
            [Other] -> lists:flatten([extract_refs(Other)|Acc]);
            List when is_list(List) -> lists:flatten([extract_refs(List)|Acc]);
            _O -> Acc %io:format("extract_refs OTHER: ~p~n",[_O]),Acc
         end
      end,
      [],
      Elements
   );
extract_refs({pfunc, {_Name, {params, Params}}}) ->
%%   io:format("extract params: ~p~n",[Params]),
   extract_refs(Params);
extract_refs({reference, _Ln, Ref1}) ->
   Ref1;
extract_refs({reference, Ref1}) ->
   Ref1;
extract_refs({pexp, Elems}) when is_list(Elems) ->
   extract_refs(Elems);
extract_refs(_Other) ->
%%   io:format("Other in extract refs: ~p~n",[_Other]),
   [].

param_from_ref(Ref) when is_binary(Ref) ->
%%   io:format("~nparam from ref: ~p~n",[Ref]),
   Ref1 = clean_param_name(Ref),
   Ref0 = binary:replace(Ref1, [<<".">>,<<"[">>,<<"]">>], <<"_">>, [global]),
   string:titlecase(binary_to_list(Ref0)).

clean_param_name(Name) when is_binary(Name) ->
   re:replace(Name, "[^a-zA-Z0-9_.]", <<"_">>, [{return, binary}]).


l_params([], Acc) ->
   Acc;
l_params([P], Acc) ->
   Acc++P;
l_params([P|Ps], Acc) ->
  l_params(Ps, Acc ++ P ++ ", ").

params_pfunc(Params) when is_list(Params) ->
   P = lists:map(
      fun(E) -> param_pfunc(E) end,
      Params
   ),
   P1 = l_params(P, []),
   lists:flatten(P1)
.
param_pfunc({identifier, _LN, Ident}) ->
   %io:format("identifier lookup for: ~p", [Ident]),
   param_pfunc({identifier, Ident});
%%param_pfunc({identifier, {identifier, 0, Ident}}) ->
%%   param_pfunc({identifier, Ident});
param_pfunc({identifier, Ident}) ->
   case get_declaration(Ident) of
      nil -> binary_to_list(Ident);
      {connect, _} -> binary_to_list(Ident);
      {string, _LN, String} -> "<<\"" ++ binary_to_list(String) ++ "\">>";
      {string, String} -> "<<\"" ++ binary_to_list(String) ++ "\">>";
      {duration, _LN, Dur} -> "<<\"" ++ binary_to_list(Dur) ++ "\">>";
      {bool, _LN, Bool} -> atom_to_list(Bool);
      {int, _LN, Int} -> integer_to_list(Int);
      {float, _LN, F} -> float_to_list(F);
      Other -> binary_to_list(unwrap(Other))
   end;
param_pfunc({reference, Ref}) ->
%%   io:format("~n(param_func) found Reference: ~p~n",[Ref]),
   param_from_ref(Ref);
param_pfunc({string, _LN, Ref}) ->
   param_pfunc({string, Ref});
param_pfunc({string, Ref}) ->
   "<<\"" ++ binary_to_list(Ref) ++ "\">>";
param_pfunc({pexp, Elements}) ->
   [param_pfunc(E) || E <- Elements ];
param_pfunc(Other) ->
%%   io:format("[param_pfunc] ~p~n",[Other]),
      lexp(Other).


%% lambda primary expressions
lexp(Expressions) when is_list(Expressions) ->
%%   io:format("LAMBDA EXPRESSIONS: ~p~n",[Expressions]),
   lists:flatten([lexp(E) || E <- Expressions]);
%% parenthesized expressions
lexp({paren, Exp}) ->
   "(" ++ lexp(Exp) ++ ")";
lexp({int, Int}) ->
   integer_to_list(Int);
lexp({int, _LN, Int}) ->
   integer_to_list(Int);
lexp({float, _LN, Float}) ->
   lexp({float, Float});
lexp({float, Float}) ->
   float_to_list(Float);
lexp({bool, _LN, Bool}) ->
   atom_to_list(Bool);
lexp({bool, Bool}) ->
   atom_to_list(Bool);
lexp({identifier, _LN, Id}) ->
%%   io:format("[lexp({identifier] ~p~n",[Id]),
   param_pfunc({identifier, Id});
lexp({reference, _LN, Ref}) ->
   param_from_ref(Ref);
lexp({operator, _LN, Op}) ->
   case Op of
      'AND' -> " andalso ";
      'OR'  -> " orelse ";
      '<='  -> " =< ";
      '=>'  -> " >= ";
      '!='  -> " /= ";
      '!'   -> " not ";
      _ -> " " ++ atom_to_list(Op) ++ " "
   end;
lexp({duration, _LN, S}) ->
   lexp({duration, S});
lexp({duration, S}) ->
   lexp({string, S});
lexp({string, _LN, S}) ->
   lexp({string, S});
lexp({string, S}) ->
%%   io:format("~nlexp string ~p~n",[S]),
   {text, Text} = find_text_template({text, S}),
   "<<\"" ++ binary_to_list(Text) ++ "\">>";
lexp({text, _LN, S} = _T) ->
%%   {text, Text} = find_text_template(T),
%%   io:format("~nlexp text ~p~n",[T]),
   lexp({string, S});
lexp({text, S} = _T) ->
%%   {text, Text} = find_text_template(T),
%%   io:format("~nlexp text ~p~n",[T]),
   lexp({string, S});
lexp({pexp, Elements}) when is_list(Elements) ->
   lists:concat([lexp(E) || E <- Elements]);
lexp({pexp, {pexp, Elements}}) when is_list(Elements) ->
   lists:concat([lexp(E) || E <- Elements]);
lexp({pfunc, {<<"if">>, {params, Params}}}) ->
   P = lists:map(
      fun(E) -> P0 = param_pfunc(E), %io:format("param_pfunc: ~p, ~p ~n",[E, P0]),
                P0 end,
      Params
   ),
   [Expr, PTrue, PFalse] = P,% f = l_params(P, []),
   F0 = "case " ++ lists:flatten(Expr) ++ " of true -> " ++ PTrue ++ "; false -> " ++ PFalse ++ " end",
%%   io:format("Lambda IF fun : ~p~n",[lists:flatten(F0)]),
   F0;
lexp({pfunc, {FName, {params, Params}}}) ->
%%   io:format("Lambda fun name is : ~p ~n",[FName]),
   Ps = params_pfunc(Params),
   FuncName = pfunction(binary_to_list(FName), length(Params)),
   FuncName ++ "(" ++ Ps ++ ")";
lexp({pfunc, FName}) ->
   pfunction(binary_to_list(FName), 0) ++ "()";
lexp({list, List}) ->
   L1 = [param_pfunc(LEle) || LEle <- List],
%%   io:format("~nL1 : ~p~n", [L1]),
   L2 = "[" ++ lists:flatten(lists:join(", ", L1)) ++ "]",
   L2.

%% save a simple declaration,
%% here is where declaration - overwriting happens,
%% you know for templates: every declaration (def keyword) which is not a chain-declaration
%% can be overwritten with a custom value
%%save_declaration(Ident, [{_VType, _Val}|_R]=Vals) when is_list(Vals) ->
%%   save_declaration(Ident, [{VTy, 0, V} || {VTy, V} <- Vals]);
save_declaration(Ident, [{VType, VLine, _Val}|_R]=Vals) when is_list(Vals) ->
   check_new_declaration(Ident),
   [{replace_def, Replacements}] = ets:lookup(?MODULE, replace_def),
   RVal = proplists:get_value(Ident, Replacements, norepl),
   %io:format("Replacements ~p~nKey: ~p~nrval: ~p~n~p",[Replacements, Ident, RVal, Vals]),
   NewValue =
      case RVal of
         norepl -> Vals;
         NVal  -> [{VType, VLine, V} || V <- NVal]
      end,
   ets:insert(?MODULE, {Ident, NewValue});
save_declaration(Ident, {lambda, _Fun, _Decs, _Refs}=Value) ->
   check_new_declaration(Ident),
   [{replace_def, Replacements}] = ets:lookup(?MODULE, replace_def),
   RVal = proplists:get_value(Ident, Replacements, norepl),
%%   io:format("~nReplacements ~p~n~nKey: ~p~nreplacement-value: ~p~nOriginal-Value~p~n~n",[Replacements, Ident, RVal, Value]),
   NewValue =
      case RVal of
         norepl -> Value;
         _  -> RVal
      end,
   ets:insert(?MODULE, {Ident, NewValue});
save_declaration(Ident, {VType, VLine, _Val}=Value) ->
%%   io:format("~nsave_declaration single: ~p: ~p~n",[Ident, Value]),
   check_new_declaration(Ident),
   [{replace_def, Replacements}] = ets:lookup(?MODULE, replace_def),
   RVal = proplists:get_value(Ident, Replacements, norepl),
%%   io:format("Replacements ~p~nKey: ~p~nrval: ~p~n~p",[Replacements, Ident, RVal, Value]),
   NewValue =
   case RVal of
      norepl -> Value;
      NVal  -> {VType, VLine, NVal}
   end,
   ets:insert(?MODULE, {Ident, NewValue}).
save_chain_declaration(Ident, Nodes) when is_list(Nodes) ->
   check_new_declaration(Ident),
   LastNode = lists:last(Nodes),
   {NodeName, _Np, _NCP} = LastNode,
   ets:insert(?MODULE, {Ident, {connect, NodeName}}).
get_declaration(Ident) ->
%%   io:format("~nget_declaration: ~p~n",[ets:lookup(dfs_parser, Ident)]),
   case ets:lookup(?MODULE, Ident) of
      [] -> nil;
      [{Ident, {connect, {_Name, _Connection}=N}}] -> {connect, N};
      [{Ident, Value}] -> %io:format("get_declaration value: ~p~n",[Value]),
         Value
   end.

check_new_declaration(Identifier) ->
   case get_declaration(Identifier) of
      nil -> ok;
      _Other -> erlang:error(iolist_to_binary([<<"Identifier ">>,
         io_lib:format("'~s'",[Identifier]),<<" already defined">>]))
   end.

%% check identifiers for possible text templates and substitute template vars
find_text_template({text, _LN, Text}) ->
   {text, text_template(Text)};
find_text_template({text, Text}) ->
   {text, text_template(Text)};
find_text_template({Type, _LN, Val}) ->
   {Type, Val};
find_text_template({Type, Val}) ->
   {Type, Val}.

text_template(Text) ->
   extract_template(Text).

extract_template(Template) when is_binary(Template) ->
   Matches = re:run(Template, "{{([a-zA-Z0-9\\+\\-\s\.\\[\\]_-]*)}}", [global, {capture, all, binary}]),
%%   io:format("~nMatches for Template: ~p~n", [Matches]),
   case Matches of
      nomatch -> Template;
      {match, Matched} ->
         Res0 = [{TVar, clean_identifier_name(Var)} || [TVar, Var] <- Matched],
         {Replace, Vars} = lists:unzip(Res0),
         Format = binary_to_list(binary:replace(Template, Replace, <<"~s">>, [global])),
         io:format("FORMAT: ~p~nVars: ~p~n",[Format, Vars]),
         io:format("get declarations for vars: ~p~n",[get_template_vars(Vars)]),
         Subst = get_template_vars(Vars),
         list_to_binary(io_lib:format(Format, conv_template_vars(Subst)))
   end.

get_template_vars(Vars) when is_list(Vars) ->
   lists:map(
      fun(Var) ->
         case get_declaration(Var) of
            nil -> throw("Undefined Identifier \"" ++ binary_to_list(Var) ++ "\" used in text template");
            Other -> unwrap(Other)
         end
      end,
      Vars
   ).

clean_identifier_name(Name) when is_binary(Name) ->
   re:replace(Name, "[\s\t\r\n]", <<"">>, [{return, binary}, global]).

conv_template_vars(Vars) when is_list(Vars) ->
   [conv_var(unwrap(Var)) || Var <- Vars].

conv_var(V) when is_float(V) ->
   float_to_binary(V, [{decimals, 8}]);
conv_var(V) when is_integer(V) ->
   integer_to_binary(V);
conv_var(V) -> V.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

unwrap({_T, _LN, Contents}) ->
   Contents;
unwrap({_T, Contents}) ->
   Contents;
unwrap(V) ->
   V.

user_node(Name) ->
   << <<"@">>/binary, Name/binary>>.

macro_node(Name) ->
   << <<"||">>/binary, Name/binary>>.

list_type([{_Type, _LN, _Val}|_R] = L) ->
   {_, _, Values} = lists:unzip3(L),
   list_type(Values);
list_type([{_Type, _Val}|_R] = L) ->
   {_, Values} = lists:unzip(L),
   list_type(Values);
list_type([E|R]) when is_number(E) ->
   lists:all(fun(El) -> is_number(El) end ,R);
list_type([E|R]) when is_list(E) ->
   lists:all(fun(El) -> is_list(El) end ,R);
list_type([E|R]) when is_binary(E) ->
   lists:all(fun(El) -> is_binary(El) end ,R);
list_type([E|R]) when is_atom(E) ->
   lists:all(fun(El) -> is_atom(El) end ,R).

%%%%%%%%%%%%%%%%%%%%%%%%%%% LAMBDA FUNCTIONS %%%%%%%%%%%%%%%%%%%
pfunction(FName, Arity) when is_list(FName) ->
   NameAtom = list_to_atom(FName),
   [{lfunc, Modules}] = ets:lookup(?MODULE, lfunc),
%%   io:format("models are ~p~n",[Modules]),
   NN0 = lists:foldl(
     fun
        (_E, {done, _Module}=M) -> M;
        (E, Module) ->
           case erlang:function_exported(E, NameAtom, Arity) of
              true -> F0 = {done, atom_to_list(E) ++ ":" ++ FName},
                 %io:format("~p :: ~p ~n",[FName, F0]),
              F0;
              false -> Module
           end
     end,
      nil,
      Modules
   ),
   NN =
   case NN0 of
      nil -> case erlang:function_exported(math, NameAtom, Arity) of
                true -> "math:" ++ FName;
                false -> FName %throw("Function " ++ FName ++ " not found in library")
             end;
      {done, Else} -> Else
   end,
%%   io:format("convert function name: ~p ==> ~p~n",[FName, NN]),
   NN.