open Proverapi
open Big_int
open Printf
open Num (* rational numbers *)
open Util
open Stats
open Lexer
open Ast
open Parser
open Verifast0
open Verifast1

module Assertions(VerifyProgramArgs: VERIFY_PROGRAM_ARGS) = struct
  
  include VerifyProgram1(VerifyProgramArgs)
  
  type auto_lemma_info =
      string option (* fraction *)
    * string list (* type parameters *)
    * string list (* index patterns *)
    * string list (* argument patterns *)
    * asn (* pre *)
    * asn (* post *)
  let auto_lemmas: (string, auto_lemma_info) Hashtbl.t = Hashtbl.create 10
  
  module CheckFile_Assertions(CheckFileArgs: CHECK_FILE_ARGS) = struct
  
  include CheckFile1(CheckFileArgs)
  
  (* Region: production of assertions *)
  
  let assert_expr env e h env l msg url = assert_term (eval None env e) h env l msg url

  let success() = SymExecSuccess
  
  let branch cont1 cont2 =
    stats#branch;
    execute_branch cont1;
    execute_branch cont2;
    SymExecSuccess
  
  let rec assert_expr_split e h env l msg url = 
    match e with
      IfExpr(l0, con, e1, e2) -> 
        branch
           (fun () -> assume (eval None env con) (fun () -> assert_expr_split e1 h env l msg url))
           (fun () -> assume (ctxt#mk_not (eval None env con)) (fun () -> assert_expr_split e2 h env l msg url))
    | Operation(l0, And, [e1; e2], tps) ->
      branch
        (fun () -> assert_expr_split e1 h env l msg url)
        (fun () -> assert_expr_split e2 h env l msg url)
    | _ -> with_context (Executing (h, env, expr_loc e, "Consuming expression")) (fun () -> assert_expr env e h env l msg url; SymExecSuccess)
  
  let rec evalpat ghost ghostenv env pat tp0 tp cont =
    match pat with
      LitPat e -> cont ghostenv env (prover_convert_term (eval None env e) tp0 tp)
    | VarPat (_, x) -> let t = get_unique_var_symb_ x tp ghost in cont (x::ghostenv) (update env x (prover_convert_term t tp tp0)) t
    | DummyPat -> let t = get_unique_var_symb_ "dummy" tp ghost in cont ghostenv env t
    | WCtorPat (l, i, targs, g, ts0, ts, pats) ->
      let (_, inductive_tparams, ctormap, _) = List.assoc i inductivemap in
      let (_, (_, _, _, _, (symb, _))) = List.assoc g ctormap in
      evalpats ghostenv env pats ts ts0 $. fun ghostenv env vs ->
      cont ghostenv env (prover_convert_term (ctxt#mk_app symb vs) tp0 tp)
  and evalpats ghostenv env pats tps0 tps cont =
    match (pats, tps0, tps) with
      ([], [], []) -> cont ghostenv env []
    | (pat::pats, tp0::tps0, tp::tps) -> evalpat true ghostenv env pat tp0 tp (fun ghostenv env t -> evalpats ghostenv env pats tps0 tps (fun ghostenv env ts -> cont ghostenv env (t::ts)))

  let real_mul l t1 t2 =
    if t1 == real_unit then t2 else if t2 == real_unit then t1 else
    let t = ctxt#mk_real_mul t1 t2 in
    if is_dummy_frac_term t1 || is_dummy_frac_term t2 then dummy_frac_terms := t::!dummy_frac_terms;
    t
  
  let real_div l t1 t2 =
    if t2 == real_unit then t1 else static_error l "Real division not yet supported." None
  
  let definitely_equal t1 t2 =
    let result = if t1 == t2 then (stats#definitelyEqualSameTerm; true) else (stats#definitelyEqualQuery; ctxt#query (ctxt#mk_eq t1 t2)) in
    (* print_endline ("Checking definite equality of " ^ ctxt#pprint t1 ^ " and " ^ ctxt#pprint t2 ^ ": " ^ (if result then "true" else "false")); *)
    result
  
  let predname_eq g1 g2 =
    match (g1, g2) with
      ((g1, literal1), (g2, literal2)) -> if literal1 && literal2 then g1 == g2 else definitely_equal g1 g2
  
  let assume_field h0 fparent fname frange fghost tp tv tcoef cont =
    let (_, (_, _, _, _, symb, _)) = List.assoc (fparent, fname) field_pred_map in
    if fghost = Real then begin
      match frange with
         Char -> ignore (ctxt#assume (ctxt#mk_and (ctxt#mk_le min_char_term tv) (ctxt#mk_le tv max_char_term)))
      | ShortType -> ignore (ctxt#assume (ctxt#mk_and (ctxt#mk_le min_short_term tv) (ctxt#mk_le tv max_short_term)))
      | IntType -> ignore (ctxt#assume (ctxt#mk_and (ctxt#mk_le min_int_term tv) (ctxt#mk_le tv max_int_term)))
      | PtrType _ | UintPtrType -> ignore (ctxt#assume (ctxt#mk_and (ctxt#mk_le (ctxt#mk_intlit 0) tv) (ctxt#mk_le tv max_ptr_term)))
      | _ -> ()
    end; 
    (* automatic generation of t1 != t2 if t1.f |-> _ &*& t2.f |-> _ *)
    begin fun cont ->
      if tcoef != real_unit && tcoef != real_half then
        assume (ctxt#mk_real_lt real_zero tcoef) cont
      else
        cont()
    end $. fun () ->
    let pred_symb = (symb, true) in
    let rec iter h =
      match h with
        [] -> cont (Chunk ((symb, true), [], tcoef, [tp; tv], None)::h0)
      | Chunk (g, targs', tcoef', [tp'; tv'], _) as chunk::h when predname_eq g pred_symb ->
        if tcoef == real_unit || tcoef' == real_unit then
          assume_neq tp tp' (fun _ -> iter h)
        else if definitely_equal tp tp' then
        begin
          assume (ctxt#mk_eq tv tv') $. fun () ->
          let cont = (fun coef -> cont (Chunk ((symb, true), [], coef, [tp'; tv'], None)::List.filter (fun ch -> ch != chunk) h0)) in
          if tcoef == real_half && tcoef' == real_half then cont real_unit else
          if is_dummy_frac_term tcoef then
            cont tcoef'
          else if is_dummy_frac_term tcoef' then
            cont tcoef
          else
            let newcoef = (ctxt#mk_real_add tcoef tcoef') in (assume (ctxt#mk_real_le newcoef real_unit) $. fun () -> cont newcoef)
        end
        else
          iter h
      | _::h -> iter h
    in
    if (file_type path) <> Java || ctxt#query (ctxt#mk_not (ctxt#mk_eq tp (ctxt#mk_intlit 0))) then 
      iter h0
    else
      assume_neq tp (ctxt#mk_intlit 0) (fun _ -> iter h0) (* in Java, the target of a field chunk is non-null *)

  let produce_chunk h g_symb targs coef inputParamCount ts size cont =
    if inputParamCount = None || coef == real_unit then
      cont (Chunk (g_symb, targs, coef, ts, size)::h)
    else
      let Some n = inputParamCount in
      let rec iter hdone htodo =
        match htodo with
          [] -> cont (Chunk (g_symb, targs, coef, ts, size)::h)
        | Chunk (g_symb', targs', coef', ts', size') as chunk::htodo ->
          if predname_eq g_symb g_symb' && List.for_all2 unify targs targs' && for_all_take2 definitely_equal n ts ts' then
            let assume_all_eq ts ts' cont =
              let rec iter ts ts' =
                match (ts, ts') with
                  (t::ts, t'::ts') -> assume (ctxt#mk_eq t t') (fun () -> iter ts ts')
                | ([], []) -> cont ()
              in
              iter ts ts'
            in
            assume_all_eq (drop n ts) (drop n ts') $. fun () ->
            let h = if List.length hdone < List.length htodo then hdone @ htodo else htodo @ hdone in
            let coef =
              if coef == real_half && coef' == real_half then real_unit else
              if is_dummy_frac_term coef then
                if is_dummy_frac_term coef' then
                  coef'
                else begin
                  ignore $. ctxt#assume (ctxt#mk_lt real_zero coef);
                  ctxt#mk_real_add coef coef'
                end
              else
                if is_dummy_frac_term coef' then begin
                  ignore $. ctxt#assume (ctxt#mk_lt real_zero coef');
                  ctxt#mk_real_add coef coef'
                end else
                  ctxt#mk_real_add coef coef'
            in
            cont (Chunk (g_symb, targs, coef, ts, size)::h)
          else
            iter (chunk::hdone) htodo
      in
      iter [] h
  
  let rec produce_asn_core tpenv h ghostenv env p coef size_first size_all (assuming: bool) cont: symexec_result =
    let with_context_helper cont =
      match p with
        Sep (_, _, _) -> cont()
      | _ ->
        if !verbosity >= 2 then Printf.printf "%10.6fs: %s: Producing assertion\n" (Perf.time()) (string_of_loc (asn_loc p));
        with_context (Executing (h, env, asn_loc p, "Producing assertion")) cont
    in
    with_context_helper (fun _ ->
    let ev = eval None env in
    match p with
    | WPointsTo (l, WRead (lr, e, fparent, fname, frange, fstatic, fvalue, fghost), tp, rhs) ->
      if fstatic then
        let (_, (_, _, _, _, symb, _)) = List.assoc (fparent, fname) field_pred_map in
        evalpat (fghost = Ghost) ghostenv env rhs tp tp $. fun ghostenv env t ->
        produce_chunk h (symb, true) [] coef (Some 0) [t] None $. fun h ->
        cont h ghostenv env
      else
        let te = ev e in
        evalpat (fghost = Ghost) ghostenv env rhs tp tp $. fun ghostenv env t ->
        assume_field h fparent fname frange fghost te t coef $. fun h ->
        cont h ghostenv env
    | WPointsTo (l, WReadArray (la, ea, _, ei), tp, rhs) ->
      let a = ev ea in
      let i = ev ei in
      evalpat false ghostenv env rhs tp tp $. fun ghostenv env t ->
      let slice = Chunk ((array_element_symb(), true), [tp], coef, [a; i; t], None) in
      cont (slice::h) ghostenv env
    | WPredAsn (l, g, is_global_predref, targs, pats0, pats) ->
      let (g_symb, pats0, pats, types, auto_info) =
        if not is_global_predref then 
          let Some term = try_assoc g#name env in ((term, false), pats0, pats, g#domain, None)
        else
          begin match try_assoc g#name predfammap with
            Some (_, _, _, declared_paramtypes, symb, _) -> ((symb, true), pats0, pats, g#domain, Some (g#name, declared_paramtypes))
          | None ->
            let PredCtorInfo (l, ps1, ps2, body, funcsym) = List.assoc g#name predctormap in
            let ctorargs = List.map (function LitPat e -> ev e | _ -> static_error l "Patterns are not supported in predicate constructor argument positions." None) pats0 in
            let g_symb = mk_app funcsym ctorargs in
            ((g_symb, false), [], pats, List.map snd ps2, None)
          end
      in
      let targs = instantiate_types tpenv targs in
      let domain = instantiate_types tpenv types in
      evalpats ghostenv env (pats0 @ pats) types domain (fun ghostenv env ts ->
        let input_param_count = match g#inputParamCount with None -> None | Some c -> Some (c + (List.length pats0)) in
        let do_assume_chunk () = produce_chunk h g_symb targs coef input_param_count ts size_first (fun h -> cont h ghostenv env) in
        match
          if assuming then None else
          match auto_info with
            None -> None
          | Some (predName, declared_paramtypes) ->
            try
              Some (Hashtbl.find auto_lemmas predName, declared_paramtypes)
            with Not_found -> None
        with
          None -> do_assume_chunk ()
        | Some ((frac, tparams, xs1, xs2, pre, post), declared_paramtypes) ->
          let ts = List.map (fun (t, (tp0, tp)) -> prover_convert_term t tp0 tp) (zip2 ts (zip2 domain declared_paramtypes)) in
          match frac with
            None -> 
            if coef == real_unit then 
              produce_asn_core (zip2 tparams targs) h [] (zip2 (xs1@xs2) ts) post coef size_first size_all true (fun h_ _ _ -> cont h_ ghostenv env)
            else
              do_assume_chunk ()
          | Some(f) ->
            produce_asn_core (zip2 tparams targs) h [] ((f, coef) :: (zip2 (xs1@xs2) ts)) post real_unit size_first size_all true (fun h_ _ _ -> cont h_ ghostenv env)
      )
    | WInstPredAsn (l, e_opt, st, cfin, tn, g, index, pats) ->
      let (pmap, pred_symb) =
        match try_assoc tn classmap1 with
          Some (lcn, abstract, fin, methods, fds_opt, ctors, super, interfs, preds, pn, ilist) ->
          let (_, pmap, _, symb, _) = List.assoc g preds in (pmap, symb)
        | None ->
          match try_assoc tn classmap0 with
            Some {cpreds} ->
            let (_, pmap, _, symb, _) = List.assoc g cpreds in (pmap, symb)
          | None ->
            match try_assoc tn interfmap1 with
              Some (li, fields, methods, preds, interfs, pn, ilist) -> let (_, pmap, family, symb) = List.assoc g preds in (pmap, symb)
            | None ->
              let InterfaceInfo (li, fields, methods, preds, interfs) = List.assoc tn interfmap0 in
              let (_, pmap, family, symb) = List.assoc g preds in
              (pmap, symb)
      in
      let target = match e_opt with None -> List.assoc "this" env | Some e -> ev e in
      let index = ev index in
      assume (ctxt#mk_not (ctxt#mk_eq target (ctxt#mk_intlit 0))) $. fun () ->
      begin fun cont -> if cfin = FinalClass then assume (ctxt#mk_eq (ctxt#mk_app get_class_symbol [target]) (List.assoc st classterms)) cont else cont () end $. fun () ->
      let types = List.map snd pmap in
      evalpats ghostenv env pats types types $. fun ghostenv env args ->
      produce_chunk h (pred_symb, true) [] coef (Some 2) (target::index::args) size_first $. fun h ->
      cont h ghostenv env
    | ExprAsn (l, e) -> assume (ev e) (fun _ -> cont h ghostenv env)
    | Sep (l, p1, p2) -> produce_asn_core tpenv h ghostenv env p1 coef size_first size_all assuming (fun h ghostenv env -> produce_asn_core tpenv h ghostenv env p2 coef size_all size_all assuming cont)
    | IfAsn (l, e, p1, p2) ->
      let cont h _ _ = cont h ghostenv env in
      branch
        (fun _ -> assume (ev e) (fun _ -> produce_asn_core tpenv h ghostenv env p1 coef size_all size_all assuming cont))
        (fun _ -> assume (ctxt#mk_not (ev e)) (fun _ -> produce_asn_core tpenv h ghostenv env p2 coef size_all size_all assuming cont))
    | WSwitchAsn (l, e, i, cs) ->
      let cont h _ _ = cont h ghostenv env in
      let t = ev e in
      let (_, tparams, ctormap, _) = List.assoc i inductivemap in
      let rec iter cs =
        match cs with
          SwitchAsnClause (lc, cn, pats, patsInfo, p)::cs ->
          branch
            (fun _ ->
               let (_, (_, tparams, _, tps, cs)) = List.assoc cn ctormap in
               let Some pts = zip pats tps in
               let xts =
                 if tparams = [] then
                   List.map (fun (x, tp) -> let term = get_unique_var_symb x tp in (x, term, term)) pts
                 else
                   let Some patsInfo = !patsInfo in
                   let Some pts = zip pts patsInfo in
                   List.map
                     (fun ((x, tp), info) ->
                      match info with
                        None -> let term = get_unique_var_symb x tp in (x, term, term)
                      | Some proverType ->
                        let term = ctxt#mk_app (mk_symbol x [] (typenode_of_provertype proverType) Uninterp) [] in
                        let term' = convert_provertype term proverType ProverInductive in
                        (x, term', term)
                     )
                     pts
               in
               let xenv = List.map (fun (x, _, t) -> (x, t)) xts in
               assume_eq t (mk_app cs (List.map (fun (x, t, _) -> t) xts)) (fun _ -> produce_asn_core tpenv h (pats @ ghostenv) (xenv @ env) p coef size_all size_all assuming cont))
            (fun _ -> iter cs)
        | [] -> success()
      in
      iter cs
    | EmpAsn l -> cont h ghostenv env
    | ForallAsn (l, i, e) ->
      in_temporary_context begin fun () ->
        ctxt#begin_formal;
        let forall = (eval None ((i, ctxt#mk_bound 0 ctxt#type_int) :: env) e) in
        ctxt#end_formal;
        ctxt#assume_forall "forall_ assertion" [] [ctxt#type_int] forall;
        cont h ghostenv env
      end
    | CoefAsn (l, DummyPat, body) ->
      produce_asn_core tpenv h ghostenv env body (get_dummy_frac_term ()) size_first size_all assuming cont
    | CoefAsn (l, coef', body) ->
      evalpat true ghostenv env coef' RealType RealType $. fun ghostenv env coef' ->
      produce_asn_core tpenv h ghostenv env body (real_mul l coef coef') size_first size_all assuming cont
    | WPluginAsn (l, xs, wasn) ->
      let [_, ((_, plugin), symb)] = pluginmap in
      let (pluginState, h) =
        match extract (function Chunk ((p, true), _, _, _, Some (PluginChunkInfo info)) when p == symb -> Some info | _ -> None) h with
          None -> (plugin#empty_state, h)
        | Some (s, h) -> (s, h)
      in
      plugin#produce_assertion pluginState env wasn $. fun pluginState env ->
      cont (Chunk ((symb, true), [], real_unit, [], Some (PluginChunkInfo pluginState))::h) (xs @ ghostenv) env
    )
  
  let produce_asn tpenv h ghostenv (env: (string * termnode) list) p coef size_first size_all cont =
    produce_asn_core tpenv h ghostenv env p coef size_first size_all false cont
  
  (* Region: consumption of assertions *)
  
  (** Checks if the specified predicate assertion matches the specified chunk. If not, returns None. Otherwise, returns the environment updated with new bindings and other stuff.
      Parameters:
        ghostenv (ghostEnvironment): string list -- The list of all variables that are ghost variables (i.e., not real variables). match_chunk adds all new bindings to this
          list. (Or, more correctly, it returns an updated list obtained by adding all new bindings.
        h (heap): chunk list -- Passed in only so that it can be passed to assert_false when an error is detected.
        env (environment): (string * term) list -- The environment used to evaluate expressions in the predicate assertion, and updated with new bindings.
        env' (environment'): (string * term) list -- The list of bindings of unbound variables. When closing a chunk, the user need not specify values for all arguments.
          As a result, the predicate body gets evaluated with an incomplete environment. This is okay so long as all unspecified (i.e. unbound) parameters appear in
          special positions where VeriFast knows how to derive their value, e.g. in the position of an output argument of a precise predicate assertion.
          match_chunk updates this list with new bindings.
        l (sourceLocation): loc -- The appropriate source location to use when reporting an error
        g (predicateName): (term * bool) -- Predicate name specified in the predicate assertion, against which to compare the predicate name of the chunk
        targs (typeArguments): type_ list -- (For a predicate with type parameters) The type arguments specified in the predicate assertion, possibly further
          instantiated with type variable bindings from the environment of this operation, e.g. from an outer type-parameterized predicate.
        coef (baseCoefficient): term -- A term denoting a real number. The base coefficient with which the coefficient specified in the predicate assertion should
          be multiplied before comparing with the coefficient of the chunk. The base coefficient is typically 1, but can be something else if a coefficient is
          specified in a close statement, e.g. "close [1/2]foo();".
        coefpat (coefficientPattern): pat0 -- Coefficient pattern specified in the predicate assertion
        inputParamCount (inputParameterCount): int option -- In case of a precise predicate, specified the number of input parameters
        pats (argumentPatterns): pat0 list -- Predicate arguments specified in the predicate assertion
        tps0 (semiinstantiatedParameterTypes): type_ list -- Parameter types of the predicate when instantiating its type parameters with the type arguments specified in
          the predicate assertion. Note that these may themselves contain type variables declared by e.g. the predicate that contains the predicate assertion. The
          latter are not instantiated. The predicate argument expressions have been typechecked against these partially-instantiated types. Therefore, the environment
          used to evaluate the predicate arguments must be boxed correctly for these types. (Boxing is necessary because the SMT solvers do not support generics.)
        tps (instantiatedParameterTypes): type_ list -- Parameter types of the predicate, after instantiation with both the type parameter bindings specified in
          the predicate assertion and any additional type parameter bindings from the environment. The chunk argument terms are of these types.
        chunk: chunk -- The chunk against which to match the predicate assertion
      Returns:
        None -- no match
        Some (chunk, coef0, ts0, size0, ghostenv, env, env', newChunks)
          chunk: chunk -- The chunk that was matched
          coef0, ts0, size0 -- Coefficient, arguments, size of the chunk that was matched (duplicates stuff from 'chunk')
          ghostenv -- Updated ghost environment
          env -- Updated environment
          env' -- Updated list of bindings of unbound variables
          newChunks -- Any new chunks generated by this match; in particular, auto-splitting of fractional permissions.
   *)
  let match_chunk ghostenv h env env' l g targs coef coefpat inputParamCount pats tps0 tps (Chunk (g', targs0, coef0, ts0, size0) as chunk) =
    let rec match_pat ghostenv env env' isInputParam pat tp0 tp t cont =
      let match_terms v t =
        if definitely_equal v t then
          cont ghostenv env env'
        else if isInputParam then
          None
        else
          assert_false h env l (Printf.sprintf "Cannot prove %s == %s" (ctxt#pprint t) (ctxt#pprint v)) None
      in
      match pat with
      | SrcPat (LitPat (Var (lx, x, scope))) when !scope = Some LocalVar ->
        begin match try_assoc x env with
          Some t' -> match_terms (prover_convert_term t' tp0 tp) t
        | None -> let binding = (x, prover_convert_term t tp tp0) in cont ghostenv (binding::env) (binding::env')
        end
      | SrcPat (LitPat e) ->
        match_terms (prover_convert_term (eval None env e) tp0 tp) t
      | TermPat t0 -> match_terms (prover_convert_term t0 tp0 tp) t
      | SrcPat (VarPat (_, x)) -> cont (x::ghostenv) ((x, prover_convert_term t tp tp0)::env) env'
      | SrcPat DummyPat -> cont ghostenv env env'
      | SrcPat (WCtorPat (l, i, targs, g, ts0, ts, pats)) ->
        let t = prover_convert_term t tp tp0 in
        let (_, inductive_tparams, ctormap, _) = List.assoc i inductivemap in
        let cont () =
          let (_, (_, _, _, _, (symb, _))) = List.assoc g ctormap in
          ctxt#push;
          let vs = List.map2 (fun tp0 tp -> let v = get_unique_var_symb "value" tp in (v, prover_convert_term v tp tp0)) ts0 ts in
          let formula = ctxt#mk_eq t (ctxt#mk_app symb (List.map snd vs)) in
          push_context (Assuming formula);
          ignore (ctxt#assume formula);
          let inputParamCount = if isInputParam then max_int else 0 in
          let pats = List.map (fun pat -> SrcPat pat) pats in
          match match_pats ghostenv env env' inputParamCount 0 pats ts ts (List.map fst vs) cont with
            None ->
            pop_context ();
            ctxt#pop;
            None
          | result ->
            push_undo_item (fun () -> pop_context (); ctxt#pop);
            result
        in
        let rec check_not_other_ctors cs =
          match cs with
            [] -> cont ()
          | (g', (_, (_, _, _, ts0, (symb, _))))::cs ->
            if
              g' = g ||
              in_temporary_context begin fun () ->
                let vs = List.map (fun t -> get_unique_var_symb "value" t) ts0 in
                ctxt#assume (ctxt#mk_eq t (ctxt#mk_app symb vs)) = Unsat
              end
            then
              check_not_other_ctors cs
            else
              if isInputParam then
                None
              else
                assert_false h env l (Printf.sprintf "Cannot prove that '%s' is not an instance of constructor '%s'" (ctxt#pprint t) g') None
        in
        check_not_other_ctors ctormap
    and match_pats ghostenv env env' inputParamCount index pats tps0 tps ts cont =
      match (pats, tps0, tps, ts) with
        (pat::pats, tp0::tps0, tp::tps, t::ts) ->
        let isInputParam = index < inputParamCount in
        match_pat ghostenv env env' isInputParam pat tp0 tp t $. fun ghostenv env env' ->
        match_pats ghostenv env env' inputParamCount (index + 1) pats tps0 tps ts cont
      | ([], [], [], []) -> cont ghostenv env env'
    in
    let match_coef ghostenv env cont =
      if coef == real_unit && coefpat == real_unit_pat && coef0 == real_unit then cont chunk ghostenv env coef0 [] else
      let match_term_coefpat t =
        let t = real_mul l coef t in
        if definitely_equal t coef0 then
          cont chunk ghostenv env coef0 []
        else
          let half_coef0 = ctxt#mk_real_mul real_half coef0 in
          if definitely_equal t half_coef0 then
            let chunk' = Chunk (g', targs0, half_coef0, ts0, size0) in
            cont chunk' ghostenv env half_coef0 [chunk']
          else if ctxt#query (ctxt#mk_real_lt real_zero t) && ctxt#query (ctxt#mk_real_lt t coef0) then
            cont (Chunk (g', targs0, t, ts0, size0)) ghostenv env t [Chunk (g', targs0, ctxt#mk_real_sub coef0 t, ts0, size0)]
          else
            None
            (*if inputParamCount = None then
              None
            else
              assert_false h env l (Printf.sprintf "Fraction mismatch: cannot prove %s == %s or 0 < %s < %s" (ctxt#pprint t) (ctxt#pprint coef0) (ctxt#pprint t) (ctxt#pprint coef0)) (Some "fractionmismatch")*)
      in
      match coefpat with
        SrcPat (LitPat e) -> match_term_coefpat (eval None env e)
      | TermPat t -> match_term_coefpat t
      | SrcPat (VarPat (_, x)) -> cont chunk (x::ghostenv) (update env x (real_div l coef0 coef)) coef0 []
      | SrcPat DummyPat ->
        if is_dummy_frac_term coef0 then
          let dummy' = get_dummy_frac_term () in
          cont (Chunk (g', targs0, dummy', ts0, size0)) ghostenv env dummy' [Chunk (g', targs0, get_dummy_frac_term (), ts0, size0)]
        else
          cont chunk ghostenv env coef0 []
    in
    if not (predname_eq g g' && List.for_all2 unify targs targs0) then None else
    let inputParamCount = match inputParamCount with None -> max_int | Some n -> n in
    match_pats ghostenv env env' inputParamCount 0 pats tps0 tps ts0 $. fun ghostenv env env' ->
    match_coef ghostenv env $. fun chunk ghostenv env coef0 newChunks ->
    Some (chunk, coef0, ts0, size0, ghostenv, env, env', newChunks)
  
  let lookup_points_to_chunk_core h0 f_symb t =
    let rec iter h =
      match h with
        [] -> None
      | Chunk ((g, true), targs, coef, [t0; v], _)::_ when g == f_symb && definitely_equal t0 t -> Some v
      | Chunk ((g, false), targs, coef, [t0; v], _):: _ when definitely_equal g f_symb && definitely_equal t0 t -> Some v
      | _::h -> iter h
    in
    iter h0

  let lookup_points_to_chunk h0 env l f_symb t =
    match lookup_points_to_chunk_core h0 f_symb t with
      None -> assert_false h0 env l ("No matching pointsto chunk: " ^ (ctxt#pprint f_symb) ^ "(" ^ (ctxt#pprint t) ^ ", _)") None
    | Some v -> v

  let read_field h env l t fparent fname =
    let (_, (_, _, _, _, f_symb, _)) = List.assoc (fparent, fname) field_pred_map in
    lookup_points_to_chunk h env l f_symb t
  
  let read_static_field h env l fparent fname =
    let (_, (_, _, _, _, f_symb, _)) = List.assoc (fparent, fname) field_pred_map in
    match extract (function Chunk (g, targs, coef, arg0::args, size) when predname_eq (f_symb, true) g -> Some arg0 | _ -> None) h with
      None -> assert_false h env l ("No matching heap chunk: " ^ ctxt#pprint f_symb) None
    | Some (v, _) -> v
  
  let try_read_java_array h env l a i tp =
    head_flatmap
      begin function
        Chunk ((g, true), [tp], coef, [a'; i'; v], _)
          when g == array_element_symb() && definitely_equal a' a && definitely_equal i' i ->
          [v]
      | Chunk ((g, true), [tp], coef, [a'; istart; iend; vs], _)
          when g == array_slice_symb() && definitely_equal a' a && ctxt#query (ctxt#mk_and (ctxt#mk_le istart i) (ctxt#mk_lt i iend)) ->
          let (_, _, _, _, nth_symb) = List.assoc "nth" purefuncmap in
          [apply_conversion ProverInductive (provertype_of_type tp) (mk_app nth_symb [ctxt#mk_sub i istart; vs])]
     (* | Chunk ((g, true), [tp;tp2;tp3], coef, [a'; istart; iend; p; info; elems; vs], _)
          when g == array_slice_deep_symb() && definitely_equal a' a && ctxt#query (ctxt#mk_and (ctxt#mk_le istart i) (ctxt#mk_lt i iend)) ->
          let (_, _, _, _, nth_symb) = List.assoc "nth" purefuncmap in
          [apply_conversion ProverInductive (provertype_of_type tp) (mk_app nth_symb [ctxt#mk_sub i istart; vs])]*)
      | _ -> []
      end
      h
  
  let try_update_java_array h env l a i tp new_value =
    let rec try_update_java_array_core todo seen = 
      match todo with
        [] -> None
      | Chunk ((g, true), [tp], coef, [a'; i'; v], b) :: rest
          when g == array_element_symb() && definitely_equal a' a && definitely_equal i' i ->
        Some(seen @ ((Chunk ((g, true), [tp], coef, [a'; i'; new_value], b)) :: rest))
      | Chunk ((g, true), [tp], coef, [a'; istart; iend; vs], b) :: rest
          when g == array_slice_symb() && definitely_equal a' a && ctxt#query (ctxt#mk_and (ctxt#mk_le istart i) (ctxt#mk_lt i iend)) ->
        let (_, _, _, _, update_symb) = List.assoc "update" purefuncmap in
        let converted_new_value = apply_conversion (provertype_of_type tp) ProverInductive new_value in
        let updated_vs = (mk_app update_symb [ctxt#mk_sub i istart; converted_new_value; vs]) in
        Some(seen @ ((Chunk ((g, true), [tp], coef, [a'; istart; iend; updated_vs], b)) :: rest))
      | chunk :: rest ->
        try_update_java_array_core rest (seen @ [chunk])
    in
      try_update_java_array_core h [] 
  
  let read_java_array h env l a i tp =
    let slices = try_read_java_array h env l a i tp in
    match slices with
      None -> assert_false h env l "No matching array element or array slice chunk" None
    | Some v -> v
  
  let pointer_pred_symb () =
    let (_, _, _, _, pointer_pred_symb, _) = List.assoc "pointer" predfammap in
    pointer_pred_symb

  let int_pred_symb () =
    let (_, _, _, _, int_pred_symb, _) = List.assoc "integer" predfammap in
    int_pred_symb

  let u_int_pred_symb () =
    let (_, _, _, _, u_int_pred_symb, _) = List.assoc "u_integer" predfammap in
    u_int_pred_symb
  
  let char_pred_symb () =
    let (_, _, _, _, char_pred_symb, _) = List.assoc "character" predfammap in
    char_pred_symb

  let u_char_pred_symb () =
    let (_, _, _, _, u_char_pred_symb, _) = List.assoc "u_character" predfammap in
    u_char_pred_symb
  
  let try_pointee_pred_symb pointeeType =
    match pointeeType with
      PtrType _ -> Some (pointer_pred_symb ())
    | IntType -> Some (int_pred_symb ())
    | UintPtrType -> Some (u_int_pred_symb ())
    | Char -> Some (char_pred_symb ())
    | UChar -> Some (u_char_pred_symb ())
    | _ -> None
  
  let pointee_pred_symb l pointeeType =
    match try_pointee_pred_symb pointeeType with
      Some symb -> symb
    | None -> static_error l ("Dereferencing pointers of type " ^ string_of_type pointeeType ^ " is not yet supported.") None
  
  let read_c_array h env l a i tp =
    let (_, _, _, _, c_array_symb, _) = List.assoc "array" predfammap in
    let predsym = pointee_pred_symb l tp in
    let slices =
      head_flatmap
        begin function
          Chunk (g, [tp2], coef, [a'; n'; size'; q'; vs'], _)
            when predname_eq g (c_array_symb, true) && tp = tp2 && definitely_equal a' a && ctxt#query (ctxt#mk_and (ctxt#mk_le (ctxt#mk_intlit 0) i) (ctxt#mk_lt i n')) &&
            ctxt#query (ctxt#mk_eq size' (sizeof l tp)) ->
            let (_, _, _, _, nth_symb) = List.assoc "nth" purefuncmap in
            [apply_conversion ProverInductive (provertype_of_type tp) (mk_app nth_symb [i; vs'])]
        | _ -> []
        end
        h
    in
    match slices with
      None ->
        begin match lookup_points_to_chunk_core h predsym (ctxt#mk_add a (ctxt#mk_mul i (sizeof l tp))) with
          None -> assert_false h env l ("No matching array chunk: array<" ^
                  (string_of_type tp) ^ ">(" ^ (ctxt#pprint a) ^ ", 0<=" ^
                  (ctxt#pprint i) ^ "<n, " ^ (ctxt#pprint (sizeof l tp)) ^
                  ", _, _).") None
        | Some v -> v
        end
    | Some v -> v
  
  let read_array h env l a i tp = 
    match language with 
      Java -> read_java_array h env l a i tp
    | CLang -> read_c_array h env l a i tp
  
  let deref_pointer h env l pointerTerm pointeeType =
    lookup_points_to_chunk h env l (pointee_pred_symb l pointeeType) pointerTerm
  
  let lists_disjoint xs ys =
    List.for_all (fun x -> not (List.mem x ys)) xs
  
  let with_updated_ref r f body =
    let value = !r in
    r := f value;
    do_finally body (fun () -> r := value)
  
  let consume_chunk_recursion_depth = ref 0
  
  (** consume_chunk_core attempts to consume a chunk matching the specified predicate assertion from the specified heap.
      If no matching chunk is found in the heap, automation rules are tried (e.g. auto-open and auto-close rules).
      Parameters:
        rules -- The automation rules
        h (heap): chunk list -- The heap
        ghostenv (ghostEnvironment): string list -- The list of ghost variables. Used to check that ghost variables are not used in real code.
        env (environment): (string * term) list -- The environment that binds variable names to their symbolic value. Updated with new bindings.
        env' (unboundVariableBindings): (string * term) list -- Bindings of variables that were declared but not bound. (Happens when you do not specify values for all predicate parameters when closing a chunk.)
        l (sourceLocation): loc -- Appropriate source location to use when reporting an error.
        g (predicateName): (term * bool) -- Predicate name specified in the predicate assertion.
        targs (typeArguments): type_ list -- Type arguments specified in the predicate assertion, instantiated with any type variable bindings currently in effect
        coef (baseCoefficient): term -- Base coefficient in effect. The coefficient specified in the predicate assertion should be multiplied by this base coefficient
          before comparing with a chunk found in the heap. Typically 1, unless e.g. a coefficient is specified in a close statement ('close [1/2]foo();').
        coefpat (coefficientPattern): pat0 -- Coefficient specified in the predicate assertion.
        inputParamCount (inputParameterCount): int option -- If the predicate is precise, specifies the number of input parameters.
        pats (argumentPatterns): pat0 list -- Predicate arguments specified in the predicate assertion.
        tps0 (semiinstantiatedParameterTypes): type_ list -- Predicate parameter types, after instantiation with the type arguments specified in the predicate
          assertion, but without further instantiation. Argument expressions in 'pats' are typechecked against these types and expect that terms are boxed correctly
          with respect to these types.
        tps (instantiatedParameterTypes): type_ list -- Predicate parameter types, after instantiation with the type arguments specified in the predicate assertion,
          as well as any additional type variable bindings currently in effect (e.g. type arguments of an outer predicate, as in 'close foo<int>();').
        cont: continuation called if successful. Typical call:
          [cont chunk h coef ts size ghostenv env env']
            chunk: chunk -- chunk that was consumed (used by the 'leak' command to re-produce all consumed chunks with dummy fraction coefficients)
            h -- heap obtained by removing the consumed chunk (as well as applying any automation rules)
            coef, ts, size -- Coefficient, arguments, size of consumed chunk (duplicates info from 'chunk')
            ghostenv: string list -- Updated ghost environment
            env: (string * term) list -- Updated environment
            env': (string * term) list -- Updated list of bindings of declared but unbound variables
    *)
  let consume_chunk_core rules h ghostenv env env' l g targs coef coefpat inputParamCount pats tps0 tps cont =
    let rec consume_chunk_core_core h =
      let rec iter hprefix h =
        match h with
          [] -> []
        | chunk::h ->
            match match_chunk ghostenv h env env' l g targs coef coefpat inputParamCount pats tps0 tps chunk with
              None -> iter (chunk::hprefix) h
            | Some (chunk, coef, ts, size, ghostenv, env, env', newChunks) -> [(chunk, newChunks @ hprefix @ h, coef, ts, size, ghostenv, env, env')]
      in
      match iter [] h with
        [] ->
        begin fun cont ->
          if !consume_chunk_recursion_depth > 100 then cont () else
          with_updated_ref consume_chunk_recursion_depth ((+) 1) $. fun () ->
          if inputParamCount = None then cont () else
          begin fun cont' ->
            let Some inputParamCount = inputParamCount in
            let rec iter n ts pats tps0 tps =
              if n = 0 then cont' (List.rev ts) else
              match (pats, tps0, tps) with
              | (pat::pats, tp0::tps0, tp::tps) ->
                let ok t = iter (n - 1) (prover_convert_term t tp0 tp::ts) pats tps0 tps in
                match pat with
                  SrcPat (LitPat e) -> ok (eval None env e)
                | TermPat t -> ok t
                | _ -> cont ()
            in
            iter inputParamCount [] pats tps0 tps
          end $. fun ts ->
          match g with
            (g, _) ->
            begin match try_assq g rules with
              Some rules ->
              let terms_are_well_typed = List.for_all (function SrcPat (LitPat (WidenedParameterArgument _)) -> false | _ -> true) pats in
              let rec iter rules =
                match rules with
                  [] -> cont ()
                | rule::rules ->
                  rule h targs terms_are_well_typed ts $. fun h ->
                  match h with
                    None -> iter rules
                  | Some h ->
                    with_context (Executing (h, env, l, "Consuming chunk (retry)")) $. fun () ->
                    consume_chunk_core_core h
              in
              iter rules
            | None -> cont ()
            end
        end $. fun () ->
        let message =
          let predname = match g with (g, _) -> ctxt#pprint g in
          let targs =
            match targs with
              [] -> ""
            | _ -> Printf.sprintf "<%s>" (String.concat ", " (List.map string_of_type targs))
          in
          let patvars = ref [] in
          let rec string_of_pat pat =
            match pat with
            | LitPat (Var (_, x, scope)) when !scope = Some LocalVar -> if List.mem_assoc x env then ctxt#pprint (List.assoc x env) else "_"
            | LitPat e -> if !patvars = [] || lists_disjoint !patvars (vars_used e) then ctxt#pprint (eval None env e) else "<expr>"
            | DummyPat -> "_"
            | VarPat (_, x) -> patvars := x::!patvars; "_"
            | WCtorPat (_, i, targs, g, ts0, ts, pats) -> Printf.sprintf "%s(%s)" g (String.concat ", " (List.map string_of_pat pats))
          in
          let string_of_pat0 pat0 =
            match pat0 with
              TermPat t -> ctxt#pprint t
            | SrcPat pat -> string_of_pat pat
          in
          Printf.sprintf "No matching heap chunks: %s%s(%s)" predname targs (String.concat ", " (List.map string_of_pat0 pats))
        in
        assert_false h env l message (Some "nomatchingheapchunks")
  (*      
      | [(h, ts, ghostenv, env)] -> cont h ts ghostenv env
      | _ -> assert_false h env l "Multiple matching heap chunks." None
  *)
      | (chunk, h, coef, ts, size, ghostenv, env, env')::_ -> cont chunk h coef ts size ghostenv env env'
    in
    consume_chunk_core_core h
  
  (** [cont] is called as [cont chunk h coef ts size ghostenv env env']. See docs at consume_chunk_core. *)
  let consume_chunk rules h ghostenv env env' l g targs coef coefpat inputParamCount pats cont =
    let tps = List.map (fun _ -> IntType) pats in (* dummies, to indicate that no prover type conversions are needed *)
    consume_chunk_core rules h ghostenv env env' l g targs coef coefpat inputParamCount pats tps tps cont
  
  let srcpat pat = SrcPat pat
  let srcpats pats = List.map srcpat pats
  
  let rec consume_asn_core rules tpenv h ghostenv env env' p checkDummyFracs coef cont =
    let with_context_helper cont =
      match p with
        Sep (_, _, _) -> cont()
      | _ ->
        if !verbosity >= 2 then Printf.printf "%10.6fs: %s: Consuming assertion\n" (Perf.time()) (string_of_loc (asn_loc p));
        with_context (Executing (h, env, asn_loc p, "Consuming assertion")) cont
    in
    with_context_helper (fun _ ->
    let ev = eval None env in
    let check_dummy_coefpat l coefpat coef =
      if language = CLang && checkDummyFracs then
      match coefpat with
        SrcPat DummyPat -> if not (is_dummy_frac_term coef) then assert_false h env l "Cannot match a non-dummy fraction chunk against a dummy fraction pattern. First leak the chunk using the 'leak' command." None
      | _ -> ()
    in
    let points_to l coefpat e tp rhs =
      match e with
        WRead (lr, e, fparent, fname, frange, fstatic, fvalue, fghost) ->
        let (_, (_, _, _, _, symb, _)) = List.assoc (fparent, fname) field_pred_map in
        let (inputParamCount, pats) =
          if fstatic then
            (Some 0, [rhs])
          else
            (Some 1, [SrcPat (LitPat e); rhs])
        in
        consume_chunk rules h ghostenv env env' l (symb, true) [] coef coefpat inputParamCount pats
          (fun chunk h coef ts size ghostenv env env' -> check_dummy_coefpat l coefpat coef; cont [chunk] h ghostenv env env' size)
      | WReadArray (la, ea, _, ei) ->
        let pats = [SrcPat (LitPat ea); SrcPat (LitPat ei); rhs] in
        consume_chunk rules h ghostenv env env' l (array_element_symb(), true) [tp] coef coefpat (Some 2) pats $.
        fun chunk h coef ts size ghostenv env env' ->
        check_dummy_coefpat l coefpat coef;
        cont [chunk] h ghostenv env env' size
    in
    let pred_asn l coefpat g is_global_predref targs pats0 pats =
      let (g_symb, pats0, pats, types) =
        if is_global_predref then
           match try_assoc g#name predfammap with
            Some (_, _, _, _, symb, _) -> ((symb, true), pats0, pats, g#domain)
          | None -> 
            let PredCtorInfo (l, ps1, ps2, body, funcsym) = List.assoc g#name predctormap in
            let ctorargs = List.map (function SrcPat (LitPat e) -> ev e | _ -> static_error l "Patterns are not supported in predicate constructor argument positions." None) pats0 in
            let g_symb = mk_app funcsym ctorargs in
            ((g_symb, false), [], pats, List.map snd ps2)
        else
          let Some term = try_assoc (g#name) env in ((term, false), pats0, pats, g#domain)
      in
      let targs = instantiate_types tpenv targs in
      let domain = instantiate_types tpenv types in
      let inputParamCount = match g#inputParamCount with None -> None | Some n -> Some (List.length pats0 + n) in
      consume_chunk_core rules h ghostenv env env' l g_symb targs coef coefpat inputParamCount (pats0 @ pats) types domain (fun chunk h coef ts size ghostenv env env' ->
        check_dummy_coefpat l coefpat coef;
        cont [chunk] h ghostenv env env' size
      )
    in
    let inst_call_pred l coefpat e_opt tn g index pats =
      let (pmap, pred_symb) =
        match try_assoc tn classmap1 with
          Some (lcn, abstract, fin, methods, fds_opt, ctors, super, interfs, preds, pn, ilist) ->
          let (_, pmap, _, symb, _) = List.assoc g preds in (pmap, symb)
        | None ->
          match try_assoc tn classmap0 with
            Some {cpreds} ->
            let (_, pmap, _, symb, _) = List.assoc g cpreds in (pmap, symb)
          | None ->
            match try_assoc tn interfmap1 with
              Some (li, fields, methods, preds, interfs, pn, ilist) -> let (_, pmap, family, symb) = List.assoc g preds in (pmap, symb)
            | None ->
              let InterfaceInfo (li, fields, methods, preds, interfs) = List.assoc tn interfmap0 in
              let (_, pmap, family, symb) = List.assoc g preds in
              (pmap, symb)
      in
      let target = match e_opt with None -> List.assoc "this" env | Some e -> ev e in
      let index = ev index in
      let types = ObjType tn::ObjType "java.lang.Class"::List.map snd pmap in
      let pats = TermPat target::TermPat index::srcpats pats in
      consume_chunk_core rules h ghostenv env env' l (pred_symb, true) [] coef coefpat (Some 2) pats types types $. fun chunk h coef ts size ghostenv env env' ->
      check_dummy_coefpat l coefpat coef;
      cont [chunk] h ghostenv env env' size
    in
    match p with
    | WPointsTo (l, e, tp, rhs) -> points_to l real_unit_pat e tp (SrcPat rhs)
    | WPredAsn (l, g, is_global_predref, targs, pats0, pats) -> pred_asn l real_unit_pat g is_global_predref targs (srcpats pats0) (srcpats pats)
    | WInstPredAsn (l, e_opt, st, cfin, tn, g, index, pats) ->
      inst_call_pred l real_unit_pat e_opt tn g index pats
    | ExprAsn (l, Operation (lo, Eq, [Var (lx, x, scope); e], tps)) when !scope = Some LocalVar ->
      begin match try_assoc x env with
        Some t -> assert_term (ctxt#mk_eq t (ev e)) h env l "Cannot prove condition." None; cont [] h ghostenv env env' None
      | None -> let binding = (x, ev e) in cont [] h ghostenv (binding::env) (binding::env') None
      end
   (* | ExprAsn(l, Operation(lo, And, [e1; e2], tps)) ->
      consume_asn_core rules tpenv h ghostenv env env' (ExprAsn (expr_loc e1, e1)) checkDummyFracs coef (fun chunks h ghostenv env env' size ->
        consume_asn_core rules tpenv h ghostenv env env' (ExprAsn (expr_loc e2, e2)) checkDummyFracs coef (fun chunks' h ghostenv env env' _ ->
          cont (chunks @ chunks') h ghostenv env env' size
        )
      )
    | ExprAsn(l, IfExpr(lo, con, e1, e2)) ->
      let cont chunks h _ _ env'' _ = cont chunks h ghostenv (env'' @ env) (env'' @ env') None in
      let env' = [] in
      branch
        (fun _ ->
           assume (ev con) (fun _ ->
             consume_asn_core rules tpenv h ghostenv env env' (ExprAsn (expr_loc e1, e1)) checkDummyFracs coef cont))
        (fun _ ->
           assume (ctxt#mk_not (ev con)) (fun _ ->
             consume_asn_core rules tpenv h ghostenv env env' (ExprAsn (expr_loc e2, e2)) checkDummyFracs coef cont))*)
    | ExprAsn (l, e) ->
      assert_expr env e h env l "Cannot prove condition." None; cont [] h ghostenv env env' None
    | Sep (l, p1, p2) ->
      consume_asn_core rules tpenv h ghostenv env env' p1 checkDummyFracs coef (fun chunks h ghostenv env env' size ->
        consume_asn_core rules tpenv h ghostenv env env' p2 checkDummyFracs coef (fun chunks' h ghostenv env env' _ ->
          cont (chunks @ chunks') h ghostenv env env' size
        )
      )
    | IfAsn (l, e, p1, p2) ->
      let cont chunks h _ _ env'' _ = cont chunks h ghostenv (env'' @ env) (env'' @ env') None in
      let env' = [] in
      branch
        (fun _ ->
           assume (ev e) (fun _ ->
             consume_asn_core rules tpenv h ghostenv env env' p1 checkDummyFracs coef cont))
        (fun _ ->
           assume (ctxt#mk_not (ev e)) (fun _ ->
             consume_asn_core rules tpenv h ghostenv env env' p2 checkDummyFracs coef cont))
    | WSwitchAsn (l, e, i, cs) ->
      let cont chunks h _ _ env'' _ = cont chunks h ghostenv (env'' @ env) (env'' @ env') None in
      let env' = [] in
      let t = ev e in
      let (_, tparams, ctormap, _) = List.assoc i inductivemap in
      let rec iter cs =
        match cs with
          SwitchAsnClause (lc, cn, pats, patsInfo, p)::cs ->
          let (_, (_, tparams, _, tps, ctorsym)) = List.assoc cn ctormap in
          let Some pts = zip pats tps in
          let (xs, xenv) =
            if tparams = [] then
              let xts = List.map (fun (x, tp) -> (x, get_unique_var_symb x tp)) pts in
              let xs = List.map (fun (x, t) -> t) xts in
              (xs, xts)
            else
              let Some patsInfo = !patsInfo in
              let Some pts = zip pts patsInfo in
              let xts =
                List.map
                  (fun ((x, tp), info) ->
                   match info with
                     None -> let term = get_unique_var_symb x tp in (x, term, term)
                   | Some proverType ->
                     let term = ctxt#mk_app (mk_symbol x [] (typenode_of_provertype proverType) Uninterp) [] in
                     let term' = convert_provertype term proverType ProverInductive in
                     (x, term', term)
                  )
                  pts
              in
              let xs = List.map (fun (x, t, _) -> t) xts in
              let xenv = List.map (fun (x, _, t) -> (x, t)) xts in
              (xs, xenv)
          in
          branch
            (fun _ -> assume_eq t (mk_app ctorsym xs) (fun _ -> consume_asn_core rules tpenv h (pats @ ghostenv) (xenv @ env) env' p checkDummyFracs coef cont))
            (fun _ -> iter cs)
        | [] -> success()
      in
      iter cs
    | EmpAsn l -> cont [] h ghostenv env env' None
    | ForallAsn (l, i, e) -> 
      let fresh_term = get_unique_var_symb i IntType in
      assert_expr ((i, fresh_term) :: env) e h ((i, fresh_term) :: env) l "Cannot prove condition." None;
      cont [] h ghostenv env env' None
    | CoefAsn (l, coefpat, WPointsTo (_, e, tp, rhs)) -> points_to l (SrcPat coefpat) e tp (SrcPat rhs)
    | CoefAsn (l, coefpat, WPredAsn (_, g, is_global_predref, targs, pat0, pats)) -> pred_asn l (SrcPat coefpat) g is_global_predref targs (srcpats pat0) (srcpats pats)
    | CoefAsn (l, coefpat, WInstPredAsn (_, e_opt, st, cfin, tn, g, index, pats)) -> inst_call_pred l (SrcPat coefpat) e_opt tn g index pats
    | WPluginAsn (l, xs, wasn) ->
      let [_, ((_, plugin), symb)] = pluginmap in
      let (pluginState, h) =
        match extract (function Chunk ((p, true), _, _, _, Some (PluginChunkInfo info)) when p == symb -> Some info | _ -> None) h with
          None -> (plugin#empty_state, h)
        | Some (s, h) -> (s, h)
      in
      try 
        plugin#consume_assertion pluginState env wasn $. fun pluginState env ->
        cont [] (Chunk ((symb, true), [], real_unit, [], Some (PluginChunkInfo pluginState))::h) (xs @ ghostenv) env env' None
      with Plugins.PluginConsumeError (off, len, msg) ->
        let ((path, line, col), _) = l in
        let l = ((path, line, col + 1 + off), (path, line, col + 1 + off + len)) in
        assert_false h env l msg None
    )
  
  let consume_asn rules tpenv h ghostenv env p checkDummyFracs coef cont =
    consume_asn_core rules tpenv h ghostenv env [] p checkDummyFracs coef (fun chunks h ghostenv env env' size_first -> cont chunks h ghostenv env size_first)

  let term_of_pred_index =
    match language with
      Java -> fun cn -> List.assoc cn classterms
    | CLang -> fun fn -> List.assoc fn funcnameterms
  
  let predinstmap_by_predfamsymb =
    flatmap
      begin fun ((p, fns), (env, l, predinst_tparams, xs, symb, inputParamCount, wbody)) ->
        if fns = [] && predinst_tparams = [] && env = [] then
          [(symb, (xs, wbody))]
        else
          []
      end
      predinstmap
  
  (* Those predicate instances that, under certain conditions on the input parameters, are likely to be closeable. *)
  let empty_preds =
    flatmap
      begin fun (((p, fns), (env, l, predinst_tparams, xs, symb, inputParamCount, wbody)) as predinst) ->
        let fsymbs = List.map term_of_pred_index fns in
        match inputParamCount with
          None -> []
        | Some n ->
          let inputVars = List.map fst (take n xs) in
          let rec iter conds wbody cont =
            match wbody with
            | Sep (_, asn1, asn2) ->
              iter conds asn1 (fun conds -> iter conds asn2 cont)
            | IfAsn (_, cond, asn1, asn2) ->
              if expr_is_fixed inputVars cond then
                iter (cond::conds) asn1 cont @ iter (Operation (dummy_loc, Not, [cond], ref None)::conds) asn2 cont
              else
                []
            | ExprAsn (_, Operation (_, Eq, [Var (_, x, _); e], _)) when not (List.mem x inputVars) && expr_is_fixed inputVars e ->
              cont conds
            | ExprAsn (_, e) when expr_is_fixed inputVars e ->
              cont (e::conds)
            | EmpAsn _ -> cont conds
            (*| ForallAsn _ -> cont conds*)
            | WSwitchAsn(_, e, i, cases) when expr_is_fixed inputVars e ->
              flatmap 
                (fun (SwitchAsnClause (l, casename, args, boxinginfo, asn)) ->
                  if (List.length args) = 0 then
                    let cond = Operation (l, Eq, [e; Var (l, casename, ref (Some PureCtor))], ref (Some [AnyType; AnyType])) in
                    iter (cond :: conds) asn cont
                  else 
                   []
                )
                cases
            | _ -> []
          in
          let conds = iter [] wbody (fun conds -> [conds]) in
          if conds <> [] then [(symb, fsymbs, conds, predinst)] else []
      end
      predinstmap
  
  (*let _ =
    begin print_endline "empty predicates:";
    List.iter
      (fun (from_symb, from_indices, conditions_list, _) ->
        begin 
          print_endline (ctxt#pprint from_symb);
          List.iter (fun conds -> 
            print_endline (string_of_int (List.length conds));
            (*List.iter (fun con -> print_endline ("    " ^ (ctxt#pprint con))) conds;*)
            print_endline "  or";
          ) 
          conditions_list;
        end
      )
      empty_preds
    end
  in*)
  
  (* direct edges from a precise predicate or predicate family to other precise predicates 
     - each element of path is of the form:
       (outer_l, outer_symb, outer_is_inst_pred, outer_formal_targs, outer_actual_indices, outer_formal_args, outer_formal_input_args, outer_wbody, inner_frac_expr_opt, inner_target_opt, inner_formal_targs, inner_formal_indices, inner_input_exprs, conds)
  *)
  let pred_fam_contains_edges =
    flatmap
      (fun ((p, fns), (env, l, predinst_tparams, xs, psymb, inputParamCount, wbody0)) ->
        let pindices = List.map term_of_pred_index fns in
        match inputParamCount with
          None -> [] (* predicate is not precise *)
        | Some nbInputParameters ->
          let inputParameters = List.map fst (take nbInputParameters xs) in
          let inputFormals = (take nbInputParameters xs) in
          let rec iter coef conds wbody =
            match wbody with
              WPointsTo(_, WRead(lr, e, fparent, fname, frange, fstatic, fvalue, fghost), tp, v) ->
              if expr_is_fixed inputParameters e || fstatic then
                let (_, (_, _, _, _, qsymb, _)) = List.assoc (fparent, fname) field_pred_map in
                [(psymb, pindices, qsymb, [(l, (psymb, true), false, predinst_tparams, fns, xs, inputFormals, wbody0, coef, None, [], [], (if fstatic then [] else [e]), conds)])]
              else
                []
            | WPredAsn(_, q, true, qtargs, qfns, qpats) ->
              begin match try_assoc q#name xs with
                Some _ -> []
              | None ->
                begin match try_assoc q#name predfammap with
                  None -> [] (* can this happen? *)
                | Some (_, qtparams, _, qtps, qsymb, _) ->
                  begin match q#inputParamCount with
                    None -> [] (* predicate is not precise, can this happen in a precise predicate? *)
                  | Some qInputParamCount ->
                    let qIndices = List.map (fun (LitPat e) -> e) qfns in
                    let qInputActuals = List.map (fun (LitPat e) -> e) (take qInputParamCount qpats) in
                    if List.for_all (fun e -> expr_is_fixed inputParameters e) (qIndices @ qInputActuals) then
                      [(psymb, pindices, qsymb, [(l, (psymb, true), false, predinst_tparams, fns, xs, inputFormals, wbody0, coef, None, qtargs, qIndices, qInputActuals, conds)])]
                    else
                      []
                  end
                end
              end
            | WInstPredAsn(l2, target_opt, static_type_name, static_type_finality, family_type_string, instance_pred_name, index, args) ->
              let (pmap, qsymb) =
                match try_assoc static_type_name classmap1 with
                  Some (lcn, abstract, fin, methods, fds_opt, ctors, super, interfs, preds, pn, ilist) ->
                  let (_, pmap, _, symb, _) = List.assoc instance_pred_name preds in (pmap, symb)
                | None ->
                  match try_assoc static_type_name classmap0 with
                    Some {cpreds} ->
                    let (_, pmap, _, symb, _) = List.assoc instance_pred_name cpreds in (pmap, symb)
                  | None ->
                    match try_assoc static_type_name interfmap1 with
                      Some (li, fields, methods, preds, interfs, pn, ilist) -> let (_, pmap, family, symb) = List.assoc instance_pred_name preds in (pmap, symb)
                    | None ->
                      let InterfaceInfo (li, fields, methods, preds, interfs) = List.assoc static_type_name interfmap0 in
                      let (_, pmap, family, symb) = List.assoc instance_pred_name preds in
                      (pmap, symb)
              in
              if match target_opt with Some e -> expr_is_fixed inputParameters e | None -> true then begin
                let target = match target_opt with Some e -> Some e | None -> Some (Var(l2, "this", ref (Some LocalVar))) in
                [(psymb, pindices, qsymb, [(l, (psymb, true), false, predinst_tparams, fns, xs, inputFormals, wbody0, coef, target, [], [index], [], conds)])]
              end else
                []
            | CoefAsn(_, DummyPat, asn) ->
              iter (Some DummyPat) conds asn
            | CoefAsn(_, LitPat(frac), asn) when expr_is_fixed inputParameters frac -> (* extend to arbitrary fractions? *)
              let new_coef = 
                match coef with
                  None -> Some (LitPat frac)
                | Some DummyPat -> Some DummyPat
                | Some (LitPat coef) -> Some (LitPat (Operation(dummy_loc, Mul, [frac;coef], ref (Some [RealType; RealType]))))
              in
              iter new_coef conds asn
            | Sep(_, asn1, asn2) ->
              (iter coef conds asn1) @ (iter coef conds asn2)
            | IfAsn(_, cond, asn1, asn2) ->
              if expr_is_fixed inputParameters cond then
                (iter coef (cond :: conds) asn1) @ (iter coef (Operation(dummy_loc, Not, [cond], ref None) :: conds) asn2)
              else
                (iter coef conds asn1) @ (iter coef conds asn2) (* replace this with []? *)
            | _ -> []
          in
          iter None [] wbody0
      )
      predinstmap
   
  let instance_predicate_contains_edges = 
    classmap1 |> flatmap 
      (fun (cn, (l, abstract, fin, meths, fds, cmap, super, interfs, preds, pn, ilist)) ->
        preds |> flatmap
          (fun (g, (l, pmap, family, psymb, wbody_opt)) ->
            match wbody_opt with None -> [] | Some wbody0 ->
            let pindices = [(List.assoc cn classterms)] in
            let instpred_tparams = [] in
            let fns = [cn] in
            let xs = pmap in
            let inputParameters = ["this"] in
            let inputFormals = [] in
            let rec iter coef conds wbody =
              match wbody with
                WPointsTo(_, WRead(lr, e, fparent, fname, frange, fstatic, fvalue, fghost), tp, v) ->
                if expr_is_fixed inputParameters e || fstatic then
                  let (_, (_, _, _, _, qsymb, _)) = List.assoc (fparent, fname) field_pred_map in
                  [(psymb, pindices, qsymb, [(l, (psymb, true), true, instpred_tparams, fns, xs, inputFormals, wbody0, coef, None, [], [], (if fstatic then [] else [e]), conds)])]
                else
                  []
              | WPredAsn(_, q, true, qtargs, qfns, qpats) ->
                begin match try_assoc q#name xs with
                  Some _ -> []
                | None ->
                  begin match try_assoc q#name predfammap with
                    None -> [] (* can this happen? *)
                  | Some (_, qtparams, _, qtps, qsymb, _) ->
                    begin match q#inputParamCount with
                      None -> [] (* predicate is not precise, can this happen in a precise predicate? *)
                    | Some qInputParamCount ->
                      let qIndices = List.map (fun (LitPat e) -> e) qfns in
                      let qInputActuals = List.map (fun (LitPat e) -> e) (take qInputParamCount qpats) in
                      if List.for_all (fun e -> expr_is_fixed inputParameters e) (qIndices @ qInputActuals) then
                        [(psymb, pindices, qsymb, [(l, (psymb, true), true, instpred_tparams, fns, xs, inputFormals, wbody0, coef, None, qtargs, qIndices, qInputActuals, conds)])]
                      else
                        []
                    end
                  end
                end
              | WInstPredAsn(l2, target_opt, static_type_name, static_type_finality, family_type_string, instance_pred_name, index, args) ->
                let (pmap, qsymb) =
                  match try_assoc static_type_name classmap1 with
                    Some (lcn, abstract, fin, methods, fds_opt, ctors, super, interfs, preds, pn, ilist) ->
                    let (_, pmap, _, symb, _) = List.assoc instance_pred_name preds in (pmap, symb)
                  | None ->
                    match try_assoc static_type_name classmap0 with
                      Some {cpreds} ->
                      let (_, pmap, _, symb, _) = List.assoc instance_pred_name cpreds in (pmap, symb)
                    | None ->
                      match try_assoc static_type_name interfmap1 with
                        Some (li, fields, methods, preds, interfs, pn, ilist) -> let (_, pmap, family, symb) = List.assoc instance_pred_name preds in (pmap, symb)
                      | None ->
                        let InterfaceInfo (li, fields, methods, preds, interfs) = List.assoc static_type_name interfmap0 in
                        let (_, pmap, family, symb) = List.assoc instance_pred_name preds in
                        (pmap, symb)
                in
                if match target_opt with Some e -> expr_is_fixed inputParameters e | None -> true then begin
                  let target = match target_opt with Some e -> Some e | None -> Some (Var(l2, "this", ref (Some LocalVar))) in
                  [(psymb, pindices, qsymb, [(l, (psymb, true), true, instpred_tparams, fns, xs, inputFormals, wbody0, coef, target, [], [index], [], conds)])]
                end else
                  []
              | CoefAsn(_, DummyPat, asn) ->
                iter (Some DummyPat) conds asn
              | CoefAsn(_, LitPat(frac), asn) when expr_is_fixed inputParameters frac -> (* extend to arbitrary fractions? *)
                let new_coef = 
                  match coef with
                    None -> Some (LitPat frac)
                  | Some DummyPat -> Some DummyPat
                  | Some (LitPat coef) -> Some (LitPat (Operation(dummy_loc, Mul, [frac;coef], ref (Some [RealType; RealType]))))
                in
                iter new_coef conds asn
              | Sep(_, asn1, asn2) ->
                (iter coef conds asn1) @ (iter coef conds asn2)
              | IfAsn(_, cond, asn1, asn2) ->
                if expr_is_fixed inputParameters cond then
                  (iter coef (cond :: conds) asn1) @ (iter coef (Operation(dummy_loc, Not, [cond], ref None) :: conds) asn2)
                else
                  (iter coef conds asn1) @ (iter coef conds asn2) (* replace this with []? *)
              | _ -> []
            in
            iter None [] wbody0
          )
      )
  
  let contains_edges = pred_fam_contains_edges @ instance_predicate_contains_edges
  
  let close1_ edges =
    flatmap
    (fun (from_symb, from_indices, to_symb, path) ->
      flatmap 
        (fun (from_symb0, from_indices0, to_symb0, (((outer_l0, outer_symb0, outer_is_inst_pred0, outer_formal_targs0, outer_actual_indices0, outer_formal_args0, outer_formal_input_args0, outer_wbody0, inner_frac_expr_opt0, inner_target_opt0, inner_formal_targs0, inner_formal_indices0, inner_input_exprs0, conds0) :: rest) as path0)) ->
          if to_symb == from_symb0 then
            let rec add_extra_conditions path = 
              match path with
                [(outer_l, outer_symb, outer_is_inst_pred, outer_formal_targs, outer_actual_indices, outer_formal_args, outer_formal_input_args, outer_wbody, inner_frac_expr_opt, inner_target_opt, inner_formal_targs, inner_formal_indices, inner_input_exprs, conds)] ->
                let extra_conditions: expr list = List.map2 (fun cn e2 -> 
                    if language = Java then 
                      Operation(dummy_loc, Eq, [ClassLit(dummy_loc, cn); e2], ref (Some [ObjType "java.lang.Class"; ObjType "java.lang.Class"]))
                    else 
                      Operation(dummy_loc, Eq, [Var(dummy_loc, cn, ref (Some FuncName)); e2], ref (Some [PtrType Void; PtrType Void]))
                ) outer_actual_indices0 inner_formal_indices in
                (* these extra conditions ensure that the actual indices match the expected ones *)
                [(outer_l, outer_symb, outer_is_inst_pred, outer_formal_targs, outer_actual_indices, outer_formal_args, outer_formal_input_args, outer_wbody, inner_frac_expr_opt, inner_target_opt, inner_formal_targs, inner_formal_indices, inner_input_exprs, extra_conditions @ conds)]
                 
              | head :: rest -> head :: (add_extra_conditions rest)
            in
            let new_path = add_extra_conditions path in
            let new_edge = (from_symb, from_indices, to_symb0, new_path @ path0) in
            if List.exists (fun (from_symb1, from_indices1, to_symb1, _) -> 
                 from_symb1 == from_symb && 
                 (for_all2 (fun t1 t2 -> t1 == t2) from_indices from_indices1) && 
                 to_symb1 == to_symb0) edges then
              []
              (* todo: improve by taking path into account *)
              (* todo: avoid cycles in the path? *)
              (* todo: avoid duplicate entries? *)
            else 
              [new_edge]
          else
            []
        )
        edges
    )
    edges
  
  let transitive_contains_edges_ = 
    let rec close edges =
      let new_edges = close1_ edges in
      if new_edges = [] then
        edges
      else
        close (new_edges @ edges)
    in
    close contains_edges
  
  (*let _ =
    print_endline "transitive_edges:";
    List.iter
      (fun (from_symb, from_indices, to_symb, path) ->
        print_endline ((ctxt#pprint from_symb) ^ " -> " ^ (ctxt#pprint to_symb));
      )
    contains_edges
  in*)
  
  let rules_cell = ref [] (* A hack to allow the rules to recursively use the rules *)
  
  let rules =
    let rulemap = ref [] in
    let add_rule predSymb rule =
      match try_assq predSymb !rulemap with
        None ->
        rulemap := (predSymb, ref [rule])::!rulemap
      | Some rules ->
        rules := rule::!rules
    in
    (* transitive auto-close rules for precise predicates and predicate families *)
    List.iter
      (fun (from_symb, indices, to_symb, path) ->
        let transitive_auto_close_rule h wanted_targs terms_are_well_typed wanted_indices_and_input_ts cont =
          let rec can_apply_rule current_this_opt current_targs current_indices current_input_args path =
            match path with
              [] -> 
                begin match try_find
                  (fun (Chunk (found_symb, found_targs, found_coef, found_ts, _)) ->
                    predname_eq found_symb (to_symb, true) &&
                    (let expected_ts = (match current_this_opt with None -> [] | Some t -> [t]) @ current_indices @ current_input_args in
                    (for_all2 definitely_equal (take (List.length (expected_ts)) found_ts) expected_ts))
                  )
                  h
                with
                  None -> begin (* check whether the wanted predicate is an empty predicate? *)
                    if List.exists 
                         (fun (symb, fsymbs, conds, ((p, fns), (env, l, predinst_tparams, xs, _, inputParamCount, wbody))) ->
                           to_symb == symb &&
                           (for_all2 definitely_equal fsymbs current_indices) &&
                           (
                             let Some inputParamCount = inputParamCount in
                             let Some tpenv = zip predinst_tparams current_targs in
                             let env = List.map2 (fun (x, tp0) actual -> let tp = instantiate_type tpenv tp0 in (x, prover_convert_term actual tp tp0)) (take inputParamCount xs) current_input_args in 
                             let env = match current_this_opt with None -> env | Some t -> ("this", t) :: env in
                             List.exists (fun conds -> (List.for_all (fun cond -> ctxt#query (eval None env cond)) conds)) conds
                           )
                         )
                        empty_preds 
                    then
                      Some (fun h cont -> cont h real_unit)
                    else
                      None
                  end
                | Some (Chunk (found_symb, found_targs, found_coef, found_ts, _)) -> Some (fun h cont -> cont h found_coef)
                end
            | (outer_l, outer_symb, outer_is_inst_pred, outer_formal_targs, outer_actual_indices, outer_formal_args, outer_formal_input_args, outer_wbody, inner_frac_expr_opt, inner_target_opt, inner_formal_targs, inner_formal_indices, inner_input_exprs, conds) :: path ->
              let Some tpenv = zip outer_formal_targs current_targs in
              let env = List.map2 (fun (x, tp0) actual -> let tp = instantiate_type tpenv tp0 in (x, prover_convert_term actual tp tp0)) outer_formal_input_args current_input_args in
              let env = match current_this_opt with
                None -> env
              | Some t ->  ("this", t) :: env
              in
              if (List.for_all (fun cond -> ctxt#query (eval None env cond)) conds) then
                let env = List.map2 (fun (x, tp0) actual -> (x, actual)) outer_formal_input_args current_input_args in
                let env = match current_this_opt with
                  None -> env
                | Some t -> ("this", t) :: env
                in
                let new_this_opt = match inner_target_opt with
                  None -> None
                | Some thisExpr -> Some (eval None env thisExpr)
                in 
                let new_actual_targs = List.map (fun tp0 -> (instantiate_type tpenv tp0)) inner_formal_targs in
                let new_actual_indices = List.map (fun index -> (eval None env index)) inner_formal_indices in
                let new_actual_input_args = List.map (fun input_e -> (eval None env input_e)) inner_input_exprs in
                match can_apply_rule new_this_opt new_actual_targs new_actual_indices new_actual_input_args path with
                  None -> None
                | Some exec_rule -> Some (fun h cont ->
                    exec_rule h (fun h coef ->
                      let rules = ! rules_cell in
                      let ghostenv = [] in
                      let checkDummyFracs = true in
                      let env = List.map2 (fun (x, tp0) actual -> let tp = instantiate_type tpenv tp0 in (x, prover_convert_term actual tp tp0)) outer_formal_input_args current_input_args in
                      let env = match current_this_opt with
                        None -> env
                      | Some t -> ("this", t) :: env
                      in
                      with_context (Executing (h, env, outer_l, "Auto-closing predicate")) $. fun () ->
                        let new_coef = 
                          match inner_frac_expr_opt with
                            None -> coef
                          | Some DummyPat -> real_unit
                          | Some (LitPat (RealLit(_, n))) -> ctxt#mk_real_mul coef (ctxt#mk_reallit_of_num ((num_of_big_int unit_big_int) // n))
                          | Some _ -> coef (* todo *)
                        in
                        consume_asn rules tpenv h ghostenv env outer_wbody checkDummyFracs new_coef $. fun _ h ghostenv env2 size_first ->
                          let outputParams = drop (List.length outer_formal_input_args) outer_formal_args in
                          let outputArgs = List.map (fun (x, tp0) -> let tp = instantiate_type tpenv tp0 in (prover_convert_term (List.assoc x env2) tp0 tp)) outputParams in
                          with_context (Executing (h, [], outer_l, "Producing auto-closed chunk")) $. fun () ->
                            let input_param_count = match current_this_opt with Some _ -> Some 2 | None -> Some((List.length current_indices) + (List.length current_input_args)) in
                            produce_chunk h outer_symb current_targs new_coef input_param_count ((match current_this_opt with None -> [] | Some t -> [t]) @ current_indices @ current_input_args @ outputArgs) None (fun h -> 
                            cont h new_coef) (* todo: properly set the size *)
                    )
                  )
              else 
                None (* conditions do not hold, so give up *)
          in
          let wanted_indices = match List.hd path with
            (_, _, true, _, _, _, _, _, _, _, _, _, _, _) -> 
             (take (List.length indices) (List.tl wanted_indices_and_input_ts))
          | (_, _, false, _, _, _, _, _, _, _, _, _, _, _) -> 
             (take (List.length indices) wanted_indices_and_input_ts)
          in
          if terms_are_well_typed &&
             (for_all2 definitely_equal indices wanted_indices) (* check that you are actually looking for from_symb at indices *) then
            let (wanted_target_opt, wanted_indices, wanted_inputs) = 
              match List.hd path with
                  (_, _, true, _, _, _, _, _, _, _, _, _, _, _) -> 
                  (Some (List.hd wanted_indices_and_input_ts), (take (List.length indices) (List.tl wanted_indices_and_input_ts)),
                  (drop (List.length indices) (List.tl wanted_indices_and_input_ts)))
                | (_, _, false, _, _, _, _, _, _, _, _, _, _, _) -> 
                  (None, (take (List.length indices) wanted_indices_and_input_ts), (drop (List.length indices) wanted_indices_and_input_ts))
            in
            match can_apply_rule wanted_target_opt wanted_targs wanted_indices wanted_inputs path with
              None -> cont None
            | Some exec_rule -> exec_rule h (fun h _ -> cont (Some h))
          else
            cont None
        in
        add_rule from_symb transitive_auto_close_rule
      )
      transitive_contains_edges_;
    (* transitive auto-open rules for precise predicates and predicate families *)
    List.iter 
      (fun (from_symb, indices, to_symb, path) ->
        let transitive_auto_open_rule h wanted_targs terms_are_well_typed wanted_indices_and_input_ts cont =
          let rec try_apply_rule_core actual_this_opt actual_targs actual_indices actual_input_args path = 
            match path with
            | [] ->
              if for_all2 definitely_equal wanted_indices_and_input_ts ((match actual_this_opt with None -> [] | Some t -> [t]) @ actual_indices @ actual_input_args) then
                Some (fun h_opt cont -> begin match h_opt with None -> cont None | Some(h) -> cont (Some h) end)
              else
                None
            | (outer_l, outer_symb, outer_is_inst_pred, outer_formal_targs, outer_actual_indices, outer_formal_args, outer_formal_input_args, outer_wbody, inner_frac_expr_opt, inner_target_opt, inner_formal_targs, inner_formal_indices, inner_input_exprs, conds) :: path ->
              
              let actual_input_args = (take (List.length outer_formal_input_args) actual_input_args) in (* to fix first call *)
              let Some tpenv = zip outer_formal_targs actual_targs in
              let env = List.map2 (fun (x, tp0) actual -> let tp = instantiate_type tpenv tp0 in (x, prover_convert_term actual tp tp0)) outer_formal_input_args actual_input_args in
              let env = match actual_this_opt with
                  None -> env
                | Some t -> ("this", t) :: env
              in
              if (List.for_all (fun cond -> ctxt#query (eval None env cond)) conds) then
                let env = List.map2 (fun (x, tp0) actual -> (x, actual)) outer_formal_input_args actual_input_args in
                let env = match actual_this_opt with
                  None -> env
                | Some t -> ("this", t) :: env
                in
                let new_this_opt = match inner_target_opt with
                  None -> None
                | Some thisExpr -> Some (eval None env thisExpr)
                in
                let new_actual_targs = List.map (fun tp0 -> (instantiate_type tpenv tp0)) inner_formal_targs in
                let new_actual_indices = List.map (fun index -> (eval None env index)) inner_formal_indices in
                let new_actual_input_args = List.map (fun input_e -> (eval None env input_e)) inner_input_exprs in
                match try_apply_rule_core new_this_opt new_actual_targs new_actual_indices new_actual_input_args path with
                  None -> None
                | Some(exec_rule) ->
                  Some (fun h_opt cont ->
                    begin match h_opt with
                      None -> cont None
                    | Some h ->
                      (* consume from_symb *)
                      let result_opt =
                        let rec iter hdone htodo =
                          match htodo with
                            [] -> None (* todo: can happen if predicate is only present under conditions that contain non-input variables *)
                          | (Chunk (found_symb, found_targs, found_coef, found_ts, _) as chunk)::htodo ->
                            if (predname_eq outer_symb found_symb) && 
                               (let actuals = ((match actual_this_opt with None -> [] | Some t -> [t]) @ actual_indices @ actual_input_args) in
                               (for_all2 definitely_equal (take (List.length actuals) found_ts)) actuals) then
                               Some ((hdone @ htodo, found_targs, found_coef, found_ts))
                            else
                              iter (chunk::hdone) htodo
                        in
                        iter [] h
                      in
                      begin match result_opt with
                        None -> cont None
                      | Some ((h, found_targs, found_coef, found_ts)) -> 
                        (* produce from_symb body *)
                        let full_env = List.map2 (fun (x, tp0) t -> let tp = instantiate_type tpenv tp0 in (x, prover_convert_term t tp tp0)) outer_formal_args (drop ((List.length actual_indices) + (match actual_this_opt with None -> 0 | Some _ -> 1)) found_ts) in 
                        let full_env = match actual_this_opt with None -> full_env | Some t -> ("this", t) :: full_env in
                        let ghostenv = [] in
                        with_context (Executing (h, full_env, outer_l, "Auto-opening predicate")) $. fun () ->
                          produce_asn tpenv h ghostenv full_env outer_wbody found_coef None None $. fun h ghostenv env ->
                            (* perform remaining opens *)
                            exec_rule (Some h) cont
                      end
                    end
                  )
              else
                None
          in
          let try_apply_rule hdone htodo =
            let rec try_apply_rule0 hdone htodo = 
              match htodo with
                [] -> None
              | ((Chunk (actual_name, actual_targs, actual_coef, actual_ts, _)) as chnk) :: rest 
                  when (predname_eq actual_name (from_symb, true)) && (
                       let indices0 = match List.hd path with
                         (_, _, true, _, _, _, _, _, _, _, _, _, _, _) ->  (take (List.length indices) (List.tl actual_ts))
                       | (_, _, false, _, _, _, _, _, _, _, _, _, _, _) -> (take (List.length indices) actual_ts)
                       in
                        (for_all2 definitely_equal indices0 indices)
                       ) ->
                let (actual_target_opt, actual_indices, actual_inputs) = 
                  match List.hd path with
                    (_, _, true, _, _, _, _, _, _, _, _, _, _, _) ->  (Some (List.hd actual_ts), indices, (drop (List.length indices) (List.tl actual_ts)))
                  | (_, _, false, _, _, _, _, _, _, _, _, _, _, _) -> (None, indices, (drop (List.length indices) actual_ts))
                in
                begin match try_apply_rule_core actual_target_opt actual_targs actual_indices actual_inputs path with
                  None -> try_apply_rule0 (chnk :: hdone) rest
                | Some exec_rule -> Some exec_rule
                end
              | chnk :: rest -> try_apply_rule0 (chnk :: hdone) rest
            in
            try_apply_rule0 hdone htodo
          in
          if terms_are_well_typed then
            match try_apply_rule [] h with
              None -> cont None
            | Some exec_rule -> exec_rule (Some h) cont
          else
            cont None
         in
         add_rule to_symb transitive_auto_open_rule;
      )
      transitive_contains_edges_;
    (* rules for closing empty chunks *)
    List.iter
      begin fun (symb, fsymbs, conds, ((p, fns), (env, l, predinst_tparams, xs, _, inputParamCount, wbody))) ->
        let g = (symb, true) in
        let indexCount = List.length fns in
        let Some n = inputParamCount in
        let (inputParams, outputParams) = take_drop n xs in
        let autoclose_rule =
          let match_func h targs ts =
            let (indices, inputArgs) = take_drop indexCount ts in
            List.for_all2 definitely_equal indices fsymbs &&
            let Some tpenv = zip predinst_tparams targs in
            let env = List.map2 (fun (x, tp0) t -> let tp = instantiate_type tpenv tp0 in (x, prover_convert_term t tp tp0)) inputParams inputArgs in
            List.exists (fun conds -> List.for_all (fun cond -> ctxt#query (eval None env cond)) conds) conds
          in
          let exec_func h targs ts cont =
            let rules = !rules_cell in
            let (indices, inputArgs) = take_drop indexCount ts in
            let Some tpenv = zip predinst_tparams targs in
            let env = List.map2 (fun (x, tp0) t -> let tp = instantiate_type tpenv tp0 in (x, prover_convert_term t tp tp0)) inputParams inputArgs in
            let ghostenv = [] in
            let checkDummyFracs = true in
            let coef = real_unit in
            with_context (Executing (h, env, l, "Auto-closing predicate")) $. fun () ->
            consume_asn rules tpenv h ghostenv env wbody checkDummyFracs coef $. fun _ h ghostenv env size_first ->
            let outputArgs = List.map (fun (x, tp0) -> let tp = instantiate_type tpenv tp0 in (prover_convert_term (List.assoc x env) tp0 tp)) outputParams in
            with_context (Executing (h, [], l, "Producing auto-closed chunk")) $. fun () ->
            cont (Chunk (g, targs, coef, inputArgs @ outputArgs, None)::h)
          in
          let rule h targs terms_are_well_typed ts cont =
            if terms_are_well_typed && match_func h targs ts then exec_func h targs ts (fun h -> cont (Some h)) else cont None
          in
          rule
        in
        add_rule symb autoclose_rule
      end
      empty_preds;
    (* rules for array slices *)
    begin if language = Java then
      let array_element_symb = array_element_symb () in
      let array_slice_symb = array_slice_symb () in
      let array_slice_deep_symb = array_slice_deep_symb () in
      let get_element_rule h [elem_tp] terms_are_well_typed [arr; index] cont =
        match extract
          begin function
            (Chunk ((g, is_symb), elem_tp'::targs_rest, coef, arr'::istart'::iend'::args_rest, _)) when
              (g == array_slice_symb || g == array_slice_deep_symb) &&
              definitely_equal arr' arr && ctxt#query (ctxt#mk_and (ctxt#mk_le istart' index) (ctxt#mk_lt index iend')) &&
              unify elem_tp elem_tp' ->
            Some (g, targs_rest, coef, istart', iend', args_rest)
          | _ -> None
          end
          h
        with
          None -> cont None
        | Some ((g, targs_rest, coef, istart', iend', args_rest), h) ->
          if g == array_slice_symb then
            let [elems] = args_rest in
            let split_after elems h =
              let elem = get_unique_var_symb_non_ghost "elem" elem_tp in
              let elems_tail = get_unique_var_symb "elems" (InductiveType ("list", [elem_tp])) in
              assume (ctxt#mk_eq elems (mk_cons elem_tp elem elems_tail)) $. fun () ->
              let chunk1 = Chunk ((array_element_symb, true), [elem_tp], coef, [arr; index; elem], None) in
              let chunk2 = Chunk ((array_slice_symb, true), [elem_tp], coef, [arr; ctxt#mk_add index (ctxt#mk_intlit 1); iend'; elems_tail], None) in
              cont (Some (chunk1::chunk2::h))
            in
            if ctxt#query (ctxt#mk_eq istart' index) then
              split_after elems h
            else
              let elems1 = mk_take (ctxt#mk_sub index istart') elems in
              let elems2 = mk_drop (ctxt#mk_sub index istart') elems in
              assume (ctxt#mk_eq elems (mk_append elems1 elems2)) $. fun () ->
              let chunk0 = Chunk ((array_slice_symb, true), [elem_tp], coef, [arr; istart'; index; elems1], None) in
              split_after elems2 (chunk0::h)
          else
            let [ta; tv] = targs_rest in
            let [p; a; elems; vs] = args_rest in
            let n1 = ctxt#mk_sub index istart' in
            let elems1 = mk_take n1 elems in
            let vs1 = mk_take n1 vs in
            let elems2 = mk_drop n1 elems in
            let vs2 = mk_drop n1 vs in
            let elem = get_unique_var_symb "elem" elem_tp in
            let tail_elems2 = get_unique_var_symb "elems" (InductiveType ("list", [elem_tp])) in
            let v = get_unique_var_symb "value" tv in
            let tail_vs2 = get_unique_var_symb "values" (InductiveType ("list", [tv])) in
            assume (ctxt#mk_eq elems2 (mk_cons elem_tp elem tail_elems2)) $. fun () ->
            assume (ctxt#mk_eq vs2 (mk_cons tv v tail_vs2)) $. fun () ->
            let before_chunks = 
              if definitely_equal istart' index then
                []
              else
                [Chunk ((array_slice_deep_symb, true), [elem_tp; ta; tv], coef, [arr; istart'; index; p; a; elems1; vs1], None)]
            in
            let after_chunks = 
              if definitely_equal (ctxt#mk_add index (ctxt#mk_intlit 1)) iend' then
                []
              else
                [Chunk ((array_slice_deep_symb, true), [elem_tp; ta; tv], coef, [arr; ctxt#mk_add index (ctxt#mk_intlit 1); iend'; p; a; tail_elems2; tail_vs2], None)]
            in
            let element_chunk = Chunk ((array_element_symb, true), [elem_tp], coef, [arr; index; elem], None) in
            let h = element_chunk :: before_chunks @ after_chunks @ h in
            match try_assq p predinstmap_by_predfamsymb with
              None -> cont (Some (Chunk ((p, false), [], coef, [a; elem; v], None)::h))
            | Some (xs, wbody) ->
              let tpenv = [] in
              let ghostenv = [] in
              let Some env = zip (List.map fst xs) [a; elem; v] in
              produce_asn tpenv h ghostenv env wbody coef None None $. fun h _ _ ->
              cont (Some h)
      in
      let get_slice_rule h [elem_tp] terms_are_well_typed [arr; istart; iend] cont =
        let extract_slice h cond cont' =
          match extract
            begin function
              Chunk ((g', is_symb), [elem_tp'], coef', [arr'; istart'; iend'; elems'], _) when
                g' == array_slice_symb && unify elem_tp elem_tp' &&
                definitely_equal arr' arr && cond coef' istart' (Some iend') ->
              Some (Some (coef', istart', iend', elems'), None)
            | Chunk ((g', is_symb), [elem_tp'], coef', [arr'; index; elem], _) when
                g' == array_element_symb && unify elem_tp elem_tp' && definitely_equal arr' arr && cond coef' index None ->
              Some (None, Some (coef', index, elem))
            | _ -> None
            end
            h
          with
            None -> cont None
          | Some ((Some slice, None), h) -> cont' (slice, h)
          | Some ((None, Some (coef', index, elem)), h) ->
            (* Close a unit array_slice chunk *)
            cont' ((coef', index, ctxt#mk_add index (ctxt#mk_intlit 1), mk_list elem_tp [elem]), h)
        in
        if definitely_equal istart iend then (* create empty array by default *)
          cont (Some (Chunk ((array_slice_symb, true), [elem_tp], real_unit, [arr; istart; iend; mk_nil()], None)::h))
        else
          extract_slice h
            begin fun coef' istart' iend' ->
              match iend' with
                None -> definitely_equal istart istart'
              | Some iend' -> ctxt#query (ctxt#mk_and (ctxt#mk_le istart' istart) (ctxt#mk_le istart iend'))
            end $.
          fun ((coef, istart0, iend0, elems0), h) ->
          let mk_chunk istart iend elems remove_if_empty =
            if remove_if_empty && (definitely_equal istart iend) then
              []
            else
              [Chunk ((array_slice_symb, true), [elem_tp], coef, [arr; istart; iend; elems], None)]
          in
          let before_length = ctxt#mk_sub istart istart0 in
          let elems0_before = mk_take before_length elems0 in
          let elems0_notbefore = mk_drop before_length elems0 in
          assume (ctxt#mk_eq elems0 (mk_append elems0_before elems0_notbefore)) $. fun () ->
          let chunks_before = mk_chunk istart0 istart elems0_before true in
          let slices = [(istart, iend0, elems0_notbefore)] in
          let rec find_slices slices curr_end h cont' =
            if ctxt#query (ctxt#mk_le iend curr_end) then
              (* found a list of chunks all the way to the end *)
              cont' (slices, h)
            else
              (* need to consume more chunks *)
            extract_slice h (fun coef'' istart'' end'' -> definitely_equal coef coef'' && definitely_equal istart'' curr_end) $.
            fun ((_, istart'', iend'', elems''), h) ->
            find_slices ((istart'', iend'', elems'')::slices) iend'' h cont'
          in
          find_slices slices iend0 h $. fun ((istart_last, iend_last, elems_last)::slices, h) ->
          let length_last = ctxt#mk_sub iend istart_last in
          let elems_last_notafter = mk_take length_last elems_last in
          let elems_last_after = mk_drop length_last elems_last in
          assume (ctxt#mk_eq elems_last (mk_append elems_last_notafter elems_last_after)) $. fun () ->
          let slices = List.rev ((istart_last, iend, elems_last_notafter)::slices) in
          let rec mk_concat lists =
            match lists with
              [] -> mk_nil()
            | [l] -> l
            | l::ls -> mk_append l (mk_concat ls)
          in
          let target_elems = mk_concat (List.map (fun (istart, iend, elems) -> elems) slices) in
          let target_chunk = mk_chunk istart iend target_elems false in
          let chunks_after = mk_chunk iend iend_last elems_last_after true in
          cont (Some (target_chunk @ chunks_before @ chunks_after @ h))
      in
      let get_slice_deep_rule h [elem_tp; a_tp; v_tp] terms_are_well_typed [arr; istart; iend; p; info] cont = 
        let extract_slice_deep h cond cont' =
          match extract
            begin function
              Chunk ((g', is_symb), [elem_tp'; a_tp'; v_tp'], coef', [arr'; istart'; iend'; p'; info'; elems'; vs'], _) when
                g' == array_slice_deep_symb && unify elem_tp elem_tp' && unify a_tp a_tp' && unify v_tp v_tp' &&
                definitely_equal arr' arr && definitely_equal p p' && definitely_equal info info' && cond coef' istart' (Some iend') ->
              Some (Some (coef', istart', iend', elems', vs'), None)
            | Chunk ((g', is_symb), [elem_tp'], coef', [arr'; index; elem], _) when
                g' == array_element_symb && unify elem_tp elem_tp' && definitely_equal arr' arr && cond coef' index None ->
              Some (None, Some (coef', index, elem))
            | _ -> None
            end
            h
          with
            None -> cont None
          | Some ((Some slice, None), h) -> cont' (slice, h)
          | Some ((None, Some (coef', index, elem)), h) ->
            (* Close a unit array_slice_deep chunk *)
            (* First check if there is a p(info, elem, ?value) chunk *)
            begin fun cont'' ->
              match
                extract
                  begin function
                    Chunk ((g, is_symb), [], coef'', [arg''; elem''; value''], _) when
                      g == p && definitely_equal coef'' coef' && definitely_equal arg'' info && definitely_equal elem'' elem ->
                      Some value''
                  | _ -> None
                  end
                  h
              with
                Some (v, h) -> cont'' v h
              | None ->
                (* Try to close p(info, elem, ?value) *)
                match try_assq p predinstmap_by_predfamsymb with
                  None -> cont None
                | Some (xs, wbody) ->
                  let tpenv = [] in
                  let ghostenv = [] in
                  let [xinfo, _; xelem, _; xvalue, _] = xs in
                  let env = [xinfo, info; xelem, elem] in
                  let rules = !rules_cell in
                  with_context (Executing (h, env, asn_loc wbody, "Auto-closing array slice")) $. fun () ->
                  consume_asn rules tpenv h ghostenv env wbody true coef' $. fun _ h ghostenv env size_first ->
                  match try_assoc xvalue env with
                    None -> cont None
                  | Some v -> cont'' v h
            end $. fun v h ->
            cont' ((coef', index, ctxt#mk_add index (ctxt#mk_intlit 1), mk_list elem_tp [elem], mk_list v_tp [v]), h)
        in
        if definitely_equal istart iend then (* create empty array by default *)
          cont (Some (Chunk ((array_slice_deep_symb, true), [elem_tp; a_tp; v_tp], real_unit, [arr; istart; iend; p; info; mk_nil(); mk_nil()], None)::h))
        else
          extract_slice_deep h
            begin fun coef' istart' iend' ->
              match iend' with
                None -> definitely_equal istart istart'
              | Some iend' -> ctxt#query (ctxt#mk_and (ctxt#mk_le istart' istart) (ctxt#mk_le istart iend'))
            end $.
          fun ((coef, istart0, iend0, elems0, vs0), h) ->
          let mk_chunk istart iend elems vs =
            Chunk ((array_slice_deep_symb, true), [elem_tp; a_tp; v_tp], coef, [arr; istart; iend; p; info; elems; vs], None)
          in
          let before_length = ctxt#mk_sub istart istart0 in
          let chunk_before = mk_chunk istart0 istart (mk_take before_length elems0) (mk_take before_length vs0) in
          let slices = [(istart, iend0, mk_drop before_length elems0, mk_drop before_length vs0)] in
          let rec find_slices slices curr_end h cont' =
            if ctxt#query (ctxt#mk_le iend curr_end) then
              (* found a list of chunks all the way to the end *)
              cont' (slices, h)
            else
              (* need to consume more chunks *)
            extract_slice_deep h (fun coef'' istart'' end'' -> definitely_equal coef coef'' && definitely_equal istart'' curr_end) $.
            fun ((_, istart'', iend'', elems'', vs''), h) ->
            find_slices ((istart'', iend'', elems'', vs'')::slices) iend'' h cont'
          in
          find_slices slices iend0 h $. fun ((istart_last, iend_last, elems_last, vs_last)::slices, h) ->
          let length_last = ctxt#mk_sub iend istart_last in
          let slices = List.rev ((istart_last, iend, mk_take length_last elems_last, mk_take length_last vs_last)::slices) in
          let rec mk_concat lists =
            match lists with
              [] -> mk_nil()
            | [l] -> l
            | l::ls -> mk_append l (mk_concat ls)
          in
          let target_elems = mk_concat (List.map (fun (istart, iend, elems, vs) -> elems) slices) in
          let target_vs = mk_concat (List.map (fun (istart, iend, elems, vs) -> vs) slices) in
          let target_chunk = mk_chunk istart iend target_elems target_vs in
          let chunk_after = mk_chunk iend iend_last (mk_drop length_last elems_last) (mk_drop length_last vs_last) in
          cont (Some (target_chunk::chunk_before::chunk_after::h))
      in
      begin
      add_rule array_element_symb get_element_rule;
      add_rule array_slice_symb get_slice_rule;
      add_rule array_slice_deep_symb get_slice_deep_rule
      end
    end;
    List.map (fun (predSymb, rules) -> (predSymb, !rules)) !rulemap
  
  let () = rules_cell := rules
  
  end
  
end