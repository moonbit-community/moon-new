/* Private blocking notification pipes for SQLite executor acknowledgements. */
#include <moonbit.h>
#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
typedef HANDLE pipe_fd;
#else
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
typedef int pipe_fd;
#endif
MOONBIT_FFI_EXPORT int moonrun_sqlite_pipe(pipe_fd *output) {
#ifdef _WIN32
  return CreatePipe(&output[0], &output[1], NULL, 0) ? 0 : -1;
#else
  if (pipe(output) < 0) return -1;
  for (int index = 0; index < 2; ++index) {
    if (fcntl(output[index], F_SETFD, FD_CLOEXEC) < 0) { int error = errno; close(output[0]); close(output[1]); errno = error; return -1; }
  }
  return 0;
#endif
}
MOONBIT_FFI_EXPORT pipe_fd moonrun_sqlite_invalid_fd(void) { return (pipe_fd)-1; }
MOONBIT_FFI_EXPORT int moonrun_sqlite_pipe_read(pipe_fd fd, unsigned char *buffer, int length) {
#ifdef _WIN32
  DWORD count;
  if (ReadFile(fd, buffer, length, &count, NULL)) return (int)count;
  return GetLastError() == ERROR_BROKEN_PIPE ? 0 : -1;
#else
  int count;
  do { count = (int)read(fd, buffer, length); } while (count < 0 && errno == EINTR);
  return count;
#endif
}
MOONBIT_FFI_EXPORT void moonrun_sqlite_pipe_close(pipe_fd fd) {
#ifdef _WIN32
  CloseHandle(fd);
#else
  close(fd);
#endif
}
#ifdef _WIN32
MOONBIT_FFI_EXPORT uint64_t moonrun_sqlite_fd_word(pipe_fd fd) { return (uintptr_t)fd; }
#endif
