passphraseWords <- readr::read_delim("https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt", col_names = c("id", "word"), show_col_types = FALSE)

usethis::use_data(passphraseWords, overwrite = TRUE)
