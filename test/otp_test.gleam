import gleam/list
import gleam/string
import otp
import qcheck

const seed_sha1 = <<"12345678901234567890":utf8>>

const seed_sha256 = <<"12345678901234567890123456789012":utf8>>

const seed_sha512 = <<
  "1234567890123456789012345678901234567890123456789012345678901234":utf8,
>>

pub fn rfc4226_appendix_d_six_digit_vectors_test() {
  assert [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    |> list.map(otp.code(
      seed_sha1,
      algorithm: otp.Sha1,
      digits: otp.Six,
      counter: _,
    ))
    == [
      "755224", "287082", "359152", "969429", "338314", "254676", "287922",
      "162583", "399871", "520489",
    ]
}

pub fn rfc6238_appendix_b_eight_digit_vectors_test() {
  [
    #(59, "94287082", "46119246", "90693936"),
    #(1_111_111_109, "07081804", "68084774", "25091201"),
    #(1_111_111_111, "14050471", "67062674", "99943326"),
    #(1_234_567_890, "89005924", "91819424", "93441116"),
    #(2_000_000_000, "69279037", "90698825", "38618901"),
    #(20_000_000_000, "65353130", "77737706", "47863826"),
  ]
  |> list.each(fn(c) {
    let #(time, sha1, sha256, sha512) = c
    let n = otp.counter_for(time, period: 30)
    assert otp.code(
        seed_sha1,
        algorithm: otp.Sha1,
        digits: otp.Eight,
        counter: n,
      )
      == sha1
    assert otp.code(
        seed_sha256,
        algorithm: otp.Sha256,
        digits: otp.Eight,
        counter: n,
      )
      == sha256
    assert otp.code(
        seed_sha512,
        algorithm: otp.Sha512,
        digits: otp.Eight,
        counter: n,
      )
      == sha512
  })
}

pub fn six_digit_leading_zeros_are_preserved_test() {
  assert otp.code(seed_sha1, algorithm: otp.Sha1, digits: otp.Six, counter: 36)
    == "003784"
}

pub fn counters_above_two_to_the_32_use_the_high_word_test() {
  assert otp.code(
      seed_sha1,
      algorithm: otp.Sha1,
      digits: otp.Eight,
      counter: 4_294_967_296,
    )
    == "55999456"
  assert otp.code(
      seed_sha1,
      algorithm: otp.Sha1,
      digits: otp.Eight,
      counter: 8_589_934_592,
    )
    == "11166590"
  assert otp.code(
      seed_sha1,
      algorithm: otp.Sha1,
      digits: otp.Eight,
      counter: 1_099_511_627_776,
    )
    == "57445672"
}

pub fn counter_for_divides_time_by_period_test() {
  assert otp.counter_for(0, period: 30) == 0
  assert otp.counter_for(29, period: 30) == 0
  assert otp.counter_for(30, period: 30) == 1
  assert otp.counter_for(59, period: 30) == 1
}

pub fn seconds_remaining_counts_down_to_the_boundary_test() {
  assert otp.seconds_remaining(0, period: 30) == 30
  assert otp.seconds_remaining(1, period: 30) == 29
  assert otp.seconds_remaining(29, period: 30) == 1
  assert otp.seconds_remaining(30, period: 30) == 30
}

pub fn a_six_digit_code_is_the_tail_of_the_eight_digit_code_test() {
  use counter <- qcheck.given(qcheck.bounded_int(0, 4_000_000_000))

  let six = otp.code(seed_sha1, algorithm: otp.Sha1, digits: otp.Six, counter:)
  let eight =
    otp.code(seed_sha1, algorithm: otp.Sha1, digits: otp.Eight, counter:)

  assert string.length(six) == 6
  assert string.length(eight) == 8
  assert six == string.drop_start(eight, 2)
}

pub fn the_countdown_ends_exactly_when_the_counter_advances_test() {
  use time <- qcheck.given(qcheck.bounded_int(0, 4_000_000_000))

  let left = otp.seconds_remaining(time, period: 30)
  let counter = otp.counter_for(time, period: 30)

  assert left >= 1 && left <= 30
  assert otp.counter_for(time + left - 1, period: 30) == counter
  assert otp.counter_for(time + left, period: 30) == counter + 1
}
