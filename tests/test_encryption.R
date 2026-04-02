source("setup.R")
run_setup(".")
source(file.path("R", "encryption.R"))

run_test_encryption <- function() {
  engine <- EncryptionEngine$new()
  passed <- 0L
  failed <- 0L

  run_case <- function(name, expr) {
    result <- tryCatch({
      force(expr)
      TRUE
    }, error = function(e) {
      message(sprintf("[FAIL] %s -> %s", name, e$message))
      FALSE
    })

    if (isTRUE(result)) {
      message(sprintf("[PASS] %s", name))
      passed <<- passed + 1L
    } else {
      failed <<- failed + 1L
    }
  }

  run_case("Encrypt then decrypt returns original content", {
    key <- engine$generate_key()
    iv <- engine$generate_iv()
    plaintext <- charToRaw("ZeroTraceFS test plaintext")
    ciphertext <- engine$encrypt(plaintext, key, iv)
    recovered <- engine$decrypt(ciphertext, key, iv)
    stopifnot(identical(plaintext, recovered))
  })

  run_case("Different IVs produce different ciphertext", {
    key <- engine$generate_key()
    plaintext <- charToRaw("same plaintext")
    c1 <- engine$encrypt(plaintext, key, engine$generate_iv())
    c2 <- engine$encrypt(plaintext, key, engine$generate_iv())
    stopifnot(!identical(c1, c2))
  })

  run_case("Wrong key fails decryption or produces non-matching plaintext", {
    key_ok <- engine$generate_key()
    key_bad <- engine$generate_key()
    iv <- engine$generate_iv()
    plaintext <- charToRaw("sensitive payload")
    ciphertext <- engine$encrypt(plaintext, key_ok, iv)

    wrong_result <- tryCatch(engine$decrypt(ciphertext, key_bad, iv), error = function(e) NULL)
    if (!is.null(wrong_result)) {
      stopifnot(!identical(wrong_result, plaintext))
    }
  })

  run_case("Binary data encrypts/decrypts correctly", {
    key <- engine$generate_key()
    iv <- engine$generate_iv()
    binary_blob <- as.raw(sample(0:255, size = 2048, replace = TRUE))
    ciphertext <- engine$encrypt(binary_blob, key, iv)
    recovered <- engine$decrypt(ciphertext, key, iv)
    stopifnot(identical(binary_blob, recovered))
  })

  run_case("Empty content handling", {
    key <- engine$generate_key()
    iv <- engine$generate_iv()
    plaintext <- raw(0)
    ciphertext <- engine$encrypt(plaintext, key, iv)
    recovered <- engine$decrypt(ciphertext, key, iv)
    stopifnot(identical(plaintext, recovered))
  })

  run_case("Large file handling (1MB+)", {
    tmp_plain <- tempfile(fileext = ".bin")
    tmp_out <- tempfile(fileext = ".bin")
    on.exit(unlink(c(tmp_plain, tmp_out), force = TRUE), add = TRUE)

    payload <- openssl::rand_bytes(1024 * 1024 + 128)
    con <- file(tmp_plain, "wb")
    writeBin(payload, con)
    close(con)

    key <- engine$generate_key()
    encrypted <- engine$encrypt_file(tmp_plain, key)
    engine$decrypt_to_file(encrypted$ciphertext, key, encrypted$iv, tmp_out)

    out_size <- file.info(tmp_out)$size
    con2 <- file(tmp_out, "rb")
    recovered <- readBin(con2, what = "raw", n = out_size)
    close(con2)

    stopifnot(identical(payload, recovered))
  })

  message(sprintf("Encryption tests complete: %d passed, %d failed", passed, failed))
  list(passed = passed, failed = failed)
}
