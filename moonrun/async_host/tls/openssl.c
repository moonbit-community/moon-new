/*
 * Copyright 2025 International Digital Economy Academy
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef _WIN32

#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <moonbit.h>

// OpenSSL 1.1.1+ / LibreSSL ABI constants, as used by moonbitlang/async.
#define BIO_TYPE_NONE 0
#define SSL_VERIFY_NONE 0x00
#define SSL_VERIFY_PEER 0x01
#define BIO_CTRL_FLUSH 11
#define SSL_CTRL_MODE 33
#define SSL_MODE_ENABLE_PARTIAL_WRITE 0x00000001U
#define SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER 0x00000002U
#define SSL_CTRL_SET_TLSEXT_HOSTNAME 55
#define TLSEXT_NAMETYPE_host_name 0
#define MAX_DIGEST_LEN 64

typedef struct BIO_METHOD BIO_METHOD;
typedef struct BIO BIO;
typedef struct SSL SSL;
typedef struct SSL_CTX SSL_CTX;
typedef struct SSL_METHOD SSL_METHOD;
typedef struct EVP_MD EVP_MD;
typedef struct X509 X509;
typedef struct X509_STORE X509_STORE;

typedef struct X509_VERIFY_PARAM X509_VERIFY_PARAM;
#define EXTRA_FUNCTIONS \
  IMPORT_FUNC(void, BIO_clear_flags, (BIO *, int)) \
  IMPORT_FUNC(void, ERR_clear_error, (void)) \
  IMPORT_FUNC(int, SSL_CTX_use_certificate_chain_file, (SSL_CTX *, const char *)) \
  IMPORT_FUNC(int, SSL_CTX_use_certificate_file, (SSL_CTX *, const char *, int)) \
  IMPORT_FUNC(int, SSL_CTX_use_PrivateKey_file, (SSL_CTX *, const char *, int)) \
  IMPORT_FUNC(int, SSL_CTX_check_private_key, (const SSL_CTX *)) \
  IMPORT_FUNC(int, SSL_CTX_load_verify_locations, (SSL_CTX *, const char *, const char *)) \
  IMPORT_FUNC(X509_VERIFY_PARAM *, SSL_get0_param, (SSL *)) \
  IMPORT_FUNC(void, X509_VERIFY_PARAM_set_hostflags, (X509_VERIFY_PARAM *, unsigned int)) \
  IMPORT_FUNC(int, X509_VERIFY_PARAM_set1_ip_asc, (X509_VERIFY_PARAM *, const char *)) \
  IMPORT_FUNC(int, i2d_X509, (const X509 *, unsigned char **))

#define IMPORTED_OPEN_SSL_FUNCTIONS\
  EXTRA_FUNCTIONS\
  IMPORT_FUNC(BIO_METHOD*, BIO_meth_new, (int type, const char *name))\
  IMPORT_FUNC(int, BIO_meth_set_write, (BIO_METHOD *biom, int (*write)(BIO *, const void *, int)))\
  IMPORT_FUNC(int, BIO_meth_set_read, (BIO_METHOD *biom, int (*read)(BIO *, void *, int)))\
  IMPORT_FUNC(int, BIO_meth_set_ctrl, (BIO_METHOD *biom, long (*ctrl)(BIO *, int, long, void *)))\
  IMPORT_FUNC(BIO *, BIO_new, (const BIO_METHOD *type))\
  IMPORT_FUNC(void, BIO_set_data, (BIO *bio, void *data))\
  IMPORT_FUNC(void *, BIO_get_data, (BIO *bio))\
  IMPORT_FUNC(void, BIO_set_init, (BIO *bio, int init))\
  IMPORT_FUNC(void, BIO_set_flags, (BIO *bio, int flags))\
  IMPORT_FUNC(SSL *, SSL_new, (SSL_CTX *ctx))\
  IMPORT_FUNC(void, SSL_set_bio, (SSL *s, BIO *rbio, BIO *wbio))\
  IMPORT_FUNC(int, SSL_connect, (SSL *ssl))\
  IMPORT_FUNC(int, SSL_set1_host, (SSL *ssl, const char *host))\
  IMPORT_FUNC(long, SSL_ctrl, (SSL *ssl, int cmd, long larg, void *parg))\
  IMPORT_FUNC(int, SSL_accept, (SSL *ssl))\
  IMPORT_FUNC(int, SSL_read, (SSL *ssl, void *buf, int num))\
  IMPORT_FUNC(int, SSL_write, (SSL *ssl, void *buf, int num))\
  IMPORT_FUNC(int, SSL_get_error, (SSL *ssl, int ret))\
  IMPORT_FUNC(size_t, SSL_get_finished, (const SSL *ssl, void *buf, size_t count))\
  IMPORT_FUNC(size_t, SSL_get_peer_finished, (const SSL *ssl, void *buf, size_t count))\
  IMPORT_FUNC(int, SSL_shutdown, (SSL *ssl))\
  IMPORT_FUNC(void, SSL_free, (SSL *ssl))\
  IMPORT_FUNC(X509 *, SSL_get_certificate, (const SSL *ssl))\
  IMPORT_FUNC(SSL_CTX *, SSL_CTX_new, (const SSL_METHOD*))\
  IMPORT_FUNC(void, SSL_CTX_free, (SSL_CTX *))\
  IMPORT_FUNC(X509_STORE *, SSL_CTX_get_cert_store, (const SSL_CTX *ctx))\
  IMPORT_FUNC(SSL_METHOD *, TLS_client_method, (void))\
  IMPORT_FUNC(SSL_METHOD *, TLS_server_method, (void))\
  IMPORT_FUNC(long, SSL_CTX_ctrl, (SSL_CTX *ctx, int cmd, long larg, void *parg))\
  IMPORT_FUNC(void, SSL_CTX_set_verify, (SSL_CTX *ctx, int mode, int (*verify_cb)(int, void*)))\
  IMPORT_FUNC(int, SSL_CTX_set_default_verify_paths, (SSL_CTX *ctx))\
  IMPORT_FUNC(unsigned long, ERR_get_error, (void))\
  IMPORT_FUNC(char *, ERR_error_string, (unsigned long e, char *buf))\
  IMPORT_FUNC(const char *, OBJ_nid2sn, (int n))\
  IMPORT_FUNC(int, OBJ_find_sigid_algs, (int signid, int *pdig_nid, int *ppkey_nid))\
  IMPORT_FUNC(const EVP_MD *, EVP_get_digestbyname, (const char *name))\
  IMPORT_FUNC(const EVP_MD *, EVP_sha256, (void))\
  IMPORT_FUNC_WITH_ALT_NAMES(X509 *, SSL_get1_peer_certificate, (const SSL *ssl), { "SSL_get_peer_certificate" })\
  IMPORT_FUNC(X509 *, d2i_X509, (X509 **px, const unsigned char **in, long len))\
  IMPORT_FUNC(int, X509_get_signature_nid, (const X509 *x))\
  IMPORT_FUNC(void, X509_free, (const X509 *cert))\
  IMPORT_FUNC(int, X509_STORE_add_cert, (X509_STORE *xs, X509 *x))\
  IMPORT_FUNC(int, X509_digest, (const X509 *data, const EVP_MD *type, unsigned char *md, unsigned int *len))

#define IMPORT_FUNC(ret, name, params) static ret (*name) params;
#define IMPORT_FUNC_WITH_ALT_NAMES(ret, name, params, alt_names) IMPORT_FUNC(ret, name, params)
IMPORTED_OPEN_SSL_FUNCTIONS
#undef IMPORT_FUNC
#undef IMPORT_FUNC_WITH_ALT_NAMES

static int (*SSL_is_init_finished_optional)(const SSL *);
static int (*SSL_state_optional)(const SSL *);
static const char *missing_symbol;
static int load_symbols(int *major, int *minor, int *fix) {
  void *handle = 0;

#ifdef __MACH__
  handle = dlopen("/usr/lib/libssl.48.dylib", RTLD_LAZY);
  if (!handle) handle = dlopen("/usr/lib/libssl.46.dylib", RTLD_LAZY);
#else
  handle = dlopen("libssl.so.3", RTLD_LAZY);
  if (!handle) handle = dlopen("libssl.so.1.1", RTLD_LAZY);
  if (!handle) handle = dlopen("libssl.so", RTLD_LAZY);
#endif
  if (!handle) return 1;

  unsigned long (*OPENSSL_version_num)() = dlsym(handle, "OpenSSL_version_num");
  if (!OPENSSL_version_num)
    return 2;

  unsigned long version = (*OPENSSL_version_num)();
  *major = version >> 28;
  *minor = (version >> 20) & 0xff;
  *fix = (version >> 12) & 0xff;

  if (*major < 1 || *major == 1 && (*minor < 1 || *minor == 1 && *fix < 1))
    return 3;

#define IMPORT_FUNC(ret, func, params)\
  func = dlsym(handle, "" #func "");\
  if (!func) { missing_symbol = #func; return 4; }
#define IMPORT_FUNC_WITH_ALT_NAMES(ret, func, params, alt_names)\
  func = dlsym(handle, "" #func "");\
  if (!func) {\
    const char *names[] = alt_names;\
    for (int i = 0; !func && i < sizeof(names) / sizeof(const char*); ++i) {\
      func = dlsym(handle, names[i]);\
    }\
    if (!func) { missing_symbol = #func; return 4; }\
  }

  IMPORTED_OPEN_SSL_FUNCTIONS

#undef IMPORT_FUNC
#undef IMPORT_FUNC_WITH_ALT_NAMES

  SSL_is_init_finished_optional = dlsym(handle, "SSL_is_init_finished");
  SSL_state_optional = dlsym(handle, "SSL_state");
  return 0;
}

/* The scoped BIO follows Rust moonrun's QueueStream. All borrowed buffers are
 * cleared before returning to MoonBit; OpenSSL only retains its own storage. */
typedef struct {
  SSL_CTX *ctx;
  SSL *ssl;
  int mode, shutdown, shutdown_done, finished, read, written, want_read, want_write;
  unsigned char *input, *output;
  int input_length, output_length;
  unsigned char *blob;
  char error[1024];
} tls_session;
static BIO_METHOD *session_bio;
static pthread_once_t loader_once = PTHREAD_ONCE_INIT;
static int loader_error;
static long bio_ctrl(BIO *bio, int command, long value, void *pointer) {
  (void)bio; (void)value; (void)pointer;
  return command == BIO_CTRL_FLUSH;
}
static int bio_read(BIO *bio, void *output, int length) {
  tls_session *session = BIO_get_data(bio);
  BIO_clear_flags(bio, 15);
  int available = session->input_length - session->read;
  if (length <= 0) return 0;
  if (available <= 0) { BIO_set_flags(bio, 9); return -1; }
  if (length > available) length = available;
  memcpy(output, session->input + session->read, length);
  session->read += length;
  return length;
}
static int bio_write(BIO *bio, const void *input, int length) {
  tls_session *session = BIO_get_data(bio);
  BIO_clear_flags(bio, 15);
  int available = session->output_length - session->written;
  if (length <= 0) return 0;
  if (available <= 0) { BIO_set_flags(bio, 10); return -1; }
  if (length > available) length = available;
  memcpy(session->output + session->written, input, length);
  session->written += length;
  return length;
}
static void initialize(void) {
  int major, minor, fix;
  loader_error = load_symbols(&major, &minor, &fix);
  if (loader_error) return;
  session_bio = BIO_meth_new(BIO_TYPE_NONE, "moonrun scoped TLS");
  if (!session_bio || !BIO_meth_set_read(session_bio, bio_read) ||
      !BIO_meth_set_write(session_bio, bio_write) ||
      !BIO_meth_set_ctrl(session_bio, bio_ctrl)) loader_error = 4;
}
static int fail(tls_session *session, const char *context) {
  unsigned long code = loader_error ? 0 : ERR_get_error();
  char detail[256] = {0};
  if (code) ERR_error_string(code, detail);
  snprintf(session->error, sizeof(session->error), "%s%s%s", context,
      code ? ": " : "", detail);
  return -1;
}
MOONBIT_FFI_EXPORT tls_session *moonrun_tls_new(void) {
  tls_session *session = calloc(1, sizeof(*session));
  if (!session) abort();
  return session;
}
MOONBIT_FFI_EXPORT void moonrun_tls_free(tls_session *session) {
  if (session->ssl) SSL_free(session->ssl);
  if (session->ctx) SSL_CTX_free(session->ctx);
  free(session->blob);
  free(session);
}
static int context(tls_session *session, int server) {
  pthread_once(&loader_once, initialize);
  if (loader_error) { snprintf(session->error, sizeof(session->error), "failed to load OpenSSL TLS backend (%d, %s)", loader_error, missing_symbol ? missing_symbol : "library or version"); return -1; }
  ERR_clear_error();
  session->mode = server;
  session->ctx = SSL_CTX_new(server ? TLS_server_method() : TLS_client_method());
  if (!session->ctx) return fail(session, "failed to create TLS context");
  SSL_CTX_ctrl(session->ctx, SSL_CTRL_MODE, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER, NULL);
  return 0;
}
static int connection(tls_session *session) {
  session->ssl = SSL_new(session->ctx);
  if (!session->ssl) return fail(session, "failed to create TLS connection");
  BIO *bio = BIO_new(session_bio);
  if (!bio) return fail(session, "failed to create TLS BIO");
  BIO_set_data(bio, session);
  BIO_set_init(bio, 1);
  SSL_set_bio(session->ssl, bio, bio);
  session->want_write = 1;
  return 0;
}
MOONBIT_FFI_EXPORT int moonrun_tls_client(tls_session *session, unsigned char *host, int sni, int trust) {
  if (context(session, 0)) return -1;
  SSL_CTX_set_verify(session->ctx, trust ? SSL_VERIFY_PEER : SSL_VERIFY_NONE, NULL);
  if (trust == 1 && !SSL_CTX_set_default_verify_paths(session->ctx))
    return fail(session, "failed to load system TLS roots");
#ifdef __MACH__
  /* Match Rust moonrun's macOS system-root fallback. OpenSSL's compiled default
   * location can differ from the system certificate bundle. */
  if (trust == 1 && !SSL_CTX_load_verify_locations(session->ctx, "/etc/ssl/cert.pem", NULL))
    return fail(session, "failed to load system TLS roots");
#endif
  if (connection(session)) return -1;
  if (*host) {
    if (sni && !SSL_ctrl(session->ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, 0, host))
      return fail(session, "failed to configure TLS SNI");
    if (trust) {
      X509_VERIFY_PARAM *param = SSL_get0_param(session->ssl);
      X509_VERIFY_PARAM_set_hostflags(param, 4); /* NO_PARTIAL_WILDCARDS */
      unsigned char address[16];
      int is_ip = inet_pton(AF_INET, (char *)host, address) == 1 ||
                  inet_pton(AF_INET6, (char *)host, address) == 1;
      if (!(is_ip ? X509_VERIFY_PARAM_set1_ip_asc(param, (char *)host) :
                    SSL_set1_host(session->ssl, (char *)host)))
        return fail(session, "failed to configure TLS host verification");
    }
  }
  return 0;
}
MOONBIT_FFI_EXPORT int moonrun_tls_add_root(tls_session *session, unsigned char *der, int length) {
  ERR_clear_error();
  const unsigned char *input = der;
  X509 *certificate = d2i_X509(NULL, &input, length);
  if (!certificate) return fail(session, "failed to parse TLS root certificate");
  int result = X509_STORE_add_cert(SSL_CTX_get_cert_store(session->ctx), certificate);
  X509_free(certificate);
  return result ? 0 : fail(session, "failed to add TLS root certificate");
}
MOONBIT_FFI_EXPORT int moonrun_tls_server_files(tls_session *session,
    unsigned char *key, int key_type, unsigned char *cert, int cert_type) {
  if (context(session, 1)) return -1;
  if (!(cert_type == 1 ? SSL_CTX_use_certificate_chain_file(session->ctx, (char *)cert) :
                        SSL_CTX_use_certificate_file(session->ctx, (char *)cert, cert_type)))
    return fail(session, "failed to load TLS certificate");
  if (!SSL_CTX_use_PrivateKey_file(session->ctx, (char *)key, key_type) ||
      !SSL_CTX_check_private_key(session->ctx))
    return fail(session, "failed to load TLS private key");
  return connection(session);
}
MOONBIT_FFI_EXPORT int moonrun_tls_server_pfx(tls_session *session, unsigned char *pfx, int length) {
  (void)pfx; (void)length;
  snprintf(session->error, sizeof(session->error),
      "TLS PFX server certificates are supported only by SChannel on Windows");
  return -1;
}
static int is_finished(tls_session *session) {
  if (SSL_is_init_finished_optional) return SSL_is_init_finished_optional(session->ssl);
  if (SSL_state_optional) return SSL_state_optional(session->ssl) == 3; /* LibreSSL SSL_ST_OK */
  return session->finished;
}
static int ssl_status(tls_session *session, int result) {
  int error = SSL_get_error(session->ssl, result);
  session->want_read = session->want_write = 0;
  if (error == 2) { session->want_read = 1; return -3; }
  if (error == 3) { session->want_write = 1; return -3; }
  if (error == 6) return -2;
  return fail(session, "TLS operation failed");
}
MOONBIT_FFI_EXPORT int moonrun_tls_step(tls_session *session, int kind,
    unsigned char *input, int input_length, unsigned char *output, int output_length,
    unsigned char *plain, int plain_length) {
  session->read = session->written = session->want_read = session->want_write = 0;
  session->input = input; session->input_length = input_length;
  session->output = output; session->output_length = output_length;
  ERR_clear_error();
  int result;
  if (kind <= 1) {
    if (kind != session->mode) result = fail(session, "TLS handshake handle mode mismatch");
    else if (session->shutdown_done) result = 0;
    else if (session->shutdown) {
      int status = SSL_shutdown(session->ssl);
      if (status >= 0) { session->shutdown_done = 1; result = 0; }
      else result = ssl_status(session, status);
    } else if (is_finished(session)) result = 0;
    else {
      int status = kind == 0 ? SSL_connect(session->ssl) : SSL_accept(session->ssl);
      if (status == 1) session->finished = 1;
      result = status == 1 ? 0 : ssl_status(session, status);
    }
    result = result == 0 ? 0 : result == -2 ? 4 : result == -3 ?
        (session->want_write ? 2 : 1) : result == -4 ? 5 : 3;
  } else if (!plain_length) result = 0;
  else if (kind == 3 && session->shutdown) result = -2;
  else if (!is_finished(session)) result = -4;
  else {
    int status = kind == 2 ? SSL_read(session->ssl, plain, plain_length) :
                           SSL_write(session->ssl, plain, plain_length);
    result = status > 0 ? status : ssl_status(session, status);
    if (result == -3 && !is_finished(session)) result = -4;
  }
  if (session->written && (result == -3 || result == -4)) session->want_write = 1;
  session->input = session->output = NULL;
  session->input_length = session->output_length = 0;
  return result;
}
MOONBIT_FFI_EXPORT int moonrun_tls_info(tls_session *session, int kind) {
  switch (kind) {
    case 0: return session->read;
    case 1: return session->written;
    case 2: return session->want_read;
    case 3: return session->want_write;
    default: session->shutdown = 1; return 0;
  }
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrun_tls_error(tls_session *session) {
  const char *message = *session->error ? session->error : "unknown TLS error";
  int length = (int)strlen(message);
  moonbit_bytes_t result = moonbit_make_bytes(length, 0);
  memcpy(result, message, length);
  session->error[0] = 0;
  return result;
}
MOONBIT_FFI_EXPORT int moonrun_tls_blob_length(tls_session *session, int kind) {
  free(session->blob); session->blob = NULL;
  if (kind == 1) {
    size_t length = session->mode ? SSL_get_peer_finished(session->ssl, NULL, 0) :
                                  SSL_get_finished(session->ssl, NULL, 0);
    if (!length) return -1;
    session->blob = malloc(length);
    if (!session->blob) abort();
    if (session->mode) SSL_get_peer_finished(session->ssl, session->blob, length);
    else SSL_get_finished(session->ssl, session->blob, length);
    return (int)length;
  }
  X509 *certificate = kind == 0 || !session->mode ? SSL_get1_peer_certificate(session->ssl) :
                                                                  SSL_get_certificate(session->ssl);
  if (!certificate) return kind == 0 ? 0 : -1;
  int length = -2;
  if (kind == 0) {
    length = i2d_X509(certificate, NULL);
    if (length > 0) {
      session->blob = malloc(length);
      if (!session->blob) abort();
      unsigned char *out = session->blob;
      i2d_X509(certificate, &out);
    }
  } else {
    int digest_nid, key_nid;
    const EVP_MD *digest = NULL;
    if (OBJ_find_sigid_algs(X509_get_signature_nid(certificate), &digest_nid, &key_nid)) {
      const char *name = OBJ_nid2sn(digest_nid);
      if (name) digest = !strcmp(name, "MD5") || !strcmp(name, "SHA1") ?
                         EVP_sha256() : EVP_get_digestbyname(name);
    }
    if (digest) {
      unsigned char buffer[64]; unsigned int count;
      if (X509_digest(certificate, digest, buffer, &count)) {
        session->blob = malloc(count);
        if (!session->blob) abort();
        memcpy(session->blob, buffer, count); length = (int)count;
      }
    }
  }
  if (kind == 0 || !session->mode) X509_free(certificate);
  if (length < 0) fail(session, "failed to read TLS certificate or channel binding");
  return length;
}
MOONBIT_FFI_EXPORT void moonrun_tls_blob_copy(tls_session *session, unsigned char *output, int length) {
  if (length) memcpy(output, session->blob, length);
}
#endif
