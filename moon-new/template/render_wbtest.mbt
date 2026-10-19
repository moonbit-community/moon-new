///|
test "Liquid compile and render errors retain source and diagnostics" {
  let context = @liquid.LiquidContext::new()
  for
    (text, detail) in [
      ("{% unknown_tag %}", "unknown_tag"),
      ("{{ missing_variable }}", "missing_variable"),
    ] {
    try render_text(text, context, source="example.mbt") catch {
      TemplateError(message) => {
        assert_true(message.contains("example.mbt"), msg=message)
        assert_true(message.contains(detail), msg=message)
      }
    } noraise {
      _ => fail("Expected Liquid diagnostics for \{text}")
    }
  }
}

///|
test "literal error-like text remains ordinary output" {
  assert_eq(
    render_text(
      "[ERROR: example]",
      @liquid.LiquidContext::new(),
      source="README.md",
    ),
    "[ERROR: example]",
  )
}
