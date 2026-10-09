import accounts
import gleam/bit_array
import gleam/dict
import gleam/list
import gleam/string
import gleam/time/timestamp
import gleam/uri
import otp
import qcheck
import support/fixture

const real_v2_export =
  "otpauth-migration://offline?data=CjUKBWYkQUSTEgdNWUxBQkVMGghNWUlTU1VFUiACKAIwAkITNjE5NGJjMTczNzcyNzc5ODc5MxACGAEgAA%3D%3D"

fn batch_of(id: Int, index: Int, size: Int, name: String) -> accounts.Batch {
  let assert Ok(b) =
    accounts.parse(
      fixture.uri(fixture.payload(
        fixture.totp_entry(fixture.secret, name),
        version: 1,
        size: size,
        index: index,
        id: id,
      )),
    )
  b
}

fn only_skip(entry_bits: BitArray) -> accounts.SkipReason {
  let assert Ok(batch) = accounts.parse(fixture.single_batch(entry_bits))
  assert batch.accounts == []
  let assert [skipped] = batch.skipped
  skipped.reason
}

fn account(issuer: String, label: String, kind: otp.Kind) -> accounts.Account {
  accounts.Account(
    secret: <<"Hello!":utf8>>,
    issuer: issuer,
    label: label,
    algorithm: otp.Sha1,
    digits: otp.Six,
    kind: kind,
  )
}

fn with_algorithm(algorithm: otp.Algorithm) -> String {
  accounts.otpauth_uri(
    accounts.Account(..account("", "x", otp.Totp(period: 30)), algorithm:),
  )
}

fn split_label(encoded: String, issuer: String) -> #(String, String) {
  case issuer {
    "" -> #("", encoded)
    _ -> {
      let assert Ok(pair) = string.split_once(encoded, ":")
      pair
    }
  }
}

fn imported_account(secret: BitArray, label: String) -> accounts.Account {
  accounts.Account(
    secret:,
    issuer: "",
    label:,
    algorithm: otp.Sha1,
    digits: otp.Six,
    kind: otp.Totp(period: 30),
  )
}

pub fn parses_a_real_version_2_export_test() {
  let assert Ok(batch) = accounts.parse(real_v2_export)
  assert batch.batch_size == 1
  assert batch.batch_index == 0
  assert batch.skipped == []

  assert batch.batch_id == 0
  assert batch.accounts
    == [
      accounts.Account(
        secret: <<0x66, 0x24, 0x41, 0x44, 0x93>>,
        issuer: "MYISSUER",
        label: "MYLABEL",
        algorithm: otp.Sha256,
        digits: otp.Eight,
        kind: otp.Totp(period: 30),
      ),
    ]
}

pub fn accepts_version_1_test() {
  let assert Ok(batch) =
    accounts.parse(
      fixture.single_batch(fixture.totp_entry(fixture.secret, "alice")),
    )
  assert batch.accounts == [imported_account(fixture.secret, "alice")]
}

pub fn rejects_a_plain_single_account_uri_by_name_test() {
  assert accounts.parse("otpauth://totp/GitHub:alice?secret=JBSWY3DPEE")
    == Error(accounts.SingleAccountQr)
}

pub fn rejects_an_unrelated_uri_test() {
  assert accounts.parse("https://example.com") == Error(accounts.NotAnExport)
}

pub fn is_otpauth_uri_accepts_only_what_parse_can_explain_test() {
  assert accounts.is_otpauth_uri(real_v2_export)
  assert accounts.is_otpauth_uri(
    "otpauth://totp/GitHub:alice?secret=JBSWY3DPEE",
  )
  assert !accounts.is_otpauth_uri("https://example.com")
}

pub fn rejects_an_unsupported_version_test() {
  let export =
    fixture.uri(fixture.payload(
      fixture.totp_entry(fixture.secret, "a"),
      version: 3,
      size: 1,
      index: 0,
      id: 0,
    ))
  assert accounts.parse(export)
    == Error(accounts.UnsupportedVersion(version: 3))
}

pub fn rejects_out_of_range_batch_sizes_test() {
  let sized = fn(size) {
    accounts.parse(
      fixture.uri(fixture.payload(
        fixture.totp_entry(fixture.secret, "a"),
        version: 1,
        size: size,
        index: 0,
        id: 0,
      )),
    )
  }

  assert sized(0) == Error(accounts.MalformedGeometry(size: 0, index: 0))
  assert sized(101) == Error(accounts.MalformedGeometry(size: 101, index: 0))
  let assert Ok(_) = sized(100)
}

pub fn rejects_out_of_range_batch_geometry_test() {
  let export =
    fixture.uri(fixture.payload(
      fixture.totp_entry(fixture.secret, "a"),
      version: 1,
      size: 1,
      index: 5,
      id: 0,
    ))
  assert accounts.parse(export)
    == Error(accounts.MalformedGeometry(size: 1, index: 5))
}

pub fn rejects_a_uri_with_no_readable_data_test() {
  assert accounts.parse("otpauth-migration://offline")
    == Error(accounts.Unreadable)
  assert accounts.parse("otpauth-migration://offline?x=1")
    == Error(accounts.Unreadable)
  assert accounts.parse("otpauth-migration://offline?data=%ZZ")
    == Error(accounts.Unreadable)
  assert accounts.parse("otpauth-migration://offline?data=!!!!")
    == Error(accounts.Unreadable)
}

pub fn parses_a_data_param_with_an_unescaped_plus_test() {
  let assert Ok(batch) =
    accounts.parse(
      "otpauth-migration://offline?data=Cg4KA++++xIBYSABKAEwAhABGAE%3D",
    )
  let assert [account] = batch.accounts
  assert account.secret == <<0xEF, 0xBE, 0xFB>>
}

pub fn an_unknown_field_is_skipped_rather_than_rejected_test() {
  let bits =
    bit_array.concat([
      fixture.payload(
        fixture.totp_entry(fixture.secret, "alice"),
        version: 1,
        size: 1,
        index: 0,
        id: 0,
      ),
      // Field 9, varint. Field 10, length-delimited.
      <<0x48, 42>>,
      <<0x52, 3, 1, 2, 3>>,
    ])
  let assert Ok(batch) = accounts.parse(fixture.uri(bits))
  assert batch.accounts == [imported_account(fixture.secret, "alice")]
}

pub fn rejects_bytes_that_are_not_a_migration_payload_test() {
  assert accounts.parse(fixture.uri(<<0xFF, 0xFF, 0xFF>>))
    == Error(accounts.Unreadable)
}

pub fn a_payload_with_no_entries_imports_nothing_test() {
  let assert Ok(batch) =
    accounts.parse(fixture.uri(<<0x10, 0x01, 0x18, 0x01, 0x20, 0x00>>))
  assert batch.accounts == []
  assert batch.skipped == []
}

pub fn skips_an_entry_with_an_empty_secret_test() {
  assert only_skip(fixture.totp_entry(<<>>, "a")) == accounts.NoSecret
}

pub fn skips_md5_test() {
  assert only_skip(fixture.entry_with(algorithm: 4, digits: 1, kind: 2))
    == accounts.Unsupported
}

pub fn rejects_an_unknown_algorithm_test() {
  assert accounts.parse(
      fixture.single_batch(fixture.entry_with(algorithm: 9, digits: 1, kind: 2)),
    )
    == Error(accounts.UnrecognizedOption)
}

pub fn rejects_an_unknown_digit_count_test() {
  assert accounts.parse(
      fixture.single_batch(fixture.entry_with(algorithm: 1, digits: 9, kind: 2)),
    )
    == Error(accounts.UnrecognizedOption)
}

pub fn skips_an_unspecified_type_test() {
  assert only_skip(fixture.entry_with(algorithm: 1, digits: 1, kind: 0))
    == accounts.UnspecifiedType
}

pub fn rejects_an_unknown_type_test() {
  assert accounts.parse(
      fixture.single_batch(fixture.entry_with(algorithm: 1, digits: 1, kind: 9)),
    )
    == Error(accounts.UnrecognizedOption)
}

pub fn a_skipped_entry_keeps_its_display_name_test() {
  let assert Ok(batch) =
    accounts.parse(fixture.single_batch(fixture.totp_entry(<<>>, "alice")))
  assert batch.skipped
    == [
      accounts.Skipped(
        name: accounts.Single(text: "alice"),
        reason: accounts.NoSecret,
      ),
    ]
}

pub fn display_name_covers_every_issuer_and_label_combination_test() {
  assert accounts.display_name("", label: "")
    == accounts.Single(text: "(unnamed)")
  assert accounts.display_name("", label: "alice")
    == accounts.Single(text: "alice")
  assert accounts.display_name("GitHub", label: "")
    == accounts.Single(text: "GitHub")
  assert accounts.display_name("GitHub", label: "alice")
    == accounts.Both(issuer: "GitHub", label: "alice")
}

pub fn an_hotp_entry_reports_hotp_kind_test() {
  let assert Ok(batch) =
    accounts.parse(
      fixture.single_batch(
        fixture.hotp_entry(fixture.secret, counter: <<0x38, 5:size(8)>>),
      ),
    )
  let assert [account] = batch.accounts
  assert account.kind == otp.Hotp(counter: 5)
}

pub fn defaults_unspecified_algorithm_and_digits_test() {
  let assert Ok(batch) =
    accounts.parse(
      fixture.single_batch(fixture.entry_with(algorithm: 0, digits: 0, kind: 2)),
    )
  let assert [account] = batch.accounts
  assert account.algorithm == otp.Sha1
  assert account.digits == otp.Six
}

pub fn an_unnamed_account_is_imported_test() {
  let assert Ok(batch) =
    accounts.parse(fixture.single_batch(fixture.totp_entry(fixture.secret, "")))
  assert batch.accounts == [imported_account(fixture.secret, "")]
}

pub fn the_digest_is_the_sha256_of_the_payload_bytes_test() {
  let assert Ok(a) = accounts.parse(real_v2_export)
  let assert Ok(other) =
    accounts.parse(
      fixture.single_batch(fixture.totp_entry(fixture.secret, "alice")),
    )
  assert a.digest
    == "7BB33F38C20CF4B01245803EC14DD1B7A10CA57B7C0231960377A7FA3AA3729C"
  assert other.digest
    == "79A3F35C4DD06E0F9304278DDBAF2E7ECB8E7B0092C1878779F80272F6B247FC"
}

pub fn a_payload_with_multiple_entries_decodes_in_order_test() {
  let assert Ok(batch) =
    accounts.parse(
      fixture.single_batch(
        bit_array.concat([
          fixture.totp_entry(<<"secret1":utf8>>, "first"),
          fixture.totp_entry(<<"secret2":utf8>>, "second"),
          fixture.totp_entry(<<"secret3":utf8>>, "third"),
        ]),
      ),
    )
  assert batch.accounts
    == [
      imported_account(<<"secret1":utf8>>, "first"),
      imported_account(<<"secret2":utf8>>, "second"),
      imported_account(<<"secret3":utf8>>, "third"),
    ]
}

pub fn a_skipped_entry_in_the_middle_keeps_the_others_test() {
  let assert Ok(batch) =
    accounts.parse(
      fixture.single_batch(
        bit_array.concat([
          fixture.totp_entry(<<"secret1":utf8>>, "first"),
          fixture.entry_with(algorithm: 4, digits: 1, kind: 2),
          fixture.totp_entry(<<"secret3":utf8>>, "third"),
          fixture.totp_entry(<<"secret4":utf8>>, "fourth"),
        ]),
      ),
    )

  assert batch.accounts
    == [
      imported_account(<<"secret1":utf8>>, "first"),
      imported_account(<<"secret3":utf8>>, "third"),
      imported_account(<<"secret4":utf8>>, "fourth"),
    ]
  assert batch.skipped
    == [
      accounts.Skipped(
        name: accounts.Single(text: "a"),
        reason: accounts.Unsupported,
      ),
    ]
}

pub fn a_single_complete_batch_finishes_immediately_test() {
  let assert Ok(m) =
    accounts.merge_batch(dict.new(), batch_of(42, 0, 1, "alice"))
  assert accounts.is_complete(m)
  assert accounts.all(m) == [imported_account(fixture.secret, "alice")]
}

pub fn two_batches_merge_and_only_then_complete_test() {
  let assert Ok(m) =
    accounts.merge_batch(dict.new(), batch_of(42, 0, 2, "alice"))
  assert !accounts.is_complete(m)
  let assert Ok(m) = accounts.merge_batch(m, batch_of(42, 1, 2, "bob"))
  assert accounts.is_complete(m)
  assert accounts.scanned_batch_count(m) == 2
}

pub fn rescanning_an_identical_qr_is_a_no_op_test() {
  let b = batch_of(42, 0, 2, "alice")
  let assert Ok(m) = accounts.merge_batch(dict.new(), b)
  let assert Ok(m) = accounts.merge_batch(m, b)
  assert accounts.all(m) == [imported_account(fixture.secret, "alice")]
}

pub fn different_content_at_a_seen_index_is_rejected_test() {
  let assert Ok(m) =
    accounts.merge_batch(dict.new(), batch_of(42, 0, 2, "alice"))
  assert accounts.merge_batch(m, batch_of(42, 0, 2, "mallory"))
    == Error(accounts.ConflictingCode(batch_index: 0))
}

pub fn a_qr_from_a_different_export_is_rejected_test() {
  let assert Ok(m) =
    accounts.merge_batch(dict.new(), batch_of(42, 0, 2, "alice"))
  assert accounts.merge_batch(m, batch_of(99, 1, 2, "bob"))
    == Error(accounts.DifferentExport(existing_id: 42, incoming_id: 99))
}

pub fn a_disagreeing_batch_size_is_rejected_test() {
  let assert Ok(m) =
    accounts.merge_batch(dict.new(), batch_of(42, 0, 2, "alice"))
  assert accounts.merge_batch(m, batch_of(42, 1, 3, "bob"))
    == Error(accounts.BatchSizeMismatch(existing_size: 2, incoming_size: 3))
}

pub fn out_of_order_arrival_still_orders_by_index_test() {
  let assert Ok(m) = accounts.merge_batch(dict.new(), batch_of(42, 1, 2, "bob"))
  let assert Ok(m) = accounts.merge_batch(m, batch_of(42, 0, 2, "alice"))
  let labels =
    accounts.all(m)
    |> list.map(fn(a) { a.label })
  assert labels == ["alice", "bob"]
}

pub fn completion_requires_every_index_test() {
  let assert Ok(m) =
    accounts.merge_batch(dict.new(), batch_of(42, 0, 3, "alice"))
  let assert Ok(m) = accounts.merge_batch(m, batch_of(42, 1, 3, "bob"))
  assert !accounts.is_complete(m)
  assert accounts.scanned_batch_count(m) == 2
}

pub fn completion_requires_the_first_index_test() {
  let assert Ok(m) = accounts.merge_batch(dict.new(), batch_of(42, 1, 2, "bob"))
  assert !accounts.is_complete(m)
  assert accounts.scanned_batch_count(m) == 1
}

pub fn an_empty_import_is_not_complete_test() {
  assert !accounts.is_complete(dict.new())
  assert accounts.expected_batch_count(dict.new()) == 0
  assert accounts.all(dict.new()) == []
}

pub fn a_skip_only_batch_still_completes_test() {
  let assert Ok(b) =
    accounts.parse(
      fixture.single_batch(fixture.entry_with(algorithm: 4, digits: 1, kind: 2)),
    )
  let assert Ok(m) = accounts.merge_batch(dict.new(), b)
  assert accounts.is_complete(m)
  assert accounts.all(m) == []
  assert accounts.skipped(m)
    == [
      accounts.Skipped(
        name: accounts.Single(text: "a"),
        reason: accounts.Unsupported,
      ),
    ]
}

pub fn codes_are_computed_from_each_accounts_own_secret_test() {
  let assert Ok(batch) =
    accounts.parse(
      fixture.single_batch(
        bit_array.concat([
          fixture.totp_entry(<<"secret_alice":utf8>>, "alice"),
          fixture.totp_entry(<<"secret_bob":utf8>>, "bob"),
        ]),
      ),
    )
  let assert Ok(m) = accounts.merge_batch(dict.new(), batch)

  let assert [#(alice, alice_tick), #(bob, bob_tick)] =
    accounts.rows(
      accounts.all(m),
      now: timestamp.from_unix_seconds(1_700_000_000),
    )
  assert alice.label == "alice"
  assert bob.label == "bob"
  assert alice_tick.code == "316605"
  assert bob_tick.code == "959316"
}

pub fn each_account_uses_its_own_algorithm_and_digit_count_test() {
  let assert Ok(batch) =
    accounts.parse(
      fixture.single_batch(
        bit_array.concat([
          fixture.entry(
            fixture.secret,
            name: "a",
            algorithm: 1,
            digits: 1,
            kind: 2,
            counter: <<>>,
          ),
          fixture.entry(
            fixture.secret,
            name: "b",
            algorithm: 2,
            digits: 2,
            kind: 2,
            counter: <<>>,
          ),
          fixture.entry(
            fixture.secret,
            name: "c",
            algorithm: 3,
            digits: 1,
            kind: 2,
            counter: <<>>,
          ),
        ]),
      ),
    )
  let assert Ok(m) = accounts.merge_batch(dict.new(), batch)

  let assert [#(_, sha1), #(_, sha256), #(_, sha512)] =
    accounts.rows(
      accounts.all(m),
      now: timestamp.from_unix_seconds(1_700_000_000),
    )

  assert sha1.code == "245823"
  assert sha256.code == "61091182"
  assert sha512.code == "780360"
}

pub fn hotp_has_no_countdown_and_ignores_now_test() {
  let assert Ok(batch) =
    accounts.parse(
      fixture.single_batch(
        bit_array.concat([
          fixture.totp_entry(<<"totp_secret":utf8>>, "t"),
          fixture.hotp_entry(<<"hotp_secret":utf8>>, counter: <<
            0x38,
            7:size(8),
          >>),
        ]),
      ),
    )
  let assert Ok(m) = accounts.merge_batch(dict.new(), batch)

  let assert [#(_, totp_before), #(_, hotp_before)] =
    accounts.rows(accounts.all(m), now: timestamp.from_unix_seconds(29))
  let assert [#(_, totp_after), #(_, hotp_after)] =
    accounts.rows(accounts.all(m), now: timestamp.from_unix_seconds(31))

  assert totp_before
    == accounts.TotpTick(code: "157344", seconds_left: 1, period: 30)
  assert totp_after
    == accounts.TotpTick(code: "885946", seconds_left: 29, period: 30)
  assert hotp_before == accounts.HotpTick(code: "951924", counter: 7)
  assert hotp_after == accounts.HotpTick(code: "951924", counter: 7)
}

pub fn builds_a_totp_uri_with_every_parameter_explicit_test() {
  assert accounts.otpauth_uri(account("GitHub", "alice", otp.Totp(period: 30)))
    == "otpauth://totp/GitHub:alice?secret=JBSWY3DPEE&algorithm=SHA1&digits=6&period=30&issuer=GitHub"
}

pub fn builds_a_hotp_uri_carrying_the_counter_test() {
  assert accounts.otpauth_uri(account("GitHub", "alice", otp.Hotp(counter: 7)))
    == "otpauth://hotp/GitHub:alice?secret=JBSWY3DPEE&algorithm=SHA1&digits=6&counter=7&issuer=GitHub"
}

pub fn omits_the_issuer_entirely_when_there_is_none_test() {
  assert accounts.otpauth_uri(account("", "alice", otp.Totp(period: 30)))
    == "otpauth://totp/alice?secret=JBSWY3DPEE&algorithm=SHA1&digits=6&period=30"
}

pub fn escapes_the_label_per_rfc_3986_test() {
  [
    #(
      "a/b?c#d%e&f=g h",
      "otpauth://totp/a%2Fb%3Fc%23d%25e%26f%3Dg%20h?secret=JBSWY3DPEE&algorithm=SHA1&digits=6&period=30",
    ),
    #(
      "café",
      "otpauth://totp/caf%C3%A9?secret=JBSWY3DPEE&algorithm=SHA1&digits=6&period=30",
    ),
    #(
      "あ",
      "otpauth://totp/%E3%81%82?secret=JBSWY3DPEE&algorithm=SHA1&digits=6&period=30",
    ),
    #(
      "a+b",
      "otpauth://totp/a%2Bb?secret=JBSWY3DPEE&algorithm=SHA1&digits=6&period=30",
    ),
    #(
      "a!b'c(d)e*f",
      "otpauth://totp/a!b'c(d)e*f?secret=JBSWY3DPEE&algorithm=SHA1&digits=6&period=30",
    ),
    #(
      "a-b.c_d~e",
      "otpauth://totp/a-b.c_d~e?secret=JBSWY3DPEE&algorithm=SHA1&digits=6&period=30",
    ),
  ]
  |> list.each(fn(c) {
    let #(label, expected) = c
    assert accounts.otpauth_uri(account("", label, otp.Totp(period: 30)))
      == expected
  })
}

pub fn escapes_colons_so_the_first_colon_is_the_separator_test() {
  assert accounts.otpauth_uri(account("ACME: Inc", "a:b", otp.Totp(period: 30)))
    == "otpauth://totp/ACME%3A%20Inc:a%3Ab?secret=JBSWY3DPEE&algorithm=SHA1&digits=6&period=30&issuer=ACME%3A%20Inc"
}

pub fn emits_the_algorithm_name_for_each_hash_test() {
  assert with_algorithm(otp.Sha1)
    == "otpauth://totp/x?secret=JBSWY3DPEE&algorithm=SHA1&digits=6&period=30"
  assert with_algorithm(otp.Sha256)
    == "otpauth://totp/x?secret=JBSWY3DPEE&algorithm=SHA256&digits=6&period=30"
  assert with_algorithm(otp.Sha512)
    == "otpauth://totp/x?secret=JBSWY3DPEE&algorithm=SHA512&digits=6&period=30"
}

pub fn emits_the_digit_count_for_eight_digit_accounts_test() {
  assert accounts.otpauth_uri(
      accounts.Account(
        ..account("", "x", otp.Totp(period: 30)),
        digits: otp.Eight,
      ),
    )
    == "otpauth://totp/x?secret=JBSWY3DPEE&algorithm=SHA1&digits=8&period=30"
}

pub fn a_typical_account_fits_in_a_qr_code_test() {
  let assert Ok(_) =
    accounts.generate_qr_svg(account("GitHub", "alice", otp.Totp(period: 30)))
}

pub fn a_label_past_qr_capacity_reports_it_test() {
  let label = string.repeat("a", 3000)
  assert accounts.generate_qr_svg(account("GitHub", label, otp.Totp(period: 30)))
    == Error(accounts.UriTooLong)
}

pub fn the_issuer_and_label_survive_escaping_test() {
  use #(issuer, label) <- qcheck.given(qcheck.tuple2(
    qcheck.string(),
    qcheck.string(),
  ))

  let assert Ok(parsed) =
    uri.parse(
      accounts.otpauth_uri(account(issuer, label, otp.Totp(period: 30))),
    )
  let encoded = string.drop_start(parsed.path, 1)
  let #(encoded_issuer, encoded_label) = split_label(encoded, issuer)

  let assert Ok(decoded_issuer) = uri.percent_decode(encoded_issuer)
  let assert Ok(decoded_label) = uri.percent_decode(encoded_label)
  assert decoded_issuer == issuer
  assert decoded_label == label
}
