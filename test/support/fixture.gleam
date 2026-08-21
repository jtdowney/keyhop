//// Builders for Google Authenticator migration payloads, shared by the
//// accounts and keyhop test modules.

import gleam/bit_array
import gleam/list
import gleam/string

pub const secret = <<"abcde":utf8>>

pub fn entry(
  secret: BitArray,
  name name: String,
  algorithm algorithm: Int,
  digits digits: Int,
  kind kind: Int,
  counter counter: BitArray,
) -> BitArray {
  let name_bits = bit_array.from_string(name)
  let body =
    bit_array.concat([
      <<0x0A, bit_array.byte_size(secret):size(8)>>,
      secret,
      <<0x12, bit_array.byte_size(name_bits):size(8)>>,
      name_bits,
      <<0x20, algorithm:size(8)>>,
      <<0x28, digits:size(8)>>,
      <<0x30, kind:size(8)>>,
      counter,
    ])
  bit_array.concat([<<0x0A, bit_array.byte_size(body):size(8)>>, body])
}

pub fn totp_entry(secret: BitArray, name: String) -> BitArray {
  entry(secret, name:, algorithm: 1, digits: 1, kind: 2, counter: <<>>)
}

pub fn hotp_entry(secret: BitArray, counter counter: BitArray) -> BitArray {
  entry(secret, name: "a", algorithm: 1, digits: 1, kind: 1, counter:)
}

pub fn entry_with(
  algorithm algorithm: Int,
  digits digits: Int,
  kind kind: Int,
) -> BitArray {
  entry(secret, name: "a", algorithm:, digits:, kind:, counter: <<>>)
}

pub fn payload(
  entry_bits: BitArray,
  version version: Int,
  size size: Int,
  index index: Int,
  id id: Int,
) -> BitArray {
  bit_array.concat([
    entry_bits,
    <<0x10, version:size(8), 0x18, size:size(8), 0x20, index:size(8)>>,
    <<0x28, id:size(8)>>,
  ])
}

pub fn uri(bits: BitArray) -> String {
  "otpauth-migration://offline?data="
  <> bit_array.base64_encode(bits, True)
  |> string.replace("+", "%2B")
  |> string.replace("/", "%2F")
  |> string.replace("=", "%3D")
}

pub fn single_batch(entry_bits: BitArray) -> String {
  uri(payload(entry_bits, version: 1, size: 1, index: 0, id: 0))
}

pub fn named_batch(
  index index: Int,
  size size: Int,
  names names: List(String),
) -> String {
  list.map(names, totp_entry(secret, _))
  |> bit_array.concat
  |> payload(version: 1, size:, index:, id: 0)
  |> uri
}
