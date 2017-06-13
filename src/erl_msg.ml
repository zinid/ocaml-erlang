type t = [ `DOWN of int
	 | `Ping of int
	 | `Pong
	 | `Sock_data of Erl_inet.socket * string
	 | `Sock_accept of Erl_inet.socket
	 | `Sock_error of Erl_inet.socket * int]
