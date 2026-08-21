import accounts
import browser
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import scanner

pub type Model {
  Scanning(
    batches: Dict(Int, accounts.Batch),
    scan_generation: Int,
    error: Option(String),
    confirming_reset: Bool,
  )
  Live(entries: List(accounts.Account), now: Timestamp)
  Slideshow(Reel)
}

pub type Reel {
  Reel(
    before: List(accounts.Account),
    current: accounts.Account,
    after: List(accounts.Account),
    qr_svg: Result(String, accounts.QrError),
  )
}

pub type Navigation {
  Previous
  Next
  Exit
}

pub type Msg {
  BrowserHidPage
  ClockTicked(now: Timestamp)
  ScannerDecodedQr(generation: Int, text: String)
  ScannerFailed(error: scanner.Error)
  ScannerStopped
  UserCancelledReset
  UserConfirmedReset
  UserNavigatedSlideshow(Navigation)
  UserPressedKey(key: String)
  UserRequestedClear
  UserRequestedReset
  UserRequestedSlideshow
}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  #(
    Scanning(
      batches: dict.new(),
      scan_generation: 0,
      error: option.None,
      confirming_reset: False,
    ),
    effect.batch([
      scanner.start(0, ScannerDecodedQr, ScannerFailed),
      browser.on_key(UserPressedKey),
      browser.on_teardown(BrowserHidPage),
      browser.start_clock(ClockTicked),
    ]),
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg, model {
    // A zxing promise may resolve after its scan was discarded.
    ScannerDecodedQr(generation, _), Scanning(_, current, _, _)
      if generation != current
    -> #(model, effect.none())

    ScannerDecodedQr(_, text), Scanning(batches, generation, ..) ->
      case ingest(batches, generation, text) {
        Ok(next) -> next
        Error(e) -> #(
          Scanning(..model, error: option.Some(import_error(e))),
          scanner.clear_last_sent(),
        )
      }

    ScannerFailed(error), Scanning(..) -> #(
      Scanning(..model, error: option.Some(scan_error(error))),
      scanner.clear_last_sent(),
    )

    UserRequestedReset, Scanning(batches, ..) ->
      case accounts.scanned_batch_count(batches) > 0 {
        True -> #(Scanning(..model, confirming_reset: True), effect.none())
        False -> #(model, scanner.stop_then(ScannerStopped))
      }

    UserConfirmedReset, Scanning(..) -> #(
      model,
      scanner.stop_then(ScannerStopped),
    )

    UserCancelledReset, Scanning(..) -> #(
      Scanning(..model, confirming_reset: False),
      effect.none(),
    )

    // ScannerStopped is sequenced after teardown; every in-flight decode is stale.
    ScannerStopped, _ | UserRequestedClear, _ | BrowserHidPage, _ ->
      restart_scanning(model)

    ClockTicked(now), Live(entries, _) -> #(Live(entries:, now:), effect.none())

    UserRequestedSlideshow, Live([first, ..rest], _) -> #(
      Slideshow(Reel(
        before: [],
        current: first,
        after: rest,
        qr_svg: accounts.generate_qr_svg(first),
      )),
      effect.none(),
    )

    UserNavigatedSlideshow(navigation), Slideshow(reel) ->
      navigate(reel, navigation)

    UserPressedKey(key), Slideshow(reel) ->
      case key {
        "ArrowRight" -> navigate(reel, Next)
        "ArrowLeft" -> navigate(reel, Previous)
        "Escape" -> navigate(reel, Exit)
        _ -> #(model, effect.none())
      }

    _, _ -> #(model, effect.none())
  }
}

fn navigate(reel: Reel, navigation: Navigation) -> #(Model, Effect(Msg)) {
  case reel, navigation {
    Reel(before, current, [next, ..after], _), Next -> #(
      Slideshow(Reel(
        before: [current, ..before],
        current: next,
        after:,
        qr_svg: accounts.generate_qr_svg(next),
      )),
      effect.none(),
    )
    Reel([previous, ..before], current, after, _), Previous -> #(
      Slideshow(Reel(
        before:,
        current: previous,
        after: [current, ..after],
        qr_svg: accounts.generate_qr_svg(previous),
      )),
      effect.none(),
    )
    Reel(before, current, after, _), Exit -> #(
      Live(
        entries: list.append(list.reverse(before), [current, ..after]),
        now: timestamp.system_time(),
      ),
      effect.none(),
    )
    Reel(_, _, [], _), Next | Reel([], _, _, _), Previous -> #(
      Slideshow(reel),
      effect.none(),
    )
  }
}

fn restart_scanning(model: Model) -> #(Model, Effect(Msg)) {
  let generation = case model {
    Scanning(_, current, _, _) -> current + 1
    Live(..) | Slideshow(..) -> 0
  }

  #(
    Scanning(
      batches: dict.new(),
      scan_generation: generation,
      error: option.None,
      confirming_reset: False,
    ),
    scanner.start(generation, ScannerDecodedQr, ScannerFailed),
  )
}

fn ingest(
  held: Dict(Int, accounts.Batch),
  generation: Int,
  text: String,
) -> Result(#(Model, Effect(Msg)), accounts.Error) {
  use batches <- result.try(
    accounts.parse(text)
    |> result.try(accounts.merge_batch(held, _)),
  )
  case accounts.is_complete(batches) {
    True ->
      Ok(#(
        Live(entries: accounts.all(batches), now: timestamp.system_time()),
        scanner.stop(),
      ))
    False ->
      Ok(#(
        Scanning(
          batches:,
          scan_generation: generation,
          error: option.None,
          confirming_reset: False,
        ),
        effect.none(),
      ))
  }
}

fn import_error(error: accounts.Error) -> String {
  case error {
    accounts.SingleAccountQr ->
      "That's a valid QR code, but not a Google Authenticator export."
    accounts.NotAnExport -> "That isn't a Google Authenticator export."
    accounts.Unreadable -> "Couldn't read that code. Try again."
    accounts.UnrecognizedOption ->
      "That export uses an option keyhop doesn't recognize."
    accounts.UnsupportedVersion(version) ->
      "That export is version "
      <> int.to_string(version)
      <> ". keyhop supports versions 1 and 2."
    accounts.MalformedGeometry(..) | accounts.BatchSizeMismatch(..) ->
      "That export looks malformed. Try exporting again."
    accounts.DifferentExport(..) ->
      "That code belongs to a different export. Start over to switch."
    accounts.ConflictingCode(..) ->
      "That code conflicts with one already scanned. Start over."
  }
}

fn skip_reason(reason: accounts.SkipReason) -> String {
  case reason {
    accounts.NoSecret -> "no secret"
    accounts.Unsupported -> "otpauth doesn't support this setting"
    accounts.UnspecifiedType -> "unspecified type"
  }
}

fn scan_error(error: scanner.Error) -> String {
  case error {
    scanner.ScannerUnavailable ->
      "The QR scanner didn't load, so nothing can be decoded. Check your connection and reload the page."
    scanner.InsecureContext ->
      "The camera is only available over HTTPS or on localhost. Open keyhop at an https:// address and reload the page."
    scanner.PermissionDenied ->
      "Camera access denied. Enable it in your browser and system settings, then reload the page."
    scanner.NoCameraFound ->
      "No camera found. keyhop needs a camera to scan the export."
    scanner.CameraInUse ->
      "The camera is in use by another app. Close it and reload the page."
    scanner.CameraFailed(name) ->
      "The camera didn't start: " <> name <> ". Reload the page and try again."
  }
}

pub fn view(model: Model) -> Element(Msg) {
  case model {
    Scanning(batches, _, error, confirming) ->
      scanning_view(batches, error, confirming)
    Live(entries, now) -> live_view(accounts.rows(entries, now:))
    Slideshow(reel) -> slideshow_view(reel)
  }
}

fn name_component(name: accounts.DisplayName) -> Element(msg) {
  case name {
    accounts.Single(text) -> html.text(text)
    accounts.Both(issuer, label) ->
      element.fragment([
        html.text(issuer),
        html.span([attribute.class("px-1 opacity-40")], [html.text("/")]),
        html.text(label),
      ])
  }
}

fn scanning_view(
  batches: Dict(Int, accounts.Batch),
  error: Option(String),
  confirming: Bool,
) -> Element(Msg) {
  html.main([attribute.class("mx-auto max-w-3xl space-y-4 p-6")], [
    html.h1([attribute.class("text-2xl font-semibold")], [
      html.text("Scan your export"),
    ]),
    html.div(
      [
        attribute.id("camera-preview"),
        attribute.class(
          "[&>video]:w-full [&>video]:max-w-[520px] [&>video]:rounded-box [&>video]:bg-black",
        ),
      ],
      [],
    ),
    html.p([], [
      html.text(
        int.to_string(accounts.scanned_batch_count(batches))
        <> " of "
        <> int.to_string(accounts.expected_batch_count(batches))
        <> " codes scanned",
      ),
    ]),
    reset_component(confirming),
    html.p([attribute.class("max-w-[52ch] text-sm opacity-60")], [
      html.text(
        "Google Authenticator shows the export on the phone that holds your accounts, so that phone cannot scan its own screen. Use a second device like a laptop with a webcam to scan it.",
      ),
    ]),
    error_banner_component(error),
    skipped_list_component(accounts.skipped(batches)),
    html.p([attribute.class("max-w-[52ch] text-sm opacity-60")], [
      html.text(
        "keyhop runs entirely in this page and never intentionally writes to storage.",
      ),
    ]),
  ])
}

fn reset_component(confirming: Bool) -> Element(Msg) {
  case confirming {
    False ->
      html.button(
        [
          attribute.class("btn btn-ghost"),
          event.on_click(UserRequestedReset),
        ],
        [html.text("Start over")],
      )
    True ->
      html.span([attribute.class("flex flex-wrap items-center gap-2 text-sm")], [
        html.text("Discard the codes already scanned?"),
        html.button(
          [
            attribute.class("btn btn-sm btn-error"),
            event.on_click(UserConfirmedReset),
          ],
          [html.text("Discard")],
        ),
        html.button(
          [
            attribute.class("btn btn-sm btn-ghost"),
            event.on_click(UserCancelledReset),
          ],
          [html.text("Keep scanning")],
        ),
      ])
  }
}

fn error_banner_component(error: Option(String)) -> Element(msg) {
  case error {
    option.None -> element.none()
    option.Some(e) ->
      html.div([attribute.class("alert alert-error"), attribute.role("alert")], [
        html.span([], [html.text(e)]),
      ])
  }
}

fn skipped_list_component(skipped: List(accounts.Skipped)) -> Element(msg) {
  case skipped {
    [] -> element.none()
    entries ->
      html.div([attribute.class("alert alert-warning block")], [
        html.p([attribute.class("font-medium")], [
          html.text("Skipped accounts:"),
        ]),
        html.ul(
          [attribute.class("list-inside list-disc text-sm")],
          list.map(entries, fn(e) {
            html.li([], [
              name_component(e.name),
              html.text(": " <> skip_reason(e.reason)),
            ])
          }),
        ),
      ])
  }
}

fn live_view(rows: List(#(accounts.Account, accounts.Tick))) -> Element(Msg) {
  html.main([attribute.class("mx-auto max-w-3xl space-y-4 p-6")], [
    html.header([attribute.class("flex flex-wrap items-center gap-2")], [
      html.h1([attribute.class("grow text-2xl font-semibold")], [
        html.text("Your accounts"),
      ]),
      html.button(
        [
          attribute.class("btn btn-primary"),
          event.on_click(UserRequestedSlideshow),
        ],
        [html.text("Start slideshow")],
      ),
      html.button(
        [attribute.class("btn btn-ghost"), event.on_click(UserRequestedClear)],
        [html.text("Clear secrets")],
      ),
    ]),
    html.ul(
      [
        attribute.class(
          "grid grid-cols-[repeat(auto-fill,minmax(240px,1fr))] gap-3",
        ),
      ],
      list.map(rows, fn(row) { account_card_component(row.0, row.1) }),
    ),
  ])
}

fn account_card_component(
  account: accounts.Account,
  tick: accounts.Tick,
) -> Element(msg) {
  html.li([attribute.class("card border border-base-300 bg-base-200")], [
    html.div([attribute.class("card-body gap-2 p-4")], [
      html.p([attribute.class("text-sm opacity-60")], [
        name_component(accounts.display_name(
          account.issuer,
          label: account.label,
        )),
      ]),
      html.p(
        [attribute.class("font-mono text-3xl font-semibold tracking-wider")],
        [html.text(group_digits(tick.code))],
      ),
      countdown_component(tick),
    ]),
  ])
}

fn countdown_component(tick: accounts.Tick) -> Element(msg) {
  case tick {
    accounts.TotpTick(seconds_left:, period:, ..) ->
      html.progress(
        [
          attribute.class("progress progress-primary h-1"),
          attribute.value(int.to_string(seconds_left)),
          attribute.max(int.to_string(period)),
        ],
        [],
      )
    accounts.HotpTick(counter:, ..) ->
      html.p([attribute.class("text-sm opacity-60")], [
        html.text("HOTP counter " <> int.to_string(counter)),
      ])
  }
}

fn group_digits(code: String) -> String {
  let length = string.length(code)
  let mid = length / 2
  string.slice(code, 0, mid) <> " " <> string.slice(code, mid, length - mid)
}

fn slideshow_view(reel: Reel) -> Element(Msg) {
  let Reel(before:, current:, after:, qr_svg:) = reel
  let position = list.length(before) + 1
  let total = position + list.length(after)
  let title =
    name_component(accounts.display_name(current.issuer, label: current.label))

  html.main(
    [
      attribute.class(
        "flex min-h-screen flex-col items-center justify-center gap-4 p-4",
      ),
    ],
    [
      html.header([attribute.class("space-y-1 text-center")], [
        html.p([attribute.class("text-sm opacity-60")], [
          html.text(int.to_string(position) <> " of " <> int.to_string(total)),
        ]),
        html.h2([attribute.class("text-xl font-semibold")], [title]),
      ]),
      qr_component(qr_svg),
      html.div([attribute.class("flex flex-wrap justify-center gap-2")], [
        html.button(
          [
            attribute.class("btn btn-ghost"),
            event.on_click(UserNavigatedSlideshow(Previous)),
          ],
          [html.text("Previous")],
        ),
        html.button(
          [
            attribute.class("btn btn-ghost"),
            event.on_click(UserNavigatedSlideshow(Next)),
          ],
          [html.text("Next")],
        ),
        html.button(
          [
            attribute.class("btn btn-primary"),
            event.on_click(UserNavigatedSlideshow(Exit)),
          ],
          [html.text("Done")],
        ),
      ]),
      html.footer([attribute.class("text-center text-sm opacity-60")], [
        html.p([attribute.class("flex items-center justify-center gap-1")], [
          html.kbd([attribute.class("kbd kbd-sm")], [html.text("Left")]),
          html.kbd([attribute.class("kbd kbd-sm")], [html.text("Right")]),
          html.text("to move,"),
          html.kbd([attribute.class("kbd kbd-sm")], [html.text("Esc")]),
          html.text("to exit"),
        ]),
      ]),
    ],
  )
}

fn qr_error_message(reason: accounts.QrError) -> String {
  case reason {
    accounts.UriTooLong ->
      "This account's issuer and label are too long to fit in a QR code."
    accounts.QrGenerationFailed -> "This account can't be shown as a QR code."
  }
}

fn qr_component(qr_svg: Result(String, accounts.QrError)) -> Element(msg) {
  case qr_svg {
    Ok(svg) ->
      // The raw SVG comes only from the local QR generator.
      element.unsafe_raw_html(
        "",
        "div",
        [
          attribute.class(
            "w-[min(70vh,90vw,100%)] [&>svg]:box-border [&>svg]:h-auto [&>svg]:w-full [&>svg]:rounded-lg [&>svg]:bg-white [&>svg]:p-4",
          ),
        ],
        svg,
      )
    Error(reason) ->
      html.div(
        [
          attribute.class(
            "grid aspect-square w-[min(70vh,90vw,100%)] place-content-center rounded-lg border border-dashed border-base-300 text-center",
          ),
        ],
        [html.p([], [html.text(qr_error_message(reason))])],
      )
  }
}
