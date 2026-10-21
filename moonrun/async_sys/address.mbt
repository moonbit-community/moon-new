/// Copyright 2025 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
struct Addr(Bytes) derive(Eq, Compare, Hash)

///|
#cfg(target="native")
extern "C" fn get_ipv4_addr_size() -> Int32 = "moonrun_native_ipv4_addr_size"

///|
let ipv4_addr_size : Int32 = get_ipv4_addr_size()

///|
#cfg(target="native")
extern "C" fn get_ipv6_addr_size() -> Int32 = "moonrun_native_ipv6_addr_size"

///|
let ipv6_addr_size : Int32 = get_ipv6_addr_size()

///|
#cfg(target="native")
#borrow(addr)
extern "C" fn init_ip_addr(addr : Bytes, ip : UInt32, port : Int32) -> Unit = "moonrun_native_init_ip_addr"

///|
pub fn Addr::new(ip : UInt32, port : Int32) -> Addr {
  let addr = Bytes::make(ipv4_addr_size, 0)
  init_ip_addr(addr, ip, port)
  Addr(addr)
}

///|
#cfg(target="native")
#borrow(addr, ip)
extern "C" fn init_ipv6_addr(
  addr : Bytes,
  ip : FixedArray[Byte],
  port : Int32,
  scope_id~ : UInt32,
) -> Unit = "moonrun_native_init_ipv6_addr"

///|
fn Addr::new_ipv6(
  ip : FixedArray[Byte],
  port : Int32,
  scope_id~ : UInt32,
) -> Addr {
  let addr = Bytes::make(ipv6_addr_size, 0)
  init_ipv6_addr(addr, ip, port, scope_id~)
  Addr(addr)
}

///|
#cfg(target="native")
#borrow(addr)
pub extern "C" fn Addr::ip(addr : Addr) -> UInt32 = "moonrun_native_ip_addr_get_ip"

///|
#cfg(target="native")
#borrow(addr)
pub extern "C" fn Addr::port(addr : Addr) -> Int32 = "moonrun_native_ip_addr_get_port"

///|
#cfg(target="native")
#borrow(addr)
pub extern "C" fn Addr::is_ipv6(addr : Addr) -> Bool = "moonrun_native_addr_is_ipv6"

///|
#cfg(target="native")
#borrow(addr)
pub extern "C" fn Addr::is_multicast(addr : Addr) -> Bool = "moonrun_native_addr_is_multicast"

///|
#cfg(target="native")
extern "C" fn Addr::get_ipv6_bytes_offset() -> Int32 = "moonrun_native_addr_get_ipv6_bytes_offset"

///|
/// The offset of IPv6 bytes in `struct sockaddr_in6`
let addr_ipv6_bytes_offset : Int32 = Addr::get_ipv6_bytes_offset()

///|
#cfg(target="native")
#borrow(addr)
extern "C" fn Addr::scope_id(addr : Addr) -> UInt32 = "moonrun_native_addr_get_ipv6_scope_id"

///|
pub impl Show for Addr with fn output(self, logger) {
  if self.is_ipv6() {
    // IPv6 address format
    logger <+ "["
    write_ipv6_str(self.0[addr_ipv6_bytes_offset:], logger)
    let scope_id = self.scope_id()
    if scope_id > 0 {
      let interface = if_indextoname(scope_id, context="") catch {
        _ => scope_id.to_string()
      }
      logger <+ "%\{interface}"
    }
    logger <+ "]:\{self.port()}"
  } else {
    // IPv4 address format
    let ip = self.ip()
    let port = self.port()
    logger <+
      "\{ip >> 24}.\{(ip >> 16) & 255}.\{(ip >> 8) & 255}.\{ip & 255}:\{port}"
  }
}

///|
pub extend Addr with Show::{to_string}

///|
pub impl Debug for Addr with fn to_repr(self) {
  Repr::opaque_("Addr", Repr::literal(Show::to_string(self)))
}

///|
pub suberror InvalidAddr derive(Debug, ToJson)

///|
/// Parse a string into IPv4 or IPv6 address, format should be `ip:port` for IPv4 or `[ip]:port` for IPv6
// TODO: faster implementation
pub fn Addr::parse(src : String) -> Addr raise {
  if src.has_prefix("[") {
    let (ip_bytes, port, interface) = try_parse_ipv6(src)
    let scope_id = if interface is Some(interface) {
      parse_ipv6_zone_suffix(interface, context="@socket.Addr::parse()")
    } else {
      0
    }
    Addr::new_ipv6(ip_bytes, port, scope_id~)
  } else {
    // IPv4 format: ip:port
    let (ip, port) = try_parse_ipv4(src) catch { _ => raise InvalidAddr }
    guard 0 <= port && port < 65536 else { raise InvalidAddr }
    Addr::new(ip, port)
  }
}

///|

///|
#deprecated
pub extend Addr with Eq::{equal, not_equal}

///|
#deprecated
pub extend Addr with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
#deprecated
pub extend Addr with Hash::{hash, hash_combine}

///|
#deprecated
pub extend Addr with Show::{output}

///|
#deprecated
pub extend Addr with Debug::{to_repr}

///|
#deprecated
pub extend InvalidAddr with Debug::{to_repr}

///|
#deprecated
pub extend InvalidAddr with ToJson::{to_json}
