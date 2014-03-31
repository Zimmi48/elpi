let debug = false
(* Immutable array *)

module IA = struct

  include BIA

  let append v1 v2 =
    let len1 = BIA.len v1 in
    BIA.init (len1 + BIA.len v2)
      (fun i -> if i < len1 then BIA.get i v1 else BIA.get (i-len1) v2)

  let cons t v =
    BIA.init (BIA.len v+1) (fun i -> if i = 0 then t else BIA.get (i-1) v)

end

(* External, user defined, datatypes *)
module C : sig

  type t
  type ty
  type data = {
    t : t;
    ty : ty;
  }

  val declare : ('a -> string) -> ('a -> 'a -> bool) -> 'a -> data
  
  val print : data -> string
  val equal : data -> data -> bool

end = struct (* {{{ *)

type t = Obj.t
type ty = int

type data = {
  t : Obj.t;
  ty : int
}

module M = Int.Map
let m : ((data -> string) * (data -> data -> bool)) M.t ref = ref M.empty

let cget x = Obj.obj x.t
let print x = fst (M.find x.ty !m) x
let equal x y = x.ty = y.ty && snd (M.find x.ty !m) x y

let fresh_tid =
  let tid = ref 0 in
  fun () -> incr tid; !tid

let declare print cmp =
  let tid = fresh_tid () in
  m := M.add tid ((fun x -> print (cget x)),
                  (fun x y -> cmp (cget x) (cget y))) !m;
  fun v -> { t = Obj.repr v; ty = tid }

end (* }}} *)

let on_buffer f x =
  let b = Buffer.create 1024 in
  let fmt = Format.formatter_of_buffer b in
  f fmt x;
  Format.pp_print_flush fmt ();
  Buffer.contents b

module LP = struct

type var = int
type level = int
type name = string
type arity = int

type data =
  | Uv of var * level * arity
  | Con of name * level
  | DB of int
  | Bin of int * data
  | Tup of data IA.t
  | Ext of C.data

let pr_cst x = x
let pr_var x = "X" ^ string_of_int x


let mkApp t v start stop =
  if start = stop then t else
  match t with
  | Tup xs -> Tup(IA.append xs (IA.sub start (stop-start) v))
  | _ -> Tup(IA.cons t (IA.sub start (stop-start) v))

let fixTup xs =
  match IA.get 0 xs with
  | Tup ys -> Tup (IA.append ys (IA.tl xs))
  | _ -> Tup xs

let rec equal a b = match a,b with
 | Uv (x,_,_), Uv (y,_,_) -> x = y
 | Con (x,_), Con (y,_) -> x = y
 | DB x, DB y -> x = y
 | Bin (n1,x), Bin (n2,y) -> n1 = n2 && equal x y
 | Tup xs, Tup ys -> IA.for_all2 equal xs ys
 | Ext x, Ext y -> C.equal x y
 | _ -> false

let rec fresh_names k = function
  | 0 -> []
  | n -> ("w" ^ string_of_int k) :: fresh_names (k+1) (n-1)

let rec iter_sep spc pp = function
  | [] -> ()
  | [x] -> pp x
  | x::tl -> pp x; spc (); iter_sep spc pp tl

let isBin = function Bin _ -> true | _ -> false

let printf ctx fmt t =
  let module P = Format in
  let rec print ?(pars=false) ctx = function
    | Bin (n,x) ->
       P.pp_open_hovbox fmt 2;
       let names = fresh_names (List.length ctx) n in
       if pars then P.pp_print_string fmt "(";
       P.pp_print_string fmt (String.concat "\\ " names ^ "\\");
       P.pp_print_space fmt ();
       print (List.rev names @ ctx) x;
       if pars then P.pp_print_string fmt ")";
       P.pp_close_box fmt ()
    | DB x -> P.pp_print_string fmt 
        (try (if debug then "'" else "") ^List.nth ctx (x-1)
        with Failure _ | Invalid_argument _ ->
          "_" ^ string_of_int (x-List.length ctx))
    | Con (x,_) -> P.pp_print_string fmt (pr_cst x)
    | Uv (x,lvl,a) ->
        P.pp_print_string fmt
          (pr_var x ^ (if debug then Printf.sprintf "(%d)" lvl else ""))
    | Tup xs ->
        P.pp_open_hovbox fmt 2;
        if pars then P.pp_print_string fmt "(";
        iter_sep (P.pp_print_space fmt) (print ~pars:true ctx) (IA.to_list xs);
        if pars then P.pp_print_string fmt ")";
        P.pp_close_box fmt ()
    | Ext x ->
        P.pp_open_hbox fmt ();
        P.pp_print_string fmt (C.print x);
        P.pp_close_box fmt ()
  in
    print ctx t
let print ?(ctx=[]) t = on_buffer (printf ctx) t


let rec fold f x a = match x with
  | (DB _ | Con _ | Uv _ | Ext _) as x -> f x a
  | Bin (_,x) -> fold f x a
  | Tup xs -> IA.fold (fold f) xs a

let rec map f = function
  | (DB _ | Con _ | Uv _ | Ext _) as x -> f x
  | Bin (ns,x) -> Bin(ns, map f x)
  | Tup xs -> Tup(IA.map (map f) xs)

let max_uv x a = match x with Uv (i,_,_) -> max a i | _ -> a

let rec fold_map f x a = match x with
  | (DB _ | Con _ | Uv _ | Ext _) as x -> f x a
  | Bin (n,x) -> let x, a = fold_map f x a in Bin(n,x), a
  | Tup xs -> let xs, a = IA.fold_map (fold_map f) xs a in Tup xs, a
 
(* PROGRAM *)
type program = clause list
and clause = int * head * premise list (* level, maxuv, head, premises *)
and head = data
and premise =
  | Atom of data
  | Impl of data * premise
  | Pi of name * premise
and goal = premise

let rec map_premise f = function
  | Atom x -> Atom(f x)
  | Impl(x,y) -> Impl(f x, map_premise f y)
  | Pi(n,x) -> Pi(n, map_premise f x)

let rec fold_premise f x a = match x with
  | Atom x -> f x a
  | Impl(x,y) -> fold_premise f y (f x a)
  | Pi(_,x) -> fold_premise f x a

let rec fold_map_premise f p a = match p with
  | Atom x -> let x, a = f x a in Atom x, a
  | Impl(x,y) -> let x, a = f x a in
                 let y, a = fold_map_premise f y a in
                 Impl(x,y), a
  | Pi(n,y) -> let y, a = fold_map_premise f y a in Pi(n, y), a

let rec ident = lexer [ [ 'a'-'z' | '\'' | '_' ] ident | ]

let tok = lexer
  [ [ 'A'-'Z' ] ident -> "UVAR", $buf 
  | [ 'a'-'z' ] ident -> "CONSTANT", $buf
  | [ ":-" ] -> "ENTAILS",$buf
  | [ ',' ] -> "COMMA",","
  | [ '.' ] -> "FULLSTOP","."
  | [ '\\' ] -> "BIND","\\"
  | [ '/' ] -> "BIND","/"
  | [ '(' ] -> "LPAREN","("
  | [ ')' ] -> "RPAREN",")"
  | [ "==>" ] -> "IMPL","==>"
]

let spy f s = if debug then begin
  Printf.eprintf "<- %s\n"
    (match Stream.peek s with None -> "EOF" | Some x -> String.make 1 x);
  let t, v as tok = f s in
  Printf.eprintf "-> %s = %s\n" t v;
  tok
  end else f s

let rec foo c = parser
  | [< ' ( ' ' | '\n' ); s >] -> foo c s
  | [< '( '%' ); s >] -> comment c s
  | [< s >] ->
       match spy (tok c) s with
       | "CONSTANT","pi" -> "PI", "pi"
       | x -> x
and comment c = parser
  | [< '( '\n' ); s >] -> foo c s
  | [< '_ ; s >] -> comment c s

open Plexing

let lex_fun s =
  (Stream.from (fun _ -> Some (foo Lexbuf.empty s))), (fun _ -> Ploc.dummy)

let tok_match (s1,_) = (); function
  | (s2,v) when s1=s2 ->
      if debug then Printf.eprintf "%s = %s = %s\n" s1 s2 v;
      v
  | (s2,v) ->
      if debug then Printf.eprintf "%s <> %s = %s\n" s1 s2 v;
      raise Stream.Failure

let lex = {
  tok_func = lex_fun;
  tok_using = (fun _ -> ());
  tok_removing = (fun _ -> ());
  tok_match = tok_match;
  tok_text = (function (s,_) -> s);
  tok_comm = None;
}

let g = Grammar.gcreate lex
let lp = Grammar.Entry.create g "lp"
let goal = Grammar.Entry.create g "goal"

let uvmap = ref []
let reset () = uvmap := []
let top_uv () = List.length !uvmap

let get_uv u =
  if List.mem_assoc u !uvmap then List.assoc u !uvmap
  else
    let n = List.length !uvmap in
    uvmap := (u,n) :: !uvmap;
    n

let rec binders c n = function
    | Con(c',_) when c = c' -> DB n
    | (Con _ | Uv _ | Ext _ | DB _) as x -> x
    | Bin(w,t) -> Bin(w,binders c (n+w) t)
    | Tup xs -> Tup (IA.map (binders c n) xs)
and binders_premise c n = function
    | Pi(c,t) -> Pi(c,binders_premise c (n+1) t)
    | Atom t -> Atom(binders c n t)
    | Impl(a,t) -> Impl(binders c n a, binders_premise c n t)

EXTEND
  GLOBAL: lp goal;
  lp: [ [ cl = LIST1 clause -> cl ] ];
  goal : [ [ g = atom; FULLSTOP -> Atom g ] ];
  clause :
    [ [ hd = atom;
        hyps =
          [ ENTAILS; hyps = LIST1 premise SEP COMMA; FULLSTOP -> hyps
          | FULLSTOP -> [] ] ->
              let top = top_uv () in reset ();
              top, hd, hyps ] ];
  atom :
    [ "1"
      [ hd = atom LEVEL "2"; args = LIST0 atom LEVEL "2" ->
          if args = [] then hd else Tup (IA.of_list (hd :: args)) ]
    | "2" 
      [ [ c = CONSTANT; b = OPT [ BIND; a = atom LEVEL "1" -> a ] ->
          match b with
          | None -> Con(c,0)
          | Some b ->  Bin(1,binders c 1 b) ]
      | [ u = UVAR -> Uv(get_uv u,0,0) ]
      | [ LPAREN; a = atom LEVEL "1"; RPAREN -> a ] ]
    ];
  premise :
    [ [ a = atom; next = OPT [ IMPL; p = premise -> p ] ->
         match next with
         | None -> Atom a
         | Some p -> Impl (a,p) ]
    | [ PI; c = CONSTANT; BIND; p = premise -> Pi(c, binders_premise c 1 p) ]
    ];
END

let parse_program s : program =  
  reset ();
  Grammar.Entry.parse lp (Stream.of_string s)

let parse_goal s : goal =  
  reset ();
  Grammar.Entry.parse goal (Stream.of_string s)

let rec print_premisef ctx fmt = function
  | Atom p -> printf ctx fmt p
  | Pi (x,p) ->
       Format.pp_open_hvbox fmt 2;
       Format.pp_print_string fmt ("pi "^x^"\\");
       Format.pp_print_space fmt ();
       print_premisef (x::ctx) fmt p;
       Format.pp_close_box fmt ()
  | Impl (x,p) ->
       Format.pp_open_hvbox fmt 2;
       printf ctx fmt x;
       Format.pp_print_space fmt ();
       Format.pp_open_hovbox fmt 0;
       Format.pp_print_string fmt "==> ";
       print_premisef ctx fmt p;
       Format.pp_close_box fmt ();
       Format.pp_close_box fmt ()
let print_premise p = on_buffer (print_premisef []) p
let print_goal = print_premise
let print_goalf = print_premisef []

let print_head = print

let print_clausef fmt (_, hd, hyps) =
  Format.pp_open_hvbox fmt 2;
  printf [] fmt hd;
  if hyps <> [] then begin
    Format.pp_print_space fmt ();
    Format.pp_print_string fmt ":- ";
  end;
  Format.pp_open_hovbox fmt 0;
  iter_sep
    (fun () -> Format.pp_print_string fmt ",";Format.pp_print_space fmt ())
    (print_premisef [] fmt) hyps;
  Format.pp_print_string fmt ".";
  Format.pp_close_box fmt ();
  Format.pp_close_box fmt ()

let print_clause c = on_buffer print_clausef c

let print_programf fmt p =
  Format.pp_open_vbox fmt 0;
  iter_sep (Format.pp_print_space fmt) (print_clausef fmt) p;
  Format.pp_close_box fmt ()
let print_program p = on_buffer print_programf p

end

(* vim:set foldmethod=marker: *)