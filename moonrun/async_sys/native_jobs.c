/* Blocking operations whose guest ABI needs native metadata or DNS records.
 * Each worker owns its input/output allocation and only writes a notification
 * byte; all MoonBit allocation and guest-memory access stays on the main thread. */
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
typedef HANDLE native_fd;
#else
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/stat.h>
#include <netdb.h>
#include <sys/socket.h>
#include <signal.h>
#include <stdatomic.h>
#if defined(__APPLE__)
#include <sys/attr.h>
#include <sys/vnode.h>
#else
#include <sys/syscall.h>
#include <linux/stat.h>
#include <sys/inotify.h>
#endif

typedef int native_fd;
#endif

/* These tags match NativeJobKind in native_jobs.mbt. */
enum { STAT_PATH = 1, READ_DIRECTORY = 2, STAT_FD = 3, RESOLVE_HOST = 4, ADD_WATCH = 5,
       OPEN_WATCHER = 6, READ_WATCH_EVENTS = 7, READ_POLICY = 8 };

typedef struct {
  int operation, request, follow, restart;
  native_fd parent, notify, opened;
  unsigned char *path, *buffer;
  int capacity, length, result, error, joined;
#ifdef _WIN32
  HANDLE thread, event, cancel;
  volatile LONG references;
  int wsa_lease;
#else
  pthread_t thread;
  _Atomic int references;
#endif
} native_job;

static void release_native_job(native_job *job) {
#ifdef _WIN32
  if (InterlockedDecrement(&job->references) != 0) return;
  CloseHandle(job->thread);
  CloseHandle(job->event);
  if (job->cancel) CloseHandle(job->cancel);
  if (job->opened != INVALID_HANDLE_VALUE) CloseHandle(job->opened);
  if (job->wsa_lease) WSACleanup();
#else
  if (atomic_fetch_sub(&job->references, 1) != 1) return;
  if (job->opened >= 0) close(job->opened);
#endif
  free(job->path); free(job->buffer); free(job);
}

extern int32_t moonbitlang_async_fstatx_sync(native_fd, uint32_t, void *, int32_t);

static void store32(unsigned char *buffer, uint32_t value) { memcpy(buffer, &value, 4); }
static void store64(unsigned char *buffer, uint64_t value) { memcpy(buffer, &value, 8); }

static int native_watch_events(native_job *job) {
#ifdef _WIN32
  OVERLAPPED operation = {0};
  operation.hEvent = (HANDLE)((uintptr_t)job->event | 1);
  DWORD count = 0;
  BOOL ok = ReadDirectoryChangesW(job->parent, job->buffer, (DWORD)job->capacity, TRUE,
      FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE,
      &count, &operation, NULL);
  if (!ok && GetLastError() != ERROR_IO_PENDING) return -1;
  HANDLE events[2] = {job->event, job->cancel};
  DWORD wait = WaitForMultipleObjects(2, events, FALSE, INFINITE);
  if (wait != WAIT_OBJECT_0) CancelIoEx(job->parent, &operation);
  if (!GetOverlappedResult(job->parent, &operation, &count, TRUE)) return -1;
  return (int)count;
#else
  (void)job; errno = ENOTSUP; return -1;
#endif
}

static int native_read_policy(native_job *job) {
#ifdef _WIN32
  LARGE_INTEGER size;
  if (GetFileType(job->parent) != FILE_TYPE_DISK) { SetLastError(ERROR_INVALID_HANDLE); return -1; }
  if (!GetFileSizeEx(job->parent, &size)) return -1;
  if (size.QuadPart < 0 || size.QuadPart > INT_MAX) { SetLastError(ERROR_FILE_TOO_LARGE); return -1; }
  int length = (int)size.QuadPart;
#else
  struct stat info;
  if (fstat(job->parent, &info) < 0) return -1;
  if (!S_ISREG(info.st_mode)) { errno = EINVAL; return -1; }
  if (info.st_size < 0 || info.st_size > INT_MAX) { errno = EFBIG; return -1; }
  int length = (int)info.st_size;
#endif
  unsigned char *buffer = realloc(job->buffer, length ? (size_t)length : 1);
  if (!buffer) {
#ifdef _WIN32
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
#else
    errno = ENOMEM;
#endif
    return -1;
  }
  job->buffer = buffer;
  int offset = 0;
#ifdef _WIN32
  LARGE_INTEGER zero = {0};
  if (!SetFilePointerEx(job->parent, zero, NULL, FILE_BEGIN)) return -1;
#endif
  while (offset < length) {
#ifdef _WIN32
    DWORD count;
    if (!ReadFile(job->parent, buffer + offset, (DWORD)(length - offset), &count, NULL)) return -1;
#else
    ssize_t count = pread(job->parent, buffer + offset, (size_t)(length - offset), offset);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) return -1;
#endif
    if (!count) break;
    offset += (int)count;
  }
  job->capacity = offset;
  return 0;
}
static int native_stat(native_job *job) {
  uint64_t values[12] = {0};
  unsigned mask = 255;
#ifdef _WIN32
  if (job->parent != INVALID_HANDLE_VALUE) { SetLastError(ERROR_NOT_SUPPORTED); return -1; }
  HANDLE handle = CreateFileW((WCHAR *)job->path, FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | (job->follow ? 0 : FILE_FLAG_OPEN_REPARSE_POINT), NULL);
  if (handle == INVALID_HANDLE_VALUE) return -1;
  BY_HANDLE_FILE_INFORMATION info;
  FILE_BASIC_INFO basic;
  if (!GetFileInformationByHandle(handle, &info) ||
      !GetFileInformationByHandleEx(handle, FileBasicInfo, &basic, sizeof(basic))) {
    DWORD error = GetLastError(); CloseHandle(handle); SetLastError(error); return -1;
  }
  CloseHandle(handle);
  values[0] = (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ? 3 :
              (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 2 : 1;
  values[1] = ((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow;
  values[2] = info.dwVolumeSerialNumber;
  values[3] = ((uint64_t)info.nFileIndexHigh << 32) | info.nFileIndexLow;
  int64_t times[] = { basic.LastAccessTime.QuadPart, basic.LastWriteTime.QuadPart,
                      basic.ChangeTime.QuadPart, basic.CreationTime.QuadPart };
  for (int i = 0; i < 4; ++i) {
    int64_t ticks = times[i] - INT64_C(116444736000000000);
    int64_t seconds = ticks / 10000000, remainder = ticks % 10000000;
    if (remainder < 0) { --seconds; remainder += 10000000; }
    values[4 + i * 2] = (uint64_t)seconds;
    values[5 + i * 2] = (uint64_t)(remainder * 100);
  }
#else
  struct stat info;
  int parent = job->parent == -1 ? AT_FDCWD : job->parent;
  if (fstatat(parent, (char *)job->path, &info, job->follow ? 0 : AT_SYMLINK_NOFOLLOW) < 0)
    return -1;
  switch (info.st_mode & S_IFMT) {
    case S_IFREG: values[0] = 1; break;
    case S_IFDIR: values[0] = 2; break;
    case S_IFLNK: values[0] = 3; break;
    case S_IFSOCK: values[0] = 4; break;
    case S_IFIFO: values[0] = 5; break;
    case S_IFBLK: values[0] = 6; break;
    case S_IFCHR: values[0] = 7; break;
  }
  values[1] = (uint64_t)info.st_size;
  values[2] = (uint64_t)info.st_dev;
  values[3] = (uint64_t)info.st_ino;
#ifdef __APPLE__
  struct timespec times[] = {info.st_atimespec, info.st_mtimespec, info.st_ctimespec, info.st_birthtimespec};
#else
  struct timespec times[] = {info.st_atim, info.st_mtim, info.st_ctim, {0, 0}};
  mask &= ~128u;
  if (job->request & 128) {
    struct statx extended;
    if (syscall(SYS_statx, parent, (char *)job->path, job->follow ? 0 : AT_SYMLINK_NOFOLLOW,
                STATX_BTIME, &extended) == 0 && (extended.stx_mask & STATX_BTIME)) {
      times[3].tv_sec = extended.stx_btime.tv_sec;
      times[3].tv_nsec = extended.stx_btime.tv_nsec;
      mask |= 128;
    }
  }
#endif
  for (int i = 0; i < 4; ++i) {
    values[4 + i * 2] = (uint64_t)times[i].tv_sec;
    values[5 + i * 2] = (uint64_t)times[i].tv_nsec;
  }
#endif
  int offset = 8;
  for (int bit = 0; bit < 8; ++bit) if (job->request & (1 << bit)) {
    int index = bit < 4 ? bit : 4 + (bit - 4) * 2;
    store64(job->buffer + offset, values[index]); offset += 8;
    if (bit >= 4) { store64(job->buffer + offset, values[index + 1]); offset += 8; }
  }
  store32(job->buffer, (uint32_t)offset);
  store32(job->buffer + 4, mask & (unsigned)job->request);
  job->length = offset;
  return 0;
}

static int native_readdir(native_job *job) {
#ifdef _WIN32
  if (!GetFileInformationByHandleEx(job->parent,
      job->restart ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo,
      job->buffer, (DWORD)job->capacity)) {
    if (GetLastError() == ERROR_NO_MORE_FILES) return 0;
    return -1;
  }
  job->length = job->capacity;
  return job->capacity;
#else
  if (job->restart && lseek(job->parent, 0, SEEK_SET) < 0) return -1;
#ifdef __APPLE__
  struct attrlist attributes = {0};
  attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
  attributes.commonattr = ATTR_CMN_NAME | ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID;
  return getattrlistbulk(job->parent, &attributes, job->buffer, (size_t)job->capacity, 0);
#else
  return (int)syscall(SYS_getdents64, job->parent, job->buffer, (size_t)job->capacity);
#endif
#endif
}

static int native_resolve(native_job *job) {
#ifdef _WIN32
  ADDRINFOW hint = {0}, *addresses = NULL;
  hint.ai_flags = AI_ADDRCONFIG;
  int code = GetAddrInfoW((WCHAR *)job->path, NULL, &hint, &addresses);
  if (code) {
    switch (code) {
      case WSATRY_AGAIN: case WSANO_RECOVERY: case WSAEAFNOSUPPORT:
      case WSAHOST_NOT_FOUND: case WSATYPE_NOT_FOUND: case WSAESOCKTNOSUPPORT:
        return code;
      default: job->error = code; return 0;
    }
  }
  ADDRINFOW *entry = addresses;
#else
  struct addrinfo hint = {0}, *addresses = NULL;
  hint.ai_flags = AI_ADDRCONFIG;
  int code = getaddrinfo((char *)job->path, NULL, &hint, &addresses);
  if (code) { if (code == EAI_SYSTEM) job->error = errno; return code; }
  struct addrinfo *entry = addresses;
#endif
  int length = 0;
  for (; entry; entry = entry->ai_next) {
    if (entry->ai_family != AF_INET && entry->ai_family != AF_INET6) continue;
    size_t size = entry->ai_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
    if (length > INT_MAX - 4 - (int)size) { job->error =
#ifdef _WIN32
      ERROR_NOT_ENOUGH_MEMORY;
#else
      ENOMEM;
#endif
      break;
    }
    unsigned char *buffer = realloc(job->buffer, (size_t)length + 4 + size);
    if (!buffer) { job->error =
#ifdef _WIN32
      ERROR_NOT_ENOUGH_MEMORY;
#else
      ENOMEM;
#endif
      break;
    }
    job->buffer = buffer;
    store32(buffer + length, (uint32_t)size);
    memcpy(buffer + length + 4, entry->ai_addr, size);
    length += 4 + (int)size;
  }
#ifdef _WIN32
  FreeAddrInfoW(addresses);
#else
  freeaddrinfo(addresses);
#endif
  job->capacity = length;
  return 0;
}

#ifdef _WIN32
static DWORD WINAPI native_job_worker(void *pointer)
#else
static void *native_job_worker(void *pointer)
#endif
{
  native_job *job = pointer;
#ifndef _WIN32
  // A detached DNS job may outlive its notification reader or host loop.
  // Keep a failed notification write from delivering SIGPIPE to the process.
  sigset_t blocked;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGPIPE);
  pthread_sigmask(SIG_BLOCK, &blocked, NULL);
#endif
  if (job->operation == RESOLVE_HOST) {
    job->result = native_resolve(job);
  } else if (job->operation == READ_POLICY) {
    job->result = native_read_policy(job);
#ifdef _WIN32
    job->error = job->result < 0 ? GetLastError() : 0;
#else
    job->error = job->result < 0 ? errno : 0;
#endif
  } else if (job->operation == OPEN_WATCHER) {
#ifdef _WIN32
    job->opened = CreateFileW((WCHAR *)job->path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
    job->result = job->opened == INVALID_HANDLE_VALUE ? -1 : 0;
    job->error = job->result < 0 ? GetLastError() : 0;
#else
    job->result = -1; job->error = ENOTSUP;
#endif
  } else if (job->operation == READ_WATCH_EVENTS) {
    job->result = native_watch_events(job);
#ifdef _WIN32
    job->error = job->result < 0 ? GetLastError() : 0;
    if (job->error == ERROR_NOTIFY_ENUM_DIR) { job->result = 0; job->error = 0; }
#else
    job->error = job->result < 0 ? errno : 0;
#endif
  } else if (job->operation == ADD_WATCH) {
#ifdef __linux__
    job->result = inotify_add_watch(job->parent, (char *)job->path,
        job->follow ? IN_CREATE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE : IN_MODIFY);
    job->error = job->result < 0 ? errno : 0;
#else
    job->result = -1;
    job->error = 50;
#endif
  } else {
  job->result = job->operation == STAT_PATH ? native_stat(job) :
                job->operation == READ_DIRECTORY ? native_readdir(job) :
                moonbitlang_async_fstatx_sync(job->parent, (uint32_t)job->request,
                                             job->buffer, job->capacity);
#ifdef _WIN32
  job->error = job->result < 0 ? (int)GetLastError() : 0;
#else
  job->error = job->result < 0 ? errno : 0;
#endif
  }
#ifdef _WIN32
  OVERLAPPED operation = {0};
  ResetEvent(job->event);
  operation.hEvent = (HANDLE)((uintptr_t)job->event | 1);
  unsigned char byte = 1;
  DWORD count;
  if (!WriteFile(job->notify, &byte, 1, &count, &operation) && GetLastError() == ERROR_IO_PENDING)
    GetOverlappedResult(job->notify, &operation, &count, TRUE);
  CloseHandle(job->notify);
  release_native_job(job);
  return 0;
#else
  unsigned char byte = 1;
  ssize_t count;
  pthread_sigmask(SIG_BLOCK, &blocked, NULL);
  do { count = write(job->notify, &byte, 1); } while (count < 0 && errno == EINTR);
  if (count < 0 && errno == EPIPE) {
    // Consume the thread's generated signal before pthread teardown restores
    // its signal mask. SIGPIPE may be ignored by the embedding process, in
    // which case no pending signal exists and sigwait must not be called.
    sigset_t pending;
    sigpending(&pending);
    if (sigismember(&pending, SIGPIPE)) {
      int received;
      sigwait(&blocked, &received);
    }
  }
  close(job->notify);
  release_native_job(job);
  return NULL;
#endif
}

MOONBIT_FFI_EXPORT void *moonrun_native_job_start(int operation, unsigned char *path, int path_len,
    native_fd parent, int request, int capacity, int follow, native_fd notify) {
  native_job *job = calloc(1, sizeof(*job));
  if (!job) {
#ifdef _WIN32
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
#else
    errno = ENOMEM;
#endif
    return NULL;
  }
  job->operation = operation; job->request = request; job->restart = follow;
  job->opened = (native_fd)-1;
  job->references = 2;
  job->capacity = capacity; job->follow = follow; job->parent = parent;
  job->path = calloc((size_t)path_len + 2, 1);
  job->buffer = calloc(capacity ? (size_t)capacity : 1, 1);
  if (!job->path || !job->buffer) {
#ifdef _WIN32
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
#else
    errno = ENOMEM;
#endif
    goto fail;
  }
  memcpy(job->path, path, (size_t)path_len);
#ifdef _WIN32
  if (operation == RESOLVE_HOST) {
    WSADATA data;
    int error = WSAStartup(MAKEWORD(2, 2), &data);
    if (error) { SetLastError(error); goto fail; }
    job->wsa_lease = 1;
  }
  if (!DuplicateHandle(GetCurrentProcess(), notify, GetCurrentProcess(), &job->notify,
                       0, FALSE, DUPLICATE_SAME_ACCESS)) goto fail;
  job->event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!job->event) goto fail_notify;
  if (operation == READ_WATCH_EVENTS) {
    job->cancel = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!job->cancel) { DWORD error = GetLastError(); CloseHandle(job->event); SetLastError(error); goto fail_notify; }
  }
  job->thread = CreateThread(NULL, 0, native_job_worker, job, 0, NULL);
  if (job->thread) return job;
  { DWORD error = GetLastError(); if (job->cancel) CloseHandle(job->cancel); CloseHandle(job->event); SetLastError(error); }
fail_notify:
  { DWORD error = GetLastError(); CloseHandle(job->notify); SetLastError(error); }
#else
  job->notify = fcntl(notify, F_DUPFD_CLOEXEC, 0);
  if (job->notify < 0) goto fail;
#ifdef __APPLE__
  // Darwin can deliver a pipe's SIGPIPE to another unblocked thread. A
  // thread-local mask alone is insufficient once the embedding loop ends.
  if (fcntl(job->notify, F_SETNOSIGPIPE, 1) < 0) {
    int error = errno; close(job->notify); errno = error; goto fail;
  }
#endif
  int thread_error = pthread_create(&job->thread, NULL, native_job_worker, job);
  if (!thread_error) return job;
  close(job->notify);
  errno = thread_error;
#endif
fail:
  {
#ifdef _WIN32
    DWORD error = GetLastError();
    if (job->wsa_lease) WSACleanup();
#else
    int error = errno;
#endif
    free(job->path); free(job->buffer); free(job);
#ifdef _WIN32
    SetLastError(error);
#else
    errno = error;
#endif
    return NULL;
  }
}
MOONBIT_FFI_EXPORT int moonrun_native_job_is_null(void *job) { return job == NULL; }
MOONBIT_FFI_EXPORT native_fd moonrun_adopt_policy_fd(uint64_t token) {
#ifdef _WIN32
  HANDLE handle = (HANDLE)(uintptr_t)token;
  DWORD flags;
  if (!token || handle == INVALID_HANDLE_VALUE || !GetHandleInformation(handle, &flags)) {
    SetLastError(ERROR_INVALID_HANDLE); return INVALID_HANDLE_VALUE;
  }
  if (!SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0)) {
    DWORD error = GetLastError(); CloseHandle(handle); SetLastError(error); return INVALID_HANDLE_VALUE;
  }
  return handle;
#else
  if (token <= 2 || token > INT_MAX) { errno = EINVAL; return -1; }
  int fd = (int)token, flags = fcntl(fd, F_GETFD);
  if (flags < 0) return -1;
  if (fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
    int error = errno; close(fd); errno = error; return -1;
  }
  return fd;
#endif
}
MOONBIT_FFI_EXPORT void moonrun_native_job_cancel(void *pointer) {
#ifdef _WIN32
  native_job *job = pointer;
  if (job->cancel) SetEvent(job->cancel);
#else
  (void)pointer;
#endif
}
MOONBIT_FFI_EXPORT native_fd moonrun_native_job_take_fd(void *pointer) {
  native_job *job = pointer;
  native_fd fd = job->opened;
  job->opened = (native_fd)-1;
  return fd;
}
MOONBIT_FFI_EXPORT void moonrun_native_job_join(void *pointer) {
  native_job *job = pointer;
  if (job->joined) return;
#ifdef _WIN32
  WaitForSingleObject(job->thread, INFINITE);
#else
  pthread_join(job->thread, NULL);
#endif
  job->joined = 1;
}
MOONBIT_FFI_EXPORT int moonrun_native_job_result(void *job) { return ((native_job *)job)->result; }
MOONBIT_FFI_EXPORT int moonrun_native_job_error(void *job) { return ((native_job *)job)->error; }
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrun_native_job_buffer(void *pointer) {
  native_job *job = pointer;
  moonbit_bytes_t bytes = moonbit_make_bytes(job->capacity, 0);
  memcpy(bytes, job->buffer, (size_t)job->capacity);
  return bytes;
}
MOONBIT_FFI_EXPORT void moonrun_native_job_free(void *pointer) {
  native_job *job = pointer;
  moonrun_native_job_join(job);
  release_native_job(job);
}

MOONBIT_FFI_EXPORT void moonrun_native_job_detach(void *pointer) {
  native_job *job = pointer;
#ifndef _WIN32
  pthread_detach(job->thread);
#endif
  // The worker's last reference frees only C allocations and OS handles.
  release_native_job(job);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonrun_tmp_path(void *path) {
  int length = 0;
  if (path) {
#ifdef _WIN32
    length = (int)wcslen((WCHAR *)path) * 2;
#else
    length = (int)strlen(path);
#endif
  }
  moonbit_bytes_t bytes = moonbit_make_bytes(length, 0);
  if (length) memcpy(bytes, path, (size_t)length);
  return bytes;
}
