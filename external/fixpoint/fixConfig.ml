(*
 * Copyright © 2009 The Regents of the University of California. All rights reserved. 
 *
 * Permission is hereby granted, without written agreement and without 
 * license or royalty fees, to use, copy, modify, and distribute this 
 * software and its documentation for any purpose, provided that the 
 * above copyright notice and the following two paragraphs appear in 
 * all copies of this software. 
 * 
 * IN NO EVENT SHALL THE UNIVERSITY OF CALIFORNIA BE LIABLE TO ANY PARTY 
 * FOR DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES 
 * ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN 
 * IF THE UNIVERSITY OF CALIFORNIA HAS BEEN ADVISED OF THE POSSIBILITY 
 * OF SUCH DAMAGE. 
 * 
 * THE UNIVERSITY OF CALIFORNIA SPECIFICALLY DISCLAIMS ANY WARRANTIES, 
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY 
 * AND FITNESS FOR A PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS 
 * ON AN "AS IS" BASIS, AND THE UNIVERSITY OF CALIFORNIA HAS NO OBLIGATION 
 * TO PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 *)

module Sy  = Ast.Symbol
module SM  = Sy.SMap
module Q   = Qualifier
module C   = FixConstraint
module So  = Ast.Sort
module Co  = Constants

module Misc = FixMisc open Misc.Ops

exception UnmappedKvar of Ast.Symbol.t

let mydebug  = false 

type qbind   = Q.t list

type solbind = Ast.Symbol.t * ((Ast.Symbol.t * (Ast.expr list)) list)

type deft = Srt of Ast.Sort.t 
          | Axm of Ast.pred 
          | Cst of FixConstraint.t
          | Wfc of FixConstraint.wf
          | Con of Ast.Symbol.t * Ast.Sort.t
          | Sol of solbind
          (* | Sol of Ast.Symbol.t * (Ast.pred * (Ast.Symbol.t * Ast.Subst.t)) list *)
          | Qul of Q.t
          | Dep of FixConstraint.dep
          | Deps of (int*int)
          | Kut of Ast.Symbol.t
          | Neg of Ast.Symbol.t
          | IBind of int * Ast.Symbol.t * FixConstraint.reft  

type 'bind cfg = { 
   a      : int                               (* Tag arity                            *)
 ; ts     : Ast.Sort.t list                   (* New sorts, now = []                  *)
 ; ps     : Ast.pred list                     (* New axioms, now = []                 *)
 ; cs     : FixConstraint.t list              (* Implication Constraints              *)
 ; ws     : FixConstraint.wf list             (* Well-formedness Constraints          *)
 ; ds     : FixConstraint.dep list            (* Constraint Dependencies              *)
 ; qs     : Q.t list                          (* Qualifiers                           *)
 ; kuts   : Ast.Symbol.t list                 (* "Cut"-Kvars, which break cycles      *)
 ; deps   : (int*int) list                 (* "Cut"-Kvars, which break cycles      *)
 ; negs   : Ast.Symbol.t list                 (* Negative k variables                 *)
 ; bm     : 'bind SM.t                        (* Initial Sol Bindings                 *)
 ; uops   : Ast.Sort.t Ast.Symbol.SMap.t      (* Globals: measures + distinct consts) *)
 ; cons   : Ast.Symbol.t list                 (* Distinct Constants, defined in uops  *)
 ; assm   : FixConstraint.soln                (* Seed Solution -- must be a fixpoint over constraints *)
}

let get_arity = function
  | []   -> Constants.bprintflush mydebug "WARNING: NO CONSTRAINTS!"; 0
  | c::_ -> c |> FixConstraint.tag_of_t |> fst |> List.length

let sift_quals qs = 
  qs >> (fun _ -> Co.bprintflush mydebug "BEGIN: Q.normalize\n")
     |> Q.normalize 
     (* >> (Format.printf "Normalized Quals: \n%a" (Misc.pprint_many true "\n" Q.print)) *)
     >> (fun _ -> Co.bprintflush mydebug "DONE: Q.normalize\n")
     |> Misc.map (Misc.pad_fst Q.name_of_t)
     |> SM.of_list

let extend f cfg = function
  | Srt t         -> {cfg with ts   = t     :: cfg.ts   }
  | Axm p         -> {cfg with ps   = p     :: cfg.ps   }
  | Cst c         -> {cfg with cs   = c     :: cfg.cs   }
  | Wfc w         -> {cfg with ws   = w     :: cfg.ws   }
  | Dep d         -> {cfg with ds   = d     :: cfg.ds   }
  | Kut k         -> {cfg with kuts = k     :: cfg.kuts }
  | Deps d        -> {cfg with deps = d     :: cfg.deps }
  | Neg n         -> {cfg with negs = n     :: cfg.negs }
  | Qul q         -> {cfg with qs   = q     :: cfg.qs   }
  | Sol (k, fess) -> {cfg with bm   = SM.add k (List.map f fess) cfg.bm  }
  | Con (s,t)     -> {cfg with cons = if So.is_func t then cfg.cons else s :: cfg.cons
                             ; uops = SM.add s t cfg.uops} 
  | IBind _       -> cfg 


let empty = 
  { a      = 0 
  ; ts     = []
  ; ps     = []
  ; cs     = []
  ; ws     = []
  ; ds     = []
  ; qs     = []
  ; deps   = []
  ; kuts   = []
  ; negs   = []
  ; bm     = SM.empty
  ; cons   = []
  ; uops   = SM.empty 
  ; assm   = FixConstraint.empty_solution 
  }

let fes2q qm (f, es) =
  let q   = SM.safeFind f qm "name2qual" in
  q |> Q.all_params_of_t
    |> List.map fst 
    |> Misc.flip (Misc.combine "FixConfig.fes2q") es
    |> Q.inst q 

let normalize_defts ds =
  let qs, ds' = Misc.either_partition begin function 
                  | Qul q -> Left q
                  | d     -> Right d
                end ds                            in
  let qm      = sift_quals qs                     in
  let ds''    = qm |>  SM.range 
                   |>: (fun q -> Qul q)
                   |>  (++) ds'                   in
  (qm, ds'')

(* API *)
let create ds =
  let qm, ds' = normalize_defts ds in
  ds' |> List.fold_left (extend (fes2q qm)) empty
      |> (fun cfg -> {cfg with a  = get_arity cfg.cs})
      |> (fun cfg -> {cfg with ws = C.add_wf_ids cfg.ws})

(* API *)
let create_raw ts env ps a ds cs ws qs kuts negs assm = 
  { empty with 
    a     = a
  ; ts    = ts
  ; uops  = env
  ; ps    = ps
  ; ds    = ds
  ; cs    = cs
  ; ws    = C.add_wf_ids ws
  ; kuts  = kuts
  ; negs  = negs
  ; qs    = Q.normalize qs 
  ; assm  = assm
  }

module type SIMPLIFIER = sig
  val simplify_ts: FixConstraint.t list -> FixConstraint.t list
end


(* type t = Ast.Qualifier.def list list cfg *)

let print ppf me =
  (* Print cs *)
  Format.fprintf ppf "@[%a@] \n" (Misc.pprint_many true "\n" (C.print_t None)) me.cs;
  (* Print ws *)
  Format.fprintf ppf "@[%a@] \n" (Misc.pprint_many true "\n" (C.print_wf None)) me.ws;
  (* Print qs *)
  Format.fprintf ppf "@[%a@] \n" (Misc.pprint_many true "\n" Q.print) (Q.normalize me.qs)

