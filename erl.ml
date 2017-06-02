exception Timeout
type pid = int
module PidSet = Set.Make (
  struct
    let compare = Pervasives.compare
    type t = pid
  end)
type msg = [`DOWN of pid | `Ping of pid | `Pong]
type msg_wrapper = Msg of msg | Timeout
type proc =
    {id : int;
     mbox : (pid * msg_wrapper) Queue.t;
     prompt : unit Delimcc.prompt;
     mutable recv_from : pid option;
     mutable timer : unit ref;
     mutable monitored_by : PidSet.t;
     mutable stack : (unit -> unit) option}

let max_pid = ref 0
let running_pid = ref 0
let run_q = Queue.create ()
let timer_q = ref []
let max_procs = 65536
let proc_table : proc option array = Array.make max_procs None
let infinity = max_float

let self () = !running_pid

let make_ref () = ref ()

let pid_to_proc pid =
  proc_table.(pid)

let is_process_alive pid =
  match pid_to_proc pid with
    | Some _ -> true
    | None -> false

let init_proc () =
  incr max_pid;
  let proc = {id = !max_pid;
	      prompt = Delimcc.new_prompt ();
	      timer = make_ref ();
	      recv_from = None;
	      mbox = Queue.create ();
	      monitored_by = PidSet.empty;
	      stack = None} in
  proc_table.(!max_pid) <- Some proc;
  proc

let spawn f =
  let proc = init_proc () in
  let stack () = Delimcc.push_prompt proc.prompt (fun () -> ignore (f ())) in
  Queue.push (proc.id, stack) run_q;
  proc.id

let send pid msg =
  let msg' = msg in
  match pid_to_proc pid with
    | None ->
      false
    | Some ({stack = None} as proc) ->
      Queue.push (self (), Msg msg') proc.mbox;
      true
    | Some ({stack = Some resume_stack;
	     recv_from = from} as proc) ->
      Queue.push (self (), Msg msg') proc.mbox;
      Queue.push (pid, resume_stack) run_q;
      true

let monitor pid =
  match pid_to_proc pid with
    | Some proc ->
      proc.monitored_by <- PidSet.add (self ()) proc.monitored_by
    | None ->
      ignore (send (self()) (`DOWN pid))

let demonitor pid =
  match pid_to_proc pid with
    | Some ({monitored_by = pids} as proc) ->
      proc.monitored_by <- PidSet.remove (self ()) pids
    | None ->
      ()

let destroy_proc proc =
  PidSet.iter (fun pid -> ignore (send pid (`DOWN proc.id))) proc.monitored_by;
  proc_table.(proc.id) <- None

let rec insert_timer timer timers acc =
  match timers with
    | timer'::timers' when timer > timer' ->
      insert_timer timer timers' (timer'::acc)
    | _ ->
      List.rev_append acc (timer::timers)

let set_timeout proc timeout =
  let fire_time = Unix.gettimeofday () +. timeout in
  proc.timer <- make_ref ();
  timer_q := insert_timer (fire_time, proc.id, proc.timer) !timer_q []

let cancel_timeout proc =
  proc.timer <- make_ref ()

let wait_for_msg proc timeout =
  match Queue.is_empty proc.mbox with
    | true when timeout > 0.0 ->
      if timeout <> infinity then
	set_timeout proc timeout;
      Delimcc.shift0 proc.prompt (fun stack -> proc.stack <- Some stack)
    | true ->
      raise Timeout
    | false ->
      ()

let receive ?timeout:(timeout = infinity) () =
  match pid_to_proc (self ()) with
    | Some proc ->
      wait_for_msg proc timeout;
      cancel_timeout proc;
      begin
	match Queue.pop proc.mbox with
	  | _, Timeout -> raise Timeout
	  | _, Msg msg -> msg
      end
    | None ->
      assert false

let process_task () =
  match Queue.pop run_q with
    | exception Queue.Empty ->
      ()
    | (pid, task) ->
      match pid_to_proc pid with
	| Some proc ->
	  running_pid := pid;
	  begin
	    match task () with
	      | exception exn ->
		let reason = Printexc.to_string exn in
		Printf.printf
		  "process %d terminated with exception: %s\n%!"
		  pid reason;
		destroy_proc proc
	      | _ ->
		begin
		  match proc.stack with
		    | None ->
		      destroy_proc proc
		    | Some _ ->
		      ()
		end
	  end
	| None ->
	  ()

let rec process_timers () =
  let cur_time = Unix.gettimeofday () in
  match !timer_q with
    | (fire_time, pid, timer)::timers when cur_time >= fire_time ->
      timer_q := timers;
      begin
	match pid_to_proc pid with
	  | Some ({stack = Some resume_stack;
		   timer = timer'} as proc) when timer == timer' ->
	    proc.stack <- None;
	    Queue.push (pid, Timeout) proc.mbox;
	    Queue.push (pid, resume_stack) run_q
	  | _ ->
	    ()
      end;
      process_timers ()
    | (fire_time, pid, _)::timers when Queue.is_empty run_q ->
      if (is_process_alive pid) then (
	Unix.sleepf (fire_time -. cur_time)
      ) else (
	timer_q := timers
      );
      process_timers ()
    | _ ->
      ()

let rec schedule () =
  let _ = process_task () in
  let _ = process_timers () in
  if (Queue.is_empty run_q) then (
    print_endline "Fatal error: nothing to schedule"
  ) else
    schedule ()
