%% ---------------------------------------------------------------------
%% @author Richard Carlsson <carlsson.richard@gmail.com>
%% @copyright 2012 Richard Carlsson
%% @doc Parse transform for merl. Evaluates calls to functions in `merl',
%% turning strings to templates, etc., at compile-time.

-module(merl_transform).

-export([parse_transform/2]).

%% NOTE: We cannot use inline metavariables or any other parse transform
%% features in this module, because it must be possible to compile it with
%% the parse transform disabled!
-include("../include/merl.hrl").

%% TODO: unroll calls to switch? it will probably get messy

parse_transform(Forms, _Options) ->
    erl_syntax:revert_forms(expand(erl_syntax:form_list(Forms))).

expand(Tree0) ->
    Tree = pre(Tree0),
    post(case erl_syntax:subtrees(Tree) of
             [] ->
                 Tree;
             Gs ->
                 erl_syntax:update_tree(Tree,
                                        [[expand(T) || T <- G] || G <- Gs])
         end).

pre(T) ->
    merl:switch(
      T,
      [{?Q("merl:quote(_@line, _@text) = _@expr"),
        fun ([{expr, _}, {line, Line}, {text,Text}]) ->
                erl_syntax:is_literal(Text) andalso erl_syntax:is_literal(Line)
        end,
        fun ([{expr, Expr}, {line, Line}, {text, Text}]) ->
                pre_expand_match(Expr, erl_syntax:concrete(Line),
                                 erl_syntax:concrete(Text))
        end},
       fun () -> T end
      ]).

post(T) ->
    merl:switch(
      T,
      [{?Q("merl:_@function(_@@args)"),
        [{fun ([{args, As}, {function, F}]) ->
                  lists:all(fun erl_syntax:is_literal/1, [F|As])
          end,
          fun ([{args, As}, {function, F}]) ->
                  Line = erl_syntax:get_pos(F),
                  [F1|As1] = lists:map(fun erl_syntax:concrete/1, [F|As]),
                  eval_call(Line, F1, As1, T)
          end},
         fun ([{args, As}, {function, F}]) ->
                 merl:switch(
                   F,
                   [{?Q("qquote"), fun ([]) -> expand_qquote(As, T, 1) end},
                    {?Q("subst"), fun ([]) -> expand_template(F, As, T) end},
                    {?Q("match"), fun ([]) -> expand_template(F, As, T) end},
                    fun () -> T end
                   ])
         end]},
       fun () -> T end]).

expand_qquote([Line, Text, Env], T, _) ->
    case erl_syntax:is_literal(Line) of
        true ->
            expand_qquote([Text, Env], T, erl_syntax:concrete(Line));
        false ->
            T
    end;
expand_qquote([Text, Env], T, Line) ->
    case erl_syntax:is_literal(Text) of
        true ->
            As = [Line, erl_syntax:concrete(Text)],
            %% expand further if possible
            expand(merl:qquote(Line, "merl:subst(_@tree, _@env)",
                               [{tree, eval_call(Line, quote, As, T)},
                                {env, Env}]));
        false ->
            T
    end;
expand_qquote(_As, T, _StartPos) ->
    T.

expand_template(F, [Pattern | Args], T) ->
    case erl_syntax:is_literal(Pattern) of
        true ->
            Line = erl_syntax:get_pos(Pattern),
            As = [erl_syntax:concrete(Pattern)],
            merl:qquote(Line, "merl:_@function(_@pattern, _@args)",
               [{function, F},
                {pattern, eval_call(Line, template, As, T)},
                {args, Args}]);
        false ->
            T
    end;
expand_template(_F, _As, T) ->
    T.

eval_call(Line, F, As, T) ->
    try apply(merl, F, As) of
        T1 when F =:= quote ->
            %% lift metavariables in a template to Erlang variables
            Template = merl:template(T1),
            Vars = merl:template_vars(Template),
            case lists:any(fun is_inline_metavar/1, Vars) of
                true when is_list(T1) ->
                    merl:qquote(Line, "merl:tree([_@template])",
                                [{template, merl:meta_template(Template)}]);
                true ->
                    merl:qquote(Line, "merl:tree(_@template)",
                                [{template, merl:meta_template(Template)}]);
                false ->
                    merl:term(T1)
            end;
        T1 ->
            merl:term(T1)
    catch
        throw:_Reason -> T
    end.

pre_expand_match(Expr, Line, Text) ->
    %% we must rewrite the metavariables in the pattern to use lowercase,
    %% and then use real matching to bind the Erlang-level variables
    T0 = merl:template(merl:quote(Line, Text)),
    Vars = [V || V <- merl:template_vars(T0), is_inline_metavar(V)],
    T1 = merl:tsubst(T0, [{V, {var_to_tag(V)}} || V <- Vars]),
    Out = erl_syntax:list([erl_syntax:tuple([erl_syntax:atom(var_to_tag(V)),
                                             erl_syntax:variable(V)])
                           || V <- Vars]),
    merl:qquote(Line, "{ok, _@out} = merl:match(_@template, _@expr)",
                [{expr, Expr},
                 {out, Out},
                 {template, erl_syntax:abstract(T1)}]).

var_to_tag(V) ->
    list_to_atom(string:to_lower(atom_to_list(V))).

is_inline_metavar(Var) when is_atom(Var) ->
    is_erlang_var(atom_to_list(Var));
is_inline_metavar(_) -> false.

is_erlang_var([C|_]) when C >= $A, C =< $Z ; C >= $�, C =< $�, C /= $� ->
    true;
is_erlang_var(_) ->
    false.
