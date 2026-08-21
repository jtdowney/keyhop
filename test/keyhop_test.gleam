import accounts
import birdie
import gleam/dict
import gleam/list
import gleam/option
import gleam/time/timestamp
import keyhop
import lustre/element
import otp
import scanner
import support/fixture
import unitest

pub fn main() {
  unitest.main()
}

fn scanning(generation: Int) -> keyhop.Model {
  keyhop.Scanning(
    batches: dict.new(),
    scan_generation: generation,
    error: option.None,
    confirming_reset: False,
  )
}

fn slideshow() -> keyhop.Model {
  showing(imported(["alice"]), 0)
}

fn imported(names: List(String)) -> dict.Dict(Int, accounts.Batch) {
  let assert Ok(batch) =
    accounts.parse(fixture.named_batch(index: 0, size: 1, names:))
  dict.insert(dict.new(), 0, batch)
}

fn showing(
  batches: dict.Dict(Int, accounts.Batch),
  index: Int,
) -> keyhop.Model {
  let entries = accounts.all(batches)
  let assert [current, ..after] = list.drop(entries, index)
  keyhop.Slideshow(keyhop.Reel(
    before: list.take(entries, index) |> list.reverse,
    current:,
    after:,
    qr_svg: accounts.generate_qr_svg(current),
  ))
}

fn rendered(model: keyhop.Model) -> String {
  keyhop.view(model)
  |> element.to_readable_string
}

pub fn a_decode_from_a_superseded_scan_is_discarded_test() {
  let model = scanning(3)
  let #(next, _) =
    keyhop.update(
      model,
      keyhop.ScannerDecodedQr(
        generation: 2,
        text: "otpauth-migration://offline?data=x",
      ),
    )

  assert next == model
}

pub fn a_decode_at_the_current_generation_is_processed_test() {
  let #(next, _) =
    keyhop.update(
      scanning(0),
      keyhop.ScannerDecodedQr(generation: 0, text: "https://not-an-export"),
    )

  assert next
    == keyhop.Scanning(
      batches: dict.new(),
      scan_generation: 0,
      error: option.Some("That isn't a Google Authenticator export."),
      confirming_reset: False,
    )
}

pub fn an_incomplete_import_keeps_scanning_test() {
  let uri = fixture.named_batch(index: 0, size: 2, names: ["alice"])
  let assert Ok(batch) = accounts.parse(uri)
  let model =
    keyhop.Scanning(
      batches: dict.new(),
      scan_generation: 4,
      error: option.Some("That isn't a Google Authenticator export."),
      confirming_reset: True,
    )

  let #(next, _) =
    keyhop.update(model, keyhop.ScannerDecodedQr(generation: 4, text: uri))

  assert next
    == keyhop.Scanning(
      batches: dict.insert(dict.new(), 0, batch),
      scan_generation: 4,
      error: option.None,
      confirming_reset: False,
    )
}

pub fn a_complete_import_goes_live_test() {
  let uri = fixture.named_batch(index: 0, size: 1, names: ["alice"])
  let assert Ok(batch) = accounts.parse(uri)

  let #(next, _) =
    keyhop.update(
      scanning(0),
      keyhop.ScannerDecodedQr(generation: 0, text: uri),
    )

  let assert keyhop.Live(entries, _) = next
  assert entries == batch.accounts
}

pub fn the_clock_only_advances_in_live_test() {
  let #(next, _) =
    keyhop.update(
      scanning(0),
      keyhop.ClockTicked(now: timestamp.from_unix_seconds(1000)),
    )
  assert next == scanning(0)

  let #(next, _) =
    keyhop.update(
      keyhop.Live(entries: [], now: timestamp.from_unix_seconds(1000)),
      keyhop.ClockTicked(now: timestamp.from_unix_seconds(2000)),
    )
  assert next
    == keyhop.Live(entries: [], now: timestamp.from_unix_seconds(2000))
}

pub fn escape_returns_to_live_test() {
  let #(next, _) =
    keyhop.update(slideshow(), keyhop.UserPressedKey(key: "Escape"))
  let assert keyhop.Live(entries, _) = next
  assert entries == accounts.all(imported(["alice"]))
}

pub fn exiting_from_the_middle_restores_the_original_order_test() {
  let batches = imported(["alice", "bob", "carol"])

  let #(next, _) =
    keyhop.update(
      showing(batches, 1),
      keyhop.UserNavigatedSlideshow(keyhop.Exit),
    )

  let assert keyhop.Live(entries, _) = next
  assert entries == accounts.all(batches)
}

pub fn navigation_past_the_last_account_is_ignored_test() {
  let #(next, _) =
    keyhop.update(slideshow(), keyhop.UserPressedKey(key: "ArrowRight"))
  assert next == slideshow()
}

pub fn navigation_before_the_first_account_is_ignored_test() {
  let batches = imported(["alice", "bob"])

  let #(next, _) =
    keyhop.update(showing(batches, 0), keyhop.UserPressedKey(key: "ArrowLeft"))

  assert next == showing(batches, 0)
}

pub fn requesting_the_slideshow_opens_the_first_account_test() {
  let batches = imported(["alice"])

  let #(next, _) =
    keyhop.update(
      keyhop.Live(
        entries: accounts.all(batches),
        now: timestamp.from_unix_seconds(90),
      ),
      keyhop.UserRequestedSlideshow,
    )

  assert next == showing(batches, 0)
}

pub fn next_advances_to_the_second_account_test() {
  let batches = imported(["alice", "bob"])

  let #(next, _) =
    keyhop.update(
      showing(batches, 0),
      keyhop.UserNavigatedSlideshow(keyhop.Next),
    )

  assert next == showing(batches, 1)
  assert showing(batches, 0) != showing(batches, 1)
}

pub fn previous_returns_to_the_first_account_test() {
  let batches = imported(["alice", "bob"])

  let #(next, _) =
    keyhop.update(
      showing(batches, 1),
      keyhop.UserNavigatedSlideshow(keyhop.Previous),
    )

  assert next == showing(batches, 0)
}

pub fn a_button_and_its_key_produce_the_same_model_test() {
  let batches = imported(["alice", "bob"])

  let #(by_key, _) =
    keyhop.update(showing(batches, 0), keyhop.UserPressedKey(key: "Escape"))
  let #(by_button, _) =
    keyhop.update(
      showing(batches, 0),
      keyhop.UserNavigatedSlideshow(keyhop.Exit),
    )
  // Both paths read the wall clock, so compare entries and ignore the
  // timestamps.
  let assert keyhop.Live(key_entries, _) = by_key
  let assert keyhop.Live(button_entries, _) = by_button
  assert key_entries == button_entries

  let #(by_key, _) =
    keyhop.update(showing(batches, 0), keyhop.UserPressedKey(key: "ArrowRight"))
  let #(by_button, _) =
    keyhop.update(
      showing(batches, 0),
      keyhop.UserNavigatedSlideshow(keyhop.Next),
    )
  assert by_key == by_button

  let #(by_key, _) =
    keyhop.update(showing(batches, 1), keyhop.UserPressedKey(key: "ArrowLeft"))
  let #(by_button, _) =
    keyhop.update(
      showing(batches, 1),
      keyhop.UserNavigatedSlideshow(keyhop.Previous),
    )
  assert by_key == by_button
}

pub fn every_teardown_message_returns_to_a_fresh_scan_test() {
  [keyhop.UserRequestedClear, keyhop.BrowserHidPage, keyhop.ScannerStopped]
  |> list.each(fn(msg) {
    let #(next, _) =
      keyhop.update(
        keyhop.Live(entries: [], now: timestamp.from_unix_seconds(0)),
        msg,
      )
    assert next == scanning(0)
  })
}

pub fn a_restart_from_a_scan_climbs_the_generation_test() {
  let #(from_scan, _) = keyhop.update(scanning(7), keyhop.UserRequestedClear)
  let assert keyhop.Scanning(_, after_scan, _, _) = from_scan
  assert after_scan == 8
}

pub fn reset_requested_with_held_accounts_confirms_test() {
  let batches =
    dict.insert(
      dict.new(),
      0,
      accounts.Batch(
        batch_id: 0,
        batch_index: 0,
        batch_size: 2,
        digest: "",
        accounts: [],
        skipped: [],
      ),
    )
  let model =
    keyhop.Scanning(
      batches:,
      scan_generation: 0,
      error: option.None,
      confirming_reset: False,
    )
  let #(next, _) = keyhop.update(model, keyhop.UserRequestedReset)

  assert next
    == keyhop.Scanning(
      batches:,
      scan_generation: 0,
      error: option.None,
      confirming_reset: True,
    )
}

pub fn reset_requested_with_nothing_scanned_skips_confirmation_test() {
  let model = scanning(0)
  let #(next, _) = keyhop.update(model, keyhop.UserRequestedReset)

  assert next == model
}

pub fn confirming_a_reset_holds_the_model_until_the_scanner_stops_test() {
  let model =
    keyhop.Scanning(
      batches: imported(["alice"]),
      scan_generation: 3,
      error: option.None,
      confirming_reset: True,
    )

  let #(confirmed, _) = keyhop.update(model, keyhop.UserConfirmedReset)
  assert confirmed == model

  let #(next, _) = keyhop.update(confirmed, keyhop.ScannerStopped)
  assert next == scanning(4)
}

pub fn reset_cancelled_clears_confirmation_test() {
  let model =
    keyhop.Scanning(
      batches: dict.new(),
      scan_generation: 0,
      error: option.None,
      confirming_reset: True,
    )
  let #(next, _) = keyhop.update(model, keyhop.UserCancelledReset)

  assert next == scanning(0)
}

pub fn start_over_bumps_the_generation_after_the_scanner_stops_test() {
  let #(next, _) = keyhop.update(scanning(1), keyhop.ScannerStopped)
  let assert keyhop.Scanning(_, generation, _, _) = next
  assert generation == 2
}

pub fn scanner_failures_are_classified_test() {
  let #(next, _) =
    keyhop.update(
      scanning(0),
      keyhop.ScannerFailed(error: scanner.ScannerUnavailable),
    )

  assert next
    == keyhop.Scanning(
      batches: dict.new(),
      scan_generation: 0,
      error: option.Some(
        "The QR scanner didn't load, so nothing can be decoded. Check your connection and reload the page.",
      ),
      confirming_reset: False,
    )
}

pub fn a_fresh_scan_renders_test() {
  rendered(scanning(0))
  |> birdie.snap("scanning: nothing scanned yet")
}

pub fn a_scan_with_an_error_and_skips_renders_test() {
  let batches =
    dict.insert(
      dict.new(),
      0,
      accounts.Batch(
        batch_id: 42,
        batch_index: 0,
        batch_size: 3,
        digest: "",
        accounts: [],
        skipped: [
          accounts.Skipped(
            name: accounts.Both(issuer: "GitHub", label: "alice"),
            reason: accounts.Unsupported,
          ),
          accounts.Skipped(
            name: accounts.Single(text: "bob"),
            reason: accounts.NoSecret,
          ),
        ],
      ),
    )

  keyhop.Scanning(
    batches:,
    scan_generation: 0,
    error: option.Some("That isn't a Google Authenticator export."),
    confirming_reset: True,
  )
  |> rendered
  |> birdie.snap("scanning: error, skipped accounts, confirming reset")
}

pub fn live_accounts_render_test() {
  keyhop.Live(
    entries: [
      accounts.Account(
        secret: <<"alice_secret":utf8>>,
        issuer: "GitHub",
        label: "alice",
        algorithm: otp.Sha1,
        digits: otp.Six,
        kind: otp.Totp(period: 30),
      ),
      accounts.Account(
        secret: <<"bob_secret":utf8>>,
        issuer: "",
        label: "bob",
        algorithm: otp.Sha256,
        digits: otp.Eight,
        kind: otp.Hotp(counter: 7),
      ),
    ],
    now: timestamp.from_unix_seconds(1_700_000_000),
  )
  |> rendered
  |> birdie.snap("live: a totp and an hotp account")
}

pub fn the_slideshow_renders_its_qr_test() {
  keyhop.Slideshow(keyhop.Reel(
    before: [],
    current: accounts.Account(
      secret: <<"alice_secret":utf8>>,
      issuer: "GitHub",
      label: "alice",
      algorithm: otp.Sha1,
      digits: otp.Six,
      kind: otp.Totp(period: 30),
    ),
    after: [],
    qr_svg: Ok("<svg data-stub=\"qr\"></svg>"),
  ))
  |> rendered
  |> birdie.snap("slideshow: first of one, qr rendered")
}

pub fn the_slideshow_renders_a_qr_failure_test() {
  let account =
    accounts.Account(
      secret: <<"alice_secret":utf8>>,
      issuer: "",
      label: "alice",
      algorithm: otp.Sha1,
      digits: otp.Six,
      kind: otp.Totp(period: 30),
    )

  keyhop.Slideshow(keyhop.Reel(
    before: [account],
    current: account,
    after: [account],
    qr_svg: Error(accounts.UriTooLong),
  ))
  |> rendered
  |> birdie.snap("slideshow: second of three, uri too long")
}
