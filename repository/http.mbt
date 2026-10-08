///|
fn remote_url(source : String) -> String? raise @object.GitError {
  if source.has_prefix("https://") {
    let authority = source[8:].split("/").next().unwrap_or("")
    guard !authority.is_empty() &&
      !authority.contains("@") &&
      !authority.contains("%") &&
      !source.contains("?") &&
      !source.contains("#") &&
      !source.contains("\\") else {
      raise @object.GitError::ProtocolError(
        "Template source must be an anonymous HTTPS repository URL",
      )
    }
    return Some(source)
  }
  // Existing paths take precedence over the owner/repo shorthand.
  if @sync_fs.path_exists(source) ||
    source.has_prefix("/") ||
    source.has_prefix(".") ||
    (source.length() >= 2 && source[1] == ':') {
    return None
  }
  let parts = source.split("/").to_array()
  if parts.length() == 2 &&
    parts.all(part => {
      !part.is_empty() &&
      part != "." &&
      part != ".." &&
      part
      .iter()
      .all(c => c is ('A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_' | '.'))
    }) {
    return Some("https://github.com/" + source)
  }
  raise @object.GitError::ProtocolError(
    "Unsupported template source; use a local repository, anonymous HTTPS URL, or owner/repo",
  )
}

///|
fn valid_ref(name : String) -> Bool {
  !name.contains("..") &&
  !name.contains("@{") &&
  !name
  .iter()
  .any(c => {
    c <= ' ' || c == '\u007f' || c is ('~' | '^' | ':' | '?' | '*' | '[' | '\\')
  }) &&
  name
  .split("/")
  .all(part => {
    !part.is_empty() &&
    !part.has_prefix(".") &&
    !part.has_suffix(".") &&
    !part.has_suffix(".lock")
  })
}

///|
async fn http_get(
  url : String,
  headers : Map[String, String],
) -> (@types.HttpResponse, Bytes) raise @object.GitError {
  http_request(url, Get, b"", headers)
}

///|
async fn http_post(
  url : String,
  body : Bytes,
  headers : Map[String, String],
) -> (@types.HttpResponse, Bytes) raise @object.GitError {
  http_request(url, Post, body, headers)
}

///|
async fn http_request(
  url : String,
  verb : @http.RequestMethod,
  body : Bytes,
  headers : Map[String, String],
) -> (@types.HttpResponse, Bytes) raise @object.GitError {
  try {
    let request_headers : @http.Headers = Map([])
    for key, value in headers {
      request_headers[@http.CaseInsensitiveString(key)] = value
    }
    let (response, data) = @http.request(url, verb, request_headers, body)
    (@types.HttpResponse::new(response.code), data.binary())
  } catch {
    error =>
      raise @object.GitError::ProtocolError(
        "Anonymous HTTPS request failed: \{error}",
      )
  }
}
