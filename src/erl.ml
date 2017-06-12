exception Timeout
type pid = int
module PidSet = Set.Make (
  struct
    let compare = Pervasives.compare
    type t = pid
  end)
type msg = [`DOWN of pid
	   | `Ping of pid
	   | `Pong
	   | `Sock_data of Erl_inet.socket * string
	   | `Sock_accept of Erl_inet.socket
	   | `Sock_error of Erl_inet.socket * int]

type msg_or_timeout = Msg of msg | Timeout
type proc =
    {id : int;
     mbox : (pid * msg_or_timeout) Queue.t;
     mutable name : string option;
     mutable recv_from : pid option;
     mutable timer : unit ref;
     mutable monitored_by : PidSet.t;
     mutable stack : (unit -> unit) option}

let last_pid = ref 0
let running_pid = ref 0
let run_q = Queue.create ()
let timer_q = ref []
let named_procs : (string, pid) Hashtbl.t = Hashtbl.create 10
let proc_table : proc option array ref = ref (Array.make 1024 None)
let infinity = max_float
let prompt = Delimcc.new_prompt ()

let next_pid () =
  incr last_pid;
  if !last_pid >= Array.length !proc_table then (
    let arr = Array.make (Array.length !proc_table) None in
    proc_table := Array.append !proc_table arr
  );
  !last_pid

let self () = !running_pid

let make_ref () = ref ()

let pid_to_proc pid =
  !proc_table.(pid)

let is_process_alive pid =
  match pid_to_proc pid with
    | Some _ -> true
    | None -> false

let processes () =
  Array.fold_right
    (fun v acc ->
      match v with
	| None -> acc
	| Some proc -> proc.id::acc
    ) !proc_table []

let init_proc () =
  let pid = next_pid () in
  let proc = {id = pid;
	      timer = make_ref ();
	      recv_from = None;
	      name = None;
	      mbox = Queue.create ();
	      monitored_by = PidSet.empty;
	      stack = None} in
  !proc_table.(pid) <- Some proc;
  proc

let spawn f =
  let proc = init_proc () in
  let stack () = Delimcc.push_prompt prompt (fun () -> ignore (f ())) in
  Queue.push (proc.id, stack) run_q;
  proc.id

let whereis name =
  Hashtbl.find named_procs name

let send pid msg =
  let msg' = msg in
  match pid_to_proc pid with
    | None ->
      false
    | Some ({stack = None} as proc) ->
      (* some task is already put in the run queue, 
	 but is not dispatched yet *)
      Queue.push (self (), Msg msg') proc.mbox;
      true
    | Some ({stack = Some resume_stack;
	     recv_from = from} as proc) ->
      proc.stack <- None;
      Queue.push (self (), Msg msg') proc.mbox;
      Queue.push (pid, resume_stack) run_q;
      true

let send_by_name name msg =
  match whereis name with
    | exception Not_found ->
      false
    | pid ->
      send pid msg

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

let register name pid =
  match pid_to_proc pid with
    | Some proc ->
      proc.name <- Some name;
      Hashtbl.replace named_procs name pid
    | None ->
      ()

let unregister name =
  let pid = Hashtbl.find named_procs name in
  Hashtbl.remove named_procs name;
  match pid_to_proc pid with
    | Some proc ->
      proc.name <- None
    | None ->
      ()

let destroy_proc proc =
  PidSet.iter (fun pid -> ignore (send pid (`DOWN proc.id))) proc.monitored_by;
  !proc_table.(proc.id) <- None;
  match proc.name with
    | Some name ->
      Hashtbl.remove named_procs name
    | None ->
      ()

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
      Delimcc.shift0 prompt (fun stack -> proc.stack <- Some stack)
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

let rec process_run_q' q =
  match Queue.pop q with
    | exception Queue.Empty ->
      ()
    | (pid, task) ->
      begin
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
      end;
      process_run_q' q

let process_run_q () =
  if not (Queue.is_empty run_q) then (
    let q = Queue.create () in
    let _ = Queue.transfer run_q q in
    process_run_q' q
  )

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
	fire_time -. cur_time
      ) else (
	timer_q := timers;
	process_timers ()
      )
    | _ ->
      0.0

let process_io timeout =
  let _ = Erl_inet.wait timeout in
  let q = Erl_inet.queue_transfer () in
  let len = Erl_inet.queue_len q in
  for i=0 to (len-1) do (
    match Erl_inet.queue_get q i with
      | 0, sock, pid, data ->
	if (data <> "") then (
	  ignore (send pid (`Sock_data (sock, data)));
	) else (
	  ignore (send pid (`Sock_accept sock))
	)
      | err, sock, pid, _ ->
	ignore (send pid (`Sock_error (sock, err)))
  ) done;
  Erl_inet.queue_free q

let rec schedule () =
  let _ = process_run_q () in
  let sleep_timeout = process_timers () in
  let _ = process_io sleep_timeout in
  schedule ()

let run () =
  let _ = Erl_inet.init () in
  schedule ()
