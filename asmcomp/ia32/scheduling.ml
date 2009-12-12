(***********************************************************************)
(*                                                                     *)
(*                           Objective Caml                            *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* $Id: scheduling.ml 2779 2000-02-04 12:43:18Z xleroy $ *)

open Schedgen (* to create a dependency *)

(* Scheduling is turned off because all IA32/SSE2 processors
   schedule at run-time much better than what we could do. *)

let fundecl f = f
