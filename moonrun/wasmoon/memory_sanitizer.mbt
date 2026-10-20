///|
fn Context::memory_sanitizer(
  self : Context,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let ptr = i32(args[if name == "register-object-alloc" { 1 } else { 0 }]).reinterpret_as_uint()
  match name {
    "register-object-alloc" => {
      if self.sanitizer_objects.get(ptr) is Some(size) {
        raise @vm.LinkErrorDetail(
          "object \{ptr} is already live with size \{size}",
        )
      }
      // FIXME: Record allocation frames when Wasmoon exposes guest stacks:
      // https://github.com/Milky2018/wasmoon/issues/547
      self.sanitizer_objects[ptr] = i32(args[0]).reinterpret_as_uint()
      []
    }
    "register-object-free" => {
      guard self.sanitizer_objects.contains(ptr) else {
        raise @vm.LinkErrorDetail("invalid object \{ptr}")
      }
      self.sanitizer_objects.remove(ptr)
      []
    }
    "object-is-valid" =>
      [I32(if self.sanitizer_objects.contains(ptr) { 1 } else { 0 })]
    _ => raise @vm.UnknownImport("moonbit:ffi/memory-sanitizer", name)
  }
}

///|
fn Context::sanitizer_leak_report(self : Context) -> String {
  let total = self.sanitizer_objects
    .values()
    .fold(init=0UL, (sum, size) => sum + size.to_uint64())
  let count = self.sanitizer_objects.length()
  let report = StringBuilder()
  report.write_string(
    "moonrun memory sanitizer detected \{count} leaked object\{if count == 1 { "" } else { "s" }} (\{total} bytes)",
  )
  let pointers = self.sanitizer_objects.keys().to_array()
  pointers.sort()
  for ptr in pointers {
    report.write_string(
      "\nleaked object \{ptr} (\{self.sanitizer_objects[ptr]} bytes)",
    )
  }
  report.to_string()
}
