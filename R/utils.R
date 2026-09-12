dec2base <- function(n, b) {
  m <- n
  result <- c()
  for (k in seq(floor(logb(m,b)),0,-1)) {
    vk <- m %/% b^k
    m <- m - (vk * b^k)
    result <- c(result, vk)
  }
  result
}

makeRandomID <- function(n=10, len=10, alphabet=c(LETTERS, strsplit('0123456789','')[[1]])) {
  replicate(n, paste0(sample(alphabet, len), collapse = ''))
}

makeRandomSeedBytes <- function(N=.Machine$integer.max) {
  result <- random::randomNumbers(n=4,min=0,max=strtoi("ff",16),base=16,col=4)
  stringi::stri_pad_left(as.character(result),width=2,pad="0")
  # c("f8","a4","32","ea") # -123456789
}

seedBytes2Decimal <- function(seedBytes) {
  # Using ones compliment signed integer representation
  as.dec <- strtoi(seedBytes,16)
  sgn <- ifelse(as.dec[[1]]>127,-1,1)
  if (sgn == -1) {
    as.dec <- 255 - as.dec
  }
  as.dec
  bk <- rev(256^(seq_along(as.dec)-1))
  sgn*sum(bk*as.dec)
}

# seedBytes2Decimal(c("00","00","00","00")) == 0
# seedBytes2Decimal(c("00","00","00","01")) == 256^0
# seedBytes2Decimal(c("00","00","01","00")) == 256^1
# seedBytes2Decimal(c("00","01","00","00")) == 256^2
# seedBytes2Decimal(c("01","00","00","00")) == 256^3
# seedBytes2Decimal(c("7f","ff","ff","ff")) == .Machine$integer.max
# seedBytes2Decimal(c("80","00","00","00")) == -.Machine$integer.max
# seedBytes2Decimal(c("80","00","00","01")) == -.Machine$integer.max+1
# # ...
# seedBytes2Decimal(c("ff","ff","ff","fd")) == -2
# seedBytes2Decimal(c("ff","ff","ff","fe")) == -1
# seedBytes2Decimal(c("ff","ff","ff","ff")) == -0

decimal2SeedBytes <- function(n) {
  if (n==0) return(rep("00", 4))  # Note we force -0 to be 0 here
  sgn <- sign(n)
  as.dec <- dec2base(sgn*n, b = 256)
  as.dec <- c(rep(0,4-length(as.dec)), as.dec)
  if (sgn == -1) as.dec <- 255 - as.dec
  as.character(stringi::stri_pad_left(as.hexmode(as.dec),width = 2,pad="0"))
}

# all(c("00","00","00","00") == decimal2SeedBytes(0))
# all(c("00","00","00","01") == decimal2SeedBytes(256^0))
# all(c("00","00","01","00") == decimal2SeedBytes(256^1))
# all(c("00","01","00","00") == decimal2SeedBytes(256^2))
# all(c("01","00","00","00") == decimal2SeedBytes(256^3))
# all(c("7f","ff","ff","ff") == decimal2SeedBytes(.Machine$integer.max))
# all(c("80","00","00","00") == decimal2SeedBytes(-.Machine$integer.max))
# all(c("80","00","00","01") == decimal2SeedBytes(-.Machine$integer.max+1))
# # ...
# all(c("ff","ff","ff","fd") == decimal2SeedBytes(-2))
# all(c("ff","ff","ff","fe") == decimal2SeedBytes(-1))
# !all(c("ff","ff","ff","ff") == decimal2SeedBytes(-0))  # -0 == 0 so inverse not well defined for this single point

seed2words <- function(seed, asList=T) {
  positiveSeed <- seed + .Machine$integer.max # shift range (-2^31+1,2^31-1) to (0,2^32-2)
  wordIndices <- dec2base(positiveSeed, b = 1626)
  set.seed(1)
  words <- sort(sample(x = jobR::passphraseWords$word, size = 1626, replace = FALSE))
  keywordList <- words[wordIndices]
  if (asList) {
    return(keywordList)
  } else {
    return(paste0(keywords, collapse='-'))
  }
}

# To go from keywords to random seed
keywords2seed <- function(keywords) {
  set.seed(1)
  words <- sort(sample(x = jobR::passphraseWords$word, size = 1626, replace = FALSE))
  vk <- sapply(keywords, function(kw){which(kw==words)}, USE.NAMES=F)
  bk <- rev(1626^(seq_along(vk)-1))
  n <- sum(vk*bk) - .Machine$integer.max
  n
}

makeRandomSeedWords <- function() {
  seedBytes <- makeRandomSeedBytes()
  n <- seedBytes2Decimal(seedBytes)
  keywords <- seed2words(seed=n)
  keywords
}

setSeedFromWords <- function(keywords){
  n <- keywords2seed(keywords=keywords)
  set.seed(n)
}

getLocalSecret <- function() {
  fname <- file.path(jobrConfigDir(), "secret.txt")
  if (!file.exists(fname)) {
    secret <- paste0(makeRandomSeedWords(), collapse='-')
    writeChar(object=secret, con=fname, nchars = nchar(secret))
  }
  secret <- readLines(con=fname, warn = FALSE)
  secret
}
