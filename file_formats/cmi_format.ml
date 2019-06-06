(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                   Fabrice Le Fessant, INRIA Saclay                     *)
(*                                                                        *)
(*   Copyright 2012 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

open Misc

type pers_flags =
  | Rectypes
  | Alerts of alerts
  | Opaque
  | Unsafe_string
  | Pack of Compilation_unit.Prefix.t
  | Parameter_of of Compilation_unit.Name.t
  | Parameters of Compilation_unit.Name.t list

type error =
  | Not_an_interface of filepath
  | Wrong_version_interface of filepath * string
  | Corrupted_interface of filepath

exception Error of error

type cmi_infos = {
    cmi_name : Compilation_unit.Name.t;
    cmi_type : Types.module_type;
    cmi_crcs : Compilation_unit.crcs;
    cmi_flags : pers_flags list;
}

let input_cmi ic =
  let (name, mty) = input_value ic in
  let crcs = input_value ic in
  let flags = input_value ic in
  {
      cmi_name = name;
      cmi_type = mty;
      cmi_crcs = crcs;
      cmi_flags = flags;
    }

let read_cmi filename =
  let ic = open_in_bin filename in
  try
    let buffer =
      really_input_string ic (String.length Config.cmi_magic_number)
    in
    if buffer <> Config.cmi_magic_number then begin
      close_in ic;
      let pre_len = String.length Config.cmi_magic_number - 3 in
      if String.sub buffer 0 pre_len
          = String.sub Config.cmi_magic_number 0 pre_len then
      begin
        let msg =
          if buffer < Config.cmi_magic_number then "an older" else "a newer" in
        raise (Error (Wrong_version_interface (filename, msg)))
      end else begin
        raise(Error(Not_an_interface filename))
      end
    end;
    let cmi = input_cmi ic in
    close_in ic;
    cmi
  with End_of_file | Failure _ ->
      close_in ic;
      raise(Error(Corrupted_interface(filename)))
    | Error e ->
      close_in ic;
      raise (Error e)

let output_cmi filename oc cmi =
(* beware: the provided signature must have been substituted for saving *)
  output_string oc Config.cmi_magic_number;
  output_value oc (cmi.cmi_name, cmi.cmi_type);
  flush oc;
  let crc = Digest.file filename in
  let for_pack_prefix =
    match List.find_opt (function Pack _ -> true | _ -> false) cmi.cmi_flags with
      Some (Pack p) -> p
    | _ -> []
  in
  let crcs =
    (Compilation_unit.create ~for_pack_prefix cmi.cmi_name, Some crc)
    :: cmi.cmi_crcs in
  output_value oc crcs;
  output_value oc cmi.cmi_flags;
  crc

(* Error report *)

open Format

let report_error ppf = function
  | Not_an_interface filename ->
      fprintf ppf "%a@ is not a compiled interface"
        Location.print_filename filename
  | Wrong_version_interface (filename, older_newer) ->
      fprintf ppf
        "%a@ is not a compiled interface for this version of OCaml.@.\
         It seems to be for %s version of OCaml."
        Location.print_filename filename older_newer
  | Corrupted_interface filename ->
      fprintf ppf "Corrupted compiled interface@ %a"
        Location.print_filename filename

let () =
  Location.register_error_of_exn
    (function
      | Error err -> Some (Location.error_of_printer_file report_error err)
      | _ -> None
    )
