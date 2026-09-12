test_that("random codes work", {
  set.seed(1)
  expect_equal(makeRandomID(n=2, len=4),
               c("D7N6", "AWRU"))


  expect_equal(makeRandomID(n=2, len=3, alphabet = "10"),
               c("101010", "101010"))
  expect_equal(makeRandomID(n=10, len=4, alphabet = LETTERS),
               c("IJFH", "OYOL", "ULTY", "EOTW", "IAZX", "YTLF", "NCYZ", "EFWG",
                 "EJFS", "BJYJ"))
})
