type socket = int
type pid = int
type sock_queue
exception Sock_error of int

external connect : pid -> string -> int -> socket = "ml_connect"
external listen : pid -> string -> int -> int -> socket = "ml_listen"
external send : socket -> string -> unit = "ml_send"
external start : unit -> unit = "ml_start"
external close : socket -> unit = "ml_close"
external strerror : int -> string = "ml_strerror"
(* for polling *)
external wait : float -> unit = "ml_wait"
external queue_transfer : unit -> sock_queue = "ml_queue_transfer"
external queue_free : sock_queue -> unit = "ml_queue_free"
external queue_len : sock_queue -> int = "ml_queue_len"
external queue_get : sock_queue -> int -> (int * socket * pid * string) = "ml_queue_get"

let init () =
  Callback.register_exception "sock_error" (Sock_error 0);
  start()
