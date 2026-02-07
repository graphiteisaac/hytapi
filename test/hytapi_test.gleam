import gleam/javascript/promise
import gleeunit
import hytapi

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn dns_test() {
  use value <- promise.await(hytapi.resolve_dns("one.one.one.one"))

  assert value == Ok("1.0.0.1") || value == Ok("1.1.1.1")

  promise.resolve(Nil)
}
