///|
fn Host::js_string(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
    "cast" => {
      ignore(self.text(args[0]))
      [args[0]]
    }
    "test" =>
      [
        I32(
          if args[0] is ExternRef(index) &&
            self.values.get(index) is Some(Text(_)) {
            1
          } else {
            0
          },
        ),
      ]
    "fromCharCode" =>
      [self.put(Text((i32(args[0]) & 0xFFFF).unsafe_to_char().to_string()))]
    "fromCodePoint" => {
      let code = i32(args[0])
      guard code >= 0 && code <= 0x10FFFF else { raise @vm.Unreachable }
      [self.put(Text(code.unsafe_to_char().to_string()))]
    }
    "length" => [I32(self.text(args[0]).length())]
    "charCodeAt" | "codePointAt" => {
      let text = self.text(args[0])
      let index = i32(args[1])
      guard index >= 0 && index < text.length() else { raise @vm.Unreachable }
      let first = text.code_unit_at(index).to_int()
      if name == "codePointAt" &&
        first >= 0xD800 &&
        first <= 0xDBFF &&
        index + 1 < text.length() {
        let second = text.code_unit_at(index + 1).to_int()
        if second >= 0xDC00 && second <= 0xDFFF {
          return [I32(0x10000 + ((first - 0xD800) << 10) + second - 0xDC00)]
        }
      }
      [I32(first)]
    }
    "concat" => [self.put(Text(self.text(args[0]) + self.text(args[1])))]
    "substring" => {
      let text = self.text(args[0])
      let start = i32(args[1]).reinterpret_as_uint().to_uint64()
      let end = i32(args[2]).reinterpret_as_uint().to_uint64()
      let value = if start > end || start > text.length().to_uint64() {
        ""
      } else {
        text[start.to_int():if end > text.length().to_uint64() {
          text.length()
        } else {
          end.to_int()
        }].to_owned()
      }
      [self.put(Text(value))]
    }
    "equals" =>
      if args[0] is Null || args[1] is Null {
        [I32(if args[0] == args[1] { 1 } else { 0 })]
      } else {
        [I32(if self.text(args[0]) == self.text(args[1]) { 1 } else { 0 })]
      }
    "compare" => {
      let left = self.text(args[0])
      let right = self.text(args[1])
      [I32(if left < right { -1 } else if left > right { 1 } else { 0 })]
    }
    "fromCharCodeArray" => {
      guard args[0] is ArrayRef(array) else { raise @vm.Unreachable }
      let start = i32(args[1])
      let end = i32(args[2])
      guard start >= 0 && end >= start && end <= caller.store.array_len(array) else {
        raise @vm.Unreachable
      }
      let builder = StringBuilder()
      for index in start..<end {
        builder.write_char(
          (i32(caller.store.array_get(array, index)) & 0xFFFF).unsafe_to_char(),
        )
      }
      [self.put(Text(builder.to_string()))]
    }
    "intoCharCodeArray" => {
      let text = self.text(args[0])
      guard args[1] is ArrayRef(array) else { raise @vm.Unreachable }
      let start = i32(args[2])
      let length = caller.store.array_len(array)
      guard start >= 0 && start <= length && text.length() <= length - start else {
        raise @vm.Unreachable
      }
      for index in 0..<text.length() {
        caller.store.array_set(
          array,
          start + index,
          I32(text.code_unit_at(index).to_int()),
        )
      }
      [I32(text.length())]
    }
    _ => raise @vm.UnknownImport("wasm:js-string", name)
  }
}

///|
fn js_string_signature(
  name : String,
  code : @wasm.Module,
  actual : @wasm.FuncType,
) -> Bool {
  let normalized : @wasm.FuncType = {
    params: actual.params.map(ty => if ty is RefExtern { ExternRef } else { ty }),
    results: actual.results.map(ty => {
      if ty is RefExtern {
        ExternRef
      } else {
        ty
      }
    }),
  }
  let expected : @wasm.FuncType = match name {
    "cast" => { params: [ExternRef], results: [ExternRef], }
    "test" | "length" => { params: [ExternRef], results: [I32], }
    "fromCharCode" | "fromCodePoint" => { params: [I32], results: [ExternRef], }
    "charCodeAt" | "codePointAt" =>
      { params: [ExternRef, I32], results: [I32], }
    "concat" => { params: [ExternRef, ExternRef], results: [ExternRef], }
    "substring" => { params: [ExternRef, I32, I32], results: [ExternRef], }
    "equals" | "compare" => { params: [ExternRef, ExternRef], results: [I32], }
    "fromCharCodeArray" => {
      guard actual.params is [ty, I32, I32] && is_i16_array(code, ty) else {
        return false
      }
      { params: [ty, I32, I32], results: [ExternRef], }
    }
    "intoCharCodeArray" => {
      guard actual.params is [_, ty, I32] && is_i16_array(code, ty) else {
        return false
      }
      { params: [ExternRef, ty, I32], results: [I32], }
    }
    _ => return false
  }
  normalized == expected
}

///|
fn is_i16_array(code : @wasm.Module, ty : @wasm.ValueType) -> Bool {
  guard ty is (RefArray(index) | RefNullArray(index)) &&
    code.types.get(index)
    is Some(
      {
        composite: Array(
          { element: { storage_type: Packed(I16), mutable: true, }, }
        ),
        ..
      }
    ) else {
    return false
  }
  true
}
