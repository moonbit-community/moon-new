/* Per-run synchronous IOCP/kqueue/epoll storage. Workers publish through OS notifications. */
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#include <wchar.h>
typedef HANDLE poll_handle;
typedef OVERLAPPED_ENTRY poll_event;
#else
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/event.h>
typedef struct kevent poll_event;
#else
#include <sys/epoll.h>
#include <sys/eventfd.h>
typedef struct epoll_event poll_event;
#endif
typedef int poll_handle;
#endif

extern char *moonrun_native_errno_to_string(int);
extern void moonrun_native_free_errno_str(void *);

MOONBIT_FFI_EXPORT moonbit_bytes_t moonrun_error_message(int code) {
  char *message = moonrun_native_errno_to_string(code);
#ifdef _WIN32
  size_t length = (wcslen((wchar_t *)message) + 1) * sizeof(wchar_t);
#else
  size_t length = strlen(message) + 1;
#endif
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)length, 0);
  memcpy(bytes, message, length);
  moonrun_native_free_errno_str(message);
  return bytes;
}

#define EVENT_CAPACITY 1024
typedef struct {
  poll_handle poll;
#ifdef _WIN32
  volatile LONG references, closed;
#else
  _Atomic int references, closed;
#endif
#ifdef _WIN32
  WSAEVENT socket_event;
  SOCKET socket;
  int socket_flags;
#endif
  int count, error;
  poll_event events[EVENT_CAPACITY];
} guest_event_bus;

static int wait_poll(guest_event_bus *bus, int timeout) {
#ifdef _WIN32
  if (bus->socket_event) {
    DWORD result = WSAWaitForMultipleEvents(1, &bus->socket_event, FALSE,
                                           timeout < 0 ? WSA_INFINITE : (DWORD)timeout, FALSE);
    if (result == WSA_WAIT_TIMEOUT) return 0;
    if (result == WSA_WAIT_FAILED) { bus->error = WSAGetLastError(); return -1; }
    WSANETWORKEVENTS events = {0};
    if (WSAEnumNetworkEvents(bus->socket, bus->socket_event, &events) < 0) {
      bus->error = WSAGetLastError(); return -1;
    }
    int flags = 0;
    if (events.lNetworkEvents & (FD_READ | FD_ACCEPT)) flags |= 1;
    if (events.lNetworkEvents & (FD_WRITE | FD_CONNECT)) flags |= 2;
    if (events.lNetworkEvents & FD_CLOSE) flags |= 3;
    if (events.lNetworkEvents & FD_CONNECT) bus->error = events.iErrorCode[FD_CONNECT_BIT];
    for (int index = 0; index < FD_MAX_EVENTS; ++index)
      if (events.iErrorCode[index]) flags |= 3;
    bus->socket_flags = flags;
    return 1;
  }
  ULONG count = 0;
  if (!GetQueuedCompletionStatusEx(bus->poll, bus->events, EVENT_CAPACITY,
                                  &count, timeout < 0 ? INFINITE : (DWORD)timeout, FALSE)) {
    bus->error = (int)GetLastError();
    return bus->error == WAIT_TIMEOUT ? 0 : -1;
  }
  return (int)count;
#elif defined(__APPLE__)
  struct timespec duration = { timeout / 1000, (timeout % 1000) * 1000000 };
  int count = kevent(bus->poll, NULL, 0, bus->events, EVENT_CAPACITY,
                     timeout < 0 ? NULL : &duration);
  if (count < 0) bus->error = errno;
  return count;
#else
  int count = epoll_wait(bus->poll, bus->events, EVENT_CAPACITY, timeout);
  if (count < 0) bus->error = errno;
  return count;
#endif
}

MOONBIT_FFI_EXPORT void *moonrun_event_bus_create(poll_handle unused) {
  (void)unused;
  guest_event_bus *bus = calloc(1, sizeof(*bus));
  if (!bus) return NULL;
  bus->references = 1;
#ifdef _WIN32
  bus->poll = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);
  if (!bus->poll) { free(bus); return NULL; }
#elif defined(__APPLE__)
  bus->poll = kqueue();
  if (bus->poll < 0) { free(bus); return NULL; }
  if (fcntl(bus->poll, F_SETFD, FD_CLOEXEC) < 0) { close(bus->poll); free(bus); return NULL; }
#else
  bus->poll = epoll_create1(EPOLL_CLOEXEC);
  if (bus->poll < 0) { free(bus); return NULL; }
#endif
  return bus;
}

MOONBIT_FFI_EXPORT int moonrun_event_bus_is_null(void *bus) { return bus == NULL; }

MOONBIT_FFI_EXPORT int moonrun_event_bus_watch_socket(void *pointer, poll_handle fd) {
#ifdef _WIN32
  guest_event_bus *bus = pointer;
  bus->socket_event = WSACreateEvent();
  if (bus->socket_event == WSA_INVALID_EVENT) { bus->socket_event = NULL; return -1; }
  bus->socket = (SOCKET)fd;
  if (WSAEventSelect(bus->socket, bus->socket_event, FD_READ | FD_WRITE | FD_CONNECT | FD_ACCEPT | FD_CLOSE) < 0) {
    int error = WSAGetLastError(); WSACloseEvent(bus->socket_event); bus->socket_event = NULL;
    WSASetLastError(error); return -1;
  }
  return 1;
#else
  (void)pointer; (void)fd; errno = ENOTSUP; return -1;
#endif
}

MOONBIT_FFI_EXPORT void moonrun_event_bus_begin(void *pointer, int timeout) {
  guest_event_bus *bus = pointer;
  bus->error = 0;
  bus->count = wait_poll(bus, timeout);
}
MOONBIT_FFI_EXPORT int moonrun_event_bus_result(void *pointer) { return ((guest_event_bus *)pointer)->count; }
MOONBIT_FFI_EXPORT int moonrun_event_bus_errno(void *pointer) { return ((guest_event_bus *)pointer)->error; }

MOONBIT_FFI_EXPORT int moonrun_event_bus_register(
    void *pointer, poll_handle fd, int read_only, int64_t key) {
  guest_event_bus *bus = pointer;
#ifdef _WIN32
  (void)read_only;
  if (!SetFileCompletionNotificationModes(fd, FILE_SKIP_COMPLETION_PORT_ON_SUCCESS))
    return -1;
  return CreateIoCompletionPort(fd, bus->poll, (ULONG_PTR)key, 0) ? 1 : -1;
#else
  int flags = fcntl(fd, F_GETFL);
  if (flags >= 0 && !(flags & O_NONBLOCK)) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
#if defined(__APPLE__)
  struct kevent changes[2], receipts[2];
  EV_SET(&changes[0], fd, EVFILT_READ, EV_ADD | EV_CLEAR | EV_RECEIPT,
         0, 0, (void *)(uintptr_t)key);
  EV_SET(&changes[1], fd, EVFILT_WRITE, EV_ADD | EV_CLEAR | EV_RECEIPT,
         0, 0, (void *)(uintptr_t)key);
  int count = kevent(bus->poll, changes, read_only ? 1 : 2, receipts, 2, NULL);
  if (count < 0) return -1;
  for (int i = 0; i < count; ++i) if (receipts[i].data == 0) return 1;
  return 0;
#else
  struct epoll_event event = {
    .events = EPOLLIN | EPOLLET | EPOLLRDHUP | (read_only ? 0 : EPOLLOUT),
    .data.u64 = (uint64_t)key
  };
  if (epoll_ctl(bus->poll, EPOLL_CTL_ADD, fd, &event) == 0) return 1;
  return errno == EPERM ? 0 : -1;
#endif
#endif
}

MOONBIT_FFI_EXPORT int64_t moonrun_event_bus_event_fd(void *pointer, int index) {
  guest_event_bus *bus = pointer;
#ifdef _WIN32
  return (int64_t)bus->events[index].lpCompletionKey;
#elif defined(__APPLE__)
  return (int64_t)(uintptr_t)bus->events[index].udata;
#else
  return (int64_t)bus->events[index].data.u64;
#endif
}

MOONBIT_FFI_EXPORT int moonrun_event_bus_event_flags(void *pointer, int index) {
  guest_event_bus *bus = pointer;
#ifdef _WIN32
  (void)index;
  return bus->socket_event ? bus->socket_flags : 0;
#elif defined(__APPLE__)
  if (bus->events[index].filter == EVFILT_READ) return 1;
  if (bus->events[index].filter == EVFILT_WRITE) return 2;
  if (bus->events[index].filter == EVFILT_PROC) return 4;
  if (bus->events[index].flags & EV_ERROR) return 3;
  return 0;
#else
  uint32_t flags = bus->events[index].events;
  if (flags & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) return 3;
  return ((flags & EPOLLIN) ? 1 : 0) | ((flags & EPOLLOUT) ? 2 : 0);
#endif
}

MOONBIT_FFI_EXPORT int moonrun_event_bus_event_bytes(void *pointer, int index) {
#ifdef _WIN32
  return (int)((guest_event_bus *)pointer)->events[index].dwNumberOfBytesTransferred;
#else
  (void)pointer; (void)index;
  return 0;
#endif
}

MOONBIT_FFI_EXPORT int64_t moonrun_event_bus_event_token(void *pointer, int index) {
#ifdef _WIN32
  return (int64_t)(uintptr_t)((guest_event_bus *)pointer)->events[index].lpOverlapped;
#else
  (void)pointer; (void)index;
  return 0;
#endif
}

MOONBIT_FFI_EXPORT int moonrun_event_bus_event_pid(void *pointer, int index) {
#ifdef __APPLE__
  return (int)((guest_event_bus *)pointer)->events[index].ident;
#else
  (void)pointer; (void)index;
  return 0;
#endif
}

MOONBIT_FFI_EXPORT int moonrun_event_bus_register_completion(void *pointer, poll_handle fd, int64_t key) {
  guest_event_bus *bus = pointer;
#ifdef _WIN32
  (void)bus; (void)fd; (void)key;
  SetLastError(ERROR_NOT_SUPPORTED);
  return -1;
#elif defined(__APPLE__)
  struct kevent event;
  EV_SET(&event, fd, EVFILT_READ, EV_ADD, 0, 0, (void *)(uintptr_t)key);
  return kevent(bus->poll, &event, 1, NULL, 0, NULL);
#else
  struct epoll_event event = { .events = EPOLLIN, .data.u64 = (uint64_t)key };
  return epoll_ctl(bus->poll, EPOLL_CTL_ADD, fd, &event);
#endif
}

MOONBIT_FFI_EXPORT int moonrun_event_bus_post(void *pointer, int64_t key, int64_t token, int bytes) {
#ifdef _WIN32
  guest_event_bus *bus = pointer;
  if (InterlockedCompareExchange(&bus->closed, 0, 0)) return 0;
  // The token is an opaque guest operation ID, never dereferenced as a pointer.
  return PostQueuedCompletionStatus(bus->poll, (DWORD)bytes, (ULONG_PTR)key,
                                   (OVERLAPPED *)(uintptr_t)token) ? 0 : -1;
#else
  (void)pointer; (void)key; (void)token; (void)bytes;
  errno = ENOTSUP;
  return -1;
#endif
}

MOONBIT_FFI_EXPORT int moonrun_completion_signal(poll_handle fd) {
#ifdef _WIN32
  (void)fd;
  SetLastError(ERROR_NOT_SUPPORTED);
  return -1;
#else
  unsigned char byte = 1;
  ssize_t result;
  do { result = write(fd, &byte, 1); } while (result < 0 && errno == EINTR);
  return (int)result;
#endif
}

MOONBIT_FFI_EXPORT int moonrun_completion_drain(poll_handle fd) {
#ifdef _WIN32
  (void)fd;
  SetLastError(ERROR_NOT_SUPPORTED);
  return -1;
#else
  unsigned char byte;
  ssize_t result;
  do { result = read(fd, &byte, 1); } while (result < 0 && errno == EINTR);
  return (int)result;
#endif
}

MOONBIT_FFI_EXPORT int moonrun_pipe_read(poll_handle fd, unsigned char *data, int length) {
#ifdef _WIN32
DWORD count;
if (ReadFile(fd, data, (DWORD)length, &count, NULL)) return (int)count;
return GetLastError() == ERROR_BROKEN_PIPE ? 0 : -1;
#else
  return (int)read(fd, data, (size_t)length);
#endif
}

#ifndef _WIN32
extern int moonrun_native_safe_write(int, const void *, int);
#endif
MOONBIT_FFI_EXPORT int moonrun_pipe_write(poll_handle fd, unsigned char *data, int length) {
#ifdef _WIN32
DWORD count;
return WriteFile(fd, data, (DWORD)length, &count, NULL) ? (int)count : -1;
#else
  return moonrun_native_safe_write(fd, data, length);
#endif
}

MOONBIT_FFI_EXPORT poll_handle moonrun_invalid_fd(void) {
#ifdef _WIN32
  return INVALID_HANDLE_VALUE;
#else
  return -1;
#endif
}

MOONBIT_FFI_EXPORT int moonrun_fd_cloexec(poll_handle fd) {
#ifdef _WIN32
  return SetHandleInformation(fd, HANDLE_FLAG_INHERIT, 0) ? 0 : -1;
#else
  int flags = fcntl(fd, F_GETFD);
  return flags < 0 ? -1 : fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
#endif
}

MOONBIT_FFI_EXPORT int moonrun_close_pipe(poll_handle fd) {
#ifdef _WIN32
  return CloseHandle(fd) ? 0 : -1;
#else
  return close(fd);
#endif
}

MOONBIT_FFI_EXPORT int moonrun_create_pipe(poll_handle *fds, int read_async, int write_async) {
#ifdef _WIN32
  static LONG64 next_pipe = 0;
  WCHAR name[128];
  _snwprintf(name, 128, L"\\\\.\\pipe\\moonrun_guest.%lu.%lld",
             GetCurrentProcessId(), (long long)InterlockedIncrement64(&next_pipe));
  HANDLE write_fd = CreateNamedPipeW(name,
      PIPE_ACCESS_OUTBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE |
        (write_async ? FILE_FLAG_OVERLAPPED : 0),
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
      1, 1024, 1024, 0, NULL);
  if (write_fd == INVALID_HANDLE_VALUE) return -1;
  HANDLE read_fd = CreateFileW(name, GENERIC_READ, 0, NULL, OPEN_EXISTING,
                               read_async ? FILE_FLAG_OVERLAPPED : 0, NULL);
  if (read_fd == INVALID_HANDLE_VALUE) {
    DWORD error = GetLastError();
    CloseHandle(write_fd);
    SetLastError(error);
    return -1;
  }
  fds[0] = read_fd;
  fds[1] = write_fd;
  return 0;
#else
  if (pipe(fds) < 0) return -1;
  for (int i = 0; i < 2; ++i) {
    int flags = fcntl(fds[i], F_GETFD);
    if (flags < 0 || fcntl(fds[i], F_SETFD, flags | FD_CLOEXEC) < 0) goto fail;
    if ((i == 0 ? read_async : write_async)) {
      flags = fcntl(fds[i], F_GETFL);
      if (flags < 0 || fcntl(fds[i], F_SETFL, flags | O_NONBLOCK) < 0) goto fail;
    }
  }
#ifdef __APPLE__
  if (fcntl(fds[1], F_SETNOSIGPIPE, 1) < 0) goto fail;
#endif
  return 0;
fail: {
    int error = errno;
    close(fds[0]);
    close(fds[1]);
    errno = error;
    return -1;
  }
#endif
}

/* A worker retains native storage through its last completion. Logical guest
 * close prevents new posts; the OS handle is released after all workers join. */
void moonrun_event_bus_retain(void *pointer) {
  if (!pointer) return;
  guest_event_bus *bus = pointer;
#ifdef _WIN32
  InterlockedIncrement(&bus->references);
#else
  atomic_fetch_add(&bus->references, 1);
#endif
}
void moonrun_event_bus_release(void *pointer) {
  if (!pointer) return;
  guest_event_bus *bus = pointer;
#ifdef _WIN32
  if (InterlockedDecrement(&bus->references)) return;
  if (bus->socket_event) {
    WSAEventSelect(bus->socket, NULL, 0);
    WSACloseEvent(bus->socket_event);
  }
  CloseHandle(bus->poll);
#else
  if (atomic_fetch_sub(&bus->references, 1) != 1) return;
  close(bus->poll);
#endif
  free(bus);
}
MOONBIT_FFI_EXPORT void moonrun_event_bus_close(void *pointer) {
  guest_event_bus *bus = pointer;
#ifdef _WIN32
  InterlockedExchange(&bus->closed, 1);
#else
  atomic_store(&bus->closed, 1);
#endif
  moonrun_event_bus_release(bus);
}

MOONBIT_FFI_EXPORT int moonrun_event_bus_register_pid(void *pointer, int pid) {
#ifdef __APPLE__
  guest_event_bus *bus = pointer;
  struct kevent event;
  EV_SET(&event, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
  if (kevent(bus->poll, &event, 1, NULL, 0, NULL) == 0) return 1;
  return errno == ESRCH ? 0 : -1;
#else
  (void)pointer; (void)pid;
#ifdef _WIN32
  SetLastError(ERROR_NOT_SUPPORTED);
#else
  errno = ENOTSUP;
#endif
  return -1;
#endif
}

MOONBIT_FFI_EXPORT int moonrun_fd_nonblocking(poll_handle fd) {
#ifdef _WIN32
  DWORD mode = PIPE_NOWAIT;
  return SetNamedPipeHandleState(fd, &mode, NULL, NULL) ? 0 : -1;
#else
  int flags = fcntl(fd, F_GETFL);
  return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
#endif
}
MOONBIT_FFI_EXPORT void *moonrun_event_bus_null(void) { return NULL; }
