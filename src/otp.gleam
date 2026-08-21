import gleam/bit_array
import gleam/int
import gleam/string
import munch

pub type Algorithm {
  Sha1
  Sha256
  Sha512
}

fn algorithm_to_munch(algorithm: Algorithm) -> munch.HashAlgorithm {
  case algorithm {
    Sha1 -> munch.sha1
    Sha256 -> munch.sha256
    Sha512 -> munch.sha512
  }
}

pub type Kind {
  Totp(period: Int)
  Hotp(counter: Int)
}

pub type Digits {
  Six
  Eight
}

pub fn digit_count(digits: Digits) -> Int {
  case digits {
    Six -> 6
    Eight -> 8
  }
}

fn truncation_modulus(digits: Digits) -> Int {
  case digits {
    Six -> 1_000_000
    Eight -> 100_000_000
  }
}

pub fn code(
  secret: BitArray,
  algorithm algorithm: Algorithm,
  digits digits: Digits,
  counter counter: Int,
) -> String {
  let mac =
    munch.hmac_bits(
      // This is wrong if counter exceeds 2^53 on Javascript but its rare in
      // practice, counter will never exceed it in any reasonable scenario
      <<counter:big-size(64)>>,
      algorithm_to_munch(algorithm),
      secret,
    )

  // RFC 4226 dynamic truncation. The 4-bit offset cannot exceed the shortest
  // supported digest.
  let assert Ok(<<_:size(4), offset:size(4)>>) =
    bit_array.slice(mac, bit_array.byte_size(mac) - 1, 1)
  let assert <<_:bytes-size(offset), _:size(1), truncated:big-size(31), _:bits>> =
    mac

  truncated % truncation_modulus(digits)
  |> int.to_string
  |> string.pad_start(digit_count(digits), "0")
}

pub fn counter_for(unix_seconds: Int, period period: Int) -> Int {
  unix_seconds / period
}

pub fn seconds_remaining(unix_seconds: Int, period period: Int) -> Int {
  period - unix_seconds % period
}
