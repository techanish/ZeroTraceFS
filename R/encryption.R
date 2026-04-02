EncryptionEngine <- R6::R6Class(
  "EncryptionEngine",
  public = list(
    encrypt = function(plaintext_raw, key_raw, iv_raw) {
      stopifnot(is.raw(plaintext_raw), is.raw(key_raw), is.raw(iv_raw))
      if (length(key_raw) != 32) {
        stop("Key must be 32 bytes for AES-256-CBC.")
      }
      if (length(iv_raw) != 16) {
        stop("IV must be 16 bytes for AES-CBC.")
      }
      openssl::aes_cbc_encrypt(plaintext_raw, key = key_raw, iv = iv_raw)
    },

    decrypt = function(ciphertext_raw, key_raw, iv_raw) {
      stopifnot(is.raw(ciphertext_raw), is.raw(key_raw), is.raw(iv_raw))
      if (length(key_raw) != 32) {
        stop("Key must be 32 bytes for AES-256-CBC.")
      }
      if (length(iv_raw) != 16) {
        stop("IV must be 16 bytes for AES-CBC.")
      }
      openssl::aes_cbc_decrypt(ciphertext_raw, key = key_raw, iv = iv_raw)
    },

    generate_iv = function() {
      openssl::rand_bytes(16)
    },

    generate_key = function() {
      openssl::rand_bytes(32)
    },

    encrypt_file = function(filepath, key_raw) {
      if (!file.exists(filepath)) {
        stop(sprintf("File does not exist: %s", filepath))
      }
      size <- file.info(filepath)$size
      con <- file(filepath, "rb")
      on.exit(close(con), add = TRUE)
      plaintext <- readBin(con, what = "raw", n = size)
      iv <- self$generate_iv()
      ciphertext <- self$encrypt(plaintext, key_raw, iv)
      list(ciphertext = ciphertext, iv = iv)
    },

    decrypt_to_file = function(ciphertext, key_raw, iv_raw, output_path) {
      plaintext <- self$decrypt(ciphertext, key_raw, iv_raw)
      out_dir <- dirname(output_path)
      if (!dir.exists(out_dir)) {
        dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
      }
      con <- file(output_path, "wb")
      on.exit(close(con), add = TRUE)
      writeBin(plaintext, con)
      invisible(output_path)
    }
  )
)
