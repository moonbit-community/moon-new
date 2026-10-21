MOONBIT_FFI_EXPORT
void *moonrun_native_make_job(
  int32_t size,
  void (*free)(void*),
  int32_t (*worker)(void*, int32_t*),
  int32_t (*cancel_handler)(void*)
) {
  struct job *job = (struct job*)malloc(size + sizeof(struct job));
  job->ret = -1;
  job->err = 0;
  job->worker = worker;
  job->free = free;
  job->cancel_handler = cancel_handler;
  return job->payload;
}

#define MAKE_JOB(name, cancel_handler) (struct name##_job*)moonrun_native_make_job(\
  sizeof(struct name##_job),\
  (void (*)(void*))free_##name##_job,\
  (int32_t (*)(void*, int32_t*)) name##_job_worker,\
  (int32_t (*)(void*))cancel_handler\
)

// ===== sleep job, sleep via thread pool, for testing only =====

struct sleep_job {
  int duration;
};

static
void free_sleep_job(struct sleep_job *job) {}

static int32_t sleep_job_worker(struct sleep_job *job, int32_t *error) {
  int remaining = job->duration;
  while (remaining > 0) {
    if (moonrun_native_enter_cancellable_region(current_worker)) {
#ifdef _WIN32
      *error = ERROR_OPERATION_ABORTED;
#else
      *error = EINTR;
#endif
      return -1;
    }
    int slice = remaining > 10 ? 10 : remaining;
#ifdef _WIN32
    Sleep(slice);
#else
    struct timespec pause = {0, slice * 1000000};
    if (nanosleep(&pause, NULL) < 0) { *error = errno; return -1; }
#endif
    moonrun_native_leave_cancellable_region(current_worker);
    remaining -= slice;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
struct sleep_job *moonrun_native_make_sleep_job(int ms) {
  struct sleep_job *job = MAKE_JOB(sleep, 0);
  job->duration = ms;
  return job;
}

// ===== read job, for reading non-pollable stuff =====

struct read_job {
  HANDLE fd;
  char *buf;
  int offset;
  int len;
  int64_t position;
};

static
int32_t read_job_worker(struct read_job *job, int32_t *err_out) {
  struct worker *worker = moonrun_native_get_current_worker();

#ifdef _WIN32

   OVERLAPPED overlapped;
   memset(&overlapped, 0, sizeof(OVERLAPPED));
   if (job->position >= 0) {
     overlapped.Offset = job->position & 0xffffffff;
     overlapped.OffsetHigh = job->position >> 32;
   }

   if (moonrun_native_enter_cancellable_region(worker)) {
     *err_out = ERROR_OPERATION_ABORTED;
     return -1;
   }

   DWORD bytes_transferred;
   BOOL result = ReadFile(
     job->fd,
     job->buf + job->offset,
     job->len,
     &bytes_transferred,
     job->position < 0 ? NULL : &overlapped
   );

   moonrun_native_leave_cancellable_region(worker);

   if (result) {
     return bytes_transferred;
   } else {
     int err = GetLastError();
     if (err == ERROR_HANDLE_EOF || err == ERROR_BROKEN_PIPE) {
       return 0;
     } else {
       *err_out = err;
       return -1;
     }
   }

#else

  int32_t ret;
  if (job->position < 0) {
    while (1) {
      if (moonrun_native_enter_cancellable_region(worker)) {
        *err_out = EINTR;
        return -1;
      }

      ret = read(job->fd, job->buf + job->offset, job->len);
      moonrun_native_leave_cancellable_region(worker);

      if (ret >= 0)
        break;

      if (errno != EAGAIN && errno != EWOULDBLOCK)
        break;

      struct pollfd pfd = { job->fd, POLLIN, 0 };
      if (moonrun_native_enter_cancellable_region(worker)) {
        *err_out = EINTR;
        return -1;
      }

      ret = poll(&pfd, 1, -1);
      moonrun_native_leave_cancellable_region(worker);

      if (ret < 0)
        break;
    }
  } else {
    ret = pread(
      job->fd,
      job->buf + job->offset,
      job->len,
      job->position
    );
  }

  if (ret < 0)
    *err_out = errno;

  return ret;

#endif
}

// ===== write job, for writing non-pollable stuff =====

struct write_job {
  HANDLE fd;
  char *buf;
  int offset;
  int len;
  int64_t position;
};

static
int32_t write_job_worker(struct write_job *job, int32_t *err_out) {
  struct worker *worker = moonrun_native_get_current_worker();

#ifdef _WIN32

   OVERLAPPED overlapped;
   memset(&overlapped, 0, sizeof(OVERLAPPED));
   if (job->position >= 0) {
     overlapped.Offset = job->position & 0xffffffff;
     overlapped.OffsetHigh = job->position >> 32;
   }

   DWORD bytes_transferred;
   if (moonrun_native_enter_cancellable_region(worker)) {
     *err_out = ERROR_OPERATION_ABORTED;
     return -1;
   }

   BOOL result = WriteFile(
     job->fd,
     job->buf + job->offset,
     job->len,
     &bytes_transferred,
     job->position < 0 ? NULL : &overlapped
   );
   moonrun_native_leave_cancellable_region(worker);

   if (result)
     return bytes_transferred;
   else {
     *err_out = GetLastError();
     return -1;
   }

#else

  int32_t ret;
  if (job->position < 0) {
    while (1) {
      if (moonrun_native_enter_cancellable_region(worker)) {
        *err_out = EINTR;
        return -1;
      }

      ret = moonrun_native_safe_write(job->fd, job->buf + job->offset, job->len);
      moonrun_native_leave_cancellable_region(worker);

      if (ret >= 0)
        break;

      if (errno != EAGAIN && errno != EWOULDBLOCK)
        break;

      struct pollfd pfd = { job->fd, POLLOUT, 0 };
      if (moonrun_native_enter_cancellable_region(worker)) {
        *err_out = EINTR;
        return -1;
      }

      ret = poll(&pfd, 1, -1);
      moonrun_native_leave_cancellable_region(worker);

      if (ret < 0)
        break;
    }
  } else {
    ret = pwrite(
      job->fd,
      job->buf + job->offset,
      job->len,
      job->position
    );
  }
  if (ret < 0)
    *err_out = errno;
  return ret;

#endif
}
