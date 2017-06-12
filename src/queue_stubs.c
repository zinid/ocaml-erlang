#include <stdlib.h>
#include <pthread.h>
#include <string.h>
#include <assert.h>

typedef struct queue {
  size_t alloc_len;
  size_t len;
  size_t elem_size;
  void *elems;
  pthread_mutex_t lock;
} queue;

queue *queue_new (size_t elem_size) {
  queue *q = malloc(sizeof(queue));
  q->alloc_len = 1024;
  q->elem_size = elem_size;
  q->elems = malloc(q->alloc_len * elem_size);
  q->len = 0;
  pthread_mutex_init(&q->lock, NULL);
  return q;
}

void queue_push (queue *q, void *elem) {
  pthread_mutex_lock(&q->lock);
  memcpy(q->elems + (q->len * q->elem_size), elem, q->elem_size);
  q->len++;
  if (q->len == q->alloc_len) {
    q->alloc_len *= 2;
    q->elems = realloc(q->elems, q->alloc_len * q->elem_size);
  };
  pthread_mutex_unlock(&q->lock);
}

queue *queue_transfer(queue *orig_q) {
  queue *q = malloc(sizeof(queue));
  pthread_mutex_lock(&orig_q->lock);
  memcpy(q, orig_q, sizeof(queue));
  orig_q->len = 0;
  orig_q->alloc_len = 1024;
  orig_q->elems = malloc(orig_q->alloc_len * orig_q->elem_size);
  pthread_mutex_unlock(&orig_q->lock);
  return q;
}

void *queue_get(queue *q, size_t pos) {
  assert(pos < q->len);
  return q->elems + (pos * q->elem_size);
}

size_t queue_len(queue *q) {
  return q->len;
}

void queue_free(queue *q) {
  free(q->elems);
  free(q);
}
