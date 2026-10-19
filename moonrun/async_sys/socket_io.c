/* Nonblocking socket calls. Readiness is awaited through the per-socket
 * native event bridge; no MoonBit object is retained by an OS operation. */
#include <moonbit.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef HANDLE socket_fd;
typedef int socklen_t;
#define native_socket(fd) ((SOCKET)(fd))
#else
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
typedef int socket_fd;
#define native_socket(fd) (fd)
#endif

MOONBIT_FFI_EXPORT int moonrun_socket_invalid(socket_fd fd) {
#ifdef _WIN32
  return native_socket(fd) == INVALID_SOCKET;
#else
  return fd < 0;
#endif
}
MOONBIT_FFI_EXPORT int moonrun_socket_prepare(socket_fd fd) {
#ifdef _WIN32
  u_long nonblocking = 1;
  return ioctlsocket(native_socket(fd), FIONBIO, &nonblocking);
#else
  int flags = fcntl(fd, F_GETFD);
  if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) return -1;
#ifdef SO_NOSIGPIPE
  int no_sigpipe = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) < 0) return -1;
#endif
  flags = fcntl(fd, F_GETFL);
  return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
#endif
}
MOONBIT_FFI_EXPORT void moonrun_socket_close(socket_fd fd) {
#ifdef _WIN32
  closesocket(native_socket(fd));
#else
  close(fd);
#endif
}
MOONBIT_FFI_EXPORT int moonrun_socket_bind(socket_fd fd, void *addr, int len) {
  return bind(native_socket(fd), addr, (socklen_t)len);
}
MOONBIT_FFI_EXPORT int moonrun_socket_connect(socket_fd fd, void *addr, int len) {
  return connect(native_socket(fd), addr, (socklen_t)len);
}
MOONBIT_FFI_EXPORT socket_fd moonrun_socket_accept(socket_fd fd, void *addr, int len) {
  socklen_t length = (socklen_t)len;
#ifdef _WIN32
  return (HANDLE)accept(native_socket(fd), addr, &length);
#else
  return accept(fd, addr, &length);
#endif
}
MOONBIT_FFI_EXPORT int moonrun_socket_error(socket_fd fd) {
  int error = 0;
  socklen_t length = sizeof(error);
  if (getsockopt(native_socket(fd), SOL_SOCKET, SO_ERROR, (void *)&error, &length) < 0) return -1;
  return error;
}
MOONBIT_FFI_EXPORT int moonrun_socket_read(socket_fd fd, void *buffer, int length, int flags) {
  return (int)recv(native_socket(fd), buffer, length, flags);
}
MOONBIT_FFI_EXPORT int moonrun_socket_write(socket_fd fd, void *buffer, int length, int flags) {
#ifdef MSG_NOSIGNAL
  flags |= MSG_NOSIGNAL;
#endif
  return (int)send(native_socket(fd), buffer, length, flags);
}
MOONBIT_FFI_EXPORT int moonrun_socket_recvfrom(socket_fd fd, void *buffer, int length, int flags, void *addr, int addr_len) {
  socklen_t size = (socklen_t)addr_len;
  return (int)recvfrom(native_socket(fd), buffer, length, flags, addr, &size);
}
MOONBIT_FFI_EXPORT int moonrun_socket_sendto(socket_fd fd, void *buffer, int length, int flags, void *addr, int addr_len) {
#ifdef MSG_NOSIGNAL
  flags |= MSG_NOSIGNAL;
#endif
  return (int)sendto(native_socket(fd), buffer, length, flags, addr, (socklen_t)addr_len);
}

#ifndef _WIN32
#include <netdb.h>
#include <string.h>
#endif
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrun_gai_message(int code) {
#ifdef _WIN32
  extern moonbit_bytes_t moonrun_error_message(int);
  return moonrun_error_message(code);
#else
  const char *message = gai_strerror(code);
  int length = (int)strlen(message) + 1;
  moonbit_bytes_t bytes = moonbit_make_bytes(length, 0);
  memcpy(bytes, message, (size_t)length);
  return bytes;
#endif
}

#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <wchar.h>
#endif
extern void *moonbitlang_async_if_indextoname(socket_fd, uint32_t);
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrun_interface_name(socket_fd fd, uint32_t index) {
  void *name = moonbitlang_async_if_indextoname(fd, index);
  if (!name) {
#ifdef _WIN32
    int error = WSAGetLastError();
#else
    int error = errno;
#endif
    moonbit_bytes_t empty = moonbit_make_bytes(0, 0);
#ifdef _WIN32
    WSASetLastError(error);
#else
    errno = error;
#endif
    return empty;
  }
#ifdef _WIN32
  int length = (int)((wcslen(name) + 1) * sizeof(wchar_t));
#else
  int length = (int)strlen(name) + 1;
#endif
  moonbit_bytes_t bytes = moonbit_make_bytes(length, 0);
  memcpy(bytes, name, (size_t)length);
  // async returns borrowed static storage; copy it before the next lookup.
  return bytes;
}
