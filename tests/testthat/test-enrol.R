# The wordlist contains four hyphenated words (drop-down, felt-tip, t-shirt,
# yo-yo). A passphrase is hyphen-separated, so drawing one used to make a
# four-word phrase read as five and break the round trip -- about 1 in 486
# passphrases, which is exactly the rate at which a bug stays hidden. These
# tests draw many rather than one.

test_that("passphrases have the requested shape, every time", {
  for (n in c(3, 4, 6)) {
    for (i in 1:200) {
      p <- passphrase_new(n)
      expect_length(passphrase_words(p), n)
      expect_match(p, sprintf("^[a-z]+(-[a-z]+){%d}$", n - 1L))
    }
  }
})

test_that("no usable word contains the separator", {
  words <- passphrase_wordlist()
  expect_gt(length(words), 7000)
  expect_false(any(grepl("-", words, fixed = TRUE)))
  expect_true(all(grepl("^[a-z]+$", words)))
})

test_that("a passphrase round-trips through split and rejoin", {
  for (i in 1:200) {
    p <- passphrase_new(4)
    expect_equal(paste(passphrase_words(p), collapse = "-"), p)
    expect_true(passphrase_equal(p, p))
  }
})

test_that("passphrases do not repeat", {
  many <- replicate(200, passphrase_new(4))
  expect_equal(length(unique(many)), 200L)
})

test_that("passphrase comparison tolerates case and whitespace", {
  expect_true(passphrase_equal("Correct-Horse", "  correct-horse "))
  expect_false(passphrase_equal("correct-horse", "correct-horses"))
  expect_false(passphrase_equal("correct-horse", "correct"))
  expect_false(passphrase_equal("a-b", "b-a"))
})

test_that("constant time comparison is still correct", {
  expect_true(constant_time_equal("abc", "abc"))
  expect_false(constant_time_equal("abc", "abd"))
  expect_false(constant_time_equal("abc", "ab"))
  expect_true(constant_time_equal("", ""))
})

test_that("tokens are unique and opaque", {
  toks <- replicate(500, token_new())
  expect_equal(length(unique(toks)), 500L)
  expect_match(toks[1], "^[0-9a-f]{32}$")
})

test_that("random_below stays in range and covers it", {
  x <- random_below(6, 3000)
  expect_true(all(x >= 1 & x <= 6))
  expect_setequal(unique(x), 1:6)
  # Rejection sampling should leave the distribution flat; a chi-square style
  # bound is enough to catch a modulo-bias regression.
  expect_lt(max(abs(table(x) - 500)) / 500, 0.25)
})

test_that("random_below handles the single value case", {
  expect_equal(unique(random_below(1, 20)), 1L)
})
