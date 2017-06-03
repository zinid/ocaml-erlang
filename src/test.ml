let p2 () =
  match Erl.receive () with
    | _ ->
      ()

let rec p1_loop = function
  | 0 ->
    print_endline "got all processes DOWN"
  | n ->
    begin match Erl.receive () with
      | _ ->
	()
    end;
    p1_loop (n-1)

let p1 () =
  let max = 100000 in
  for i=1 to max do
    let p = Erl.spawn p2 in
    let name = string_of_int i in
    let _ = Erl.monitor p in
    let _ = Erl.register name p in
    ignore (Erl.send_by_name name (`Ping (Erl.self ())))
  done;
  p1_loop max

let _ =
  let _ = Erl.spawn p1 in
  Erl.schedule ();
  Printf.printf "run_q = %d\n" (Queue.length Erl.run_q);
  Printf.printf "timer_q = %d\n" (List.length !Erl.timer_q);
  Printf.printf "named_procs = %d\n" (Hashtbl.length Erl.named_procs);
  Printf.printf "proc_table = %d\n" (List.length (Erl.processes ()))
