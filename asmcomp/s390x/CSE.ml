(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*            Xavier Leroy, projet Gallium, INRIA Rocquencourt         *)
(*                          Bill O'Farrell, IBM                        *)
(*                                                                     *)
(*    Copyright 2015 Institut National de Recherche en Informatique    *)
(*    et en Automatique. Copyright 2015 IBM (Bill O'Farrell with       *)
(*    help from Tristan Amini). All rights reserved.  This file is     *)
(*    distributed under the terms of the Q Public License version 1.0. *)
(*                                                                     *)
(***********************************************************************)

(* CSE for the Z Processor *)

open Arch
open Mach
open CSEgen

class cse = object (self)

inherit cse_generic as super

method! class_of_operation op =
  match op with
  | Ispecific(Imultaddf | Imultsubf) -> Op_pure
  | _ -> super#class_of_operation op

method! is_cheap_operation op =
  match op with
  | Iconst_int n | Iconst_blockheader n ->
      n >= -0x8000_0000n && n <= 0x7FFF_FFFFn
  | _ -> false

end

let fundecl f =
  (new cse)#fundecl f
