/* Child processes own their native inputs and notification writer. No worker
 * accesses MoonBit values or guest memory. The caller retains redirected fds
 * until the spawn acknowledgement, then a scoped task owns child cleanup. */
#ifndef _WIN32
#define _GNU_SOURCE
#endif
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#ifdef _WIN32
#include <windows.h>
typedef HANDLE child_fd;
typedef WCHAR child_char;
#else
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <stdatomic.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
typedef int child_fd;
typedef char child_char;
static sigset_t child_signal_mask;
#endif

MOONBIT_FFI_EXPORT void moonrun_child_init(void) {
#ifndef _WIN32
  pthread_sigmask(SIG_SETMASK, NULL, &child_signal_mask);
#endif
}

typedef struct {
  child_char *input, *command, *cwd, **argv, **env;
  child_fd stdio[3], notify, handle;
  child_fd policy_fd;
  unsigned char *policy;
  int policy_length;
  child_char *policy_entry;
  int argc, envc, pid, error, status, no_console, orphan, joined, exited;
#ifdef _WIN32
  HANDLE thread, event, job;
  CRITICAL_SECTION mutex;
  volatile LONG references;
#else
  pthread_t thread;
  pthread_mutex_t mutex;
  sigset_t signal_mask;
  int policy_child_fd;
  _Atomic int references;
#endif
} guest_child;

#ifdef _WIN32
#define LOCK(p) EnterCriticalSection(&(p)->mutex)
#define UNLOCK(p) LeaveCriticalSection(&(p)->mutex)
#else
#define LOCK(p) pthread_mutex_lock(&(p)->mutex)
#define UNLOCK(p) pthread_mutex_unlock(&(p)->mutex)
#endif

static void child_release(guest_child *p) {
#ifdef _WIN32
  if (InterlockedDecrement(&p->references)) return;
  if (p->handle != INVALID_HANDLE_VALUE) CloseHandle(p->handle);
  if (p->job) CloseHandle(p->job);
  CloseHandle(p->thread); CloseHandle(p->event);
  DeleteCriticalSection(&p->mutex);
#else
  if (atomic_fetch_sub(&p->references, 1) != 1) return;
  if (p->handle >= 0) close(p->handle);
  pthread_mutex_destroy(&p->mutex);
#endif
  free(p->argv); free(p->env); free(p->input); free(p->policy); free(p->policy_entry); free(p);
}

static int child_prepare_policy(guest_child *p) {
  if (!p->policy_length) return 0;
#ifdef _WIN32
  WCHAR *path = calloc(32768 + 128, sizeof(WCHAR));
  if (!path) return ERROR_NOT_ENOUGH_MEMORY;
  DWORD length = GetTempPathW(32768, path);
  if (!length || length >= 32768) { int error = GetLastError(); free(path); return error ? error : ERROR_BUFFER_OVERFLOW; }
  static volatile LONG sequence;
  for (;;) {
    LARGE_INTEGER ticks; QueryPerformanceCounter(&ticks);
    _snwprintf(path + length, 128, L"moonrun-policy-%lu-%llx-%ld", GetCurrentProcessId(),
        (unsigned long long)ticks.QuadPart, (long)InterlockedIncrement(&sequence));
    p->policy_fd = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE,
        NULL, CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, NULL);
    if (p->policy_fd != INVALID_HANDLE_VALUE || GetLastError() != ERROR_FILE_EXISTS) break;
  }
  if (p->policy_fd == INVALID_HANDLE_VALUE) { int error = GetLastError(); free(path); return error; }
  free(path);
  int offset = 0;
  while (offset < p->policy_length) {
    DWORD written;
    if (!WriteFile(p->policy_fd, p->policy + offset, (DWORD)(p->policy_length - offset), &written, NULL)) return GetLastError();
    if (!written) return ERROR_WRITE_FAULT;
    offset += (int)written;
  }
  LARGE_INTEGER zero = {0};
  if (!SetFilePointerEx(p->policy_fd, zero, NULL, FILE_BEGIN)) return GetLastError();
  p->policy_entry = calloc(96, sizeof(WCHAR));
  if (!p->policy_entry) return ERROR_NOT_ENOUGH_MEMORY;
  _snwprintf(p->policy_entry, 96, L"MOONRUN_INHERITED_POLICY=%llu", (unsigned long long)(uintptr_t)p->policy_fd);
#else
  FILE *file = tmpfile();
  if (!file) return errno;
  p->policy_fd = fcntl(fileno(file), F_DUPFD_CLOEXEC, 3);
  int error = errno;
  fclose(file);
  if (p->policy_fd < 0) return error;
  // dup2(fd, fd) may preserve CLOEXEC. Reserve a distinct child descriptor so
  // the spawn action makes only its child-side copy inheritable.
  p->policy_child_fd = fcntl(p->policy_fd, F_DUPFD_CLOEXEC, 3);
  if (p->policy_child_fd < 0) return errno;
  int offset = 0;
  while (offset < p->policy_length) {
    ssize_t written = write(p->policy_fd, p->policy + offset, (size_t)(p->policy_length - offset));
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return written < 0 ? errno : EIO;
    offset += (int)written;
  }
  if (lseek(p->policy_fd, 0, SEEK_SET) < 0) return errno;
  p->policy_entry = calloc(64, 1);
  if (!p->policy_entry) return ENOMEM;
  snprintf(p->policy_entry, 64, "MOONRUN_INHERITED_POLICY=%d", p->policy_child_fd);
#endif
  p->env[p->envc++] = p->policy_entry;
  return 0;
}

static int child_notify(guest_child *p) {
  unsigned char byte = 1;
#ifdef _WIN32
  OVERLAPPED operation = {0};
  ResetEvent(p->event);
  operation.hEvent = (HANDLE)((uintptr_t)p->event | 1);
  DWORD written;
  if (!p->notify) return 0;
  BOOL ok = WriteFile(p->notify, &byte, 1, &written, &operation);
  if (!ok && GetLastError() == ERROR_IO_PENDING)
    ok = GetOverlappedResult(p->notify, &operation, &written, TRUE);
  if (ok && written == 1) return 1;
  CloseHandle(p->notify); p->notify = NULL;
#else
  ssize_t count;
  if (p->notify < 0) return 0;
  do { count = write(p->notify, &byte, 1); } while (count < 0 && errno == EINTR);
  if (count < 0 && errno == EPIPE) {
    sigset_t pending, pipe_signal;
    sigemptyset(&pipe_signal); sigaddset(&pipe_signal, SIGPIPE);
    sigpending(&pending);
    if (sigismember(&pending, SIGPIPE)) { int signal; sigwait(&pipe_signal, &signal); }
  }
  if (count == 1) return 1;
  close(p->notify); p->notify = -1;
#endif
  return 0;
}

#ifdef _WIN32
static int child_spawn(guest_child *p) {
  STARTUPINFOEXW startup = {0};
  PROCESS_INFORMATION info = {0};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  HANDLE inherited[4]; int count = 0, error = 0;
  WCHAR *environment = NULL;
  for (int i = 0; i < 3; ++i) {
    HANDLE fd = p->stdio[i];
    if (fd == INVALID_HANDLE_VALUE) fd = GetStdHandle(i == 0 ? STD_INPUT_HANDLE : i == 1 ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE);
    if (!fd || fd == INVALID_HANDLE_VALUE) continue;
    HANDLE copy;
    if (!DuplicateHandle(GetCurrentProcess(), fd, GetCurrentProcess(), &copy, 0, TRUE, DUPLICATE_SAME_ACCESS)) { error = GetLastError(); goto done; }
    inherited[count++] = copy;
    if (i == 0) startup.StartupInfo.hStdInput = copy;
    if (i == 1) startup.StartupInfo.hStdOutput = copy;
    if (i == 2) startup.StartupInfo.hStdError = copy;
  }
  if (p->policy_fd != INVALID_HANDLE_VALUE) {
    /* The transferred numeric token must name the inherited handle itself. */
    if (!SetHandleInformation(p->policy_fd, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)) { error = GetLastError(); goto done; }
    inherited[count++] = p->policy_fd;
  }
  SIZE_T size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &size);
  startup.lpAttributeList = malloc(size);
  if (!startup.lpAttributeList) { error = ERROR_NOT_ENOUGH_MEMORY; goto done; }
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &size)) { error = GetLastError(); free(startup.lpAttributeList); startup.lpAttributeList = NULL; goto done; }
  if (count && !UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, count * sizeof(HANDLE), NULL, NULL)) { error = GetLastError(); goto done; }
  if (!p->orphan) {
    p->job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!p->job || !SetInformationJobObject(p->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) { error = GetLastError(); goto done; }
  }
  size_t environment_length = 2;
  for (int i = 0; i < p->envc; ++i) environment_length += wcslen(p->env[i]) + 1;
  environment = calloc(environment_length, sizeof(WCHAR));
  if (!environment) { error = ERROR_NOT_ENOUGH_MEMORY; goto done; }
  WCHAR *cursor = environment;
  for (int i = 0; i < p->envc; ++i) {
    size_t length = wcslen(p->env[i]) + 1;
    memcpy(cursor, p->env[i], length * sizeof(WCHAR)); cursor += length;
  }
  if (!CreateProcessW(NULL, p->command, NULL, NULL, count != 0,
      CREATE_NEW_PROCESS_GROUP | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED |
      (p->no_console ? CREATE_NO_WINDOW : 0), environment, p->cwd, &startup.StartupInfo, &info)) { error = GetLastError(); goto done; }
  if (p->job && !AssignProcessToJobObject(p->job, info.hProcess)) {
    error = GetLastError(); TerminateProcess(info.hProcess, 1);
    WaitForSingleObject(info.hProcess, INFINITE); CloseHandle(info.hThread); CloseHandle(info.hProcess); goto done;
  }
  p->handle = info.hProcess; p->pid = (int)info.dwProcessId;
  if (ResumeThread(info.hThread) == (DWORD)-1) {
    error = GetLastError(); TerminateProcess(info.hProcess, 1);
    WaitForSingleObject(info.hProcess, INFINITE); p->pid = 0;
  }
  CloseHandle(info.hThread);
done:
  free(environment);
  if (startup.lpAttributeList) { DeleteProcThreadAttributeList(startup.lpAttributeList); free(startup.lpAttributeList); }
  for (int i = 0; i < count; ++i) if (inherited[i] != p->policy_fd) CloseHandle(inherited[i]);
  return error;
}
#else
static int child_spawn(guest_child *p) {
  posix_spawnattr_t attr;
  int error = posix_spawnattr_init(&attr);
  if (error) return error;
  posix_spawn_file_actions_t actions;
  error = posix_spawn_file_actions_init(&actions);
  if (error) { posix_spawnattr_destroy(&attr); return error; }
  sigset_t defaults; sigfillset(&defaults);
  int copies[3] = {-1, -1, -1};
  if ((error = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) ||
      (error = posix_spawnattr_setsigmask(&attr, &p->signal_mask)) ||
      (error = posix_spawnattr_setsigdefault(&attr, &defaults))) goto done;
  for (int i = 0; i < 3; ++i) {
    if (p->stdio[i] < 0) continue;
    copies[i] = fcntl(p->stdio[i], F_DUPFD_CLOEXEC, 3);
    if (copies[i] < 0) { error = errno; goto done; }
    if ((error = posix_spawn_file_actions_adddup2(&actions, copies[i], i))) goto done;
  }
  if (p->policy_fd >= 0 && (error = posix_spawn_file_actions_adddup2(&actions, p->policy_fd, p->policy_child_fd))) goto done;
  if ((error = posix_spawn_file_actions_addchdir_np(&actions, p->cwd))) goto done;
  pid_t pid;
  if (strchr(p->command, '/')) error = posix_spawn(&pid, p->command, &actions, &attr, p->argv, p->env);
  else error = posix_spawnp(&pid, p->command, &actions, &attr, p->argv, p->env);
  if (!error) {
    p->pid = pid;
#ifdef __linux__
#ifdef SYS_pidfd_open
    p->handle = (int)syscall(SYS_pidfd_open, pid, 0);
#endif
#endif
  }
done:
  for (int i = 0; i < 3; ++i) if (copies[i] >= 0) close(copies[i]);
  posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr);
  return error;
}
#endif

#ifdef _WIN32
static DWORD WINAPI child_worker(void *pointer)
#else
static void *child_worker(void *pointer)
#endif
{
  guest_child *p = pointer;
#ifndef _WIN32
  sigset_t blocked; sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
  pthread_sigmask(SIG_BLOCK, &blocked, NULL);
#endif
  LOCK(p);
  p->error = child_prepare_policy(p);
  if (!p->error) p->error = child_spawn(p);
#ifdef _WIN32
  if (p->policy_fd != INVALID_HANDLE_VALUE) CloseHandle(p->policy_fd);
#else
  if (p->policy_fd >= 0) close(p->policy_fd);
  if (p->policy_child_fd >= 0) close(p->policy_child_fd);
#endif
  p->policy_fd = (child_fd)-1;
  free(p->input); p->input = NULL;
  free(p->argv); p->argv = NULL;
  free(p->env); p->env = NULL;
  free(p->policy); p->policy = NULL;
  free(p->policy_entry); p->policy_entry = NULL;
  int pid = p->pid;
  UNLOCK(p);
  if (!child_notify(p) && pid) {
#ifdef _WIN32
    TerminateProcess(p->handle, 1);
#else
    kill(pid, SIGKILL);
#endif
  }
  int status = 0, error = 0;
  if (pid) {
#ifdef _WIN32
    if (WaitForSingleObject(p->handle, INFINITE) != WAIT_OBJECT_0 || !GetExitCodeProcess(p->handle, (DWORD *)&status)) error = GetLastError();
#else
    // Keep the child unreaped until holding the same lock as signal delivery.
    // Otherwise a concurrent kill could target a newly reused process ID.
    siginfo_t info;
    int result;
    do { result = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT); } while (result < 0 && errno == EINTR);
    LOCK(p);
    if (result < 0) error = errno;
    else {
      int native_status;
      do { result = waitpid(pid, &native_status, 0); } while (result < 0 && errno == EINTR);
      if (result < 0) error = errno;
      else status = WIFEXITED(native_status) ? WEXITSTATUS(native_status) : -WTERMSIG(native_status);
    }
    p->exited = 1;
    UNLOCK(p);
#endif
  }
  LOCK(p); p->status = status; p->exited = 1; if (error) p->error = error; UNLOCK(p);
  child_notify(p);
#ifdef _WIN32
  if (p->notify) CloseHandle(p->notify);
#else
  if (p->notify >= 0) close(p->notify);
#endif
  child_release(p);
#ifdef _WIN32
  return 0;
#else
  return NULL;
#endif
}

MOONBIT_FFI_EXPORT void *moonrun_child_start(unsigned char *input, int length, int argc, int envc,
    child_fd in, child_fd out, child_fd err, int orphan, int no_console, child_fd notify,
    unsigned char *policy, int policy_length) {
  guest_child *p = calloc(1, sizeof(*p));
  if (!p) goto oom;
  p->references = 2; p->handle = (child_fd)-1; p->policy_fd = (child_fd)-1;
#ifndef _WIN32
  p->policy_child_fd = -1;
#endif
  p->argc = argc; p->envc = envc; p->orphan = orphan; p->no_console = no_console;
  p->stdio[0] = in; p->stdio[1] = out; p->stdio[2] = err;
  p->input = calloc((size_t)length + sizeof(child_char) * 2, 1);
  p->argv = calloc((size_t)argc + 1, sizeof(child_char *));
  p->env = calloc((size_t)envc + 2, sizeof(child_char *));
  if (policy_length) { p->policy = malloc((size_t)policy_length); if (p->policy) memcpy(p->policy, policy, (size_t)policy_length); }
  p->policy_length = policy_length;
  if (!p->input || !p->argv || !p->env || (policy_length && !p->policy)) goto free_oom;
  memcpy(p->input, input, (size_t)length);
  child_char *cursor = p->input;
  p->command = cursor; while (*cursor) ++cursor; ++cursor;
  p->cwd = cursor; while (*cursor) ++cursor; ++cursor;
  for (int i = 0; i < argc; ++i) { p->argv[i] = cursor; while (*cursor) ++cursor; ++cursor; }
  for (int i = 0; i < envc; ++i) { p->env[i] = cursor; while (*cursor) ++cursor; ++cursor; }
#ifdef _WIN32
  InitializeCriticalSection(&p->mutex);
  if (!DuplicateHandle(GetCurrentProcess(), notify, GetCurrentProcess(), &p->notify, 0, FALSE, DUPLICATE_SAME_ACCESS)) goto fail;
  p->event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!p->event) { CloseHandle(p->notify); goto fail; }
  p->thread = CreateThread(NULL, 0, child_worker, p, 0, NULL);
  if (p->thread) return p;
  { DWORD error = GetLastError(); CloseHandle(p->event); CloseHandle(p->notify); SetLastError(error); }
fail:
  { DWORD error = GetLastError(); DeleteCriticalSection(&p->mutex); free(p->input); free(p->argv); free(p->env); free(p->policy); free(p); SetLastError(error); return NULL; }
#else
  int error = pthread_mutex_init(&p->mutex, NULL);
  if (error) { errno = error; goto fail_alloc; }
  p->signal_mask = child_signal_mask;
  p->notify = fcntl(notify, F_DUPFD_CLOEXEC, 0);
  if (p->notify < 0) goto fail_mutex;
#ifdef __APPLE__
  if (fcntl(p->notify, F_SETNOSIGPIPE, 1) < 0) { error = errno; close(p->notify); errno = error; goto fail_mutex; }
#endif
  error = pthread_create(&p->thread, NULL, child_worker, p);
  if (!error) return p;
  close(p->notify); errno = error;
fail_mutex:
  error = errno; pthread_mutex_destroy(&p->mutex); errno = error;
fail_alloc:
  error = errno; free(p->input); free(p->argv); free(p->env); free(p->policy); free(p); errno = error; return NULL;
#endif
free_oom:
  free(p->input); free(p->argv); free(p->env); free(p->policy); free(p);
oom:
#ifdef _WIN32
  SetLastError(ERROR_NOT_ENOUGH_MEMORY);
#else
  errno = ENOMEM;
#endif
  return NULL;
}
MOONBIT_FFI_EXPORT int moonrun_child_is_null(void *p) { return p == NULL; }
MOONBIT_FFI_EXPORT int moonrun_child_pid(void *pointer) { guest_child *p = pointer; LOCK(p); int result = p->pid; UNLOCK(p); return result; }
MOONBIT_FFI_EXPORT int moonrun_child_error(void *pointer) { guest_child *p = pointer; LOCK(p); int result = p->error; UNLOCK(p); return result; }
MOONBIT_FFI_EXPORT int moonrun_child_status(void *pointer) { guest_child *p = pointer; LOCK(p); int result = p->status; UNLOCK(p); return result; }
MOONBIT_FFI_EXPORT child_fd moonrun_child_handle(void *pointer) { return ((guest_child *)pointer)->handle; }
MOONBIT_FFI_EXPORT int moonrun_process_fd_valid(child_fd fd) {
#ifdef _WIN32
  return fd && fd != INVALID_HANDLE_VALUE;
#else
  return fd >= 0;
#endif
}
MOONBIT_FFI_EXPORT int moonrun_buffered_pipe_bytes(child_fd fd) {
#ifdef _WIN32
  DWORD available;
  if (!PeekNamedPipe(fd, NULL, 0, NULL, &available, NULL))
    return GetLastError() == ERROR_BROKEN_PIPE ? 0 : -1;
  return available > INT32_MAX ? INT32_MAX : (int)available;
#else
  int available;
  return ioctl(fd, FIONREAD, &available) < 0 ? -1 : available;
#endif
}
MOONBIT_FFI_EXPORT int moonrun_process_ready(child_fd fd) {
#ifdef _WIN32
  DWORD status = WaitForSingleObject(fd, 0);
  return status == WAIT_OBJECT_0 ? 1 : status == WAIT_TIMEOUT ? 0 : -1;
#else
  (void)fd;
  return 1;
#endif
}
MOONBIT_FFI_EXPORT void moonrun_signal_process_pid(int pid, int signal) {
#ifdef _WIN32
  if (signal == -1) {
    HANDLE process = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)pid);
    if (process) { TerminateProcess(process, 1); CloseHandle(process); }
  } else {
    GenerateConsoleCtrlEvent((DWORD)signal, (DWORD)pid);
  }
#else
  kill(pid, signal == -1 ? SIGKILL : signal);
#endif
}
MOONBIT_FFI_EXPORT void moonrun_child_signal(void *pointer, int signal) {
  guest_child *p = pointer;
  LOCK(p);
  if (p->exited) { UNLOCK(p); return; }
#ifdef _WIN32
  if (signal == -1) TerminateProcess(p->handle, 1);
  else GenerateConsoleCtrlEvent((DWORD)signal, (DWORD)p->pid);
#else
  if (p->pid > 0) kill(p->pid, signal == -1 ? SIGKILL : signal);
#endif
  UNLOCK(p);
}
MOONBIT_FFI_EXPORT void moonrun_child_join(void *pointer) {
  guest_child *p = pointer;
  if (p->joined) return;
#ifdef _WIN32
  WaitForSingleObject(p->thread, INFINITE);
#else
  pthread_join(p->thread, NULL);
#endif
  p->joined = 1;
}
MOONBIT_FFI_EXPORT void moonrun_child_free(void *pointer) {
  guest_child *p = pointer;
#ifndef _WIN32
  if (!p->joined) pthread_detach(p->thread);
#endif
  child_release(p);
}
MOONBIT_FFI_EXPORT int moonrun_environment_key_equal(uint16_t *left, int left_len, uint16_t *right, int right_len) {
#ifdef _WIN32
  return CompareStringOrdinal((WCHAR *)left, left_len, (WCHAR *)right, right_len, TRUE) == CSTR_EQUAL;
#else
  return left_len == right_len && memcmp(left, right, (size_t)left_len * 2) == 0;
#endif
}
