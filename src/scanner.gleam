import lustre/effect.{type Effect}

pub type Error {
  ScannerUnavailable
  InsecureContext
  PermissionDenied
  NoCameraFound
  CameraInUse
  CameraFailed(name: String)
}

@external(javascript, "./scanner_ffi.mjs", "start")
fn do_start(
  generation: Int,
  on_decode: fn(Int, String) -> Nil,
  on_error: fn(Error) -> Nil,
) -> Nil

@external(javascript, "./scanner_ffi.mjs", "stop")
fn do_stop() -> Nil

@external(javascript, "./scanner_ffi.mjs", "clearLastSent")
fn do_clear_last_sent() -> Nil

pub fn start(
  generation: Int,
  on_decode: fn(Int, String) -> msg,
  on_error: fn(Error) -> msg,
) -> Effect(msg) {
  effect.before_paint(fn(dispatch, _root) {
    do_start(generation, fn(g, text) { dispatch(on_decode(g, text)) }, fn(err) {
      dispatch(on_error(err))
    })
  })
}

pub fn stop() -> Effect(msg) {
  effect.from(fn(_) { do_stop() })
}

pub fn stop_then(msg: msg) -> Effect(msg) {
  effect.from(fn(dispatch) {
    do_stop()
    dispatch(msg)
  })
}

pub fn clear_last_sent() -> Effect(msg) {
  effect.from(fn(_) { do_clear_last_sent() })
}
