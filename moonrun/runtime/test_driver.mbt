///|
fn parse_test_selection(
  selection : String,
) -> Array[(String, Array[(UInt32, UInt32)])] raise {
  let json = @json.parse(selection)
  guard json is { "package": String(_), "file_and_index": Array(files), .. } else {
    raise @vm.LinkErrorDetail(
      "invalid MoonBit test arguments: expected package and file_and_index",
    )
  }
  let selected = []
  for file in files {
    guard file is [String(name), Array(ranges)] else {
      raise @vm.LinkErrorDetail("invalid MoonBit test file selection")
    }
    let indices = []
    for range in ranges {
      guard range is { "start": Number(start, ..), "end": Number(end, ..), .. } &&
        start >= 0 &&
        end >= 0 &&
        start <= 4294967295 &&
        end <= 4294967295 &&
        start == start.to_uint().to_double() &&
        end == end.to_uint().to_double() else {
        raise @vm.LinkErrorDetail("invalid MoonBit test index range")
      }
      indices.push((start.to_uint(), end.to_uint()))
    }
    selected.push((name, indices))
  }
  selected
}

///|
async fn Host::run_tests(
  self : Host,
  store : @vm.Store,
  instance : @vm.ModuleInstance,
  selected : Array[(String, Array[(UInt32, UInt32)])],
) -> Unit {
  let mut execute = None
  let mut finish = None
  for entry in instance.exports {
    if entry.desc is Func(index) {
      if entry.name == "moonbit_test_driver_internal_execute" {
        execute = Some(index)
      }
      if entry.name == "moonbit_test_driver_finish" {
        finish = Some(index)
      }
    }
  }
  guard execute is Some(execute) && finish is Some(finish) else {
    raise @vm.LinkErrorDetail("missing MoonBit test driver exports")
  }
  for (name, ranges) in selected {
    for (start, end) in ranges {
      for index = start; index < end; index = index + 1U {
        ignore(
          self.call(store, instance, execute, [
            self.put(Text(name)),
            I32(index.reinterpret_as_int()),
          ]),
        ) catch {
          @vm.HostExit(code) => raise @vm.HostExit(code)
          error => {
            let result : Json = {
              "type": "result",
              "file": name,
              "index": index,
              "message": "\{error}",
            }
            self.output(
              1,
              @utf8.encode(
                "----- BEGIN MOON TEST RESULT -----\n\{result.stringify()}\n----- END MOON TEST RESULT -----\n",
              ),
            )
          }
        }
      }
    }
  }
  self.call(store, instance, finish, []) |> ignore
}
