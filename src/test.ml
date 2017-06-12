let rec p1_loop () =
  match Erl.receive () with
    | `Sock_data (sock, data) ->
      Erl_inet.send sock data;
      p1_loop ()
    | `Sock_accept sock ->
      Printf.printf "accepted on %d\n%!" sock;
      p1_loop ()
    | `Sock_error (sock, errno) ->
      Printf.printf
	"got error: %s (%d)\n%!"
	(Erl_inet.strerror errno) errno;
      p1_loop ()
    | _ ->
      p1_loop ()

let p1 () =
  match Erl_inet.listen (Erl.self()) "0.0.0.0" 5222 5 with
    | exception (Erl_inet.Sock_error errno) ->
      Printf.printf "failed to listen: %s\n%!" (Erl_inet.strerror errno)
    | _ ->
      p1_loop ()

let _ =
  let _ = Erl.spawn p1 in
  Erl.run ()
