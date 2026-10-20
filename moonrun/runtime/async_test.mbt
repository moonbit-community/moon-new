///|
async test "async host buffers survive guest memory growth" {
  let program = compile(
    (
      #|(module
      #| (import "moonbitlang/async" "c_buffer/new" (func $new (param i32) (result i64)))
      #| (import "moonbitlang/async" "c_buffer/blit_to_c" (func $copyin (param i64 i32 i32 i32 i32)))
      #| (import "moonbitlang/async" "c_buffer/blit_from_c" (func $copyout (param i64 i32 i32 i32 i32)))
      #| (import "moonbitlang/async" "c_buffer/free" (func $free (param i64)))
      #| (memory (export "memory") 1)
      #| (data (i32.const 16) "\00\ff\42")
      #| (func (export "_start") (local $buffer i64)
      #|   i32.const 3 call $new local.set $buffer
      #|   local.get $buffer i32.const 0 i32.const 16 i32.const 0 i32.const 3 call $copyin
      #|   i32.const 1 memory.grow drop
      #|   local.get $buffer i32.const 0 i32.const 65536 i32.const 0 i32.const 3 call $copyout
      #|   i32.const 65536 i32.load8_u if unreachable end
      #|   i32.const 65537 i32.load8_u i32.const 255 i32.ne if unreachable end
      #|   i32.const 65538 i32.load8_u i32.const 66 i32.ne if unreachable end
      #|   local.get $buffer call $free))
    ),
  )
  assert_eq(program.run(), Completed)
}

///|
async test "freed async buffers remain invalid after another allocation" {
  let program = compile(
    (
      #|(module
      #| (import "moonbitlang/async" "c_buffer/new" (func $new (param i32) (result i64)))
      #| (import "moonbitlang/async" "c_buffer/free" (func $free (param i64)))
      #| (import "moonbitlang/async" "c_buffer/blit_from_c" (func $copy (param i64 i32 i32 i32 i32)))
      #| (memory (export "memory") 1)
      #| (func (export "_start") (local $old i64)
      #|   i32.const 0 call $new local.set $old
      #|   local.get $old call $free
      #|   i32.const 0 call $new drop
      #|   local.get $old i32.const 0 i32.const 0 i32.const 0 i32.const 0 call $copy))
    ),
  )
  assert_true(program.run() is Trapped(_))
}

///|
async test "async buffer byte access and null-terminated length" {
  let program = compile(
    (
      #|(module
      #| (import "moonbitlang/sqlite" "sqlite3_null_handle" (func $runtime_null (result i64)))
      #| (import "moonbitlang/async" "c_buffer/new" (func $new (param i32) (result i64)))
      #| (import "moonbitlang/async" "c_buffer/free" (func $free (param i64)))
      #| (import "moonbitlang/async" "c_buffer/blit_to_c" (func $copy (param i64 i32 i32 i32 i32)))
      #| (import "moonbitlang/async" "c_buffer/c_buffer_get" (func $get (param i64 i32) (result i32)))
      #| (import "moonbitlang/async" "c_buffer/strlen" (func $strlen (param i64) (result i32)))
      #| (import "moonbitlang/async" "c_buffer/length" (func $length (param i64) (result i32)))
      #| (import "moonbitlang/async" "c_buffer/is_null" (func $null (param i64) (result i32)))
      #| (memory (export "memory") 1)
      #| (data (i32.const 16) "A\00B")
      #| (func (export "_start") (local $buffer i64)
      #|   i32.const 3 call $new local.set $buffer
      #|   local.get $buffer i32.const 0 i32.const 16 i32.const 0 i32.const 3 call $copy
      #|   local.get $buffer call $length i32.const 3 i32.ne if unreachable end
      #|   local.get $buffer call $strlen i32.const 1 i32.ne if unreachable end
      #|   local.get $buffer i32.const 2 call $get i32.const 66 i32.ne if unreachable end
      #|   local.get $buffer call $null if unreachable end
      #|   call $runtime_null call $null i32.eqz if unreachable end
      #|   call $runtime_null call $free
      #|   local.get $buffer call $free))
    ),
  )
  assert_eq(program.run(), Completed)
}

///|
async test "socket addresses preserve IPv4, IPv6 and scope fields" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "socket/ipv4_addr_size" (func $size4 (result i32)))
    #| (import "moonbitlang/async" "socket/ipv6_addr_size" (func $size6 (result i32)))
    #| (import "moonbitlang/async" "socket/init_ip_addr" (func $v4 (param i32 i32 i32)))
    #| (import "moonbitlang/async" "socket/init_ipv6_addr" (func $v6 (param i32 i32 i32 i32)))
    #| (import "moonbitlang/async" "socket/ip_addr_get_ip" (func $ip (param i32 i32) (result i32)))
    #| (import "moonbitlang/async" "socket/ip_addr_get_port" (func $port (param i32 i32) (result i32)))
    #| (import "moonbitlang/async" "socket/addr_get_ipv6_scope_id" (func $scope (param i32 i32) (result i32)))
    #| (import "moonbitlang/async" "socket/addr_is_ipv6_wildcard" (func $wildcard (param i32 i32) (result i32)))
    #| (import "moonbitlang/async" "socket/addr_is_multicast" (func $multicast (param i32 i32) (result i32)))
    #| (memory (export "memory") 1)
    #| (data (i32.const 128) "\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\01")
    #| (func (export "_start")
    #|   i32.const 0 i32.const 2130706433 i32.const 54321 call $v4
    #|   i32.const 0 call $size4 call $ip i32.const 2130706433 i32.ne if unreachable end
    #|   i32.const 0 call $size4 call $port i32.const 54321 i32.ne if unreachable end
    #|   i32.const 0 call $size4 call $multicast if unreachable end
    #|   i32.const 32 i32.const 128 i32.const 1234 i32.const 7 call $v6
    #|   i32.const 32 call $size6 call $port i32.const 1234 i32.ne if unreachable end
    #|   i32.const 32 call $size6 call $scope i32.const 7 i32.ne if unreachable end
    #|   i32.const 32 call $size6 call $wildcard if unreachable end
    #|   i32.const 143 i32.const 0 i32.store8
    #|   i32.const 64 i32.const 128 i32.const 0 i32.const 0 call $v6
    #|   i32.const 64 call $size6 call $wildcard i32.const 1 i32.ne if unreachable end))
  assert_eq(compile(source).run(), Completed)
}

///|
async test "interface lookup copies borrowed native names" {
  if @async.platform is Windows {
    return
  }
  let source =
    #|(module
    #| (import "moonbitlang/async" "socket/if_nametoindex" (func $index (param i32 i32) (result i32)))
    #| (import "moonbitlang/async" "socket/if_indextoname" (func $name (param i32) (result i64)))
    #| (import "moonbitlang/async" "c_buffer/c_buffer_get" (func $get (param i64 i32) (result i32)))
    #| (import "moonbitlang/async" "c_buffer/strlen" (func $length (param i64) (result i32)))
    #| (import "moonbitlang/async" "c_buffer/free" (func $free (param i64)))
    #| (memory (export "memory") 1)
    #| (data (i32.const 0) "NAME")
    #| (func (export "_start") (local $name i64) (local $index i32)
    #|   i32.const 0 i32.const LENGTH call $index local.tee $index i32.eqz if unreachable end
    #|   local.get $index call $name local.set $name
    #|   local.get $index call $name call $free
    #|   local.get $name call $length i32.const LENGTH i32.ne if unreachable end
    #|   local.get $name i32.const 0 call $get i32.const 108 i32.ne if unreachable end
    #|   local.get $name call $free))
  let source = source
    .replace_all(
      old="LENGTH",
      new=if @async.platform is MacOS { "3" } else { "2" },
    )
    .replace(
      old="NAME",
      new=if @async.platform is MacOS {
        "l\\00o\\000\\00"
      } else {
        "l\\00o\\00"
      },
    )
  assert_eq(compile(source).run(), Completed)
}

///|
async test "socket syscalls return EFAULT for invalid guest buffers" {
  if @async.platform is Windows {
    return
  }
  let source =
    #|(module
    #| (import "moonbitlang/async" "socket/make_udp_socket" (func $udp (param i32 i32) (result i64)))
    #| (import "moonbitlang/async" "socket/make_tcp_socket" (func $tcp (param i32) (result i64)))
    #| (import "moonbitlang/async" "socket/recvfrom/unix" (func $recv (param i64 i32 i32 i32 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "socket/sendto/unix" (func $send (param i64 i32 i32 i32 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "socket/accept/unix" (func $accept (param i64 i32 i32) (result i64)))
    #| (import "moonbitlang/async" "fd_util/invalid_fd" (func $invalid (result i64)))
    #| (import "moonbitlang/async" "os_error/get_errno" (func $errno (result i32)))
    #| (memory (export "memory") 1)
    #| (func (export "_start") (local $fd i64)
    #|   i32.const 4 i32.const 0 call $udp local.set $fd
    #|   local.get $fd i32.const 65536 i32.const 0 i32.const 1 i32.const 0 i32.const 16 call $recv i32.const -1 i32.ne if unreachable end
    #|   call $errno i32.const 14 i32.ne if unreachable end
    #|   local.get $fd i32.const 0 i32.const 0 i32.const 1 i32.const 65536 i32.const 16 call $send i32.const -1 i32.ne if unreachable end
    #|   call $errno i32.const 14 i32.ne if unreachable end
    #|   i32.const 4 call $tcp i32.const 65536 i32.const 16 call $accept call $invalid i64.ne if unreachable end
    #|   call $errno i32.const 14 i32.ne if unreachable end))
  assert_eq(compile(source).run(), Completed)
}

///|
async test "Windows accept rejects closed and already reserved target handles" {
  if !(@async.platform is Windows) {
    return
  }
  let source =
    #|(module
    #| (import "moonbitlang/async" "socket/make_tcp_socket" (func $tcp (param i32) (result i64)))
    #| (import "moonbitlang/async" "socket/init_ip_addr" (func $addr (param i32 i32 i32)))
    #| (import "moonbitlang/async" "socket/ipv4_addr_size" (func $size (result i32)))
    #| (import "moonbitlang/async" "socket/bind" (func $bind (param i64 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "socket/listen" (func $listen (param i64) (result i32)))
    #| (import "moonbitlang/async" "event_bus/create" (func $bus (result i64)))
    #| (import "moonbitlang/async" "event_bus/try_register" (func $register (param i64 i64 i32) (result i32)))
    #| (import "moonbitlang/async" "io/make_accept_io_result/windows" (func $result (param i32) (result i64)))
    #| (import "moonbitlang/async" "socket/accept/windows" (func $accept (param i64 i64 i64) (result i32)))
    #| (import "moonbitlang/async" "fd_util/close_fd" (func $close (param i64) (result i32)))
    #| (import "moonbitlang/async" "os_error/get_errno" (func $errno (result i32)))
    #| (memory (export "memory") 1)
    #| (func (export "_start") (local $server i64) (local $target i64) (local $first i64) (local $second i64)
    #|   i32.const 4 call $tcp local.set $server
    #|   i32.const 4 call $tcp local.set $target
    #|   i32.const 0 i32.const 2130706433 i32.const 0 call $addr
    #|   local.get $server i32.const 0 call $size call $bind if unreachable end
    #|   local.get $server call $listen if unreachable end
    #|   call $bus local.get $server i32.const 1 call $register i32.const 1 i32.ne if unreachable end
    #|   call $size call $result local.set $first
    #|   call $size call $result local.set $second
    #|   local.get $server local.get $target local.get $first call $accept if unreachable end
    #|   call $errno i32.const 997 i32.ne if unreachable end
    #|   local.get $server local.get $target local.get $second call $accept if unreachable end
    #|   call $errno i32.const 87 i32.ne if unreachable end
    #|   local.get $target call $close if unreachable end
    #|   local.get $server local.get $target local.get $second call $accept if unreachable end
    #|   call $errno i32.const 6 i32.ne if unreachable end))
  assert_eq(compile(source).run(), Completed)
}
