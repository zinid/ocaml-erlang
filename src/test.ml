let port = ref 5221

let rec loop () =
  match Erl.receive () with
    | `Sock_data (sock, data) ->
      Erl_tcp.activate sock;
      Erl_tcp.send sock data;
      loop ()
    | `Sock_accept sock ->
      Printf.printf "accepted on %d\n%!" sock;
      Erl_tcp.activate sock;
      loop ()
    | `Sock_error (sock, errno) ->
      Printf.printf
	"got error: %s (%d)\n%!"
	(Erl_inet.strerror errno) errno;
      loop ()
    | _ ->
      loop ()

let p () =
  incr port;
  match Erl_tcp.listen "0.0.0.0" !port with
    | exception (Erl_inet.Sock_error errno) ->
      Printf.printf "failed to listen: %s\n%!" (Erl_inet.strerror errno)
    | _ ->
      loop ()

let _ =
  for i=1 to 4 do (
    ignore (Erl.spawn p)
  ) done;
  Erl.run ()
