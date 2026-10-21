/* Synchronous OS adapters. All borrowed MoonBit buffers are used only during
 * the FFI call; native workers receive separate, C-owned copies. */
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
typedef HANDLE native_fd;
#else
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <poll.h>
#include <time.h>
#include <net/if.h>
typedef int native_fd;
#endif
extern native_fd moonrun_native_open_sync(void *, int, int, int, int, int, int);
MOONBIT_FFI_EXPORT native_fd moonrun_native_open(unsigned char *path, int access,
    int create, int append, int sync, int mode) {
  return moonrun_native_open_sync(path, access, 0, create, append, sync, mode);
}
MOONBIT_FFI_EXPORT native_fd moonrun_native_standard_fd(int id) {
#ifdef _WIN32
  return GetStdHandle(id == 0 ? STD_INPUT_HANDLE : id == 1 ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE);
#else
  return id;
#endif
}
MOONBIT_FFI_EXPORT void moonrun_native_pause(int milliseconds) {
#ifdef _WIN32
  Sleep(milliseconds);
#else
  struct timespec duration = {milliseconds / 1000, (milliseconds % 1000) * 1000000};
  nanosleep(&duration, NULL);
#endif
}
MOONBIT_FFI_EXPORT int64_t moonrun_native_now(void) {
#ifdef _WIN32
  FILETIME time; GetSystemTimeAsFileTime(&time);
  ULARGE_INTEGER value; value.LowPart = time.dwLowDateTime; value.HighPart = time.dwHighDateTime;
  return (int64_t)(value.QuadPart / 10000 - 11644473600000ULL);
#else
  struct timespec time; clock_gettime(CLOCK_REALTIME, &time);
  return (int64_t)time.tv_sec * 1000 + time.tv_nsec / 1000000;
#endif
}
#ifndef _WIN32
#include <dirent.h>
#endif
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrun_native_listdir(unsigned char *path, int32_t *error) {
  unsigned char *buffer = NULL;
  size_t length = 0;
  *error = 0;
#ifdef _WIN32
  size_t path_length = wcslen((WCHAR *)path);
  WCHAR *pattern = calloc(path_length + 3, sizeof(WCHAR));
  if (!pattern) abort();
  memcpy(pattern, path, path_length * 2);
  pattern[path_length] = L'\\'; pattern[path_length + 1] = L'*';
  WIN32_FIND_DATAW entry;
  HANDLE directory = FindFirstFileW(pattern, &entry);
  free(pattern);
  if (directory == INVALID_HANDLE_VALUE) { *error = GetLastError(); goto done; }
  do {
    if (!wcscmp(entry.cFileName, L".") || !wcscmp(entry.cFileName, L"..")) continue;
    size_t bytes = (wcslen(entry.cFileName) + 1) * 2;
    unsigned char *grown = realloc(buffer, length + bytes);
    if (!grown) abort();
    buffer = grown; memcpy(buffer + length, entry.cFileName, bytes); length += bytes;
  } while (FindNextFileW(directory, &entry));
  if (GetLastError() != ERROR_NO_MORE_FILES) *error = GetLastError();
  FindClose(directory);
#else
  DIR *directory = opendir((char *)path);
  if (!directory) { *error = errno; goto done; }
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(directory);
    if (!entry) { *error = errno; break; }
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    size_t bytes = strlen(entry->d_name) + 1;
    unsigned char *grown = realloc(buffer, length + bytes);
    if (!grown) abort();
    buffer = grown; memcpy(buffer + length, entry->d_name, bytes); length += bytes;
  }
  closedir(directory);
#endif
done:;
  moonbit_bytes_t out = moonbit_make_bytes((int)length, 0);
  if (length) memcpy(out, buffer, length);
  free(buffer); return out;
}

#ifndef _WIN32
#include <pthread.h>
#include <signal.h>
/* A broken guest pipe must report EPIPE without changing the embedding
 * application's SIGPIPE disposition. Consume only a signal generated here. */
int moonrun_native_safe_write(int fd, const void *buffer, int length) {
#ifdef __APPLE__
  (void)fcntl(fd, F_SETNOSIGPIPE, 1);
#endif
  sigset_t blocked, original, pending;
  sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
  pthread_sigmask(SIG_BLOCK, &blocked, &original);
  sigpending(&pending);
  int already_pending = sigismember(&pending, SIGPIPE);
  int count = (int)write(fd, buffer, (size_t)length);
  int error = errno;
  if (count < 0 && error == EPIPE && !already_pending && !sigismember(&original, SIGPIPE)) {
    sigpending(&pending);
    if (sigismember(&pending, SIGPIPE)) { int signal; sigwait(&blocked, &signal); }
  }
  pthread_sigmask(SIG_SETMASK, &original, NULL);
  errno = error;
  return count;
}
#endif
