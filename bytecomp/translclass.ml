(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*         Jerome Vouillon, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

open Asttypes
open Types
open Typedtree
open Lambda
open Translobj
open Translcore

(* XXX Rajouter des evenements... *)

type error = Illegal_class_expr | Tags of label * label

exception Error of Location.t * error

let lfunction params body =
  if params = [] then body else
  match body.lb_expr with
    Lfunction (Curried, params', body') ->
      { body with lb_expr = Lfunction (Curried, params @ params', body') }
  |  _ ->
      { body with lb_expr = Lfunction (Curried, params, body) }

let lapply func args loc =
  match func.lb_expr with
    Lapply(func', args', _) ->
      { func with lb_expr = Lapply(func', args' @ args, loc) }
  | _ ->
      { func with lb_expr = Lapply(func, args, loc) }

let mkappl (func, args) =
  mk_lambda ?ty:None ~from:"mkappl" ?env:None @@
  Lapply (func, args, Location.none);;

let lsequence l1 l2 =
  if l2.lb_expr = lambda_unit.lb_expr then l1 else { l2 with lb_expr = Lsequence(l1, l2) }

let lfield v i =
  mk_lambda ?ty:None ~from:"lfield" ?env:None @@
  Lprim(Pfield i, [mk_lambda ?ty:None ~from:"lfield" ?env:None @@ Lvar v])

let transl_label l = share (Const_immstring l)

let transl_meth_list lst =
  if lst = [] then mk_lambda ?ty:None ~from:"transl_meth_list" ?env:None
    @@ Lconst (Const_pointer 0)
  else
    share (Const_block
             (0, List.map (fun lab -> Const_immstring lab) lst))

let set_inst_var obj id expr =
  let kind = if Typeopt.maybe_pointer expr then Paddrarray else Pintarray in
  as_unit ~from:"set_inst_var" ~env:expr.exp_env @@
  Lprim(Parraysetu kind,
        [mk_lambda ?ty:None ~from:"set_inst_var" ~env:expr.exp_env @@ Lvar obj;
         mk_lambda ?ty:None ~from:"set_inst_var" ~env:expr.exp_env @@ Lvar id;
         transl_exp expr])

let copy_inst_var obj id expr templ offset =
  let kind = if Typeopt.maybe_pointer expr then Paddrarray else Pintarray in
  let id' = Ident.create (Ident.name id) in
  let mk_u l = mk_lambda ?ty:None ~from:"copy_inst_var" ~env:expr.exp_env l in
  mk_u @@
  Llet(Strict, id',
       mk_u @@ Lprim (Pidentity, [mk_u @@ Lvar id]),
       mk_u @@ Lprim(Parraysetu kind,
                     [mk_u @@ Lvar obj; mk_u @@ Lvar id';
                      mk_u @@
                      Lprim(Parrayrefu kind,
                    [mk_u @@ Lvar templ;
                     mk_u @@ Lprim(Paddint,
                                   [mk_u @@ Lvar id';
                                    mk_u @@ Lvar offset])])]))

let transl_val tbl create name =
  mkappl (oo_prim (if create then "new_variable" else "get_variable"),
          [mk_lambda ?ty:None ~from:"transl_val" ?env:None @@ Lvar tbl;
           transl_label name])

let transl_vals tbl create strict vals rem =
  List.fold_right
    (fun (name, id) rem ->
       as_arg ~from:"transl_vals" ?env:None rem @@
       Llet(strict, id, transl_val tbl create name, rem))
    vals rem

let meths_super tbl meths inh_meths =
  List.fold_right
    (fun (nm, id) rem ->
       try
         (nm, id,
          mkappl(oo_prim "get_method",
                 [mk_lambda ?ty:None
                    ~from:"meths_super" ?env:None @@ Lvar tbl;
                  mk_lambda ?ty:None
                    ~from:"meths_super" ?env:None @@
                  Lvar (Meths.find nm meths)]))
         :: rem
       with Not_found -> rem)
    inh_meths []

let bind_super tbl (vals, meths) cl_init =
  transl_vals tbl false StrictOpt vals
    (List.fold_right (fun (nm, id, def) rem ->
         as_arg ~from:"bind_super" ?env:None rem @@ Llet(StrictOpt, id, def, rem))
        meths cl_init)

let create_object ?ty cl obj init =
  let mk_u = mk_lambda ?ty:None ~from:"create_object" ?env:None in
  let mk = mk_lambda ?ty ~from:"create_object" ?env:None in
  let obj' = Ident.create "self" in
  let (inh_init, obj_init, has_init) = init obj' in
  if obj_init.lb_expr = lambda_unit.lb_expr then
    (inh_init,
     mkappl (oo_prim (if has_init then "create_object_and_run_initializers"
                      else"create_object_opt"),
             [obj; mk_u @@ Lvar cl]))
  else begin
   (inh_init,
    mk @@
    Llet(Strict, obj',
         mkappl (oo_prim "create_object_opt", [obj; mk_u @@ Lvar cl]),
         mk @@
         Lsequence(obj_init,
                   if not has_init then mk @@ Lvar obj' else
                   mkappl (oo_prim "run_initializers_opt",
                           [obj;
                            mk @@ Lvar obj';
                            mk_u @@ Lvar cl]))))
  end

let name_pattern default p =
  match p.pat_desc with
  | Tpat_var (id, _) -> id
  | Tpat_alias(p, id, _) -> id
  | _ -> Ident.create default

let normalize_cl_path cl path =
  Env.normalize_path (Some cl.cl_loc) cl.cl_env path

let rec build_object_init cl_table obj params inh_init obj_init cl =
  match cl.cl_desc with
    Tcl_ident ( path, _, _) ->
      let obj_init = Ident.create "obj_init" in
      let envs, inh_init = inh_init in
      let env =
        match envs with
          None -> []
        | Some envs ->
            [mk_lambda ?ty:None ~from:"build_object_init" ~env:cl.cl_env@@
             Lprim(Pfield (List.length inh_init + 1),
                   [mk_lambda ?ty:None ~from:"build_object_init"  ~env:cl.cl_env @@
                    Lvar envs])]
      in
      ((envs, (obj_init, normalize_cl_path cl path)
        ::inh_init),
       mkappl(mk_lambda ?ty:None ~from:"build_object_init"  ~env:cl.cl_env @@
              Lvar obj_init, env @ [obj]))
  | Tcl_structure str ->
      create_object cl_table obj (fun obj ->
        let (inh_init, obj_init, has_init) =
          List.fold_right
            (fun field (inh_init, obj_init, has_init) ->
               match field.cf_desc with
                 Tcf_inherit (_, cl, _, _, _) ->
                   let (inh_init, obj_init') =
                     build_object_init cl_table
                       (mk_lambda ?ty:None
                          ~from:"build_object_init" ~env:cl.cl_env @@ Lvar obj)
                       [] inh_init
                       (fun _ -> lambda_unit) cl
                   in
                   (inh_init, lsequence obj_init' obj_init, true)
               | Tcf_val (_, _, id, Tcfk_concrete (_, exp), _) ->
                   (inh_init, lsequence (set_inst_var obj id exp) obj_init,
                    has_init)
               | Tcf_method _ | Tcf_val _ | Tcf_constraint _ | Tcf_attribute _->
                   (inh_init, obj_init, has_init)
               | Tcf_initializer _ ->
                   (inh_init, obj_init, true)
            )
            str.cstr_fields
            (inh_init, obj_init obj, false)
        in
        (inh_init,
         List.fold_right
           (fun (id, expr) rem ->
              lsequence (mk_lambda ?ty:None ~from:"build_object_init" ~env:cl.cl_env @@
                         Lifused (id, set_inst_var obj id expr)) rem)
           params obj_init,
         has_init))
  | Tcl_fun (_, pat, vals, cl, partial) ->
      let vals = List.map (fun (id, _, e) -> id,e) vals in
      let (inh_init, obj_init) =
        build_object_init cl_table obj (vals @ params) inh_init obj_init cl
      in
      (inh_init,
       let build params rem =
         let param = name_pattern "param" pat in
         mk_lambda ?ty:None ~from:"build_object_init" ~env:cl.cl_env @@
         Lfunction (Curried, param::params,
                    Matching.for_function
                      pat.pat_loc None
                      (mk_lambda ?ty:None ~from:"build_object_init" ~env:cl.cl_env @@
                       Lvar param) [pat, rem] partial)
       in
       begin match obj_init.lb_expr with
         Lfunction (Curried, params, rem) -> build params rem
       | _                              -> build [] obj_init
       end)
  | Tcl_apply (cl', oexprs) ->
      let (inh_init, obj_init) =
        build_object_init cl_table obj params inh_init obj_init cl'
      in
      (inh_init, transl_apply cl.cl_env obj_init oexprs Location.none)
  | Tcl_let (rec_flag, defs, vals, cl) ->
      let vals = List.map (fun (id, _, e) -> id,e) vals in
      let (inh_init, obj_init) =
        build_object_init cl_table obj (vals @ params) inh_init obj_init cl
      in
      (inh_init, Translcore.transl_let rec_flag defs obj_init)
  | Tcl_constraint (cl, _, vals, pub_meths, concr_meths) ->
      build_object_init cl_table obj params inh_init obj_init cl

let rec build_object_init_0 cl_table params cl copy_env subst_env top ids =
  match cl.cl_desc with
    Tcl_let (rec_flag, defs, vals, cl) ->
      let vals = List.map (fun (id, _, e) -> id,e) vals in
      build_object_init_0 cl_table (vals@params) cl copy_env subst_env top ids
  | _ ->
      let self = Ident.create "self" in
      let env = Ident.create "env" in
      let obj = if ids = [] then lambda_unit
        else mk_lambda ?ty:None ~from:"build_object_init_0" ~env:cl.cl_env @@
          Lvar self in
      let envs = if top then None else Some env in
      let ((_,inh_init), obj_init) =
        build_object_init cl_table obj params (envs,[]) (copy_env env) cl in
      let obj_init =
        if ids = [] then obj_init else lfunction [self] obj_init in
      (inh_init, lfunction [env] (subst_env env inh_init obj_init))


let bind_method tbl lab id cl_init =
  as_arg ~from:"build_object_init" ?env:None cl_init @@
  Llet(Strict, id, mkappl
         (oo_prim "get_method_label",
          [mk_lambda ?ty:None ~from:"build_object_init" ?env:cl_init.lb_env @@
           Lvar tbl; transl_label lab]),
       cl_init)

let bind_methods tbl meths vals cl_init =
  let methl = Meths.fold (fun lab id tl -> (lab,id) :: tl) meths [] in
  let len = List.length methl and nvals = List.length vals in
  if len < 2 && nvals = 0 then Meths.fold (bind_method tbl) meths cl_init else
  if len = 0 && nvals < 2 then transl_vals tbl true Strict vals cl_init else
  let ids = Ident.create "ids" in
  let i = ref (len + nvals) in
  let getter, names =
    if nvals = 0 then "get_method_labels", [] else
    "new_methods_variables", [transl_meth_list (List.map fst vals)]
  in
  as_arg ~from:"bind_methods" cl_init @@
  Llet(Strict, ids,
       mkappl (oo_prim getter,
               [mk_lambda ?ty:None ~from:"bind_methods" ?env:cl_init.lb_env @@
                Lvar tbl; transl_meth_list (List.map fst methl)] @ names),
       List.fold_right
         (fun (lab,id) lam -> decr i;
           as_arg ~from:"bind_methods" ?env:None lam @@
           Llet(StrictOpt, id, lfield ids !i, lam))
         (methl @ vals) cl_init)

let output_methods tbl methods lam =
  match methods with
    [] -> lam
  | [lab; code] ->
      lsequence (mkappl(oo_prim "set_method", [
          mk_lambda ?ty:None ~from:"output_methods" ?env:lam.lb_env @@
          Lvar tbl; lab; code])) lam
  | _ ->
      lsequence (mkappl(oo_prim "set_methods",
                        [mk_lambda ?ty:None ~from:"output_method" ?env:lam.lb_env @@
                         Lvar tbl;
                         mk_lambda ?ty:None ~from:"output_method" ?env:lam.lb_env @@
                         Lprim(Pmakeblock(0,Immutable), methods)]))
        lam

let rec ignore_cstrs cl =
  match cl.cl_desc with
    Tcl_constraint (cl, _, _, _, _) -> ignore_cstrs cl
  | Tcl_apply (cl, _) -> ignore_cstrs cl
  | _ -> cl

let rec index a = function
    [] -> raise Not_found
  | b :: l ->
      if b = a then 0 else 1 + index a l

let bind_id_as_val (id, _, _) = ("", id)

let rec build_class_init cla cstr super inh_init cl_init msubst top cl =
  match cl.cl_desc with
    Tcl_ident ( path, _, _) ->
      begin match inh_init with
        (obj_init, path')::inh_init ->
          let lpath = transl_path ~loc:cl.cl_loc cl.cl_env path in
          (inh_init,
           mk_lambda ?ty:None ~from:"build_class_init: Tcl_ident" ~env:cl.cl_env @@
           Llet (Strict, obj_init,
                 mkappl(
                   mk_lambda ?ty:None ~from:"build_class_init" ~env:cl.cl_env @@
                   Lprim(Pfield 1, [lpath]),
                   (mk_lambda ?ty:None ~from:"build_class_init" ~env:cl.cl_env @@
                    Lvar cla) ::
                   if top then
                     [mk_lambda ?ty:None ~from:"build_class_init" ~env:cl.cl_env @@
                      Lprim(Pfield 3, [lpath])] else []),
                 bind_super cla super cl_init))
      | _ ->
          assert false
      end
  | Tcl_structure str ->
      let cl_init = bind_super cla super cl_init in
      let (inh_init, cl_init, methods, values) =
        List.fold_right
          (fun field (inh_init, cl_init, methods, values) ->
            match field.cf_desc with
              Tcf_inherit (_, cl, _, vals, meths) ->
                let cl_init = output_methods cla methods cl_init in
                let inh_init, cl_init =
                  build_class_init cla false
                    (vals, meths_super cla str.cstr_meths meths)
                    inh_init cl_init msubst top cl in
                (inh_init, cl_init, [], values)
            | Tcf_val (name, _, id, _, over) ->
                let values =
                  if over then values else (name.txt, id) :: values
                in
                (inh_init, cl_init, methods, values)
            | Tcf_method (_, _, Tcfk_virtual _)
            | Tcf_constraint _
              ->
                (inh_init, cl_init, methods, values)
            | Tcf_method (name, _, Tcfk_concrete (_, exp)) ->
                let met_code = msubst true (transl_exp exp) in
                let met_code =
                  if !Clflags.native_code && List.length met_code = 1 then
                    (* Force correct naming of method for profiles *)
                    let met = Ident.create ("method_" ^ name.txt) in
                    [mk_lambda ?ty:None ~from:"build_class_init" ~env:cl.cl_env @@
                     Llet(Strict, met, List.hd met_code,
                          mk_lambda ?ty:None ~from:"build_class_init" ~env:cl.cl_env @@
                          Lvar met)]
                  else met_code
                in
                (inh_init, cl_init,
                 (mk_lambda ?ty:None ~from:"build_class_init" ~env:cl.cl_env @@
                 Lvar(Meths.find name.txt str.cstr_meths)) :: met_code @ methods,
                 values)
            | Tcf_initializer exp ->
                (inh_init,
                 mk_lambda ?ty:None ~from:"build_class_init" ~env:cl.cl_env @@
                 Lsequence(mkappl
                             (oo_prim "add_initializer",
                              (mk_lambda ?ty:None
                                 ~from:"build_class_init" ~env:cl.cl_env @@
                               Lvar cla) :: msubst false (transl_exp exp)),
                           cl_init),
                 methods, values)
            | Tcf_attribute _ ->
                (inh_init, cl_init, methods, values))
          str.cstr_fields
          (inh_init, cl_init, [], [])
      in
      let cl_init = output_methods cla methods cl_init in
      (inh_init, bind_methods cla str.cstr_meths values cl_init)
  | Tcl_fun (_, pat, vals, cl, _) ->
      let (inh_init, cl_init) =
        build_class_init cla cstr super inh_init cl_init msubst top cl
      in
      let vals = List.map bind_id_as_val vals in
      (inh_init, transl_vals cla true StrictOpt vals cl_init)
  | Tcl_apply (cl, exprs) ->
      build_class_init cla cstr super inh_init cl_init msubst top cl
  | Tcl_let (rec_flag, defs, vals, cl) ->
      let (inh_init, cl_init) =
        build_class_init cla cstr super inh_init cl_init msubst top cl
      in
      let vals = List.map bind_id_as_val vals in
      (inh_init, transl_vals cla true StrictOpt vals cl_init)
  | Tcl_constraint (cl, _, vals, meths, concr_meths) ->
      let virt_meths =
        List.filter (fun lab -> not (Concr.mem lab concr_meths)) meths in
      let concr_meths = Concr.elements concr_meths in
      let narrow_args =
        [mk_lambda ?ty:None ~from:"build_class_init" ~env:cl.cl_env @@ Lvar cla;
         transl_meth_list vals;
         transl_meth_list virt_meths;
         transl_meth_list concr_meths] in
      let cl = ignore_cstrs cl in
      begin match cl.cl_desc, inh_init with
        Tcl_ident (path, _, _), (obj_init, path')::inh_init ->
          assert (Path.same (normalize_cl_path cl path) path');
          let lpath = transl_normal_path cl.cl_env path' in
          let inh = Ident.create "inh"
          and ofs = List.length vals + 1
          and valids, methids = super in
          let cl_init =
            List.fold_left
              (fun init (nm, id, _) ->
                 as_arg ~from:"build_class_init" init @@
                 Llet(StrictOpt, id, lfield inh (index nm concr_meths + ofs),
                      init))
              cl_init methids in
          let cl_init =
            List.fold_left
              (fun init (nm, id) ->
                 as_arg ~from:"build_class_init" cl_init @@
                 Llet(StrictOpt, id, lfield inh (index nm vals + 1), init))
              cl_init valids in
          (inh_init,
           as_arg ~from:"build_class_init" cl_init @@
           Llet (Strict, inh,
                 mkappl(oo_prim "inherits",
                        narrow_args @
                        [lpath;
                         mk_lambda ?ty:None ~from:"build_class_init" ~env:cl.cl_env @@
                         Lconst(Const_pointer(if top then 1 else 0))]),
                 as_arg ~from:"build_class_init" cl_init ?env:None @@
                 Llet(StrictOpt, obj_init, lfield inh 0, cl_init)))
      | _ ->
          let core cl_init =
            build_class_init cla true super inh_init cl_init msubst top cl
          in
          if cstr then core cl_init else
          let (inh_init, cl_init) =
            core (as_arg ~from:"build_class_init" ?env:None cl_init @@
                    Lsequence (mkappl
                                 (oo_prim "widen",
                                  [mk_lambda ?ty:None
                                     ~from:"build_class_init" ~env:cl.cl_env @@
                                   Lvar cla]), cl_init))
          in
          (inh_init,
           as_arg ~from:"build_class_init" ?env:None cl_init @@
           Lsequence(mkappl (oo_prim "narrow", narrow_args),
                     cl_init))
      end

let rec build_class_lets cl ids =
  match cl.cl_desc with
    Tcl_let (rec_flag, defs, vals, cl') ->
      let env, wrap = build_class_lets cl' [] in
      (env, fun x ->
        let lam = Translcore.transl_let rec_flag defs (wrap x) in
        (* Check recursion in toplevel let-definitions *)
        if ids = [] || Translcore.check_recursive_lambda ids lam then lam
        else raise(Error(cl.cl_loc, Illegal_class_expr)))
  | _ ->
      (cl.cl_env, fun x -> x)

let rec get_class_meths cl =
  match cl.cl_desc with
    Tcl_structure cl ->
      Meths.fold (fun _ -> IdentSet.add) cl.cstr_meths IdentSet.empty
  | Tcl_ident _ -> IdentSet.empty
  | Tcl_fun (_, _, _, cl, _)
  | Tcl_let (_, _, _, cl)
  | Tcl_apply (cl, _)
  | Tcl_constraint (cl, _, _, _, _) -> get_class_meths cl

(*
   XXX Il devrait etre peu couteux d'ecrire des classes :
     class c x y = d e f
*)
let rec transl_class_rebind obj_init cl vf =
  match cl.cl_desc with
    Tcl_ident (path, _, _) ->
      if vf = Concrete then begin
        try if (Env.find_class path cl.cl_env).cty_new = None then raise Exit
        with Not_found -> raise Exit
      end;
      (normalize_cl_path cl path, obj_init)
  | Tcl_fun (_, pat, _, cl, partial) ->
      let path, obj_init = transl_class_rebind obj_init cl vf in
      let build params rem =
        let param = name_pattern "param" pat in
        mk_lambda ?ty:None ~from:"transl_class_rebind:Tcl_fun" ~env:cl.cl_env @@
        Lfunction (Curried, param::params,
                   Matching.for_function
                     pat.pat_loc None
                     (mk_lambda ?ty:None
                        ~from:"transl_class_rebind:Tcl_fun" ~env:cl.cl_env @@
                      Lvar param) [pat, rem] partial)
      in
      (path,
       match obj_init.lb_expr with
         Lfunction (Curried, params, rem) -> build params rem
       | _                                -> build [] obj_init)
  | Tcl_apply (cl', oexprs) ->
      let path, obj_init = transl_class_rebind obj_init cl' vf in
      (path, transl_apply cl.cl_env obj_init oexprs Location.none)
  | Tcl_let (rec_flag, defs, vals, cl) ->
      let path, obj_init = transl_class_rebind obj_init cl vf in
      (path, Translcore.transl_let rec_flag defs obj_init)
  | Tcl_structure _ -> raise Exit
  | Tcl_constraint (cl', _, _, _, _) ->
      let path, obj_init = transl_class_rebind obj_init cl' vf in
      let rec check_constraint = function
          Cty_constr(path', _, _) when Path.same path path' -> ()
        | Cty_arrow (_, _, cty) -> check_constraint cty
        | _ -> raise Exit
      in
      check_constraint cl.cl_type;
      (path, obj_init)

let rec transl_class_rebind_0 self obj_init cl vf =
  match cl.cl_desc with
    Tcl_let (rec_flag, defs, vals, cl) ->
      let path, obj_init = transl_class_rebind_0 self obj_init cl vf in
      (path, Translcore.transl_let rec_flag defs obj_init)
  | _ ->
      let path, obj_init = transl_class_rebind obj_init cl vf in
      (path, lfunction [self] obj_init)

let transl_class_rebind ids cl vf =
  try
    let obj_init = Ident.create "obj_init"
    and self = Ident.create "self" in
    let obj_init0 = lapply
        (mk_lambda ?ty:None ~from:"transl_class_rebind" ~env:cl.cl_env @@
         Lvar obj_init)
        [mk_lambda ?ty:None ~from:"transl_class_rebind" ~env:cl.cl_env @@
         Lvar self]
        Location.none in
    let path, obj_init' = transl_class_rebind_0 self obj_init0 cl vf in
    if not (Translcore.check_recursive_lambda ids obj_init') then
      raise(Error(cl.cl_loc, Illegal_class_expr));
    let id = (obj_init' = lfunction [self] obj_init0) in
    if id then transl_normal_path cl.cl_env path else

    let cla = Ident.create "class"
    and new_init = Ident.create "new_init"
    and env_init = Ident.create "env_init"
    and table = Ident.create "table"
    and envs = Ident.create "envs" in
    let mk_u = mk_lambda ?ty:None ~from:"transl_class_rebind" ~env:cl.cl_env in
    mk_lambda ~ty:(Class cl.cl_type) ~from:"transl_class_rebind" ~env:cl.cl_env @@
    Llet(
    Strict, new_init, lfunction [obj_init] obj_init',
    mk_lambda ~ty:(Class cl.cl_type) ~from:"transl_class_rebind" ~env:cl.cl_env @@
    Llet(
    Alias, cla, transl_normal_path cl.cl_env path,
    mk_lambda ~ty:(Class cl.cl_type) ~from:"transl_class_rebind" ~env:cl.cl_env @@
    Lprim(Pmakeblock(0, Immutable),
          [mkappl(mk_u @@ Lvar new_init, [lfield cla 0]);
           lfunction [table]
             (mk_u @@
              Llet(Strict, env_init,
                   mkappl(lfield cla 1, [mk_u @@ Lvar table]),
                   lfunction [envs]
                     (mkappl(mk_u @@ Lvar new_init,
                             [mkappl(mk_u @@ Lvar env_init,
                                     [mk_u @@ Lvar envs])]))));
           lfield cla 2;
           lfield cla 3])))
  with Exit ->
    lambda_unit

(* Rewrite a closure using builtins. Improves native code size. *)

let rec module_path l =
  match l.lb_expr with
    Lvar id ->
      let s = Ident.name id in s <> "" && s.[0] >= 'A' && s.[0] <= 'Z'
  | Lprim(Pfield _, [p])    -> module_path p
  | Lprim(Pgetglobal _, []) -> true
  | _                       -> false

let const_path local l =
  match l.lb_expr with
    Lvar id -> not (List.mem id local)
  | Lconst _ -> true
  | Lfunction (Curried, _, body) ->
      let fv = free_variables body in
      List.for_all (fun x -> not (IdentSet.mem x fv)) local
  | _ -> module_path l

let rec builtin_meths self env env2 body =
  let const_path = const_path (env::self) in
  let conv l =
    match l.lb_expr with
    (* Lvar s when List.mem s self ->  "_self", [] *)
    | _ when const_path l -> "const", [l]
    | Lprim(Parrayrefu _, [{lb_expr = Lvar s}; {lb_expr = Lvar n}])
      when List.mem s self ->
        "var", [mk_lambda ?ty:None ~from:"buildin_meths" ?env:None @@ Lvar n]
    | Lprim(Pfield n, [{lb_expr = Lvar e}]) when Ident.same e env ->
        "env", [mk_lambda ?ty:None ~from:"buildin_meths" ?env:None @@ Lvar env2;
                mk_lambda ?ty:None ~from:"buildin_meths" ?env:None @@ Lconst(Const_pointer n)]
    | Lsend(Self, met, {lb_expr = Lvar s}, [], _) when List.mem s self ->
        "meth", [met]
    | _ -> raise Not_found
  in
  match body.lb_expr with
  | Llet(_, s', {lb_expr = Lvar s}, body) when List.mem s self ->
      builtin_meths (s'::self) env env2 body
  | Lapply(f, [arg], _) when const_path f ->
      let s, args = conv arg in ("app_"^s, f :: args)
  | Lapply(f, [arg; p], _) when const_path f && const_path p ->
      let s, args = conv arg in
      ("app_"^s^"_const", f :: args @ [p])
  | Lapply(f, [p; arg], _) when const_path f && const_path p ->
      let s, args = conv arg in
      ("app_const_"^s, f :: p :: args)
  | Lsend(Self, ({lb_expr = Lvar n} as ln), {lb_expr = Lvar s}, [arg], _)
    when List.mem s self ->
      let s, args = conv arg in
      ("meth_app_"^s, ln :: args)
  | Lsend(Self, met, { lb_expr = Lvar s }, [], _) when List.mem s self ->
      ("get_meth", [met])
  | Lsend(Public, met, arg, [], _) ->
      let s, args = conv arg in
      ("send_"^s, met :: args)
  | Lsend(Cached, met, arg, [_;_], _) ->
      let s, args = conv arg in
      ("send_"^s, met :: args)
  | Lfunction (Curried, [x], body) ->
      let rec enter self l =
        match l.lb_expr with
        | Lprim(Parraysetu _, [{lb_expr = Lvar s};
                               {lb_expr = Lvar n} as ln;
                               {lb_expr = Lvar x'}])
          when Ident.same x x' && List.mem s self ->
            ("set_var", [ln])
        | Llet(_, s', {lb_expr = Lvar s}, body) when List.mem s self ->
            enter (s'::self) body
        | _ -> raise Not_found
      in enter self body
  | Lfunction _ -> raise Not_found
  | _ ->
      let s, args = conv body in ("get_"^s, args)

module M = struct
  open CamlinternalOO
  let builtin_meths self env env2 body =
    let builtin, args = builtin_meths self env env2 body in
    (* if not arr then [mkappl(oo_prim builtin, args)] else *)
    let tag = match builtin with
      "get_const" -> GetConst
    | "get_var"   -> GetVar
    | "get_env"   -> GetEnv
    | "get_meth"  -> GetMeth
    | "set_var"   -> SetVar
    | "app_const" -> AppConst
    | "app_var"   -> AppVar
    | "app_env"   -> AppEnv
    | "app_meth"  -> AppMeth
    | "app_const_const" -> AppConstConst
    | "app_const_var"   -> AppConstVar
    | "app_const_env"   -> AppConstEnv
    | "app_const_meth"  -> AppConstMeth
    | "app_var_const"   -> AppVarConst
    | "app_env_const"   -> AppEnvConst
    | "app_meth_const"  -> AppMethConst
    | "meth_app_const"  -> MethAppConst
    | "meth_app_var"    -> MethAppVar
    | "meth_app_env"    -> MethAppEnv
    | "meth_app_meth"   -> MethAppMeth
    | "send_const" -> SendConst
    | "send_var"   -> SendVar
    | "send_env"   -> SendEnv
    | "send_meth"  -> SendMeth
    | _ -> assert false
    in (mk_lambda ?ty:None ~from:"M.buildin_meths" ?env:None 
        @@ Lconst(Const_pointer(Obj.magic tag))) :: args
end
open M


(*
   Traduction d'une classe.
   Plusieurs cas:
    * reapplication d'une classe connue -> transl_class_rebind
    * classe sans dependances locales -> traduction directe
    * avec dependances locale -> creation d'un arbre de stubs,
      avec un noeud pour chaque classe locale heritee
   Une classe est un 4-uplet:
    (obj_init, class_init, env_init, env)
    obj_init: fonction de creation d'objet (unit -> obj)
    class_init: fonction d'heritage (table -> env_init)
      (une seule par code source)
    env_init: parametrage par l'environnement local (env -> params -> obj_init)
      (une par combinaison de class_init herites)
    env: environnement local
   Si ids=0 (objet immediat), alors on ne conserve que env_init.
*)

let prerr_ids msg ids =
  let names = List.map Ident.unique_toplevel_name ids in
  prerr_endline (String.concat " " (msg :: names))

let transl_class ids cl_id pub_meths cl vflag =
  (* First check if it is not only a rebind *)
  let rebind = transl_class_rebind ids cl vflag in
  if rebind <> lambda_unit then rebind else

  (* Prepare for heavy environment handling *)
  let tables = Ident.create (Ident.name cl_id ^ "_tables") in
  let (top_env, req) = oo_add_class tables in
  let top = not req in
  let cl_env, llets = build_class_lets cl ids in
  let new_ids = if top then [] else Env.diff top_env cl_env in
  let env2 = Ident.create "env" in
  let meth_ids = get_class_meths cl in
  let subst env lam i0 new_ids' =
    let fv = free_variables lam in
    (* prerr_ids "cl_id =" [cl_id]; prerr_ids "fv =" (IdentSet.elements fv); *)
    let fv = List.fold_right IdentSet.remove !new_ids' fv in
    (* We need to handle method ids specially, as they do not appear
       in the typing environment (PR#3576, PR#4560) *)
    (* very hacky: we add and remove free method ids on the fly,
       depending on the visit order... *)
    method_ids :=
      IdentSet.diff (IdentSet.union (free_methods lam) !method_ids) meth_ids;
    (* prerr_ids "meth_ids =" (IdentSet.elements meth_ids);
       prerr_ids "method_ids =" (IdentSet.elements !method_ids); *)
    let new_ids = List.fold_right IdentSet.add new_ids !method_ids in
    let fv = IdentSet.inter fv new_ids in
    new_ids' := !new_ids' @ IdentSet.elements fv;
    (* prerr_ids "new_ids' =" !new_ids'; *)
    let i = ref (i0-1) in
    List.fold_left
      (fun subst id ->
        incr i; Ident.add id (lfield env !i)  subst)
      Ident.empty !new_ids'
  in
  let new_ids_meths = ref [] in
  let msubst arr l =
    match l.lb_expr with
      Lfunction (Curried, self :: args, body) ->
        let env = Ident.create "env" in
        let body' =
          if new_ids = [] then body else
          subst_lambda (subst env body 0 new_ids_meths) body in
        begin try
          (* Doesn't seem to improve size for bytecode *)
          (* if not !Clflags.native_code then raise Not_found; *)
          if not arr || !Clflags.debug then raise Not_found;
          builtin_meths [self] env env2 (lfunction args body')
        with Not_found ->
          [lfunction (self :: args)
             (if not (IdentSet.mem env (free_variables body')) then body' else
                mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                Llet(Alias, env,
                     mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                     Lprim(Parrayrefu Paddrarray,
                           [mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                            Lvar self;
                            mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                            Lvar env2]), body'))]
        end
      | _ -> assert false
  in
  let new_ids_init = ref [] in
  let env1 = Ident.create "env" and env1' = Ident.create "env'" in
  let copy_env envs self =
    if top then lambda_unit else
      mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
      Lifused(env2, mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
              Lprim(Parraysetu Paddrarray,
                    [mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar self;
                     mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar env2;
                     mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar env1']))
  and subst_env envs l lam =
    if top then lam else
    (* must be called only once! *)
      let lam = subst_lambda (subst env1 lam 1 new_ids_init) lam in
      as_arg ~from:"transl_class" ~env:cl.cl_env lam @@
      Llet(Alias, env1,
           (if l = [] then
              mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar envs
            else lfield envs 0),
           as_arg ~from:"transl_class" ~env:cl.cl_env lam @@
           Llet(Alias, env1',
                (if !new_ids_init = [] then
                   mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar env1
                 else lfield env1 0),
                lam))
  in

  (* Now we start compiling the class *)
  let cla = Ident.create "class" in
  let (inh_init, obj_init) =
    build_object_init_0 cla [] cl copy_env subst_env top ids in
  let inh_init' = List.rev inh_init in
  let (inh_init', cl_init) =
    build_class_init cla true ([],[]) inh_init' obj_init msubst top cl
  in
  assert (inh_init' = []);
  let table = Ident.create "table"
  and class_init = Ident.create (Ident.name cl_id ^ "_init")
  and env_init = Ident.create "env_init"
  and obj_init = Ident.create "obj_init" in
  let pub_meths =
    List.sort
      (fun s s' -> compare (Btype.hash_variant s) (Btype.hash_variant s'))
      pub_meths in
  let tags = List.map Btype.hash_variant pub_meths in
  let rev_map = List.combine tags pub_meths in
  List.iter2
    (fun tag name ->
      let name' = List.assoc tag rev_map in
      if name' <> name then raise(Error(cl.cl_loc, Tags(name, name'))))
    tags pub_meths;
  let ltable table lam =
    as_arg ~from:"transl_class" lam @@ Llet(Strict, table,
         mkappl (oo_prim "create_table", [transl_meth_list pub_meths]), lam)
  and ldirect obj_init =
    mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
    Llet(Strict, obj_init, cl_init,
         mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
         Lsequence(mkappl (oo_prim "init_class",
                           [mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                            Lvar cla]),
                   mkappl (mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                           Lvar obj_init,
                           [lambda_unit])))
  in
  (* Simplest case: an object defined at toplevel (ids=[]) *)
  if top && ids = [] then llets (ltable cla (ldirect obj_init)) else

  let concrete = (vflag = Concrete)
  and lclass lam =
    let res = lam (free_variables cl_init) in
    let cl_init = llets (mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                         Lfunction(Curried, [cla], cl_init)) in
    as_arg ~from:"transl_class" ~env:cl.cl_env res @@
    Llet(Strict, class_init, cl_init, res)
  and lbody fv =
    if List.for_all (fun id -> not (IdentSet.mem id fv)) ids then
      mkappl (oo_prim "make_class",
              [transl_meth_list pub_meths;
               mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
               Lvar class_init])
    else
      ltable table (
        mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
        Llet(
          Strict, env_init, mkappl
            (mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar class_init,
             [mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar table]),
          mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
          Lsequence(
            mkappl (oo_prim "init_class",
                    [mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar table]),
            mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
            Lprim(Pmakeblock(0, Immutable),
                  [mkappl
                     (mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                      Lvar env_init, [lambda_unit]);
                   mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar class_init;
                   mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar env_init;
                   lambda_unit]))))
  and lbody_virt lenvs =
    mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
    Lprim(Pmakeblock(0, Immutable),
          [lambda_unit;
           mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
           Lfunction(Curried,[cla], cl_init); lambda_unit; lenvs])
  in
  (* Still easy: a class defined at toplevel *)
  if top && concrete then lclass lbody else
  if top then llets (lbody_virt lambda_unit) else

  (* Now for the hard stuff: prepare for table cacheing *)
  let envs = Ident.create "envs"
  and cached = Ident.create "cached" in
  let lenvs =
    if !new_ids_meths = [] && !new_ids_init = [] && inh_init = []
    then lambda_unit
    else mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar envs in
  let lenv =
    let menv =
      if !new_ids_meths = [] then lambda_unit else
        mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
        Lprim(Pmakeblock(0, Immutable),
              List.map (fun id ->
                  mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar id)
                !new_ids_meths) in
    if !new_ids_init = [] then menv else
      mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
      Lprim(Pmakeblock(0, Immutable),
            menv :: List.map (fun id ->
                mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@ Lvar id)
              !new_ids_init)
  and linh_envs =
    List.map (fun (_, p) ->
        mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
               Lprim(Pfield 3, [transl_normal_path cl.cl_env p]))
      (List.rev inh_init)
  in
  let make_envs lam =
    as_arg ~from:"transl_class" ~env:cl.cl_env lam @@
    Llet(StrictOpt, envs,
         (if linh_envs = [] then lenv else
            mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
            Lprim(Pmakeblock(0, Immutable), lenv :: linh_envs)),
         lam)
  and def_ids cla lam =
    as_arg ~from:"transl_class" lam @@
    Llet(StrictOpt, env2,
         mkappl (oo_prim "new_variable",
                 [mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                  Lvar cla; transl_label ""]),
         lam)
  in
  let inh_paths =
    List.filter
      (fun (_,path) -> List.mem (Path.head path) new_ids) inh_init in
  let inh_keys =
    List.map (fun (_,p) -> mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
               Lprim(Pfield 1, [transl_normal_path cl.cl_env p])) inh_paths in
  let lclass lam =
    as_arg ~from:"transl_class" ~env:cl.cl_env lam @@
    Llet(Strict, class_init,
         mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
         Lfunction(Curried, [cla], def_ids cla cl_init), lam)
  and lcache lam =
    if inh_keys = [] then
      as_arg ~from:"transl_class" ~env:cl.cl_env lam @@
      Llet(Alias, cached, mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
           Lvar tables, lam)
    else
      as_arg ~from:"transl_class" ~env:cl.cl_env lam @@
      Llet(Strict, cached,
           mkappl (oo_prim "lookup_tables",
                   [mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                    Lvar tables;
                    mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                    Lprim(Pmakeblock(0, Immutable), inh_keys)]),
           lam)
  and lset cached i lam =
    mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
    Lprim(Psetfield(i, true),
          [mk_lambda  ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
           Lvar cached; lam])
  in
  let ldirect () =
    ltable cla
      (mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
       Llet(Strict, env_init, def_ids cla cl_init,
            mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
            Lsequence(mkappl
                        (oo_prim "init_class",
                         [mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                          Lvar cla]),
                      lset cached 0
                        (mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                         Lvar env_init))))
  and lclass_virt () =
    lset cached 0 (mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                   Lfunction(Curried, [cla], def_ids cla cl_init))
  in
  llets (
    lcache (
      mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
      Lsequence(
        mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
        Lifthenelse(lfield cached 0, lambda_unit,
                    if ids = [] then ldirect () else
                    if not concrete then lclass_virt () else
                      lclass (
                        mkappl (oo_prim "make_class_store",
                                [transl_meth_list pub_meths;
                                 mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                                 Lvar class_init;
                                 mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
                                 Lvar cached]))),
        make_envs (
          if ids = [] then mkappl (lfield cached 0, [lenvs]) else
            mk_lambda ?ty:None ~from:"transl_class" ~env:cl.cl_env @@
            Lprim(Pmakeblock(0, Immutable),
                  if concrete then
                    [mkappl (lfield cached 0, [lenvs]);
                     lfield cached 1;
                     lfield cached 0;
                     lenvs]
                  else [lambda_unit; lfield cached 0; lambda_unit; lenvs]
                 )))))

(* Wrapper for class compilation *)
(*
    let cl_id = ci.ci_id_class in
(* TODO: cl_id is used somewhere else as typesharp ? *)
  let _arity = List.length ci.ci_params in
  let pub_meths = m in
  let cl = ci.ci_expr in
  let vflag = vf in
*)

let transl_class ids id pub_meths cl vf =
  oo_wrap cl.cl_env false (transl_class ids id pub_meths cl) vf

let () =
  transl_object := (fun id meths cl -> transl_class [] id meths cl Concrete)

(* Error report *)

open Format

let report_error ppf = function
  | Illegal_class_expr ->
      fprintf ppf "This kind of recursive class expression is not allowed"
  | Tags (lab1, lab2) ->
      fprintf ppf "Method labels `%s' and `%s' are incompatible.@ %s"
        lab1 lab2 "Change one of them."

let () =
  Location.register_error_of_exn
    (function
      | Error (loc, err) ->
        Some (Location.error_of_printer loc report_error err)
      | _ ->
        None
    )
