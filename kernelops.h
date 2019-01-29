#pragma once

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>

// select implementation for ready Q
//#define READYQ_MUTEX
//#define READYQ_LF
#define READYQ_SPIN

// select implementation for message Q
//#define MSGQ_MUTEX
//#define MSGQ_LF
#define MSGQ_SPIN

// select implementation for waiting Q
#define WAITQ_MUTEX
//#define WAITQ_LF


// validate ops implementation selection
#if !defined(READYQ_MUTEX) && !defined(READYQ_LF) && !defined(READYQ_SPIN)
#error Either READYQ_MUTEX or READYQ_LF must be defined
#endif
#if !defined(MSGQ_MUTEX) && !defined(MSGQ_LF) && !defined(MSGQ_SPIN)
#error Either MSGQ_MUTEX, MSGQ_LF or MSGQ_SPIN must be defined
#endif
#if !defined(WAITQ_MUTEX) && !defined(WAITQ_LF)
#error Either WAITQ_MUTEX or WAITQ_LF must be defined
#endif

#if defined(READYQ_MUTEX) || defined(MSGQ_MUTEX) || defined(WAITQ_MUTEX)
#include <pthread.h>
#endif

#if defined(READYQ_LF) || defined(MSGQ_LF) || defined(WAITQ_LF)
#define CAS(v, c, n) atomic_compare_exchange_weak(&(v), &(c), n)
#include "liblfds711.h"
#endif


#include <stdatomic.h>

extern _Atomic uint32_t clos_created;
extern _Atomic uint64_t clos_create_time;
extern _Atomic uint32_t msg_created;
extern _Atomic uint64_t msg_create_time;
extern _Atomic uint32_t readyQ_pushes;
extern _Atomic uint32_t readyQ_pops;
extern _Atomic uint64_t readyQ_push_time;
extern _Atomic uint64_t readyQ_pop_time;
extern _Atomic uint32_t msg_enq_count;
extern _Atomic uint32_t wait_freeze_count;

typedef void *WORD;

struct R;
struct Clos;
struct Msg;
struct Actor;

typedef struct R R;
typedef struct Clos *Clos;
typedef struct Msg *Msg;
typedef struct Actor *Actor;

enum RTAG { RDONE, RCONT, RWAIT, REXIT };
typedef enum RTAG RTAG;

struct R {
    RTAG tag;
    Clos cont;
    WORD value;
};

struct Clos {
    R (*code)(Clos, WORD);
    int nvar;
    WORD var[];
};

struct Msg {
    Msg next;
    Actor waiting;
    Clos clos;
#if defined(WAITQ_MUTEX)
    pthread_mutex_t wait_lock;
#endif
    WORD value;
};

struct Actor {
    Actor next;
    Msg msgQ;
    Msg msgTail;
#if defined(MSGQ_MUTEX)
    pthread_mutex_t msg_lock;
#elif defined(MSGQ_SPIN)
    volatile atomic_flag msg_lock;
#endif
    WORD state[];
};

// Allocate a Clos node with space for n var words.
Clos    CLOS(R (*code)(Clos, WORD), int n);
// Allocate a Msg node.
Msg     MSG(Clos clos);
// Allocate an Actor node with space for n state words.
Actor   ACTOR(int n);


// Atomic operaions required by the inner-most message processing loop:

// Initialize some global things ~ must be called precisely once.
void kernelops_INIT();
// Undos what INIT did ~ no kernel ops functions must be called after.
void kernelops_CLOSE();

// Operations for: Global ready queue
//   these operations accesses the ready queue atomically.
// Push actor "a" to the global ready-set.
void    ready_PUSH(Actor a);
// Pops an actor from the global ready-set and,
//   returns actor, or NULL if none are ready.
Actor   ready_POP();

// Operations for: An actor's message queue
//   these operations accesses an actor's message queue atomically.
// Enqueue message "m" onto the message queue of actor "a",
//   return true if this was the first message in the queue.
bool    msg_ENQ(Msg m, Actor a);
// Dequeue the first message from the queue of actor "a",
//   return true if the queue still holds messages after operation.
bool    msg_DEQ(Actor a);

// Operations for: A message's waiting queue
//   these operations accesses a message's queue of waiting actors atomically.
// Add actor "a" to the waiting list of message "m" if list is not frozen,
//   return whether the message was added or not.
bool    waiting_ADD(Actor a, Msg m);
// "freeze" waiting list of message "m",
//   return waiting actors.
Actor   waiting_FREEZE(Msg m);
