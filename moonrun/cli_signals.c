/* The standalone executable owns OS signal handlers. The embedding library
 * only accepts explicit, per-run delivery and never installs these handlers. */
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
typedef HANDLE cli_fd;
static SRWLOCK signal_lock = SRWLOCK_INIT;
typedef struct { HANDLE write, event; volatile LONG pending; } signal_relay;
static signal_relay *active_relay;
static BOOL WINAPI relay_handler(DWORD signal) {
  unsigned bit;
  switch (signal) {
    case CTRL_C_EVENT: bit = 1; break;
    case CTRL_CLOSE_EVENT: bit = 4; break;
    case CTRL_BREAK_EVENT: bit = 8; break;
    default: return FALSE;
  }
  AcquireSRWLockExclusive(&signal_lock);
  signal_relay *relay = active_relay;
  if (relay && !InterlockedOr(&relay->pending, (LONG)bit)) {
    unsigned char byte = 1;
    DWORD count;
    OVERLAPPED operation = {0};
    ResetEvent(relay->event);
    operation.hEvent = (HANDLE)((uintptr_t)relay->event | 1);
    if (!WriteFile(relay->write, &byte, 1, &count, &operation) && GetLastError() == ERROR_IO_PENDING)
      GetOverlappedResult(relay->write, &operation, &count, TRUE);
  }
  ReleaseSRWLockExclusive(&signal_lock);
  return relay != NULL;
}
#else
#include <errno.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <sched.h>
#include <stdatomic.h>
typedef int cli_fd;
typedef struct { int write; _Atomic unsigned pending; struct sigaction previous[3]; } signal_relay;
static _Atomic(signal_relay *) active_relay;
static _Atomic unsigned active_handlers;
_Static_assert(ATOMIC_POINTER_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2,
               "signal relay requires lock-free atomics");
static const int relay_signals[] = { SIGINT, SIGTERM, SIGHUP };
static void relay_handler(int signal) {
  int saved_errno = errno;
  atomic_fetch_add(&active_handlers, 1);
  signal_relay *relay = atomic_load(&active_relay);
  if (relay) {
    unsigned bit = signal == SIGINT ? 1 : signal == SIGTERM ? 2 : 4;
    if (!atomic_fetch_or(&relay->pending, bit)) {
      unsigned char byte = 1;
      ssize_t count;
      do { count = write(relay->write, &byte, 1); } while (count < 0 && errno == EINTR);
    }
  }
  atomic_fetch_sub(&active_handlers, 1);
  errno = saved_errno;
}
#endif

MOONBIT_FFI_EXPORT void *moonrun_cli_signal_open(cli_fd write_fd) {
  signal_relay *relay = calloc(1, sizeof(*relay));
  if (!relay) return NULL;
#ifdef _WIN32
  if (!DuplicateHandle(GetCurrentProcess(), write_fd, GetCurrentProcess(), &relay->write,
                       0, FALSE, DUPLICATE_SAME_ACCESS)) goto fail;
  relay->event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!relay->event) goto fail_write;
  AcquireSRWLockExclusive(&signal_lock);
  active_relay = relay;
  ReleaseSRWLockExclusive(&signal_lock);
  if (SetConsoleCtrlHandler(relay_handler, TRUE)) return relay;
  AcquireSRWLockExclusive(&signal_lock);
  active_relay = NULL;
  ReleaseSRWLockExclusive(&signal_lock);
  CloseHandle(relay->event);
fail_write:
  CloseHandle(relay->write);
#else
  relay->write = fcntl(write_fd, F_DUPFD_CLOEXEC, 0);
  if (relay->write < 0) goto fail;
  int flags = fcntl(relay->write, F_GETFL);
  if (flags < 0 || fcntl(relay->write, F_SETFL, flags | O_NONBLOCK) < 0) goto fail_write;
  struct sigaction action = {0};
  action.sa_handler = relay_handler;
  sigemptyset(&action.sa_mask);
  action.sa_flags = SA_RESTART;
  int installed = 0;
  atomic_store(&active_relay, relay);
  for (; installed < 3; ++installed)
    if (sigaction(relay_signals[installed], &action, &relay->previous[installed]) < 0) break;
  if (installed == 3) return relay;
  atomic_store(&active_relay, NULL);
  while (installed--) sigaction(relay_signals[installed], &relay->previous[installed], NULL);
  while (atomic_load(&active_handlers)) sched_yield();
fail_write:
  close(relay->write);
#endif
fail:
  free(relay);
  return NULL;
}

MOONBIT_FFI_EXPORT int moonrun_cli_signal_is_null(void *relay) { return relay == NULL; }
MOONBIT_FFI_EXPORT int moonrun_cli_signal_take(void *pointer) {
#ifdef _WIN32
  return (int)InterlockedExchange(&((signal_relay *)pointer)->pending, 0);
#else
  return (int)atomic_exchange(&((signal_relay *)pointer)->pending, 0);
#endif
}
MOONBIT_FFI_EXPORT void moonrun_cli_signal_close(void *pointer) {
  signal_relay *relay = pointer;
#ifdef _WIN32
  SetConsoleCtrlHandler(relay_handler, FALSE);
  AcquireSRWLockExclusive(&signal_lock);
  active_relay = NULL;
  ReleaseSRWLockExclusive(&signal_lock);
  CloseHandle(relay->event);
  CloseHandle(relay->write);
#else
  atomic_store(&active_relay, NULL);
  for (int i = 0; i < 3; ++i) sigaction(relay_signals[i], &relay->previous[i], NULL);
  while (atomic_load(&active_handlers)) sched_yield();
  close(relay->write);
#endif
  free(relay);
}
