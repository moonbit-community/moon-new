/*
 * Copyright 2025 International Digital Economy Academy
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <stdint.h>
#include <moonbit.h>

#ifdef _WIN32

#ifndef _MSC_VER
#error "Currently only MSVC is supported on Windows"
#endif

#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>
#include <stddef.h>

#pragma comment(lib, "ws2_32.lib")

typedef volatile int32_t atomic_int32_t;

#else

#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <stdatomic.h>
#include <errno.h>
#include <time.h>
#if !defined(__ANDROID__) || __ANDROID_API__ >= 28
#include <spawn.h>
#endif
#include <sys/socket.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/wait.h>
#include <poll.h>

#ifdef __linux__
#include <sys/syscall.h>
#include <sys/inotify.h>
#include <linux/version.h>
#endif

#ifdef __MACH__
#include <sys/attr.h>
#endif

typedef int HANDLE;
typedef int SOCKET;
#define GetLastError() errno
#define SetLastError(err) errno = err

typedef _Atomic int32_t atomic_int32_t;

#endif


#ifdef _WIN32
// Windows, use native event system to wake up worker thread
#define WAKEUP_METHOD_EVENT

#elif defined(__MACH__)
// MacOS, there are some bug with thread-directed signal and `sigwait`,
// so use condition variable to wake up worker threads
#include <sys/event.h>
#define WAKEUP_METHOD_COND_VAR

#include <Availability.h>
#ifdef __MAC_OS_X_VERSION_MIN_REQUIRED
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 260000
#define posix_spawn_file_actions_addchdir_np posix_spawn_file_actions_addchdir
#endif
#endif

#else
// Other UNIX-like systems, use signal and `sigwait` to wake up worker threads
#define WAKEUP_METHOD_SIGNAL

#if defined(__ANDROID__) && __ANDROID_API__ < 34
#define posix_spawn_file_actions_addchdir_np(...) ENOSYS
#endif

#endif

MOONBIT_FFI_EXPORT
int32_t moonrun_native_get_platform() {
#ifdef __linux__
  return 0;
#elif defined(__MACH__)
  return 1;
#elif defined(_WIN32)
  return 2;
#else
  abort();
#endif
}

/* Unlike the async library's global pool, each worker owns its notification
 * endpoint. Workers only touch C allocations; publication happens on the VM thread. */
struct job {
  int32_t ret, err;
  int32_t (*worker)(void *, int32_t *);
  void (*free)(void *);
  int32_t (*cancel_handler)(void *);
  char payload[];
};
#define JOB_HEADER(p) ((struct job *)(p) - 1)
struct worker {
#ifdef _WIN32
  HANDLE thread, event;
#else
  pthread_t thread;
  pthread_mutex_t mutex;
  pthread_cond_t condition;
#endif
  atomic_int32_t state, inside_cancellable_region, stopping, notice;
  struct job *job;
  HANDLE notify;
  void *bus;
  int32_t id;
  int64_t source, token;
};
static int load_atomic(atomic_int32_t *value) {
#ifdef _WIN32
  return InterlockedCompareExchange((volatile LONG *)value, 0, 0);
#else
  return atomic_load(value);
#endif
}
static int compare_atomic(atomic_int32_t *value, int expected, int replacement) {
#ifdef _WIN32
  return InterlockedCompareExchange((volatile LONG *)value, replacement, expected);
#else
  atomic_compare_exchange_strong(value, &expected, replacement); return expected;
#endif
}
static void store_atomic(atomic_int32_t *value, int state) {
#ifdef _WIN32
  InterlockedExchange((volatile LONG *)value, state);
#else
  atomic_store(value, state);
#endif
}
#ifdef _WIN32
static __declspec(thread) struct worker *current_worker;
#else
static pthread_key_t current_worker_key;
static atomic_int32_t worker_key_ready;
static int cancellation_error;
static struct worker *get_current_worker(void) {
  return load_atomic(&worker_key_ready) ? pthread_getspecific(current_worker_key) : NULL;
}
#define current_worker get_current_worker()
static pthread_once_t cancellation_once = PTHREAD_ONCE_INIT;
static struct sigaction previous_cancellation;
static void notify_worker(struct worker *);
static void cancellation_handler(int sig, siginfo_t *info, void *context) {
  struct worker *worker = current_worker;
  if (worker && worker->bus && load_atomic(&worker->state) == 1 &&
      load_atomic(&worker->inside_cancellable_region)) {
    int saved_errno = errno;
    if (compare_atomic(&worker->notice, 0, 1) == 0) {
      unsigned char byte = 1;
      ssize_t count = write(worker->notify, &byte, 1);
      (void)count;
    }
    errno = saved_errno;
  }
  if (!worker && previous_cancellation.sa_handler != SIG_DFL &&
      previous_cancellation.sa_handler != SIG_IGN && previous_cancellation.sa_handler) {
    if (previous_cancellation.sa_flags & SA_SIGINFO)
      previous_cancellation.sa_sigaction(sig, info, context);
    else
      previous_cancellation.sa_handler(sig);
  }
}
static void install_cancellation(void) {
  cancellation_error = pthread_key_create(&current_worker_key, NULL);
  if (cancellation_error) return;
  store_atomic(&worker_key_ready, 1);
  struct sigaction action = {0};
  action.sa_sigaction = cancellation_handler;
  action.sa_flags = SA_SIGINFO;
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGUSR2, &action, &previous_cancellation)) cancellation_error = errno;
}
#endif
void *moonrun_native_get_current_worker(void) { return current_worker; }
int32_t moonrun_native_enter_cancellable_region(struct worker *worker) {
  if (!worker) return 0;
  store_atomic(&worker->inside_cancellable_region, 1);
  return load_atomic(&worker->state) == 1;
}
void moonrun_native_leave_cancellable_region(struct worker *worker) {
  if (worker) store_atomic(&worker->inside_cancellable_region, 0);
}
MOONBIT_FFI_EXPORT void moonrun_native_free_job(void *payload) {
  if (!payload) return;
  struct job *job = JOB_HEADER(payload);
  job->free(payload);
  free(job);
}
MOONBIT_FFI_EXPORT int32_t moonrun_native_job_get_ret(void *payload) { return JOB_HEADER(payload)->ret; }
MOONBIT_FFI_EXPORT int32_t moonrun_native_job_get_err(void *payload) { return JOB_HEADER(payload)->err; }
MOONBIT_FFI_EXPORT void moonrun_native_run_job(void *payload) {
  struct job *job = JOB_HEADER(payload);
  job->err = 0;
  job->ret = job->worker(payload, &job->err);
}
extern int moonrun_event_bus_post(void *, int64_t, int64_t, int);
extern void moonrun_event_bus_retain(void *);
extern void moonrun_event_bus_release(void *);
static void notify_worker(struct worker *worker) {
  if (load_atomic(&worker->stopping)) return;
  if (!worker->bus && worker->notify == (HANDLE)-1) return;
#ifdef _WIN32
  if (worker->bus) {
    moonrun_event_bus_post(worker->bus, worker->source, worker->token, worker->token ? (worker->job->ret > 0 ? worker->job->ret : 0) : worker->id);
  } else {
    DWORD count;
    WriteFile(worker->notify, &worker->id, 4, &count, NULL);
  }
#else
ssize_t count;
if (worker->bus) {
  if (compare_atomic(&worker->notice, 0, 1) == 0) {
    unsigned char byte = 1;
    do { count = write(worker->notify, &byte, 1); } while (count < 0 && errno == EINTR);
  }
} else {
  do { count = write(worker->notify, &worker->id, 4); } while (count < 0 && errno == EINTR);
}
#endif
}
#ifdef _WIN32
static DWORD WINAPI worker_loop(void *pointer)
#else
static void *worker_loop(void *pointer)
#endif
{
  struct worker *worker = pointer;
#ifdef _WIN32
  current_worker = worker;
#else
  pthread_setspecific(current_worker_key, worker);
  sigset_t blocked;
  sigfillset(&blocked);
  sigdelset(&blocked, SIGUSR2);
  pthread_sigmask(SIG_SETMASK, &blocked, NULL);
#endif
  for (;;) {
#ifdef _WIN32
    WaitForSingleObject(worker->event, INFINITE);
#else
    pthread_mutex_lock(&worker->mutex);
    while (load_atomic(&worker->state) == 2 && !load_atomic(&worker->stopping)) pthread_cond_wait(&worker->condition, &worker->mutex);
    pthread_mutex_unlock(&worker->mutex);
#endif
    if (load_atomic(&worker->stopping)) break;
    moonrun_native_run_job(worker->job->payload);
    /* Release publishes both job output and errno before the notification. */
    store_atomic(&worker->inside_cancellable_region, 0);
    store_atomic(&worker->state, 2);
    notify_worker(worker);
  }
#ifdef _WIN32
  current_worker = NULL;
#else
  pthread_setspecific(current_worker_key, NULL);
#endif
  return 0;
}
MOONBIT_FFI_EXPORT void *moonrun_native_worker_start(void *payload, int32_t id,
    HANDLE notify, void *bus, int64_t source, int64_t token) {
  struct worker *worker = calloc(1, sizeof(*worker));
  if (!worker) return NULL;
  worker->job = JOB_HEADER(payload);
  worker->id = id; worker->notify = notify; worker->bus = bus;
  worker->source = source; worker->token = token;
  moonrun_event_bus_retain(bus);
#ifdef _WIN32
  worker->event = CreateEventW(NULL, FALSE, TRUE, NULL);
  if (!worker->event) { moonrun_event_bus_release(bus); free(worker); return NULL; }
  worker->thread = CreateThread(NULL, 0, worker_loop, worker, 0, NULL);
  if (!worker->thread) { CloseHandle(worker->event); moonrun_event_bus_release(bus); free(worker); return NULL; }
#else
  pthread_once(&cancellation_once, install_cancellation);
  if (cancellation_error) {
    moonrun_event_bus_release(bus); free(worker); errno = cancellation_error; return NULL;
  }
  int error = pthread_mutex_init(&worker->mutex, NULL);
  if (error) {
    moonrun_event_bus_release(bus); free(worker); errno = error; return NULL;
  }
  error = pthread_cond_init(&worker->condition, NULL);
  if (error) {
    pthread_mutex_destroy(&worker->mutex);
    moonrun_event_bus_release(bus); free(worker); errno = error; return NULL;
  }
  /* The child must install its worker pointer before cancellation is delivered.
   * In particular, signal handlers must not interrupt lazy TLS allocation. */
  sigset_t blocked, previous_mask;
  sigfillset(&blocked);
  error = pthread_sigmask(SIG_SETMASK, &blocked, &previous_mask);
  if (!error) {
    error = pthread_create(&worker->thread, NULL, worker_loop, worker);
    pthread_sigmask(SIG_SETMASK, &previous_mask, NULL);
  }
  if (error) {
    pthread_cond_destroy(&worker->condition); pthread_mutex_destroy(&worker->mutex);
    moonrun_event_bus_release(bus); free(worker); errno = error; return NULL;
  }
#endif
  return worker;
}
MOONBIT_FFI_EXPORT int moonrun_native_worker_done(struct worker *worker) { return load_atomic(&worker->state) == 2; }
MOONBIT_FFI_EXPORT void moonrun_native_worker_cancel(struct worker *worker) {
  if (compare_atomic(&worker->state, 0, 1) == 2) return;
  if (worker->job->cancel_handler) worker->job->cancel_handler(worker->job->payload);
#ifdef _WIN32
  CancelSynchronousIo(worker->thread);
#else
  pthread_kill(worker->thread, SIGUSR2);
#endif
}
MOONBIT_FFI_EXPORT void moonrun_native_worker_free(struct worker *worker) {
  /* Cancellation can race with entering a syscall. Retry until the worker
   * acknowledges completion, as in Rust moonrun's cancellation state machine. */
  while (!moonrun_native_worker_done(worker)) {
    moonrun_native_worker_cancel(worker);
#ifdef _WIN32
    Sleep(1);
#else
    struct timespec pause = {0, 1000000}; nanosleep(&pause, NULL);
#endif
  }
#ifdef _WIN32
  store_atomic(&worker->stopping, 1); SetEvent(worker->event);
  while (WaitForSingleObject(worker->thread, 1) == WAIT_TIMEOUT) CancelSynchronousIo(worker->thread);
  CloseHandle(worker->thread); CloseHandle(worker->event);
#else
  pthread_mutex_lock(&worker->mutex);
  store_atomic(&worker->stopping, 1);
  pthread_cond_signal(&worker->condition);
  pthread_mutex_unlock(&worker->mutex);
  pthread_join(worker->thread, NULL);
  pthread_cond_destroy(&worker->condition); pthread_mutex_destroy(&worker->mutex);
#endif
  moonrun_event_bus_release(worker->bus);
  free(worker);
}
#ifndef _WIN32
extern int moonrun_native_safe_write(int, const void *, int);
#endif
#include "jobs.h"

#include "operation.h"
struct owned_io_job {
  HANDLE fd;
  void *file_lock;
  unsigned char *buffer;
  int length, reading, socket, flags;
  int64_t position;
};
static void free_owned_io_job(void *pointer) {
  struct owned_io_job *job = pointer;
  free(job->buffer);
}
/* Synchronous Windows positioned I/O changes the shared file pointer. Follow
 * Rust moonrun: serialize per-file calls and restore the original pointer.
 * Pipes and sockets keep independent read/write progress. */
MOONBIT_FFI_EXPORT void *moonrun_file_lock_create(HANDLE fd) {
#ifdef _WIN32
  if (GetFileType(fd) != FILE_TYPE_DISK) return NULL;
  CRITICAL_SECTION *lock = malloc(sizeof(*lock));
  if (!lock) abort();
  InitializeCriticalSection(lock); return lock;
#else
  struct stat status;
  if (fstat(fd, &status) < 0 || !S_ISDIR(status.st_mode)) return NULL;
  pthread_mutex_t *lock = malloc(sizeof(*lock));
  if (!lock || pthread_mutex_init(lock, NULL)) abort();
  return lock;
#endif
}
MOONBIT_FFI_EXPORT void moonrun_file_lock_free(void *lock) {
#ifdef _WIN32
  if (lock) { DeleteCriticalSection(lock); free(lock); }
#else
  if (lock) { pthread_mutex_destroy(lock); free(lock); }
#endif
}
int moonrun_file_lock_acquire(void *lock) {
  if (!lock) return 0;
  for (;;) {
    if (current_worker && load_atomic(&current_worker->state) == 1) {
#ifdef _WIN32
      SetLastError(ERROR_OPERATION_ABORTED);
#else
      errno = EINTR;
#endif
      return -1;
    }
#ifdef _WIN32
    if (TryEnterCriticalSection(lock)) return 0;
    Sleep(1);
#else
    int error = pthread_mutex_trylock(lock);
    if (!error) return 0;
    if (error != EBUSY) { errno = error; return -1; }
    struct timespec pause = {0, 1000000}; nanosleep(&pause, NULL);
#endif
  }
}
void moonrun_file_lock_release(void *lock) {
  if (!lock) return;
#ifdef _WIN32
  LeaveCriticalSection(lock);
#else
  pthread_mutex_unlock(lock);
#endif
}
MOONBIT_FFI_EXPORT void moonrun_operation_file_lock(moonrun_operation *operation, void *lock) {
  ((struct owned_io_job *)operation->job)->file_lock = lock;
}
static int32_t owned_file_io_worker(struct owned_io_job *job, int32_t *error) {
#ifdef _WIN32
  CRITICAL_SECTION *lock = job->file_lock;
  if (moonrun_file_lock_acquire(lock) < 0) { *error = GetLastError(); return -1; }
  LARGE_INTEGER saved, zero = {0};
  int restore = lock && job->position >= 0;
  if (restore && !SetFilePointerEx(job->fd, zero, &saved, FILE_CURRENT)) {
    *error = GetLastError(); LeaveCriticalSection(lock); return -1;
  }
#endif
  int32_t result;
  if (job->reading) {
    struct read_job input = {job->fd, (char *)job->buffer, 0, job->length, job->position};
    result = read_job_worker(&input, error);
  } else {
    struct write_job input = {job->fd, (char *)job->buffer, 0, job->length, job->position};
    result = write_job_worker(&input, error);
  }
#ifdef _WIN32
  if (restore && !SetFilePointerEx(job->fd, saved, NULL, FILE_BEGIN) && result >= 0) {
    *error = GetLastError(); result = -1;
  }
  if (lock) LeaveCriticalSection(lock);
#endif
  return result;
}
static int32_t owned_io_worker(void *pointer, int32_t *error) {
  struct owned_io_job *job = pointer;
  if (!job->socket) return owned_file_io_worker(job, error);
  for (;;) {
    struct worker *worker = current_worker;
    if (moonrun_native_enter_cancellable_region(worker)) {
#ifdef _WIN32
      *error = ERROR_OPERATION_ABORTED;
#else
      *error = EINTR;
#endif
      return -1;
    }
    int result = job->reading
      ? recv((SOCKET)job->fd, (char *)job->buffer, job->length, job->flags)
      : send((SOCKET)job->fd, (char *)job->buffer, job->length, job->flags);
    moonrun_native_leave_cancellable_region(worker);
    if (result >= 0) return result;
#ifdef _WIN32
    int code = WSAGetLastError();
    if (code != WSAEWOULDBLOCK) { *error = code; return -1; }
    WSAPOLLFD pollfd = {(SOCKET)job->fd, job->reading ? POLLRDNORM : POLLWRNORM, 0};
    if (WSAPoll(&pollfd, 1, 10) >= 0) continue;
    *error = WSAGetLastError(); return -1;
#else
    if (errno != EAGAIN && errno != EWOULDBLOCK) { *error = errno; return -1; }
    struct pollfd pollfd = {job->fd, job->reading ? POLLIN : POLLOUT, 0};
    if (moonrun_native_enter_cancellable_region(worker)) { *error = EINTR; return -1; }
    int ready = poll(&pollfd, 1, -1);
    moonrun_native_leave_cancellable_region(worker);
    if (ready < 0) { *error = errno; return -1; }
#endif
  }
}
MOONBIT_FFI_EXPORT void *moonrun_operation_io(HANDLE fd, unsigned char *data, int length,
    int reading, int socket, int flags, int64_t position) {
  struct owned_io_job *job = moonrun_native_make_job(sizeof(*job), free_owned_io_job, owned_io_worker, NULL);
  job->fd = fd; job->file_lock = NULL; job->length = length; job->reading = reading;
  job->socket = socket; job->flags = flags; job->position = position;
#ifdef MSG_NOSIGNAL
  if (socket) job->flags |= MSG_NOSIGNAL;
#endif
  job->buffer = calloc(length ? length : 1, 1);
  if (!job->buffer) abort();
  if (!reading && length) memcpy(job->buffer, data, length);
  return moonrun_operation_wrap(job, job->buffer, reading ? length : 0, reading ? 20 : 21);
}
MOONBIT_FFI_EXPORT void *moonrun_operation_sleep(int milliseconds) {
  return moonrun_operation_wrap(moonrun_native_make_sleep_job(milliseconds), NULL, 0, 22);
}

struct network_job {
  HANDLE fd, accepted;
  unsigned char *address, *buffer;
  int address_length, length, kind, flags;
};
static void free_network_job(void *pointer) {
  struct network_job *job = pointer;
  if (job->accepted != (HANDLE)-1) {
#ifdef _WIN32
    closesocket((SOCKET)job->accepted);
#else
    close(job->accepted);
#endif
  }
  free(job->address); free(job->buffer);
}
static int32_t network_job_worker(void *pointer, int32_t *error) {
  struct network_job *job = pointer;
  int connecting = 0;
  for (;;) {
    if (moonrun_native_enter_cancellable_region(current_worker)) {
#ifdef _WIN32
      *error = ERROR_OPERATION_ABORTED;
#else
      *error = EINTR;
#endif
      return -1;
    }
    int result;
#ifdef _WIN32
    int address_length = job->address_length;
#else
    socklen_t address_length = job->address_length;
#endif
    if (connecting) {
      int status = 0;
      address_length = sizeof(status);
      result = getsockopt((SOCKET)job->fd, SOL_SOCKET, SO_ERROR, (char *)&status, &address_length);
      if (!result && status) {
#ifdef _WIN32
        WSASetLastError(status);
#else
        errno = status;
#endif
        result = -1;
      }
    } else switch (job->kind) {
      case 0: result = bind((SOCKET)job->fd, (struct sockaddr *)job->address, address_length); break;
      case 1: result = connect((SOCKET)job->fd, (struct sockaddr *)job->address, address_length); break;
      case 2: result = sendto((SOCKET)job->fd, (char *)job->buffer, job->length, job->flags, (struct sockaddr *)job->address, address_length); break;
      case 3: result = recvfrom((SOCKET)job->fd, (char *)job->buffer, job->length, job->flags, (struct sockaddr *)job->address, &address_length); break;
      default:
        job->accepted = (HANDLE)accept((SOCKET)job->fd, (struct sockaddr *)job->address, &address_length);
        result = job->accepted == (HANDLE)-1 ? -1 : 0;
        break;
    }
    moonrun_native_leave_cancellable_region(current_worker);
    if (result >= 0) return result;
#ifdef _WIN32
    int code = WSAGetLastError();
    int blocked = code == WSAEWOULDBLOCK || code == WSAEINPROGRESS;
#else
    int code = errno;
    int blocked = code == EAGAIN || code == EWOULDBLOCK || code == EINPROGRESS;
#endif
    if (!blocked || connecting || job->kind == 0) { *error = code; return -1; }
    if (job->kind == 1) connecting = 1;
    for (;;) {
      if (moonrun_native_enter_cancellable_region(current_worker)) {
#ifdef _WIN32
        *error = ERROR_OPERATION_ABORTED;
#else
        *error = EINTR;
#endif
        return -1;
      }
#ifdef _WIN32
      WSAPOLLFD pollfd = {(SOCKET)job->fd, job->kind >= 3 ? POLLRDNORM : POLLWRNORM, 0};
      int ready = WSAPoll(&pollfd, 1, 10);
#else
      struct pollfd pollfd = {job->fd, job->kind >= 3 ? POLLIN : POLLOUT, 0};
      int ready = poll(&pollfd, 1, -1);
#endif
      moonrun_native_leave_cancellable_region(current_worker);
      if (ready > 0) break;
      if (ready < 0) {
#ifdef _WIN32
        *error = WSAGetLastError();
#else
        *error = errno;
#endif
        return -1;
      }
    }
  }
}
MOONBIT_FFI_EXPORT void *moonrun_operation_network(int kind, HANDLE fd,
    unsigned char *address, int address_length, unsigned char *data, int length, int flags) {
  struct network_job *job = moonrun_native_make_job(sizeof(*job), free_network_job, network_job_worker, NULL);
  job->kind = kind; job->fd = fd; job->accepted = (HANDLE)-1;
  job->address_length = address_length; job->length = length; job->flags = flags;
#ifdef MSG_NOSIGNAL
  job->flags |= MSG_NOSIGNAL;
#endif
  job->address = calloc(address_length ? address_length : 1, 1);
  job->buffer = calloc(length ? length : 1, 1);
  if (!job->address || !job->buffer) abort();
  memcpy(job->address, address, address_length);
  if (kind == 2 && length) memcpy(job->buffer, data, length);
  return moonrun_operation_wrap(job, kind == 3 ? job->buffer : NULL, kind == 3 ? length : 0, 31);
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrun_operation_peer(moonrun_operation *operation) {
  struct network_job *job = operation->job;
  moonbit_bytes_t out = moonbit_make_bytes(job->address_length, 0);
  memcpy(out, job->address, job->address_length); return out;
}
MOONBIT_FFI_EXPORT HANDLE moonrun_network_take_fd(void *pointer) {
  struct network_job *job = pointer;
  HANDLE fd = job->accepted; job->accepted = (HANDLE)-1; return fd;
}

MOONBIT_FFI_EXPORT int moonrun_native_worker_is_null(void *worker) { return worker == NULL; }

MOONBIT_FFI_EXPORT int moonrun_native_worker_notice(struct worker *worker) {
  return load_atomic(&worker->notice);
}
MOONBIT_FFI_EXPORT int moonrun_native_worker_take_notice(struct worker *worker) {
  return compare_atomic(&worker->notice, 1, 0) == 1;
}
MOONBIT_FFI_EXPORT int moonrun_native_worker_id(struct worker *worker) { return worker->id; }

/* Retrying at VM checkpoints covers cancellation racing with syscall entry,
 * including Windows ERROR_NOT_FOUND and an embedding loop's signal handler. */
MOONBIT_FFI_EXPORT int moonrun_native_worker_poll(struct worker *worker) {
  if (load_atomic(&worker->state) == 1) moonrun_native_worker_cancel(worker);
  return moonrun_native_worker_done(worker);
}
