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

(** Work list of root unknowns of solver tasks. *)
module type WorkList =
sig
  type elt
  type t

  val create: unit -> t

  (** Add an element to the work list.
      @@@ duplicates can be removed but need not?
      @param w The work list.
      @param x The element to add.
  *)
  val add: t -> elt -> unit

  (** Remove the next element from the work list.
      @param w The work list.
      @return The next element, or [None] if the work list is empty.
  *)
  val choose: t -> elt option
end

(** A work list heuristic, for any kind of unknowns. *)
module type WorkListHeuristic = functor (Var: VarType) -> WorkList with type elt = Var.t

(** Set of unknowns that always returns the least unknown w.r.t. [Var.compare].
    Being a set, it does not contain duplicates. *)
module MinSet: WorkListHeuristic = functor (Var: VarType) ->
struct
  module VS = Set.Make (Var)

  type elt = Var.t
  type t = VS.t ref

  let create () = ref VS.empty

  let add w x = w := VS.add x !w

  let choose w =
    if VS.is_empty !w then
      None
    else (
      let x = VS.min_elt !w in
      w := VS.remove x !w;
      Some x
    )
end

module Lifo: WorkListHeuristic = functor (Var: VarType) ->
struct
  type elt = Var.t
  type t = Var.t Stack.t

  let create () = Stack.create ()

  let add w x = Stack.push x w

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

  let create () = Queue.create ()
  let add w x = Queue.push x w
  let choose = Queue.take_opt
end

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
    }

    let solve st vs =
      let (data : var_data ref HM.t) = HM.create 10 in

      (** Roots of the tasks that are waiting to be executed. *)
      let work = Work.create () in

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
        | Some f -> f get set create
      in

      (** Check if the unknown is a global. *)
      let is_global x = S.system x = None in

      (** Add a task to solve for y to the work list. *)
      let add_task y =
        if tracing then trace "create" "add_task %a" S.Var.pretty_trace y;
        Work.add work y
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
              y_ref := { !y_ref with stable = false };
            ) else (
              let inner_w = !y_ref.infl in
              if tracing then trace "destab" "stable remove %a (top_level:%b, called:%b)" S.Var.pretty_trace y !y_ref.top_level !y_ref.called;
              y_ref := { !y_ref with stable = false; infl = VS.empty };
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

        (** Get the value for y, triggering an iteration if necessary, and performing a lookup otherwise.
            @param x The unknown whose query led to the query for y, so that the infl of y can be updated.
            @param y The unknown to get the value for.
            @return The value of y.
        *)
        let query x y = (* ~eval in td3 *)
          let y_ref = init y in
          if tracing then trace "sol_query" "entering query for %a; stable %b; called %b" S.Var.pretty_trace y !y_ref.stable !y_ref.called;
          get_var_event y;
          if !y_ref.called then (
            if tracing && not !y_ref.wpoint then trace "wpoint" "query adding wpoint %a" S.Var.pretty_trace y;
            y_ref := { !y_ref with wpoint = true };
            add_infl y x
          ) else if !y_ref.stable then (
            add_infl y x
          ) else if is_global y then (
            y_ref := { !y_ref with stable = true };
            add_infl y x
          ) else (
            y_ref := { !y_ref with stable = true; called = true };
            (* Infl is added at the end of iterate, so that changes of y during its own iteration do not destabilize x.  @@@ TODO: check *)
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
        if Timing.wrap "S.Dom.equal" (fun () -> S.Dom.equal old_value new_value) () then (
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
          iterate None y
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
      solver ();
      (* After termination, only those variables are stable which are
       * - reachable from any of the queried variables vs, or
       * - effected by side-effects and have no constraints on their own (this should be the case for all of our analyses). *)

      stop_event ();
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
  Selector.add_solver ("td_worklist_min", 
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (MinSet))));
  Selector.add_solver ("td_worklist_lifo", 
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (Lifo))));
  Selector.add_solver ("td_worklist_fifo", 
    (module PostSolver.DemandEqIncrSolverFromDemandEqSolver (Base (Fifo))));
