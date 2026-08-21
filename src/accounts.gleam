import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/pair
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import gleam/uri
import gleam_protobuf/wire
import glqr
import migration
import munch
import otp
import thirtytwo

const max_batch_size = 100

const migration_prefix = "otpauth-migration://"

const account_prefix = "otpauth://"

pub type Account {
  Account(
    secret: BitArray,
    issuer: String,
    label: String,
    algorithm: otp.Algorithm,
    digits: otp.Digits,
    kind: otp.Kind,
  )
}

pub type Tick {
  TotpTick(code: String, seconds_left: Int, period: Int)
  HotpTick(code: String, counter: Int)
}

pub type DisplayName {
  Both(issuer: String, label: String)
  Single(text: String)
}

pub type SkipReason {
  NoSecret
  Unsupported
  UnspecifiedType
}

pub type Skipped {
  Skipped(name: DisplayName, reason: SkipReason)
}

pub type Error {
  SingleAccountQr
  NotAnExport
  Unreadable
  UnrecognizedOption
  UnsupportedVersion(version: Int)
  MalformedGeometry(size: Int, index: Int)
  DifferentExport(existing_id: Int, incoming_id: Int)
  BatchSizeMismatch(existing_size: Int, incoming_size: Int)
  ConflictingCode(batch_index: Int)
}

pub type Batch {
  Batch(
    batch_id: Int,
    batch_index: Int,
    batch_size: Int,
    digest: String,
    accounts: List(Account),
    skipped: List(Skipped),
  )
}

pub fn display_name(issuer: String, label label: String) -> DisplayName {
  case issuer, label {
    "", "" -> Single(text: "(unnamed)")
    "", label -> Single(text: label)
    issuer, "" -> Single(text: issuer)
    issuer, label -> Both(issuer:, label:)
  }
}

pub fn is_otpauth_uri(text: String) -> Bool {
  string.starts_with(text, migration_prefix)
  || string.starts_with(text, account_prefix)
}

pub fn parse(uri_string: String) -> Result(Batch, Error) {
  use <- bool.guard(
    when: string.starts_with(uri_string, account_prefix),
    return: Error(SingleAccountQr),
  )
  use <- bool.guard(
    when: !string.starts_with(uri_string, migration_prefix),
    return: Error(NotAnExport),
  )
  use bytes <- result.try(
    data_param(uri_string)
    |> result.try(bit_array.base64_decode)
    |> result.replace_error(Unreadable),
  )
  use payload <- result.try(
    migration.decode_migration_payload(bytes)
    |> result.map_error(decode_error),
  )

  use <- bool.guard(
    when: payload.version != 1 && payload.version != 2,
    return: Error(UnsupportedVersion(version: payload.version)),
  )

  use <- bool.guard(
    when: !valid_geometry(size: payload.batch_size, index: payload.batch_index),
    return: Error(MalformedGeometry(
      size: payload.batch_size,
      index: payload.batch_index,
    )),
  )
  let digest = bit_array.base16_encode(munch.hash_bits(munch.sha256, bytes))

  let #(accounts, skipped) =
    list.map(payload.otp_parameters, convert)
    |> result.partition

  Ok(Batch(
    batch_id: payload.batch_id,
    batch_index: payload.batch_index,
    batch_size: payload.batch_size,
    digest:,
    accounts: list.reverse(accounts),
    skipped: list.reverse(skipped),
  ))
}

fn valid_geometry(size size: Int, index index: Int) -> Bool {
  size >= 1 && size <= max_batch_size && index >= 0 && index < size
}

fn data_param(uri_string: String) -> Result(String, Nil) {
  use parsed <- result.try(uri.parse(uri_string))
  use query <- result.try(option.to_result(parsed.query, Nil))
  // uri.parse_query follows form-encoding and decodes "+" as a space, which
  // would corrupt the base64 payload.
  use pairs <- result.try(
    query
    |> string.replace("+", "%2B")
    |> uri.parse_query,
  )
  list.key_find(pairs, "data")
}

fn convert(
  entry: migration.MigrationPayloadOtpParameters,
) -> Result(Account, Skipped) {
  case classify(entry) {
    Error(reason) ->
      Error(Skipped(
        name: display_name(entry.issuer, label: entry.name),
        reason: reason,
      ))
    Ok(#(algorithm, digits, kind)) ->
      Ok(Account(
        secret: entry.secret,
        issuer: entry.issuer,
        label: entry.name,
        algorithm: algorithm,
        digits: digits,
        kind: kind,
      ))
  }
}

fn classify(
  entry: migration.MigrationPayloadOtpParameters,
) -> Result(#(otp.Algorithm, otp.Digits, otp.Kind), SkipReason) {
  use <- bool.guard(
    when: bit_array.byte_size(entry.secret) == 0,
    return: Error(NoSecret),
  )
  use algorithm <- result.try(algorithm_of(entry.algorithm))
  use kind <- result.map(kind_of(entry.otp_type, counter: entry.counter))
  #(algorithm, digits_of(entry.digits), kind)
}

fn decode_error(error: wire.DecodeError) -> Error {
  case error {
    wire.UnknownEnumValue(..) -> UnrecognizedOption
    wire.Truncated
    | wire.InvalidVarint
    | wire.UnsupportedWireType(_)
    | wire.LengthOverflow
    | wire.InvalidUtf8
    | wire.MissingPayload -> Unreadable
  }
}

fn algorithm_of(
  algorithm: migration.Algorithm,
) -> Result(otp.Algorithm, SkipReason) {
  case algorithm {
    // Google Authenticator treats an unspecified algorithm as SHA1.
    migration.AlgorithmUnspecified | migration.AlgorithmSha1 -> Ok(otp.Sha1)
    migration.AlgorithmSha256 -> Ok(otp.Sha256)
    migration.AlgorithmSha512 -> Ok(otp.Sha512)
    migration.AlgorithmMd5 -> Error(Unsupported)
  }
}

fn digits_of(digits: migration.DigitCount) -> otp.Digits {
  case digits {
    migration.DigitCountUnspecified | migration.DigitCountSix -> otp.Six
    migration.DigitCountEight -> otp.Eight
  }
}

fn kind_of(
  otp_type: migration.OtpType,
  counter counter: Int,
) -> Result(otp.Kind, SkipReason) {
  case otp_type {
    migration.OtpTypeUnspecified -> Error(UnspecifiedType)
    migration.OtpTypeHotp -> Ok(otp.Hotp(counter:))
    migration.OtpTypeTotp -> Ok(otp.Totp(period: 30))
  }
}

pub fn merge_batch(
  into batches: Dict(Int, Batch),
  incoming incoming: Batch,
) -> Result(Dict(Int, Batch), Error) {
  use _ <- result.try(same_export(batches, incoming))
  insert_batch(batches, incoming)
}

fn same_export(
  batches: Dict(Int, Batch),
  incoming: Batch,
) -> Result(Nil, Error) {
  case any_batch(batches) {
    Error(_) -> Ok(Nil)
    Ok(existing) if existing.batch_id != incoming.batch_id ->
      Error(DifferentExport(
        existing_id: existing.batch_id,
        incoming_id: incoming.batch_id,
      ))
    Ok(existing) if existing.batch_size != incoming.batch_size ->
      Error(BatchSizeMismatch(
        existing_size: existing.batch_size,
        incoming_size: incoming.batch_size,
      ))
    Ok(_) -> Ok(Nil)
  }
}

fn insert_batch(
  batches: Dict(Int, Batch),
  incoming: Batch,
) -> Result(Dict(Int, Batch), Error) {
  case dict.get(batches, incoming.batch_index) {
    Error(_) -> Ok(dict.insert(batches, incoming.batch_index, incoming))
    Ok(existing) if existing.digest == incoming.digest -> Ok(batches)
    Ok(_) -> Error(ConflictingCode(batch_index: incoming.batch_index))
  }
}

fn any_batch(batches: Dict(Int, Batch)) -> Result(Batch, Nil) {
  batches
  |> dict.values
  |> list.first
}

pub fn all(batches: Dict(Int, Batch)) -> List(Account) {
  ordered(batches)
  |> list.flat_map(fn(b) { b.accounts })
}

pub fn rows(
  entries: List(Account),
  now now: Timestamp,
) -> List(#(Account, Tick)) {
  entries
  |> list.map(fn(a) { #(a, tick_of(a, now)) })
}

fn tick_of(account: Account, now: Timestamp) -> Tick {
  let #(unix_seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
  case account.kind {
    otp.Totp(period) ->
      TotpTick(
        code: code_at(account, otp.counter_for(unix_seconds, period:)),
        seconds_left: otp.seconds_remaining(unix_seconds, period:),
        period:,
      )
    otp.Hotp(counter) -> HotpTick(code: code_at(account, counter), counter:)
  }
}

fn code_at(account: Account, counter: Int) -> String {
  otp.code(
    account.secret,
    algorithm: account.algorithm,
    digits: account.digits,
    counter:,
  )
}

pub fn skipped(batches: Dict(Int, Batch)) -> List(Skipped) {
  ordered(batches)
  |> list.flat_map(fn(b) { b.skipped })
}

fn ordered(batches: Dict(Int, Batch)) -> List(Batch) {
  batches
  |> dict.to_list
  |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
  |> list.map(pair.second)
}

pub fn scanned_batch_count(batches: Dict(Int, Batch)) -> Int {
  dict.size(batches)
}

pub fn expected_batch_count(batches: Dict(Int, Batch)) -> Int {
  case any_batch(batches) {
    Ok(b) -> b.batch_size
    Error(_) -> 0
  }
}

pub fn is_complete(batches: Dict(Int, Batch)) -> Bool {
  let total = expected_batch_count(batches)
  total > 0 && has_every_index(batches, total - 1)
}

fn has_every_index(batches: Dict(Int, Batch), index: Int) -> Bool {
  case index {
    0 -> dict.has_key(batches, 0)
    _ -> dict.has_key(batches, index) && has_every_index(batches, index - 1)
  }
}

fn escape(value: String) -> String {
  uri.percent_encode(value)
  |> string.replace("+", "%2B")
}

pub fn otpauth_uri(account: Account) -> String {
  let kind = case account.kind {
    otp.Totp(_) -> "totp"
    otp.Hotp(_) -> "hotp"
  }

  // Encode before joining so the only literal colon is the separator.
  let label = case account.issuer {
    "" -> escape(account.label)
    issuer -> escape(issuer) <> ":" <> escape(account.label)
  }

  let algorithm = case account.algorithm {
    otp.Sha1 -> "SHA1"
    otp.Sha256 -> "SHA256"
    otp.Sha512 -> "SHA512"
  }

  let tail = case account.kind {
    otp.Totp(period) -> #("period", int.to_string(period))
    otp.Hotp(counter) -> #("counter", int.to_string(counter))
  }

  let issuer_param = case account.issuer {
    "" -> []
    issuer -> [#("issuer", issuer)]
  }

  let query = [
    #("secret", thirtytwo.encode(account.secret, padding: False)),
    #("algorithm", algorithm),
    #("digits", int.to_string(otp.digit_count(account.digits))),
    tail,
    ..issuer_param
  ]

  "otpauth://" <> kind <> "/" <> label <> "?" <> uri.query_to_string(query)
}

pub type QrError {
  UriTooLong
  QrGenerationFailed
}

pub fn generate_qr_svg(account: Account) -> Result(String, QrError) {
  glqr.new(otpauth_uri(account))
  |> glqr.error_correction(glqr.M)
  |> glqr.generate()
  |> result.map(glqr.to_svg)
  |> result.map_error(qr_error)
}

fn qr_error(error: glqr.GenerateError) -> QrError {
  case error {
    glqr.ProvidedValueExceedsCapacity(..) -> UriTooLong
    glqr.EmptyValue(_)
    | glqr.InvalidVersion(_)
    | glqr.InvalidNumericEncoding(_)
    | glqr.InvalidAlphanumericEncoding(_)
    | glqr.InvalidUtf8Encoding(_)
    | glqr.InvalidRemainingBits(_) -> QrGenerationFailed
  }
}
