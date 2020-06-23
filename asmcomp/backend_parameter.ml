module type S = sig

  module Arch : sig

    val command_line_options : (string * Arg.spec * string) list

    type addressing_mode

    type specific_operation

    val size_int: int
    val size_float: int

    val size_addr: int

    val division_crashes_on_overflow: bool

    val big_endian: bool
    val allow_unaligned_access: bool

    val print_addressing:
      (Format.formatter -> Reg.t -> unit) ->
      addressing_mode -> Format.formatter -> Reg.t array -> unit

    val print_specific_operation:
      (Format.formatter -> Reg.t -> unit) ->
      specific_operation -> Format.formatter -> Reg.t array -> unit

    val offset_addressing : addressing_mode -> int -> addressing_mode

    val identity_addressing : addressing_mode

    val spacetime_node_hole_pointer_is_live_before: specific_operation -> bool

  end

  module Proc : sig
    (* Processor descriptions *)

    (* Instruction selection *)
    val word_addressed: bool

    (* Registers available for register allocation *)
    val num_register_classes: int
    val register_class: Reg.t -> int
    val num_available_registers: int array
    val first_available_register: int array
    val register_name: int -> string
    val phys_reg: int -> Reg.t
    val rotate_registers: bool

    (* Calling conventions *)
    val loc_arguments: Reg.t array -> Reg.t array * int
    val loc_results: Reg.t array -> Reg.t array
    val loc_parameters: Reg.t array -> Reg.t array
    (* For argument number [n] split across multiple registers, the target-specific
       implementation of [loc_external_arguments] must return [regs] such that
       [regs.(n).(0)] is to hold the part of the value at the lowest address.
       (All that matters for the input to [loc_external_arguments] is the pattern
       of lengths and register types of the various supplied arrays.) *)
    val loc_external_arguments: Reg.t array array -> Reg.t array array * int
    val loc_external_results: Reg.t array -> Reg.t array
    val loc_exn_bucket: Reg.t
    val loc_spacetime_node_hole: Reg.t

    (* The maximum number of arguments of an OCaml to OCaml function call for
       which it is guaranteed there will be no arguments passed on the stack.
       (Above this limit, tail call optimization may be disabled.)
       N.B. The values for this parameter in the backends currently assume
       that no unboxed floats are passed using the OCaml calling conventions.
    *)
    val max_arguments_for_tailcalls : int

    (* Maximal register pressures for pre-spilling *)
    val safe_register_pressure: Mach_type.Make(Arch).operation -> int
    val max_register_pressure: Mach_type.Make(Arch).operation -> int array

    (* Registers destroyed by operations *)
    val destroyed_at_oper: Mach_type.Make(Arch).instruction_desc -> Reg.t array
    val destroyed_at_raise: Reg.t array
    val destroyed_at_reloadretaddr : Reg.t array

    (* Volatile registers: those that change value when read *)
    val regs_are_volatile: Reg.t array -> bool

    (* Pure operations *)
    val op_is_pure: Mach_type.Make(Arch).operation -> bool

    (* Info for laying out the stack frame *)
    val frame_required : Mach_type.Make(Arch).fundecl -> bool

    (* Function prologues *)
    val prologue_required : Mach_type.Make(Arch).fundecl -> bool

    (** For a given register class, the DWARF register numbering for that class.
        Given an allocated register with location [Reg n] and class [reg_class], the
        returned array contains the corresponding DWARF register number at index
        [n - first_available_register.(reg_class)]. *)
    val dwarf_register_numbers : reg_class:int -> int array

    (** The DWARF register number corresponding to the stack pointer. *)
    val stack_ptr_dwarf_register_number : int

    (* Calling the assembler *)
    val assemble_file: string -> string -> int

    (* Called before translating a fundecl. *)
    val init : unit -> unit

  end

  (* Common subexpression elimination by value numbering over extended
     basic blocks. *)
  [@@@ocaml.warning "-67"]
  module CSE : functor (CSE : CSE_type.S with module Arch := Arch) -> sig
    val fundecl: Mach_type.Make(Arch).fundecl -> Mach_type.Make(Arch).fundecl
  end


  (* Selection of pseudo-instructions, assignment of pseudo-registers,
     sequentialization. *)
  [@@@ocaml.warning "-67"]
  module Selection : functor (S : Selector.S with module Arch := Arch) -> sig
    val fundecl: Cmm.fundecl -> Mach_type.Make(Arch).fundecl
  end

  (* Insert load/stores for pseudoregs that got assigned to stack locations. *)
  [@@@ocaml.warning "-67"]
  module Reload : functor (S : Reload_type.S with module Arch := Arch) -> sig
    val fundecl:
      Mach_type.Make(Arch).fundecl -> int array ->
      Mach_type.Make(Arch).fundecl * bool
  end

  (* Instruction scheduling *)
  [@@@ocaml.warning "-67"]
  module Scheduling : functor (S : Scheduler.S with module Arch := Arch) -> sig
    val fundecl: Linear_type.Make(Arch).fundecl -> Linear_type.Make(Arch).fundecl
  end

  (* Generation of assembly code *)
  [@@@ocaml.warning "-67"]
  module Emit : functor
    (Emit_param : sig
       module Mach : Mach_type.S with module Arch := Arch
       module Linear : Linear_type.S with module Arch := Arch
     end) -> sig

    module Emitaux : Emitaux.S

    val fundecl: Emit_param.Linear.fundecl -> unit
    val data: Cmm.data_item list -> unit
    val begin_assembly: Compilation_unit.t -> unit
    val end_assembly: Compilation_unit.t -> unit

  end

end
