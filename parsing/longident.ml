(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

type t =
    Lident of string
  | Ldot of t * string
  | Lapply of t * t

let rec flat accu = function
    Lident s -> s :: accu
  | Ldot(lid, s) -> flat (s :: accu) lid
  | Lapply(_, _) -> Format.printf "Apply???@."; Misc.fatal_error "Longident.flat"

let flatten lid = flat [] lid

let rec first = function
    Lident s -> s
  | Ldot (s, _) -> first s
  | Lapply (_, _) -> Misc.fatal_error "Longident.first"

let last = function
    Lident s -> s
  | Ldot(_, s) -> s
  | Lapply(_, _) -> Misc.fatal_error "Longident.last"

let rec split_at_dots s pos =
  try
    let dot = String.index_from s pos '.' in
    String.sub s pos (dot - pos) :: split_at_dots s (dot + 1)
  with Not_found ->
    [String.sub s pos (String.length s - pos)]

let parse s =
  match split_at_dots s 0 with
    [] -> Lident ""  (* should not happen, but don't put assert false
                        so as not to crash the toplevel (see Genprintval) *)
  | hd :: tl -> List.fold_left (fun p s -> Ldot(p, s)) (Lident hd) tl

let rec to_string acc = function
    Lident s -> Format.sprintf "%s%s" s acc
  | Ldot (s, l) -> let acc = Format.sprintf ".%s%s" l acc in to_string acc s
  | Lapply (_, _) -> failwith "Misc.to_string: nope"

let string_of_longident = to_string ""

let optstring = function
    None -> Format.printf "optstring fails with None ?@."; None
  | Some ns -> Format.printf "optstring fails with Some ?@."; Some (string_of_longident ns)

let from_optstring = function
    None -> None
  | Some ns -> Some (parse ns)
