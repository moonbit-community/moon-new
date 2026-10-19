///|
async fn Context::run_tests(
  self : Context,
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
            self.runtime.stdio.output(
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
