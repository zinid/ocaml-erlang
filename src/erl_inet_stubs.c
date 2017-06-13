#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/signals.h>
#include <ev.h>
#include <stdio.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <assert.h>
#include <pthread.h>
#include <string.h>

#define RECV_BUF_SIZE 65536
#define MAX_FD_NUMBER 1024
/* TODO: This currently works in linux only */
#define SEND_FLAGS MSG_NOSIGNAL

enum {
  CMD_CONNECT,
  CMD_SEND,
  CMD_RECV,
  CMD_CLOSE,
  CMD_ERROR,
  CMD_ACTIVATE,
  CMD_LISTEN,
  CMD_ACCEPT
};

typedef struct command {
  int pid;
  int fd;
  int cmd;
  int err;
  char *buf;
  size_t buf_size;
} command;

typedef struct socket_state {
  int pid;
  size_t obuf_size;
  char *obuf;
  ev_io *read_w;
  ev_io *write_w;
  int err;
} socket_state;

typedef struct thread_args {
  int cpu;
  pthread_mutex_t *lock;
  pthread_cond_t *done;
} thread_args;

static ev_timer timer_w;
static ev_async wakeup_w;
static socket_state *socket_tab[MAX_FD_NUMBER] = {NULL};
static void *socket_loop[256] = {NULL};
static void *send_q[256] = {NULL};
static void *async_w[256] = {NULL};
static pthread_t thread[256];
static struct ev_loop *default_loop = NULL;
static void *recv_q = NULL;
static int num_of_cpus = 1;

extern void *queue_new(size_t);
extern void queue_free(void *);
extern void queue_push(void *, void *);
extern void *queue_transfer(void *);
extern void *queue_get(void *, size_t);
extern size_t queue_len(void *);

static void send_command(int fd, command *cmd) {
  int cpu = fd % num_of_cpus;
  struct ev_loop *loop = socket_loop[cpu];
  void *q = send_q[cpu];
  ev_async *w = async_w[cpu];
  queue_push(q, cmd);
  ev_async_send(loop, w);
}

static socket_state *init_state(int pid, int fd) {
  socket_state *state = NULL;
  if (fd < MAX_FD_NUMBER) {
    state = malloc(sizeof(socket_state));
    state->write_w = malloc(sizeof(ev_io));
    state->read_w = malloc(sizeof(ev_io));
    state->pid = pid;
    state->obuf = NULL;
    state->obuf_size = 0;
    socket_tab[fd] = state;
  }
  return state;
}

static void destroy_state(socket_state *state, int fd) {
  if (fd < MAX_FD_NUMBER)
    socket_tab[fd] = NULL;
  if (state) {
    free(state->obuf);
    free(state->write_w);
    free(state->read_w);
  };
  free(state);
}

static socket_state *lookup_state(int fd) {
  if (fd < MAX_FD_NUMBER)
    return socket_tab[fd];
  else
    return NULL;
}

static void handle_error(socket_state *state, struct ev_loop *loop, int err)
{
  if (err == EAGAIN || err == EWOULDBLOCK || err == EINPROGRESS) {
    /* Do nothing, socket is not ready yet */
  } else {
    int fd = state->write_w->fd;
    err ? (err = errno) : (err = ECONNRESET);
    command cmd = {.pid = state->pid,
		   .fd = fd,
		   .cmd = CMD_ERROR,
		   .err = err,
		   .buf = NULL,
		   .buf_size = 0};
    ev_io_stop(loop, state->write_w);
    ev_io_stop(loop, state->read_w);
    destroy_state(state, fd);
    close(fd);
    queue_push(recv_q, &cmd);
    ev_async_send(default_loop, &wakeup_w);
  }
}

static void handle_read(struct ev_loop *loop, ev_io *w, int revents) {
  socket_state *state = lookup_state(w->fd);
  assert(state);
  char *buf = malloc(RECV_BUF_SIZE);
  ssize_t recv = read(w->fd, buf, RECV_BUF_SIZE);
  if (recv > 0) {
    assert(RECV_BUF_SIZE >= recv);
    command cmd = {.pid = state->pid,
		   .fd = w->fd,
		   .cmd = CMD_RECV,
		   .err = 0,
		   .buf = buf,
		   .buf_size = recv};
    ev_io_stop(loop, w);
    queue_push(recv_q, &cmd);
    ev_async_send(default_loop, &wakeup_w);
  } else {
    free(buf);
    handle_error(state, loop, recv);
  }
}

static void handle_write(struct ev_loop *loop, ev_io *w, int revents) {
  socket_state *state = lookup_state(w->fd);
  assert(state);
  if (state->obuf_size) {
    ssize_t sent = send(w->fd, state->obuf, state->obuf_size, SEND_FLAGS);
    if (sent >= state->obuf_size) {
      free(state->obuf);
      state->obuf_size = 0;
      state->obuf = NULL;
      ev_io_stop(loop, w);
    } else if (sent > 0) {
      state->obuf_size -= sent;
      memmove(state->obuf, state->obuf + sent, state->obuf_size);
    } else {
      handle_error(state, loop, sent);
    }
  } else {
    ev_io_stop(loop, w);
  }
}

static void handle_connect(struct ev_loop *loop, ev_io *w, int revents) {
  socket_state *state = lookup_state(w->fd);
  assert(state);
  errno = 0;
  unsigned int len = sizeof(errno);
  getsockopt(w->fd, SOL_SOCKET, SO_ERROR, &errno, &len);
  if (errno) {
    handle_error(state, loop, -1);
  } else {
    ev_set_cb(state->write_w, handle_write);
    if (!state->obuf_size)
      ev_io_stop(loop, w);
  }
}

static void handle_accept(struct ev_loop *loop, ev_io *w, int revents) {
  socket_state *state = lookup_state(w->fd);
  assert(state);
  struct sockaddr src;
  socklen_t len;
  int fd = accept(w->fd, &src, &len);
  if (fd < 0) {
    handle_error(state, loop, errno);
  } else {
    command cmd = {.pid = state->pid,
		   .fd = fd,
		   .cmd = CMD_ACCEPT,
		   .err = 0,
		   .buf = NULL,
		   .buf_size = 0};
    send_command(fd, &cmd);
  }
}

static void process_connect(struct ev_loop *loop, socket_state *state, command *cmd) {
  if (!state) {
    state = init_state(cmd->pid, cmd->fd);
    ev_io_init(state->read_w, handle_read, cmd->fd, EV_READ);
    ev_io_init(state->write_w, handle_connect, cmd->fd, EV_WRITE);
    ev_io_start(loop, state->write_w);
  }
}

static void process_listen(struct ev_loop *loop, socket_state *state, command *cmd) {
  if (!state) {
    state = init_state(cmd->pid, cmd->fd);
    ev_io_init(state->read_w, handle_accept, cmd->fd, EV_READ);
    ev_io_init(state->write_w, handle_write, cmd->fd, EV_WRITE);
    ev_io_start(loop, state->read_w);
  }
}

static void process_accept(struct ev_loop *loop, socket_state *state, command *cmd) {
  if (!state) {
    state = init_state(cmd->pid, cmd->fd);
    ev_io_init(state->read_w, handle_read, cmd->fd, EV_READ);
    ev_io_init(state->write_w, handle_write, cmd->fd, EV_WRITE);
    command c = {.pid = cmd->pid,
		 .fd = cmd->fd,
		 .cmd = CMD_ACCEPT,
		 .err = 0,
		 .buf = NULL,
		 .buf_size = 0};
    queue_push(recv_q, &c);
    ev_async_send(default_loop, &wakeup_w);
  }
}

static void process_send(struct ev_loop *loop, socket_state *state, command *cmd) {
  if (state) {
    if (!state->obuf_size) {
      ssize_t sent = send(cmd->fd, cmd->buf, cmd->buf_size, SEND_FLAGS);
      if (sent >= cmd->buf_size) {
	free(cmd->buf);
      } else if (sent > 0) {
	state->obuf_size = cmd->buf_size - sent;
	state->obuf = malloc(state->obuf_size);
	memcpy(state->obuf, cmd->buf + sent, state->obuf_size);
	free(cmd->buf);
	ev_io_start(loop, state->write_w);
      } else {
	handle_error(state, loop, sent);
      }
    } else {
      state->obuf = realloc(state->obuf, state->obuf_size + cmd->buf_size);
      memcpy(state->obuf + state->obuf_size, cmd->buf, cmd->buf_size);
      state->obuf_size += cmd->buf_size;
      free(cmd->buf);
      ev_io_start(loop, state->write_w);
    }
  }
}

static void process_activate(struct ev_loop *loop, socket_state *state, command *cmd) {
  if (state)
    ev_io_start(loop, state->read_w);
}

static void process_close(struct ev_loop *loop, socket_state *state, command *cmd) {
  if (state) {
    ev_io_stop(loop, state->read_w);
    ev_io_stop(loop, state->write_w);
    destroy_state(state, cmd->fd);
    close(cmd->fd);
  }
}

static void handle_event(struct ev_loop *loop, ev_async *w, int revents) {
  int *cpu = ev_userdata(loop);
  void *q = queue_transfer(send_q[*cpu]);
  size_t len = queue_len(q);
  socket_state *state;
  for (int i = 0; i < len; i++) {
    command *cmd = queue_get(q, i);
    state = lookup_state(cmd->fd);
    switch (cmd->cmd) {
    case CMD_CONNECT:
      process_connect(loop, state, cmd);
      break;
    case CMD_LISTEN:
      process_listen(loop, state, cmd);
      break;
    case CMD_ACCEPT:
      process_accept(loop, state, cmd);
      break;
    case CMD_SEND:
      process_send(loop, state, cmd);
      break;
    case CMD_ACTIVATE:
      process_activate(loop, state, cmd);
      break;
    case CMD_CLOSE:
      process_close(loop, state, cmd);
      break;
    default:
      assert(0);
    }
  }
  queue_free(q);
}

static void handle_wakeup(struct ev_loop *loop, ev_async *w, int revents) {
  ev_timer_stop(loop, &timer_w);
  ev_break(loop, EVBREAK_ALL);
}

static void handle_timeout(struct ev_loop *loop, ev_timer *w, int revents) {
  ev_break(loop, EVBREAK_ALL);
}

static void *run (void *data) {
  thread_args *args = data;
  int cpu = args->cpu;
  async_w[cpu] = malloc(sizeof(ev_async));
  send_q[cpu] = queue_new(sizeof(command));
  socket_loop[cpu] = ev_loop_new(EVFLAG_AUTO);
  ev_async *w = async_w[cpu];
  struct ev_loop *loop = socket_loop[cpu];
  ev_async_init(w, handle_event);
  ev_async_start(loop, w);
  ev_set_userdata(loop, &cpu);
  pthread_mutex_lock(args->lock);
  pthread_cond_signal(args->done);
  pthread_mutex_unlock(args->lock);
  ev_run(loop, 0);
  printf("libev loop has terminated unexpectedly\n");
  abort();
  return NULL;
}

static int parse_addr(char *host, int port, struct sockaddr_in *dst) {
  int res = inet_pton(AF_INET, host, &(dst->sin_addr));
  dst->sin_family = AF_INET;
  dst->sin_port = htons(port);
  return res;
}

static int sock_open() {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd != -1) {
    int res = fcntl(fd, F_SETFL, O_NONBLOCK);
    if (res != -1)
      return fd;
    else
      close(fd);
  }
  return -1;
}

value raise_sock_error(int err) {
  caml_raise_with_arg(*caml_named_value("sock_error"), Val_int(err));
  return Val_unit;
}

value ml_start(value v) {
  num_of_cpus = sysconf(_SC_NPROCESSORS_ONLN);
  assert(num_of_cpus > 0);
  recv_q = queue_new(sizeof(command));
  pthread_mutex_t lock;
  pthread_cond_t done;
  pthread_mutex_init(&lock, NULL);
  pthread_cond_init(&done, NULL);
  for (int i=0; i < num_of_cpus; i++) {
    thread_args *args = malloc(sizeof(thread_args));
    args->cpu = i;
    args->lock = &lock;
    args->done = &done;
    pthread_create(&thread[i], NULL, run, args);
    pthread_mutex_lock(&lock);
    pthread_cond_wait(&done, &lock);
    pthread_mutex_unlock(&lock);
  }
  default_loop = ev_default_loop(0);
  ev_timer_init(&timer_w, handle_timeout, 0.0, 0.0);
  ev_async_init(&wakeup_w, handle_wakeup);
  ev_async_start(default_loop, &wakeup_w);
  return Val_unit;
}

value ml_wait(value v) {
  ev_tstamp timeout = Double_val(v);
  caml_enter_blocking_section();
  if (timeout > 0.0) {
    ev_timer_set(&timer_w, timeout, 0.0);
    ev_timer_start(default_loop, &timer_w);
  }
  ev_run(default_loop, EVRUN_ONCE);
  caml_leave_blocking_section();
  return Val_unit;
}

value ml_connect(value pid_v, value host, value port) {
  int pid = Int_val(pid_v);
  int fd, res;
  struct sockaddr_in dst;
  if (!(parse_addr(String_val(host), Int_val(port), &dst)))
    caml_failwith("inet_addr_of_string");
  if ((fd = sock_open()) < 0)
    return raise_sock_error(errno);
  res = connect(fd, (struct sockaddr *) &dst, sizeof(dst));
  if (!res || errno == EAGAIN || errno == EINPROGRESS || errno == EWOULDBLOCK) {
    command cmd = {.pid = pid,
		   .fd = fd,
		   .cmd = CMD_CONNECT,
		   .err = 0,
		   .buf = NULL,
		   .buf_size = 0};
    send_command(fd, &cmd);
    return Val_int(fd);
  } else {
    close(fd);
    return raise_sock_error(errno);
  }
}

value ml_listen(value pid_v, value host, value port, value backlog_v) {
  int pid = Int_val(pid_v);
  int backlog = Int_val(backlog_v);
  int fd, res;
  struct sockaddr_in src;
  if (!(parse_addr(String_val(host), Int_val(port), &src)))
    caml_failwith("inet_addr_of_string");
  if ((fd = sock_open()) < 0)
    return raise_sock_error(errno);
  if ((res = bind(fd, (struct sockaddr *) &src, sizeof(src))) < 0) {
    close(fd);
    return raise_sock_error(errno);
  }
  if ((res = listen(fd, backlog)) < 0) {
    close(fd);
    return raise_sock_error(errno);
  }
  command cmd = {.pid = pid,
		 .fd = fd,
		 .cmd = CMD_LISTEN,
		 .err = 0,
		 .buf = NULL,
		 .buf_size = 0};
  send_command(fd, &cmd);
  return Val_int(fd);
}

value ml_close(value fd_v) {
  int fd = Int_val(fd_v);
  command cmd = {.pid = 0,
		 .fd = fd,
		 .cmd = CMD_CLOSE,
		 .err = 0,
		 .buf = NULL,
		 .buf_size = 0};
  send_command(fd, &cmd);
  return Val_unit;
}

value ml_send(value fd_v, value data) {
  size_t size = caml_string_length(data);
  if (size) {
    int fd = Int_val(fd_v);
    char *buf = malloc(size);
    memcpy(buf, String_val(data), size);
    command cmd = {.pid = 0,
		   .fd = fd,
		   .cmd = CMD_SEND,
		   .err = 0,
		   .buf = buf,
		   .buf_size = size};
    send_command(fd, &cmd);
  }
  return Val_unit;
}

value ml_activate(value fd_v) {
  int fd = Int_val(fd_v);
  command cmd = {.pid = 0,
		 .fd = fd,
		 .cmd = CMD_ACTIVATE,
		 .err = 0,
		 .buf = NULL,
		 .buf_size = 0};
  send_command(fd, &cmd);
  return Val_unit;
}

value ml_queue_transfer(value v) {
  void *q = queue_transfer(recv_q);
  return Val_long(q);
}

value ml_queue_free(value v) {
  void *q = (void *) Long_val(v);
  queue_free(q);
  return Val_unit;
}

value ml_queue_len(value v) {
  void *q = (void *) Long_val(v);
  return Val_int(queue_len(q));
}

value ml_queue_get(value v1, value v2) {
  CAMLparam0 ();
  CAMLlocal2 (result, data);
  void *q = (void *) Long_val(v1);
  int i = Int_val(v2);
  command *cmd = queue_get(q, i);
  data = caml_alloc_string(cmd->buf_size);
  memcpy(String_val(data), cmd->buf, cmd->buf_size);
  free(cmd->buf);
  result = alloc_tuple(4);
  Store_field(result, 0, Val_int(cmd->err));
  Store_field(result, 1, Val_int(cmd->fd));
  Store_field(result, 2, Val_int(cmd->pid));
  Store_field(result, 3, data);
  CAMLreturn (result);
}

value ml_strerror(value v) {
  CAMLparam0();
  CAMLlocal1(result);
  int err = Int_val(v);
  char *reason = strerror(err);
  result = caml_copy_string(reason);
  CAMLreturn (result);
}
