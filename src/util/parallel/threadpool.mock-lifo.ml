(** Sequential mock of the thread pool without domainslib, that executes work in LIFO order.

    [add_work] puts the work on a stack. The outermost [await_all] (or [run]) executes the work on the stack,
    most recently added first, until it is empty. This is the same strategy as a LIFO work list, e.g. [td_worklist_lifo].
    An [await_all] from inside executing work returns immediately, the outermost one completes the promises.
    This suffices for callers that do not use the results of the promises they await. *)

type t = {
  work: (unit -> unit) Stack.t; (** Work that was added but not started yet *)
  mutable executing: bool;      (** Whether work is currently being executed from [work] *)
}

type 'a promise = 'a option ref

let create n = { work = Stack.create (); executing = false }

let add_work pool f =
  let p = ref None in
  Stack.push (fun () -> p := Some (f ())) pool.work;
  p

(** Execute work from the stack until it is empty, unless this already happens further up the call stack. *)
let execute_all pool =
  if not pool.executing then (
    pool.executing <- true;
    Fun.protect ~finally:(fun () -> pool.executing <- false) (fun () ->
        while not (Stack.is_empty pool.work) do
          (Stack.pop pool.work) ()
        done
      )
  )

let run pool f =
  let x = f () in
  execute_all pool;
  x

let await_all pool promises = execute_all pool

let finished_with pool = ()
