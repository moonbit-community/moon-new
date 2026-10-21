///|
priv struct ProcessRule {
  program : String
  args : Array[String]
  windows_prefix : String
}

///|
fn quote_windows_arg(text : String) -> String {
  if text.is_empty() {
    return "\"\""
  }
  if !text.iter().any(c => c is (' ' | '\t' | '"' | '\u0000')) {
    return text
  }
  let output = StringBuilder()
  output.write_char('"')
  let mut slashes = 0
  for c in text {
    if c == '\\' {
      slashes += 1
      continue
    }
    output.write_string(
      String::make(
        slashes * (if c == '"' { 2 } else { 1 }) +
        (if c == '"' { 1 } else { 0 }),
        '\\',
      ),
    )
    slashes = 0
    output.write_char(c)
  }
  output.write_string(String::make(slashes * 2, '\\'))
  output.write_char('"')
  output.to_string()
}

///|
pub fn Policy::allows_process(
  self : Policy,
  command : String,
  args : Array[String],
) -> Bool {
  self.spawn ||
  self.programs.any(rule => {
    if @sys.platform is Windows {
      command == rule.windows_prefix ||
      command.has_prefix(rule.windows_prefix + " ")
    } else {
      command == rule.program &&
      args.get(0) == Some(command) &&
      args.length() > rule.args.length() &&
      rule.args
      .iter()
      .mapi((index, expected) => args[index + 1] == expected)
      .all(value => value)
    }
  })
}
