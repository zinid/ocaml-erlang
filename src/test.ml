let f = ref 0
let port = ref 5222
let data = String.make (64*1024) '\000'

let rec send_loop sock =
  Erl_tcp.activate sock;
  Erl_tcp.send sock data;
  match Erl.receive () with
    | `Sock_data (_, d) ->
      send_loop sock
    | `Sock_error (_, errno) ->
      Printf.printf
	"got error: %s (%d)\n%!"
	(Erl_inet.strerror errno) errno;
      send_loop sock
    | _ ->
      send_loop sock

let sender () =
  match Erl_tcp.connect "127.0.0.1" !port with
    | exception (Erl_inet.Sock_error errno) ->
      Printf.printf "failed to connect: %s\n%!" (Erl_inet.strerror errno)
    | sock ->
      send_loop sock

let rec recv_loop () =
  match Erl.receive () with
    | `Sock_data (sock, data) ->
      Erl_tcp.activate sock;
      Erl_tcp.send sock data;
      recv_loop ()
    | `Sock_accept sock ->
      incr f;
      (* Printf.printf "accepted on %d\n%!" !f; *)
      Erl_tcp.activate sock;
      recv_loop ()
    | `Sock_error (sock, errno) ->
      Printf.printf
	"got error: %s (%d)\n%!"
	(Erl_inet.strerror errno) errno;
      exit 0;
      recv_loop ()
    | _ ->
      recv_loop ()

let receiver () =
  match Erl_tcp.listen "0.0.0.0" !port ~backlog:1000 with
    | exception (Erl_inet.Sock_error errno) ->
      Printf.printf "failed to listen: %s\n%!" (Erl_inet.strerror errno)
    | _ ->
      for i=1 to 1000 do (
	ignore (Erl.spawn sender)
      ) done;
      recv_loop ()

let _ =
  ignore (Erl.spawn receiver);
  Erl.run ()
