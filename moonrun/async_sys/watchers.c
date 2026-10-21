#include <moonbit.h>
#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
typedef HANDLE watcher_fd;
#else
#include <errno.h>
#include <unistd.h>
typedef int watcher_fd;
#ifdef __APPLE__
#include <sys/event.h>
#else
#include <sys/inotify.h>
#endif
#endif

MOONBIT_FFI_EXPORT watcher_fd moonrun_watcher_create(void) {
#ifdef _WIN32
  SetLastError(ERROR_NOT_SUPPORTED); return INVALID_HANDLE_VALUE;
#elif defined(__APPLE__)
  extern int moonrun_native_kqueue_watcher_create(void);
  return moonrun_native_kqueue_watcher_create();
#else
  return inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
#endif
}
MOONBIT_FFI_EXPORT int64_t moonrun_fd_word(watcher_fd fd) { return (int64_t)(uintptr_t)fd; }
MOONBIT_FFI_EXPORT int moonrun_watcher_buffer_size(void) {
#ifdef __APPLE__
  return 1024 * (int)sizeof(struct kevent);
#else
  return 4096;
#endif
}
MOONBIT_FFI_EXPORT int moonrun_watcher_fetch(watcher_fd fd, unsigned char *buffer, int length) {
#ifdef _WIN32
  (void)fd; (void)buffer; (void)length;
  SetLastError(ERROR_NOT_SUPPORTED); return -1;
#elif defined(__APPLE__)
  struct timespec timeout = {0, 0};
  return kevent(fd, NULL, 0, (struct kevent *)buffer, length / (int)sizeof(struct kevent), &timeout);
#else
  int count = (int)read(fd, buffer, (size_t)length);
  return count < 0 && errno == EAGAIN ? 0 : count;
#endif
}
MOONBIT_FFI_EXPORT int moonrun_watcher_add_file(watcher_fd watcher, watcher_fd fd, int directory) {
#ifdef __APPLE__
  extern int moonrun_native_kqueue_watcher_add_file(int, int, int);
  return moonrun_native_kqueue_watcher_add_file(watcher, fd, directory);
#else
  (void)watcher; (void)fd; (void)directory;
#ifdef _WIN32
  SetLastError(ERROR_NOT_SUPPORTED);
#else
  errno = ENOTSUP;
#endif
  return -1;
#endif
}
MOONBIT_FFI_EXPORT int moonrun_watcher_remove_file(watcher_fd watcher, int wd) {
#ifdef __linux__
  return inotify_rm_watch(watcher, wd);
#else
  (void)watcher; (void)wd;
#ifdef _WIN32
  SetLastError(ERROR_NOT_SUPPORTED);
#else
  errno = ENOTSUP;
#endif
  return -1;
#endif
}
