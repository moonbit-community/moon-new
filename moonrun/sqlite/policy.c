/* SQL admission policy ported from moonrun/src/sqlite/policy.rs.
 * Copyright (C) 2026 International Digital Economy Academy.
 * Licensed under the Apache License, Version 2.0. */
#include <moonbit.h>
#include <stddef.h>

typedef int (*moonrun_authorizer)(void *, int, const char *, const char *,
                                  const char *, const char *);

static int untrusted_authorizer(void *context, int action, const char *argument,
                               const char *argument2, const char *database,
                               const char *trigger) {
  (void)context; (void)argument2; (void)database; (void)trigger;
  /* SQLite's stable authorizer codes: PRAGMA=19, ATTACH=24, DETACH=25. */
  if (action == 19 && argument != NULL) {
    const char *encoding = "encoding";
    int i = 0;
    for (; encoding[i] && argument[i]; i++) {
      unsigned char c = (unsigned char)argument[i];
      if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
      if (c != (unsigned char)encoding[i]) break;
    }
    if (encoding[i] == '\0' && argument[i] == '\0') return 0;
  }
  return action == 19 || action == 24 || action == 25 ? 1 : 0;
}

MOONBIT_FFI_EXPORT moonrun_authorizer moonrun_sqlite_authorizer(void) {
  return untrusted_authorizer;
}
