#ifndef MOONRUN_OPERATION_H
#define MOONRUN_OPERATION_H
#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
typedef HANDLE moonrun_fd;
#else
typedef int moonrun_fd;
#endif
typedef struct moonrun_operation {
  void *job;
  unsigned char *buffer;
  int capacity, kind, taken;
} moonrun_operation;
void *moonrun_native_make_job(int32_t, void (*)(void *), int32_t (*)(void *, int32_t *), int32_t (*)(void *));
void moonrun_native_free_job(void *);
int32_t moonrun_native_job_get_ret(void *);
int32_t moonrun_native_job_get_err(void *);
moonrun_operation *moonrun_operation_wrap(void *, unsigned char *, int, int);
#endif
