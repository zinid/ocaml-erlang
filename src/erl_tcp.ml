let connect host port =
  let pid = Erl.self () in
  let fd = Erl_inet.connect pid host port in
  let _ = Erl.register_socket pid fd in
  fd

let listen ?backlog:(backlog = 5) host port =
  let pid = Erl.self () in
  let fd = Erl_inet.listen pid host port backlog in
  let _ = Erl.register_socket pid fd in
  fd

let close sock =
  let pid = Erl.self () in
  let _ = Erl_inet.close sock in
  Erl.unregister_socket pid sock

let activate = Erl_inet.activate
let send = Erl_inet.send
