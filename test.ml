let p2 () =
  let _ = Erl.receive () in ()

let p1 () =
  let p = Erl.spawn p2 in
  let _ = Erl.monitor p in
  let _ = Erl.send p (`Ping 1) in
  match Erl.receive ~timeout:1.0 () with
    | _ -> ()

let _ =
  let _ = Erl.spawn p1 in
  Erl.schedule ()
