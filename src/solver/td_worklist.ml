(** top-down solver with side effects and a work list of solver tasks ([td_worklist]). *)

(** Equivalently either
  * - An extension of [td_simplified_ref] with a worklist of top-level tasks
  * - A single-threaded version of [td_parallel_base]
*)

open Batteries
open Goblint_constraint.ConstrSys
open Goblint_constraint.SolverTypes
open Goblint_constraint.Translators
open Messages

(** Seed for the next solve with td_worklist_random, instead of solvers.td_worklist.random_seed.
    Set by comparesolvers, which solves with several random orders in one run, where the configuration cannot change. *)
let random_seed_override: int option ref = ref None

(** What the solver knows about a root unknown when it adds it to the work list. *)
type info = {
  invalidations: int; (** How often the root has been destabilized so far *)
  depth: int;         (** Creation depth: 0 for the start unknowns, otherwise 1 + the depth of the root
                          whose task first created it. Only collected if [need_depth], 0 otherwise. *)
  last_cost: int;     (** Right-hand side evaluations of the last task of the root, 0 if it has not run yet.
                          Only collected if [need_cost], 0 otherwise. *)
}

(** The data that is only collected if the heuristic needs it: fields of [info] and of [context]. *)
type needs = {
  need_depth: bool;
  need_cost: bool;
  need_dependencies: bool;
}

let needs_nothing = { need_depth = false; need_cost = false; need_dependencies = false }

(** What the solver knows about the dependencies between roots, for heuristics that need more than [info].
    It may change between calls of [choose]. *)
type 'v context = {
  consumers: 'v -> 'v list;
  (** Roots whose tasks have read a global that the task of the given root has written, without the root itself.
      Only collected if [need_dependencies], [] otherwise. *)
}

(** Work list of root unknowns of solver tasks. *)
module type WorkList =
sig
  type elt
  type t

  (** Which data the solver has to collect for [add] and the context. *)
  val needs: needs

  val create: elt context -> t

  (** Add an element to the work list.
      @@@ duplicates can be removed but need not?
      @param w The work list.
      @param x The element to add.
      @param info What the solver knows about x, see [info] and [needs].
  *)
  val add: t -> elt -> info -> unit

  (** Remove the next element from the work list.
      @param w The work list.
      @return The next element, or [None] if the work list is empty.
  *)
  val choose: t -> elt option
end

(** A work list heuristic, for any kind of unknowns. *)
module type WorkListHeuristic = functor (Var: VarType) -> WorkList with type elt = Var.t


module Lifo: WorkListHeuristic = functor (Var: VarType) ->
struct
  type elt = Var.t
  type t = Var.t Stack.t

  let needs = needs_nothing
  let create _ = Stack.create ()

  let add w x _ = Stack.push x w

  let choose w =
    if Stack.is_empty w then
      None
    else
      Some (Stack.pop w)
end

module Fifo: WorkListHeuristic = functor (Var: VarType) ->
struct
  type elt = Var.t
  type t = Var.t Queue.t

  let needs = needs_nothing
  let create _ = Queue.create ()
  let add w x _ = Queue.push x w
  let choose = Queue.take_opt
end

(** Chooses a uniformly random element, with a different seed in each run. *)
module Random: WorkListHeuristic = functor (Var: VarType) ->
struct
  type elt = Var.t
  type t = { elems: Var.t DynArray.t; rand: Random.State.t }

  let needs = needs_nothing

  let create _ =
    (* The seed is logged, so that an ordering can be traced back to its run (and run again with solvers.td_worklist.random_seed). *)
    let seed = match !random_seed_override, GobConfig.get_int "solvers.td_worklist.random_seed" with
      | Some seed, _ -> seed
      | None, -1 -> Random.State.bits (Random.State.make_self_init ())
      | None, seed -> seed
    in
    Logs.info "td_worklist_random: seed = %d" seed;
    { elems = DynArray.create (); rand = Random.State.make [|seed|] }

  let add w x _ = DynArray.add w.elems x

  let choose w =
    let n = DynArray.length w.elems in
    if n = 0 then
      None
    else (
      let i = Random.State.int w.rand n in
      let x = DynArray.get w.elems i in
      DynArray.set w.elems i (DynArray.last w.elems);
      DynArray.delete_last w.elems;
      Some x
    )
end

(** Chooses an element with the largest ([most = true]) or smallest ([most = false]) [key],
    as it was when the element was added. Ties are broken in LIFO order.
    @param needs The data that [key] uses. *)
module ByKey (P: sig val key: info -> int val most: bool val needs: needs end): WorkListHeuristic = functor (Var: VarType) ->
struct
  type elt = Var.t
  (** Elements by their key; buckets are never empty. *)
  type t = Var.t list Map.Int.t ref

  let needs = P.needs
  let create _ = ref Map.Int.empty

  let add w x info =
    w := Map.Int.modify_def [] (P.key info) (List.cons x) !w

  let choose w =
    match (if P.most then Map.Int.max_binding_opt else Map.Int.min_binding_opt) !w with
    | None -> None
    | Some (_, []) -> assert false
    | Some (n, [x]) -> w := Map.Int.remove n !w; Some x
    | Some (n, x :: xs) -> w := Map.Int.add n xs !w; Some x
end

module MostInvalidated = ByKey (struct let key i = i.invalidations let most = true let needs = needs_nothing end)
module LeastInvalidated = ByKey (struct let key i = i.invalidations let most = false let needs = needs_nothing end)

(** Roots that were created closer to the start unknowns first, e.g. main before the threads it creates. *)
module ShallowestCreated = ByKey (struct let key i = i.depth let most = false let needs = { needs_nothing with need_depth = true } end)

(** The opposite of [ShallowestCreated]: roots that were created further from the start unknowns first,
    e.g. the threads before main, which created them. *)
module DeepestCreated = ByKey (struct let key i = i.depth let most = true let needs = { needs_nothing with need_depth = true } end)

(** Roots whose last task was cheapest first; roots that have not run yet count as cost 0. *)
module CheapestFirst = ByKey (struct let key i = i.last_cost let most = false let needs = { needs_nothing with need_cost = true } end)

(** The opposite of [CheapestFirst]: roots whose last task was costliest first; roots that have not run yet
    count as cost 0, i.e. they come after all roots that have run. *)
module CostliestFirst = ByKey (struct let key i = i.last_cost let most = true let needs = { needs_nothing with need_cost = true } end)

(** Producers before consumers ([producers = true]): chooses a waiting root that no other waiting root can reach in the graph of
    [context.consumers], unless they reach each other (they are in the same cycle). Such a root always exists,
    as "reaches, but is not reached back" is a strict partial order.
    Consumers before producers ([producers = false]), the opposite: chooses a waiting root that reaches no other waiting root
    in that graph, unless they reach each other.
    Ties are broken in FIFO order. A root that is added while it is already waiting keeps its position.
    Each choose costs O(n * (r + e)) for n waiting roots, r roots and e edges in the graph:
    fine for the few roots of thread creations, but a lot for programs with many roots. *)
module ByDependencies (P: sig val producers: bool end): WorkListHeuristic = functor (Var: VarType) ->
struct
  module VH = Hashtbl.Make (Var)
  type elt = Var.t
  type t = {
    waiting: Var.t DynArray.t; (** In the order in which they were added *)
    is_waiting: unit VH.t;
    context: Var.t context;
  }

  let needs = { needs_nothing with need_dependencies = true }
  let create context = { waiting = DynArray.create (); is_waiting = VH.create 10; context }

  let add w x _ =
    if not (VH.mem w.is_waiting x) then (
      VH.replace w.is_waiting x ();
      DynArray.add w.waiting x
    )

  (** The roots that can be reached from x via at least one edge. *)
  let reachable w x =
    let seen = VH.create 10 in
    let rec visit y =
      List.iter (fun z ->
          if not (VH.mem seen z) then (
            VH.replace seen z ();
            visit z
          )
        ) (w.context.consumers y)
    in
    visit x;
    seen

  let choose w =
    let n = DynArray.length w.waiting in
    if n = 0 then
      None
    else (
      let reach = Array.init n (fun i -> reachable w (DynArray.get w.waiting i)) in
      (* Whether root a reaches root b, but b does not reach a back (indices into waiting). *)
      let strictly_reaches a b =
        VH.mem reach.(a) (DynArray.get w.waiting b) && not (VH.mem reach.(b) (DynArray.get w.waiting a))
      in
      (* Whether root i has to wait for another waiting root: for producers first, if another root strictly reaches it
         (produces for it); for consumers first, if it strictly reaches another root (another root consumes from it). *)
      let blocked i =
        let rec check j =
          j < n && ((j <> i && (if P.producers then strictly_reaches j i else strictly_reaches i j)) || check (j + 1))
        in
        check 0
      in
      (* Never runs past the end, as one of the roots is not blocked by any other. *)
      let rec first i =
        if i = n - 1 || not (blocked i) then i else first (i + 1)
      in
      let i = first 0 in
      let x = DynArray.get w.waiting i in
      DynArray.delete w.waiting i;
      VH.remove w.is_waiting x;
      Some x
    )
end

module ProducersFirst = ByDependencies (struct let producers = true end)
module ConsumersFirst = ByDependencies (struct let producers = false end)

(** @param WL The heuristic that decides in which order the tasks are executed. *)
module Base (WL: WorkListHeuristic) : DemandEqSolver =
  functor (S: DemandEqConstrSys) ->
  functor (HM: Hashtbl.S with type key = S.v) ->
  struct
    open SolverBox.Warrow (S.Dom)
    include Generic.SolverStats (EqConstrSysFromDemandConstrSys (S)) (HM)
    module VS = Set.Make (S.Var)
    module Work = WL (S.Var)

    (** State for each unknown. *)
    type var_data = {
      value: S.Dom.t;
      infl: VS.t;      (** Unknowns influenced by this unknown *)
      wpoint: bool;    (** Unknown is a widening point *)
      stable: bool;    (** Unknown is stable, i.e. its value is known unless its dependencies change *)
      called: bool;    (** Unknown is currently being solved *)
      top_level: bool; (** Unknown is the root of a solver task *)
      invalidations: int; (** How often the unknown has been destabilized *)
    }

    let solve st vs =
      let (data : var_data ref HM.t) = HM.create 10 in

      (** Calls to query (~eval in td3) and iterate, as a proxy for how much work the solver does.
          Logged at the end, in the format that scripts/solver_work.sh parses. *)
      let eval_calls = ref 0 in
      let iterate_calls = ref 0 in
      let rhs_evals = ref 0 in (* evaluations of right-hand sides, comparable between solvers *)

      (* Data for the work list heuristics, see [info] and [context] *)
      let current_root = ref None in (* Root of the task that is currently executed *)
      let depths : int HM.t = HM.create 10 in (* Creation depth of each root *)
      let costs : int HM.t = HM.create 10 in (* Right-hand side evaluations of the last task of each root *)
      (* Dependencies are guarded by need_dependencies: they cost hash table updates on every side effect and query. *)
      let writes : VS.t HM.t = HM.create 10 in (* Globals written by the tasks of each root *)
      let readers : VS.t HM.t = HM.create 10 in (* Roots whose tasks read each global *)

      (* Only called inside a task, so there is a current root. *)
      let record_access table key value =
        HM.replace table key (VS.add value (HM.find_default table key VS.empty))
      in
      let record_write g = record_access writes (Option.get !current_root) g in
      let record_read g = record_access readers g (Option.get !current_root) in
      let consumers r =
        let rs = VS.fold (fun g acc -> VS.union (HM.find_default readers g VS.empty) acc) (HM.find_default writes r VS.empty) VS.empty in
        VS.elements (VS.remove r rs)
      in

      (** Roots of the tasks that are waiting to be executed. *)
      let work = Work.create { consumers } in

      print_solver_stats := (fun () ->
          Logs.debug "|data|=%d" (HM.length data);
        );

      (** Initialize or get the state for an unknown.
          @param x The unknown to get the state for.
          @return The reference to the state of x.
      *)
      let init x =
        match HM.find_option data x with
        | Some x_ref -> x_ref
        | None ->
          new_var_event x;
          if tracing then trace "init" "init %a" S.Var.pretty_trace x;
          let x_ref = ref {
              value = S.Dom.bot ();
              infl = VS.empty;
              wpoint = false;
              stable = false;
              called = false;
              top_level = false;
              invalidations = 0;
            } in
          HM.replace data x x_ref;
          x_ref
      in

      (** Record that the value of y was used to compute x.
          @param y The unknown that was read.
          @param x The unknown whose rhs read y.
      *)
      let add_infl y x =
        if tracing then trace "infl" "add_infl %a %a" S.Var.pretty_trace y S.Var.pretty_trace x;
        let y_ref = init y in
        y_ref := { !y_ref with infl = VS.add x !y_ref.infl }
      in

      (** Get the right-hand-side for an unknown.
          @param x The unknown to get the rhs for.
          @param get Function to return values for unknowns.
          @param set Function to set values for unknowns.
          @param create Function to handle create nodes, i.e. add new solver tasks.
          @return The value of the rhs for the unknown.
      *)
      let eq x get set create =
        if tracing then trace "eq" "eq %a" S.Var.pretty_trace x;
        match S.system x with
        | None -> S.Dom.bot ()
        | Some f -> incr rhs_evals; f get set create
      in

      (** Check if the unknown is a global. *)
      let is_global x = S.system x = None in

      (** Add a task to solve for y to the work list. *)
      let add_task y =
        if tracing then trace "create" "add_task %a" S.Var.pretty_trace y;
        let info = {
          invalidations = !(init y).invalidations;
          depth = if Work.needs.need_depth then HM.find_default depths y 0 else 0;
          last_cost = if Work.needs.need_cost then HM.find_default costs y 0 else 0;
        } in
        Work.add work y info
      in

      (** Record that y can be reached as a root at creation depth d; keeps the smallest depth.
          Only called if [Work.needs.need_depth]. *)
      let record_depth y d =
        match HM.find_option depths y with
        | Some d' when d' <= d -> ()
        | _ -> HM.replace depths y d
      in

      (** Destabilizes the unknowns in w and their infl recursively.
          If an unknown was the root of a solver task, the task is added to the work list again.
          @param w The set of unknowns to destabilize.
      *)
      let rec destabilize w =
        VS.iter (fun y ->
            let y_ref = HM.find data y in
            if not !y_ref.stable then (
              ()
            ) else if !y_ref.called then (
              (* If y is called, we do not need to destabilize its infl, as it will happen after the value change anyway. *)
              if tracing then trace "destab" "stable remove %a (top_level:%b, called:%b)" S.Var.pretty_trace y !y_ref.top_level !y_ref.called;
              y_ref := { !y_ref with stable = false; invalidations = !y_ref.invalidations + 1 };
            ) else (
              let inner_w = !y_ref.infl in
              if tracing then trace "destab" "stable remove %a (top_level:%b, called:%b)" S.Var.pretty_trace y !y_ref.top_level !y_ref.called;
              y_ref := { !y_ref with stable = false; infl = VS.empty; invalidations = !y_ref.invalidations + 1 };
              if !y_ref.top_level then add_task y;
              destabilize inner_w
            )
          ) w
      in

      (** Iterates to solve for x (invoked from query to orig if present)
          @param orig The unknown whose query led to the iteration of x.
          @param x The unknown to solve for.
      *)
      let rec iterate orig x = (* ~(inner) solve in td3 *)
        incr iterate_calls;

        (** Get the value for y, triggering an iteration if necessary, and performing a lookup otherwise.
            @param x The unknown whose query led to the query for y, so that the infl of y can be updated.
            @param y The unknown to get the value for.
            @return The value of y.
        *)
        let query x y = (* ~eval in td3 *)
          incr eval_calls;
          let y_ref = init y in
          if tracing then trace "sol_query" "entering query for %a; stable %b; called %b" S.Var.pretty_trace y !y_ref.stable !y_ref.called;
          get_var_event y;
          (* As in td_parallel_base, infl is added before y is iterated: if y changes during its own iteration,
             x is destabilized and evaluated again, which may narrow x if it is a widening point.
             Adding it only afterwards saves these evaluations, but loses precision (e.g. tests/regression/53-races-mhp/12-lockset_inter_threaded_lock_transitive_racefree.c). *)
          add_infl y x;
          (* Only globals connect tasks: locals that another root's task solved are not recorded. *)
          if Work.needs.need_dependencies && is_global y then record_read y;
          if !y_ref.called then (
            if tracing && not !y_ref.wpoint then trace "wpoint" "query adding wpoint %a" S.Var.pretty_trace y;
            y_ref := { !y_ref with wpoint = true }
          ) else if !y_ref.stable then (
            ()
          ) else if is_global y then (
            y_ref := { !y_ref with stable = true }
          ) else (
            y_ref := { !y_ref with stable = true; called = true };
            (* Destabilizing y during its iteration clears its infl, so iterate adds x again at its end. *)
            iterate (Some x) y
          );
          let tmp = !y_ref.value in
          if tracing then trace "answer" "exiting query for %a\nanswer: %a" S.Var.pretty_trace y S.Dom.pretty tmp;
          tmp
        in

        (** Apply a side effect to y
            @param x The unknown that caused the side effect.
            @param y The unknown to side-effect.
            @param d The value to side-effect y with.
        *)
        let side x y d =
          assert (is_global y);
          (* Also if d adds nothing: the task produces y, its next contribution may be new. *)
          if Work.needs.need_dependencies then record_write y;
          let y_ref = init y in
          if tracing then trace "side" "side to %a (wpx: %b) from %a ## value: %a" S.Var.pretty_trace y !y_ref.wpoint S.Var.pretty_trace x S.Dom.pretty d;
          let old = !y_ref.value in
          if not (S.Dom.leq d old) then (
            (* As in td_parallel_base, globals are always widened. *)
            let widen a b =
              if tracing then trace "wpoint" "side widen %a" S.Var.pretty_trace y;
              S.Dom.widen a (S.Dom.join a b)
            in
            let tmp = widen old d in
            if tracing then trace "update" "side to %a from %a: %a -> %a" S.Var.pretty_trace y S.Var.pretty_trace x S.Dom.pretty old S.Dom.pretty tmp;
            update_var_event y old tmp;
            let w = !y_ref.infl in
            y_ref := { !y_ref with value = tmp; stable = true; infl = VS.empty };
            destabilize w
          )
        in

        (** Handle create nodes
            @param x The unknown that caused the create node.
            @param y The unknown to create a solver task for.
        *)
        let create x y = (* create called from x on y *)
          if tracing then trace "create" "create from td_worklist was executed from %a on %a" S.Var.pretty_trace x S.Var.pretty_trace y;
          if Work.needs.need_depth then (
            (* Create nodes are only evaluated inside a task, so there is a current root. *)
            let parent_depth = HM.find_default depths (Option.get !current_root) 0 in
            record_depth y (parent_depth + 1)
          );
          add_task y
        in

        (** Finish the iteration of x, if it is still stable, and iterate again otherwise.
            @param remove_wpoint Whether x should stop being a widening point.
        *)
        let finalize ~remove_wpoint =
          let x_ref = HM.find data x in
          if !x_ref.stable then (
            Option.may (fun z -> add_infl x z) orig;
            if tracing && remove_wpoint && !x_ref.wpoint then trace "wpoint" "iterate removing wpoint %a" S.Var.pretty_trace x;
            x_ref := { !x_ref with called = false; wpoint = !x_ref.wpoint && not remove_wpoint };
          ) else (
            (* x destabilized itself during its rhs *)
            if tracing then trace "iter" "iterate still unstable %a" S.Var.pretty_trace x;
            x_ref := { !x_ref with stable = true };
            (iterate[@tailcall]) orig x
          )
        in

        (* beginning of iteration to update the value for x *)
        assert (not (is_global x));
        let x_ref = init x in
        if tracing then trace "iter" "iterate %a, stable: %b, wpoint: %b" S.Var.pretty_trace x !x_ref.stable !x_ref.wpoint;
        let x_is_widening_point = !x_ref.wpoint in (* if x becomes a wpoint during eq, checking this will delay widening until next iterate *)
        let value_from_rhs = eq x (query x) (side x) (create x) in
        let old_value = !x_ref.value in
        let new_value = (* value after box operator (if wp: widening) *)
          if not x_is_widening_point then
            value_from_rhs
          else (
            if tracing then trace "wpoint" "box widening %a" S.Var.pretty_trace x;
            box old_value value_from_rhs)
        in
        if S.Dom.equal old_value new_value then (
          (* this makes e.g. nested loops precise, ex. tests/regression/34-localization/01-nested.c - if we do not remove wpoint, the inner loop head will stay a wpoint and widen the outer loop variable. *)
          finalize ~remove_wpoint:true
        ) else (
          (* value has changed *)
          if tracing then trace "update" "iterate update %a with \n\t%a" S.Var.pretty_trace x S.Dom.pretty new_value;
          update_var_event x old_value new_value;
          let w = !x_ref.infl in
          x_ref := { !x_ref with value = new_value; infl = VS.empty };
          destabilize w;
          finalize ~remove_wpoint:false
        )
      in

      (** Execute the task for y, i.e. solve y as the root of a new top-down iteration.
          @param y The root unknown of the task.
      *)
      let run_task y =
        let y_ref = init y in
        (* Tasks are only started from the work list loop, so no unknown can be called at this point. *)
        (* y may also have been added multiple times, if the work list keeps duplicates. *)
        assert (not !y_ref.called);
        y_ref := { !y_ref with top_level = true };
        if !y_ref.stable then (
          (* Unlike td_parallel_base, we do not re-evaluate y, if another task has already solved it.
           * We never see half finished state from another thread *)
          if tracing then trace "thread_pool" "skipping task for stable %a" S.Var.pretty_trace y
        ) else (
          if tracing then trace "thread_pool" "starting task to iterate %a" S.Var.pretty_trace y;
          y_ref := { !y_ref with stable = true; called = true };
          current_root := Some y;
          let rhs_before = !rhs_evals in
          iterate None y;
          if Work.needs.need_cost then HM.replace costs y (!rhs_evals - rhs_before);
          current_root := None
        )
      in

      let set_start (x,d) =
        let x_ref = init x in
        x_ref := { !x_ref with value = d; stable = true }
      in

      (* beginning of main solve *)
      start_event ();

      List.iter set_start st;

      List.iter (fun x -> ignore @@ init x) vs;
      (* If we have multiple start variables vs, we might solve v1, then while solving v2 we
         side some global which v1 depends on with a new value.
         Then v1 is no longer stable and we have to solve it again. *)
      let i = ref 0 in
      let rec solver () =
        incr i;
        let unstable_vs = List.filter (fun x -> not !(HM.find data x).stable) vs in
        if unstable_vs <> [] then (
          if Logs.Level.should_log Debug then (
            if !i = 1 then Logs.newline ();
            Logs.debug "Unstable solver start vars in %d. phase:" !i;
            List.iter (fun v -> Logs.debug "\t%a" S.Var.pretty_trace v) unstable_vs;
            Logs.newline ();
            flush_all ();
          );
          List.iter (fun x ->
              if tracing then trace "multivar" "solving for %a" S.Var.pretty_trace x;
              if Work.needs.need_depth then record_depth x 0;
              add_task x;
              (* while not (is_empty work) do run_task (pop work) done *)
              let rec run_all () =
                match Work.choose work with
                | None -> ()
                | Some y -> run_task y; run_all ()
              in
              run_all ()
            ) unstable_vs;
          solver ();
        )
      in
      Timing.wrap "solve" solver ();
      (* After termination, only those variables are stable which are
       * - reachable from any of the queried variables vs, or
       * - effected by side-effects and have no constraints on their own (this should be the case for all of our analyses). *)

      stop_event ();
      Logs.info "solver work: eval = %d, iterate = %d, rhs = %d" !eval_calls !iterate_calls !rhs_evals;
      if Logs.Level.should_log Debug then (
        Logs.debug "Data after iterate completed";
        Logs.debug "|data|=%d" (HM.length data);
      );

      if GobConfig.get_bool "dbg.print_wpoints" then (
        Logs.newline ();
        Logs.debug "Widening points:";
        HM.iter (fun x x_ref -> if !x_ref.wpoint then Logs.debug "%a" S.Var.pretty_trace x) data;
        Logs.newline ();
      );

      HM.map (fun _ x_ref -> !x_ref.value) data
  end

let () =
  (* Differences from td_parallel_base with LIFO mock: 
   *    - td_parallel_base re-runs roots that are stable
   *    - td_parallel_base sorts top-level roots by Saturn hash order,
   *      we walk the VS set
   *)
  Selector.add_solver ("td_worklist_lifo", 
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (Lifo))));
  Selector.add_solver ("td_worklist_fifo", 
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (Fifo))));
  Selector.add_solver ("td_worklist_random",
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (Random))));
  Selector.add_solver ("td_worklist_most_invalidated",
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (MostInvalidated))));
  Selector.add_solver ("td_worklist_least_invalidated",
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (LeastInvalidated))));
  Selector.add_solver ("td_worklist_shallowest_created",
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (ShallowestCreated))));
  Selector.add_solver ("td_worklist_cheapest_first",
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (CheapestFirst))));
  Selector.add_solver ("td_worklist_producers_first",
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (ProducersFirst))));
  Selector.add_solver ("td_worklist_deepest_created",
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (DeepestCreated))));
  Selector.add_solver ("td_worklist_costliest_first",
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (CostliestFirst))));
  Selector.add_solver ("td_worklist_consumers_first",
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (ConsumersFirst))));
