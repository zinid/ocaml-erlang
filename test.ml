let p2 () =
  match Erl.receive () with
    | `Ping pid ->
      Erl.send pid `Pong

let p1 () =
  let p = Erl.spawn p2 in
  let _ = Erl.send p (`Ping (Erl.self () )) in
  match Erl.receive () with
    | exception Erl.Timeout ->
      ()
    | `Pong ->
      ()

let _ =
  let _ = Erl.spawn p1 in
  Erl.schedule ()
