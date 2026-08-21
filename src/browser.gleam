import gleam/time/timestamp.{type Timestamp}
import lustre/effect.{type Effect}
import plinth/javascript/global

@external(javascript, "./browser_ffi.mjs", "onKey")
fn do_on_key(handler: fn(String) -> Nil) -> Nil

@external(javascript, "./browser_ffi.mjs", "onTeardown")
fn do_on_teardown(handler: fn() -> Nil) -> Nil

pub fn on_key(to_msg: fn(String) -> msg) -> Effect(msg) {
  effect.from(fn(dispatch) { do_on_key(fn(k) { dispatch(to_msg(k)) }) })
}

pub fn on_teardown(msg: msg) -> Effect(msg) {
  effect.from(fn(dispatch) { do_on_teardown(fn() { dispatch(msg) }) })
}

pub fn start_clock(to_msg: fn(Timestamp) -> msg) -> Effect(msg) {
  effect.from(fn(dispatch) {
    let _ =
      global.set_interval(1000, fn() {
        dispatch(to_msg(timestamp.system_time()))
      })
    Nil
  })
}
