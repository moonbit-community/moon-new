/*
 * Copyright 2025 International Digital Economy Academy
 * Licensed under the Apache License, Version 2.0.
 * Adapted from moonbitlang/async's Schannel primitives and Rust moonrun's
 * transport-independent TLS state machine. See NOTICE.
 */
#ifdef _WIN32
#define SECURITY_WIN32
#define SCHANNEL_USE_BLACKLISTS
#include <windows.h>
#include <security.h>
#include <schannel.h>
#include <wincrypt.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <moonbit.h>
#pragma comment(lib, "secur32.lib")
#pragma comment(lib, "crypt32.lib")

typedef struct {
  CredHandle credentials;
  CtxtHandle context;
  int credentials_live, context_live, mode, trust, manual_verify, finished, sni;
  int shutdown, shutdown_applied, shutdown_done;
  int read, written, want_read, want_write;
  wchar_t *host;
  SecPkgContext_StreamSizes sizes;
  HCERTSTORE roots, server_store;
  PCCERT_CONTEXT server_cert;
  unsigned char *pending, *plain, *blob;
  int pending_length, pending_offset, plain_length, plain_offset;
  char error[1024];
} tls_session;
static int failure(tls_session *session, const char *operation, SECURITY_STATUS code) {
  snprintf(session->error, sizeof(session->error), "%s: 0x%08lx", operation, (unsigned long)code);
  return -1;
}
MOONBIT_FFI_EXPORT tls_session *moonrun_tls_new(void) {
  tls_session *session = calloc(1, sizeof(*session));
  if (!session) abort();
  SecInvalidateHandle(&session->context);
  return session;
}
MOONBIT_FFI_EXPORT void moonrun_tls_free(tls_session *session) {
  if (session->context_live) DeleteSecurityContext(&session->context);
  if (session->credentials_live) FreeCredentialsHandle(&session->credentials);
  if (session->server_cert) CertFreeCertificateContext(session->server_cert);
  if (session->server_store) CertCloseStore(session->server_store, 0);
  if (session->roots) CertCloseStore(session->roots, 0);
  free(session->host); free(session->pending); free(session->plain); free(session->blob); free(session);
}
static int credentials(tls_session *session, PCCERT_CONTEXT cert) {
  TLS_PARAMETERS protocols = {0};
  protocols.grbitDisabledProtocols = session->mode ?
      SP_PROT_TLS1_0_SERVER | SP_PROT_TLS1_1_SERVER : SP_PROT_TLS1_CLIENT;
  SCH_CREDENTIALS config = {0};
  config.dwVersion = SCH_CREDENTIALS_VERSION;
  config.dwFlags = SCH_USE_STRONG_CRYPTO | SCH_CRED_IGNORE_NO_REVOCATION_CHECK;
  if (!session->mode && session->manual_verify) config.dwFlags |= SCH_CRED_MANUAL_CRED_VALIDATION;
  if (cert) { config.cCreds = 1; config.paCred = &cert; }
  config.cTlsParameters = 1; config.pTlsParameters = &protocols;
  SECURITY_STATUS status = AcquireCredentialsHandleW(NULL, UNISP_NAME_W,
      session->mode ? SECPKG_CRED_INBOUND : SECPKG_CRED_OUTBOUND,
      NULL, &config, NULL, NULL, &session->credentials, NULL);
  if (status != SEC_E_OK) return failure(session, "failed to create TLS credentials", status);
  session->credentials_live = 1; session->want_write = 1;
  return 0;
}
MOONBIT_FFI_EXPORT int moonrun_tls_client(tls_session *session, unsigned char *host, int sni, int trust) {
  session->mode = 0; session->trust = trust; session->sni = sni;
  session->manual_verify = trust != 1 || !sni;
  size_t length = wcslen((wchar_t *)host);
  session->host = malloc((length + 1) * sizeof(wchar_t));
  if (!session->host) abort();
  memcpy(session->host, host, (length + 1) * sizeof(wchar_t));
  /* Keep hostname verification when SNI is disabled, without sending a name. */
  return credentials(session, NULL);
}
MOONBIT_FFI_EXPORT int moonrun_tls_add_root(tls_session *session, unsigned char *der, int length) {
  PCCERT_CONTEXT cert = CertCreateCertificateContext(X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, der, length);
  if (!cert) return failure(session, "failed to parse TLS root certificate", GetLastError());
  if (!session->roots) session->roots = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, CERT_STORE_CREATE_NEW_FLAG, NULL);
  int ok = session->roots && CertAddCertificateContextToStore(session->roots, cert, CERT_STORE_ADD_USE_EXISTING, NULL);
  DWORD error = GetLastError(); CertFreeCertificateContext(cert);
  return ok ? 0 : failure(session, "failed to add TLS root certificate", error);
}
MOONBIT_FFI_EXPORT int moonrun_tls_server_files(tls_session *session, unsigned char *key, int key_type, unsigned char *cert, int cert_type) {
  (void)key; (void)key_type; (void)cert; (void)cert_type;
  snprintf(session->error, sizeof(session->error), "SChannel TLS servers require PKCS#12/PFX certificates on Windows");
  return -1;
}
MOONBIT_FFI_EXPORT int moonrun_tls_server_pfx(tls_session *session, unsigned char *pfx, int length) {
  session->mode = 1;
  CRYPT_DATA_BLOB blob = {(DWORD)length, pfx};
  session->server_store = PFXImportCertStore(&blob, NULL, PKCS12_NO_PERSIST_KEY);
  if (!session->server_store) return failure(session, "failed to load TLS PFX", GetLastError());
  session->server_cert = CertFindCertificateInStore(session->server_store,
      X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, 0, CERT_FIND_HAS_PRIVATE_KEY, NULL, NULL);
  if (!session->server_cert) return failure(session, "TLS PFX contains no private key", GetLastError());
  return credentials(session, session->server_cert);
}
static int verify(tls_session *session) {
  if (!session->trust || !session->manual_verify) return 0;
  PCCERT_CONTEXT cert = NULL;
  SECURITY_STATUS status = QueryContextAttributesW(&session->context, SECPKG_ATTR_REMOTE_CERT_CONTEXT, &cert);
  if (status != SEC_E_OK) return failure(session, "failed to query TLS certificate", status);
  HCERTCHAINENGINE engine = NULL;
  if (session->trust == 2) {
    if (!session->roots) session->roots = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, CERT_STORE_CREATE_NEW_FLAG, NULL);
    CERT_CHAIN_ENGINE_CONFIG config = {0};
    config.cbSize = sizeof(config); config.hExclusiveRoot = session->roots;
    config.dwExclusiveFlags = CERT_CHAIN_EXCLUSIVE_ENABLE_CA_FLAG;
    if (!session->roots || !CertCreateCertificateChainEngine(&config, &engine)) {
      DWORD error = GetLastError(); CertFreeCertificateContext(cert);
      return failure(session, "failed to create TLS root chain", error);
    }
  }
  CERT_CHAIN_PARA chain_config = {0}; chain_config.cbSize = sizeof(chain_config);
  PCCERT_CHAIN_CONTEXT chain = NULL;
  BOOL ok = CertGetCertificateChain(engine, cert, NULL, cert->hCertStore, &chain_config, 0, NULL, &chain);
  DWORD error = GetLastError();
  if (ok) {
    SSL_EXTRA_CERT_CHAIN_POLICY_PARA ssl = {0};
    ssl.cbSize = sizeof(ssl); ssl.dwAuthType = AUTHTYPE_SERVER;
    ssl.pwszServerName = *session->host ? session->host : NULL;
    CERT_CHAIN_POLICY_PARA config = {0}; config.cbSize = sizeof(config); config.pvExtraPolicyPara = &ssl;
    CERT_CHAIN_POLICY_STATUS result = {0}; result.cbSize = sizeof(result);
    ok = CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, chain, &config, &result);
    error = ok ? result.dwError : GetLastError();
    CertFreeCertificateChain(chain);
  }
  if (engine) CertFreeCertificateChainEngine(engine);
  CertFreeCertificateContext(cert);
  return ok && !error ? 0 : failure(session, "TLS certificate verification failed", error);
}
static void drain(tls_session *session, unsigned char *output, int length) {
  int count = session->pending_length - session->pending_offset;
  if (count > length - session->written) count = length - session->written;
  if (count) memcpy(output + session->written, session->pending + session->pending_offset, count);
  session->pending_offset += count; session->written += count;
  if (session->pending_offset == session->pending_length) {
    free(session->pending); session->pending = NULL;
    session->pending_length = session->pending_offset = 0;
  }
  session->want_write = session->pending_length > 0;
}
static int handshake(tls_session *session, unsigned char *input, int length) {
  SecBuffer incoming[2] = {{(unsigned long)length, SECBUFFER_TOKEN, input}, {0, SECBUFFER_EMPTY, NULL}};
  SecBuffer outgoing = {0, SECBUFFER_TOKEN, NULL};
  SecBufferDesc in = {SECBUFFER_VERSION, 2, incoming}, out = {SECBUFFER_VERSION, 1, &outgoing};
  ULONG attributes = 0;
  SECURITY_STATUS status;
  int initial = !session->context_live;
  if (session->mode) status = AcceptSecurityContext(&session->credentials,
      initial ? NULL : &session->context, &in,
      ASC_REQ_ALLOCATE_MEMORY | ASC_REQ_STREAM | ASC_REQ_CONFIDENTIALITY | ASC_REQ_INTEGRITY,
      SECURITY_NATIVE_DREP, &session->context, &out, &attributes, NULL);
  else status = InitializeSecurityContextW(&session->credentials,
      initial ? NULL : &session->context,
      session->sni && *session->host ? session->host : NULL,
      ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM | ISC_REQ_CONFIDENTIALITY | ISC_REQ_INTEGRITY,
      0, SECURITY_NATIVE_DREP, initial ? NULL : &in, 0, &session->context, &out, &attributes, NULL);
  session->context_live = SecIsValidHandle(&session->context);
  if (outgoing.pvBuffer) {
    if (outgoing.cbBuffer) {
      session->pending = malloc(outgoing.cbBuffer);
      if (!session->pending) abort();
      memcpy(session->pending, outgoing.pvBuffer, outgoing.cbBuffer);
      session->pending_length = outgoing.cbBuffer; session->pending_offset = 0;
    }
    FreeContextBuffer(outgoing.pvBuffer);
  }
  if (status == SEC_E_INCOMPLETE_MESSAGE) { session->want_read = 1; return -3; }
  session->read = initial && !session->mode ? 0 : length;
  if (incoming[1].BufferType == SECBUFFER_EXTRA) session->read -= incoming[1].cbBuffer;
  if (status == SEC_E_OK) {
    if (session->shutdown) session->shutdown_done = 1;
    else {
      status = QueryContextAttributesW(&session->context, SECPKG_ATTR_STREAM_SIZES, &session->sizes);
      if (status != SEC_E_OK) return failure(session, "failed to query TLS stream sizes", status);
      if (!session->mode && verify(session)) return -1;
      session->finished = 1;
    }
    return 0;
  }
  if (status == SEC_I_CONTINUE_NEEDED) { session->want_read = !session->pending_length; return -3; }
  if (status == SEC_I_CONTEXT_EXPIRED) return -2;
  return failure(session, "TLS handshake failed", status);
}
static int read_plain(tls_session *session, unsigned char *input, int length, unsigned char *plain, int capacity) {
  if (!session->plain_length) {
    if (!length) { session->want_read = 1; return -3; }
    SecBuffer buffers[4] = {{(unsigned long)length, SECBUFFER_DATA, input}, {0, SECBUFFER_EMPTY, NULL}, {0, SECBUFFER_EMPTY, NULL}, {0, SECBUFFER_EMPTY, NULL}};
    SecBufferDesc desc = {SECBUFFER_VERSION, 4, buffers};
    SECURITY_STATUS status = DecryptMessage(&session->context, &desc, 0, NULL);
    if (status == SEC_E_INCOMPLETE_MESSAGE) { session->want_read = 1; return -3; }
    if (status != SEC_E_OK && status != SEC_I_RENEGOTIATE && status != SEC_I_CONTEXT_EXPIRED)
      return failure(session, "TLS plaintext read failed", status);
    session->read = length;
    for (int i = 0; i < 4; ++i) {
      if (buffers[i].BufferType == SECBUFFER_EXTRA) session->read -= buffers[i].cbBuffer;
      if (buffers[i].BufferType == SECBUFFER_DATA && buffers[i].cbBuffer) {
        session->plain = malloc(buffers[i].cbBuffer);
        if (!session->plain) abort();
        memcpy(session->plain, buffers[i].pvBuffer, buffers[i].cbBuffer);
        session->plain_length = buffers[i].cbBuffer;
      }
    }
    if (status == SEC_I_CONTEXT_EXPIRED) return -2;
    if (status == SEC_I_RENEGOTIATE) { session->read = 0; session->finished = 0; return -4; }
  }
  int count = session->plain_length - session->plain_offset;
  if (count > capacity) count = capacity;
  if (count) memcpy(plain, session->plain + session->plain_offset, count);
  session->plain_offset += count;
  if (session->plain_offset == session->plain_length) {
    free(session->plain); session->plain = NULL; session->plain_length = session->plain_offset = 0;
  }
  if (!count) { session->want_read = 1; return -3; }
  return count;
}
static int write_plain(tls_session *session, unsigned char *plain, int length,
    unsigned char *output, int output_length) {
  int remaining = output_length - session->written;
  int overhead = session->sizes.cbHeader + session->sizes.cbTrailer;
  if (session->pending_length || remaining <= overhead) { session->want_write = 1; return -3; }
  int count = length;
  if (count > (int)session->sizes.cbMaximumMessage) count = session->sizes.cbMaximumMessage;
  if (count > remaining - overhead) count = remaining - overhead;
  unsigned char *buffer = output + session->written;
  SecBuffer buffers[4] = {
    {session->sizes.cbHeader, SECBUFFER_STREAM_HEADER, buffer},
    {(unsigned long)count, SECBUFFER_DATA, buffer + session->sizes.cbHeader},
    {session->sizes.cbTrailer, SECBUFFER_STREAM_TRAILER, buffer + session->sizes.cbHeader + count},
    {0, SECBUFFER_EMPTY, NULL}
  };
  memcpy(buffers[1].pvBuffer, plain, count);
  SecBufferDesc desc = {SECBUFFER_VERSION, 4, buffers};
  SECURITY_STATUS status = EncryptMessage(&session->context, 0, &desc, 0);
  if (status != SEC_E_OK) return failure(session, "TLS plaintext write failed", status);
  int actual = 0;
  for (int i = 0; i < 3; ++i) { memmove(buffer + actual, buffers[i].pvBuffer, buffers[i].cbBuffer); actual += buffers[i].cbBuffer; }
  session->written += actual;
  session->want_write = 1;
  return count;
}
MOONBIT_FFI_EXPORT int moonrun_tls_step(tls_session *session, int kind, unsigned char *input, int input_length,
    unsigned char *output, int output_length, unsigned char *plain, int plain_length) {
  session->read = session->written = session->want_read = session->want_write = 0;
  drain(session, output, output_length);
  int result;
  if (kind <= 1) {
    if (kind != session->mode) result = failure(session, "TLS handshake handle mode mismatch", SEC_E_INVALID_HANDLE);
    else if (session->pending_length) result = -3;
    else if (session->shutdown_done || (session->finished && !session->shutdown)) result = 0;
    else {
      if (session->shutdown && !session->shutdown_applied) {
        DWORD command = SCHANNEL_SHUTDOWN;
        SecBuffer token = {sizeof(command), SECBUFFER_TOKEN, &command};
        SecBufferDesc desc = {SECBUFFER_VERSION, 1, &token};
        SECURITY_STATUS status = ApplyControlToken(&session->context, &desc);
        if (status != SEC_E_OK) return failure(session, "TLS shutdown failed", status), 3;
        session->shutdown_applied = 1;
      }
      result = handshake(session, input, input_length);
      drain(session, output, output_length);
      if (!result && session->pending_length) result = -3;
    }
    return !result ? 0 : result == -3 ? (session->want_write ? 2 : 1) : result == -2 ? 4 : 3;
  }
  if (!plain_length) return 0;
  if (kind == 3 && session->shutdown) return -2;
  if (!session->finished) return -4;
  result = kind == 2 ? read_plain(session, input, input_length, plain, plain_length) : write_plain(session, plain, plain_length, output, output_length);
  if (kind == 2) drain(session, output, output_length);
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
  moonbit_bytes_t bytes = moonbit_make_bytes(length, 0); memcpy(bytes, message, length);
  session->error[0] = 0; return bytes;
}
MOONBIT_FFI_EXPORT int moonrun_tls_blob_length(tls_session *session, int kind) {
  free(session->blob); session->blob = NULL;
  if (!session->context_live) return kind == 0 ? 0 : -1;
  if (kind == 0) {
    PCCERT_CONTEXT cert = NULL;
    SECURITY_STATUS status = QueryContextAttributesW(&session->context, SECPKG_ATTR_REMOTE_CERT_CONTEXT, &cert);
    if (status == SEC_E_NO_CREDENTIALS || (status == SEC_E_OK && !cert)) return 0;
    if (status != SEC_E_OK) { failure(session, "failed to query TLS certificate", status); return -2; }
    int length = cert->cbCertEncoded;
    session->blob = malloc(length); if (!session->blob) abort();
    memcpy(session->blob, cert->pbCertEncoded, length); CertFreeCertificateContext(cert);
    return length;
  }
  SecPkgContext_Bindings result = {0};
  SECURITY_STATUS status = QueryContextAttributesW(&session->context,
      kind == 1 ? SECPKG_ATTR_UNIQUE_BINDINGS : SECPKG_ATTR_ENDPOINT_BINDINGS, &result);
  if (status != SEC_E_OK) { failure(session, "failed to query TLS channel binding", status); return -2; }
  SEC_CHANNEL_BINDINGS *bindings = result.Bindings;
  int length = bindings->cbApplicationDataLength;
  unsigned char *data = (unsigned char *)bindings + bindings->dwApplicationDataOffset;
  const char *prefix = kind == 1 ? "tls-unique:" : "tls-server-end-point:";
  int prefix_length = (int)strlen(prefix);
  if (length >= prefix_length && !memcmp(data, prefix, prefix_length)) { data += prefix_length; length -= prefix_length; }
  session->blob = malloc(length ? length : 1); if (!session->blob) abort();
  if (length) memcpy(session->blob, data, length);
  FreeContextBuffer(bindings);
  return length ? length : -1;
}
MOONBIT_FFI_EXPORT void moonrun_tls_blob_copy(tls_session *session, unsigned char *output, int length) {
  if (length) memcpy(output, session->blob, length);
}
#endif
