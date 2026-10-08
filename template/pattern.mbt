///|
priv enum Glob {
  Literal(Bytes)
  Any
  Star
  Tree
  TreePrefix
  Class(Bool, Array[(Byte, Byte)])
  Alternatives(Array[Array[Glob]])
}

///|
priv struct Rule {
  tokens : Array[Glob]
  basename : Bool
  directory : Bool
  negated : Bool
}

///|
fn parse_rule(pattern : String) -> Rule? raise TemplateError {
  if pattern.has_prefix("#") {
    return None
  }
  let text = if pattern.has_suffix("\\ ") {
    pattern
  } else {
    pattern.trim_end().to_owned()
  }
  if text.is_empty() {
    return None
  }
  let chars = text.to_array()
  let negated = chars[0] == '!'
  let start = if negated { 1 } else { 0 }
  let anchored = chars.get(start) is Some('/')
  let start = if anchored { start + 1 } else { start }
  let directory = chars.length() > start && chars.last() is Some('/')
  let mut end = if directory { chars.length() - 1 } else { chars.length() }
  if directory && end > start && chars[end - 1] == '\\' {
    end -= 1
  }
  let body = chars[start:end].to_owned()
  let (tokens, _) = parse_glob(body, 0, false) catch {
    TemplateError(message) =>
      raise TemplateError(
        "Invalid moon.new.json pattern \{pattern}: \{message}",
      )
  }
  Some({
    tokens,
    basename: !anchored && !body.contains('/'),
    directory,
    negated,
  })
}

///|
fn parse_glob(
  chars : Array[Char],
  start : Int,
  group : Bool,
) -> (Array[Glob], Int) raise TemplateError {
  let tokens = []
  let mut i = start
  while i < chars.length() {
    match chars[i] {
      '}' | ',' if group => break
      '}' => raise TemplateError("Unopened alternation")
      '{' => {
        let branches = []
        i += 1
        while true {
          let (branch, end) = parse_glob(chars, i, true)
          if !branch.is_empty() {
            branches.push(branch)
          }
          guard end < chars.length() else {
            raise TemplateError("Unclosed alternation")
          }
          i = end + 1
          if chars[end] == '}' {
            break
          }
        }
        tokens.push(Alternatives(branches))
      }
      '\\' => {
        guard i + 1 < chars.length() else {
          raise TemplateError("Dangling escape")
        }
        tokens.push(Literal(@utf8.encode(chars[i + 1].to_string())))
        i += 2
      }
      '?' => {
        tokens.push(Any)
        i += 1
      }
      '*' =>
        if chars.get(i + 1) is Some('*') &&
          (i == start || chars[i - 1] == '/') &&
          (
            i + 2 == chars.length() ||
            chars.get(i + 2) is Some('/') ||
            (group && i > start && chars.get(i + 2) is Some('}' | ','))
          ) {
          if chars.get(i + 2) is Some('/') {
            tokens.push(TreePrefix)
            i += 3
          } else {
            tokens.push(Tree)
            i += 2
          }
        } else {
          tokens.push(Star)
          i += 1
        }
      '[' => {
        let (token, end) = parse_class(chars, i)
        tokens.push(token)
        i = end
      }
      c => {
        tokens.push(Literal(@utf8.encode(c.to_string())))
        i += 1
      }
    }
  }
  (tokens, i)
}

///|
fn parse_class(
  chars : Array[Char],
  start : Int,
) -> (Glob, Int) raise TemplateError {
  let negated = chars.get(start + 1) is Some('!' | '^')
  let first = start + (if negated { 2 } else { 1 })
  let mut end = first
  if chars.get(end) is Some(']') {
    end += 1
  }
  while end < chars.length() && chars[end] != ']' {
    end += 1
  }
  // Gitignore treats an unclosed class as a literal '['.
  if end == chars.length() {
    return (Literal(b"["), start + 1)
  }
  let ranges : Array[(Char, Char)] = []
  let mut i = first
  let mut pending_range = false
  while i < end {
    let c = chars[i]
    if c == '-' && !ranges.is_empty() && !pending_range {
      pending_range = true
    } else if pending_range {
      let low = ranges[ranges.length() - 1].0
      guard low <= c else { raise TemplateError("Reversed character range") }
      ranges[ranges.length() - 1] = (low, c)
      pending_range = false
    } else {
      ranges.push((c, c))
    }
    i += 1
  }
  if pending_range {
    ranges.push(('-', '-'))
  }
  // globset, used by cargo-generate, matches UTF-8 bytes even for character
  // classes. A literal non-ASCII character outside a class matches all its bytes.
  let bytes = []
  for (low, high) in ranges {
    let first = @utf8.encode(low.to_string())
    let last = @utf8.encode(high.to_string())
    if low == high {
      for byte in first {
        bytes.push((byte, byte))
      }
    } else {
      for i in 0..<(first.length() - 1) {
        bytes.push((first[i], first[i]))
      }
      guard first[first.length() - 1] <= last[0] else {
        raise TemplateError("Reversed byte range")
      }
      bytes.push((first[first.length() - 1], last[0]))
      for i in 1..<last.length() {
        bytes.push((last[i], last[i]))
      }
    }
  }
  (Class(negated, bytes), end + 1)
}

///|
// Track all reachable positions instead of backtracking through wildcard
// combinations. Nested alternatives never expand into a product of patterns.
fn consume(tokens : Array[Glob], text : Bytes, initial : Set[Int]) -> Set[Int] {
  let mut positions = initial
  for token in tokens {
    let next : Set[Int] = Set([])
    for pos in positions {
      match token {
        Literal(bytes) =>
          if pos + bytes.length() <= text.length() &&
            text[pos:pos + bytes.length()] == bytes[:] {
            next.add(pos + bytes.length())
          }
        Any => if pos < text.length() && text[pos] != b'/' { next.add(pos + 1) }
        Class(negated, ranges) =>
          if pos < text.length() &&
            ranges.any(range => text[pos] >= range.0 && text[pos] <= range.1) !=
            negated {
            next.add(pos + 1)
          }
        Star | Tree | TreePrefix => {
          next.add(pos)
          for end in pos..<text.length() {
            if token is Star && text[end] == b'/' {
              break
            }
            if !(token is TreePrefix) || text[end] == b'/' {
              next.add(end + 1)
            }
          }
        }
        Alternatives(branches) => {
          if branches.is_empty() {
            next.add(pos)
          }
          for branch in branches {
            for end in consume(branch, text, Set([pos])) {
              next.add(end)
            }
          }
        }
      }
    }
    positions = next
    if positions.is_empty() {
      break
    }
  }
  positions
}

///|
fn matches_content(rules : Array[Rule], path : String) -> Bool {
  let components = path.split("/").map(part => part.to_owned()).to_array()
  for length in components.length()>=..0 {
    let is_dir = length < components.length()
    for rule in rules.rev_iter() {
      if rule.directory && !is_dir {
        continue
      }
      let candidate = if length == 0 {
        ""
      } else if rule.basename {
        components[length - 1]
      } else {
        components[:length].to_owned().join("/")
      }
      let text = @utf8.encode(candidate)
      if consume(rule.tokens, text, Set([0])).contains(text.length()) {
        return !rule.negated
      }
    }
  }
  false
}
