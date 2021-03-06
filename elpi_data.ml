(* elpi: embedded lambda prolog interpreter                                  *)
(* license: GNU Lesser General Public License Version 2.1                    *)
(* ------------------------------------------------------------------------- *)

(* Internal term representation *)

module Fmt = Format
module F = Elpi_ast.Func
open Elpi_util

module IM = Map.Make(struct type t = int let compare x y = x - y end)

let { CData.cin = in_float; isc = is_float; cout = out_float } as cfloat =
  CData.(declare {
    data_name = "float";
    data_pp = (fun f x -> Fmt.fprintf f "%f" x);
    data_eq = (==);
    data_hash = Hashtbl.hash;
  })
let { CData.cin = in_int; isc = is_int; cout = out_int } as cint =
  CData.(declare {
    data_name = "int";
    data_pp = (fun f x -> Fmt.fprintf f "%d" x);
    data_eq = (==);
    data_hash = Hashtbl.hash;
  })
let { CData.cin = in_string; isc = is_string; cout = out_string } as cstring =
  CData.(declare {
    data_name = "string";
    data_pp = (fun f x -> Fmt.fprintf f "\"%s\"" (F.show x));
    data_eq = (==);
    data_hash = Hashtbl.hash;
  })
let { CData.cin = in_loc; isc = is_loc; cout = out_loc } as cloc =
  CData.(declare {
    data_name = "loc";
    data_pp = (fun f (x,name) ->
      let bname = Filename.basename (Ploc.file_name x) in
      let line_no = Ploc.line_nb x in
      match name with
      | None -> Fmt.fprintf f "%s:%4d:" bname line_no 
      | Some name -> Fmt.fprintf f "%s:%4d:%s:" bname line_no name);
    data_eq = (==);
    data_hash = Hashtbl.hash;
  })

(******************************************************************************
  Terms: data type definition and printing
 ******************************************************************************)

(* To break circularity, we open the index type (index of clauses) here
 * and extend it with the Index constructor when such data type will be
 * defined.  The same for chr with CHR.t *)
type prolog_prog = ..
let pp_prolog_prog = mk_extensible_printer ()
type chr = ..
let pp_chr = mk_extensible_printer ()

(* Used by pretty printers, to be later instantiated in module Constants *)
let pp_const = mk_extensible_printer ()
type constant = int (* De Bruijn levels *)
[@printer (pp_extensible pp_const)]
[@@deriving show, eq]

(* To be instantiated after the dummy term is defined *)
let pp_oref = mk_extensible_printer ()

(* Invariant: a Heap term never points to a Query term *)
let id_term = UUID.make ()
type term =
  (* Pure terms *)
  | Const of constant
  | Lam of term
  | App of constant * term * term list
  (* Clause terms: unif variables used in clauses *)
  | Arg of (*id:*)int * (*argsno:*)int
  | AppArg of (*id*)int * term list
  (* Heap terms: unif variables in the query *)
  | UVar of term_attributed_ref * (*depth:*)int * (*argsno:*)int
  | AppUVar of term_attributed_ref * (*depth:*)int * term list
  (* Misc: $custom predicates, ... *)
  | Custom of constant * term list
  | CData of CData.t
  (* Optimizations *)
  | Cons of term * term
  | Nil
and term_attributed_ref = {
  mutable contents : term [@printer (pp_extensible_any ~id:id_term pp_oref)];
  mutable rest : stuck_goal list [@printer fun _ _ -> ()]
                                 [@equal fun _ _ -> true];
}
and stuck_goal = {
  mutable blockers : term_attributed_ref list;
  kind : stuck_goal_kind;
}
and stuck_goal_kind =
 | Constraint of constraint_def (* inline record in 4.03 *)
 | Unification of unification_def 
and unification_def = {
  adepth : int;
  env : term array;
  bdepth : int;
  a : term;
  b : term;
}
and constraint_def = {
  depth : int;
  prog : prolog_prog [@equal fun _ _ -> true]
               [@printer (pp_extensible pp_prolog_prog)];
  pdiff : (int * term) list;
  goal : term;
}
[@@deriving show, eq]

module CD = struct
  let is_int = is_int
  let to_int = out_int
  let of_int x = CData (in_int x)

  let is_float = is_float
  let to_float = out_float
  let of_float x = CData (in_float x)

  let is_string = is_string
  let to_string x = F.show (out_string x)
  let of_string x = CData (in_string (F.from_string x))
end

let destConst = function Const x -> x | _ -> assert false

(* Our ref data type: creation and dereference.  Assignment is defined
   After the constraint store, since assigning may wake up some constraints *)
let oref x = { contents = x; rest = [] }
let (!!) { contents = x } = x

(* Arg/AppArg point to environments, here the empty one *)
type env = term array
let empty_env = [||]

(* - negative constants are global names
   - constants are hashconsed (terms)
   - we use special constants to represent !, pi, sigma *)
module Constants : sig

  val funct_of_ast : F.t -> constant * term
  val of_dbl : constant -> term
  val show : constant -> string
  val pp : Format.formatter -> constant -> unit
  val fresh : unit -> constant * term
  val from_string : string -> term
  val from_stringc : string -> constant
 
  (* To keep the type of terms small, we use special constants for !, =, pi.. *)
  (* {{{ *)
  val cutc   : term
  val truec  : term
  val andc   : constant
  val andt   : term
  val andc2  : constant
  val orc    : constant
  val implc  : constant
  val rimplc  : constant
  val rimpl  : term
  val pic    : constant
  val pi    : term
  val sigmac : constant
  val eqc    : constant
  val rulec : constant
  val cons : term
  val consc : constant
  val nil : term
  val nilc : constant
  val entailsc : constant
  val nablac : constant
  val uvc : constant
  val asc : constant
  val letc : constant
  val arrowc : constant

  val ctypec : constant

  val spillc : constant
  (* }}} *)

  (* Value for unassigned UVar/Arg *)
  val dummy  : term

  type t = constant
  val compare : t -> t -> int

  module Set : Set.S with type elt = t
  module Map : Map.S with type key = t

  (* mkinterval d n 0 = [d; ...; d+n-1] *)
  val mkinterval : int -> int -> int -> term list

end = struct (* {{{ *)

(* Hash re-consing :-( *)
let funct_of_ast, of_dbl, show, fresh =
 let h = Hashtbl.create 37 in
 let h' = Hashtbl.create 37 in
 let h'' = Hashtbl.create 17 in
 let fresh = ref 0 in
 (function x ->
  try Hashtbl.find h x
  with Not_found ->
   decr fresh;
   let n = !fresh in
   let xx = Const n in
   let p = n,xx in
   Hashtbl.add h' n (F.show x);
   Hashtbl.add h'' n xx;
   Hashtbl.add h x p; p),
 (function x ->
  try Hashtbl.find h'' x
  with Not_found ->
   let xx = Const x in
   Hashtbl.add h' x ("x" ^ string_of_int x);
   Hashtbl.add h'' x xx; xx),
 (function n ->
   try Hashtbl.find h' n
   with Not_found -> string_of_int n),
 (fun () ->
   decr fresh;
   let n = !fresh in
   let xx = Const n in
   Hashtbl.add h' n ("frozen-"^string_of_int n);
   Hashtbl.add h'' n xx;
   n,xx)
;;

let pp fmt c = Format.fprintf fmt "%s" (show c)

let from_stringc s = fst (funct_of_ast F.(from_string s))
let from_string s = snd (funct_of_ast F.(from_string s))

let cutc = snd (funct_of_ast F.cutf)
let truec = snd (funct_of_ast F.truef)
let andc, andt = funct_of_ast F.andf
let andc2 = fst (funct_of_ast F.andf2)
let orc = fst (funct_of_ast F.orf)
let implc = fst (funct_of_ast F.implf)
let rimplc, rimpl = funct_of_ast F.rimplf
let pic, pi = funct_of_ast F.pif
let sigmac = fst (funct_of_ast F.sigmaf)
let eqc = fst (funct_of_ast F.eqf)
let rulec = fst (funct_of_ast (F.from_string "rule"))
let nilc, nil = (funct_of_ast F.nilf)
let consc, cons = (funct_of_ast F.consf)
let nablac = fst (funct_of_ast (F.from_string "nabla"))
let entailsc = fst (funct_of_ast (F.from_string "?-"))
let uvc = fst (funct_of_ast (F.from_string "??"))
let asc = fst (funct_of_ast (F.from_string "as"))
let letc = fst (funct_of_ast (F.from_string ":="))
let spillc = fst (funct_of_ast (F.spillf))
let arrowc = fst (funct_of_ast F.arrowf)
let ctypec = fst (funct_of_ast F.ctypef)

let dummy = App (-9999,cutc,[])

module Self = struct
  type t = constant
  let compare x y = x - y
end

module Map = Map.Make(Self)
module Set = Set.Make(Self)

include Self

let () = extend_printer pp_const (fun fmt i ->
  Fmt.fprintf fmt "%s" (show i);
  `Printed)

(* mkinterval d n 0 = [d; ...; d+n-1] *)
let rec mkinterval depth argsno n =
 if n = argsno then []
 else of_dbl (n+depth)::mkinterval depth argsno (n+1)
;;

end (* }}} *)
module C = Constants

module CHR : sig

  (* a set of rules *)
  type t

  (* a set of predicates contributing to represent a constraint *)
  type clique 

  type rule = (term, int) Elpi_ast.chr

  val empty : t

  val new_clique : constant list -> t -> t * clique
  val clique_of : constant -> t -> C.Set.t
  val add_rule : clique -> rule -> t -> t
  
  val rules_for : constant -> t -> rule list

  (* to store CHR.t in program *)
  val wrap_chr : t -> chr
  val unwrap_chr : chr -> t

end = struct (* {{{ *)

  type rule = (term, int) Elpi_ast.chr
  type t = { cliques : C.Set.t C.Map.t; rules : rule list C.Map.t }
  type clique = C.Set.t

  type chr += Chr of t
  let () = extend_printer pp_chr (fun fmt -> function
    | Chr c -> Fmt.fprintf fmt "<CHRs>";`Printed
    | _ -> `Passed)
  let wrap_chr x = Chr x
  let unwrap_chr = function Chr x -> x | _ -> assert false

  let empty = { cliques = C.Map.empty; rules = C.Map.empty }

  let new_clique cl ({ cliques } as chr) =
    if cl = [] then error "empty clique";
    let c = List.fold_right C.Set.add cl C.Set.empty in
    if C.Map.exists (fun _ c' -> not (C.Set.is_empty (C.Set.inter c c'))) cliques then
            error "overlapping constraint cliques";
    let cliques =
      List.fold_right (fun x cliques -> C.Map.add x c cliques) cl cliques in
    { chr with cliques }, c

  let clique_of c { cliques } =
    try C.Map.find c cliques with Not_found -> C.Set.empty

  let add_rule cl r ({ rules } as chr) =
    let rules = C.Set.fold (fun c rules ->
      try      
        let rs = C.Map.find c rules in
        C.Map.add c (rs @ [r]) rules
      with Not_found -> C.Map.add c [r] rules)
      cl rules in
    { chr with rules }


  let rules_for c { rules } =
    try C.Map.find c rules
    with Not_found -> []

end (* }}} *)

module CustomConstraints : sig
    type 'a constraint_type

    (* Must be purely functional *)
    val declare_constraint :
      name:string ->
      pp:(Fmt.formatter -> 'a -> unit) ->
      empty:'a ->
        'a constraint_type

     
    type state = Obj.t IM.t
    val update : state ref -> 'a constraint_type -> ('a -> 'a) -> unit
    val read : state ref -> 'a constraint_type -> 'a
  end = struct
    type 'a constraint_type = int
    type state = Obj.t IM.t
  let custom_constraints_declarations = ref IM.empty

    let cid = ref 0
    let declare_constraint ~name ~pp ~empty =
      incr cid;
      custom_constraints_declarations :=
        IM.add !cid (name,Obj.repr pp, Obj.repr empty) !custom_constraints_declarations;
      !cid

    let find custom_constraints id =
      try IM.find id !custom_constraints
      with Not_found ->
        let _, _, init = IM.find id !custom_constraints_declarations in
        init

    let update custom_constraints id f =
      custom_constraints :=
        IM.add id (Obj.repr (f (Obj.obj (find custom_constraints id)))) !custom_constraints
    let read custom_constraints id = Obj.obj (find custom_constraints id)
  end

(* true=input, false=output *)
type mode = bool list [@@deriving show]

module TwoMapIndexingTypes = struct (* {{{ *)

type key1 = int
type key2 = int
type key = key1 * key2

type clause = {
    depth : int;
    args : term list;
    hyps : term list;
    vars : int;
    key : key;
    mode: mode;
  }

type idx = {
  src : (int * term) list;
  map : (clause list * clause list * clause list Elpi_ptmap.t) Elpi_ptmap.t
}

end (* }}} *)

module UnifBitsTypes = struct (* {{{ *)

  type key = int

  type clause = {
    depth : int;
    args : term list;
    hyps : term list;
    vars : int;
    key : key;
    mode: mode;
  }

  type idx = {
    src : (int * term) list;
    map : (clause * int) list Elpi_ptmap.t  (* timestamp *)
  }

end (* }}} *)

type idx = TwoMapIndexingTypes.idx
type key = TwoMapIndexingTypes.key
type clause = TwoMapIndexingTypes.clause = {
  depth : int;
  args : term list;
  hyps : term list;
  vars : int;
  key : key;
  mode : mode;
}

type mode_decl =
  | Mono of mode
  | Multi of (constant * (constant * constant) list) list

(* An elpi program, as parsed.  But for idx and query_depth that are threaded
   around in the main loop, chr and modes are globally stored in Constraints
   and Clausify. *)
type clause_w_info = {
  clloc : CData.t;
  clargsname : string list;
  clbody : clause;
}

let drop_clause_info { clbody } = clbody

type program = {
  (* n of sigma/local-introduced variables *)
  query_depth : int;
  (* the lambda-Prolog program: an indexed list of clauses *) 
  prolog_program : prolog_prog [@printer (pp_extensible pp_prolog_prog)];
  (* constraint handling rules *)
  chr : chr [@printer (pp_extensible pp_chr)];
  modes : mode_decl C.Map.t; 

  (* extra stuff, for typing & pretty printing *)
  declared_types : (constant * int * term) list; (* name, nARGS, type *)
  clauses_w_info : clause_w_info list
}
type query = Ploc.t * string list * int * env * term

type prolog_prog += Index of idx
let () = extend_printer pp_prolog_prog (fun fmt -> function
  | Index _ -> Fmt.fprintf fmt "<prolog_prog>";`Printed
  | _ -> `Passed)
let wrap_prolog_prog x = Index x
let unwrap_prolog_prog = function Index x -> x | _ -> assert false

exception No_clause

(* vim: set foldmethod=marker: *)
