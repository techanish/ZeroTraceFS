KeyDerivation <- R6::R6Class(
  "KeyDerivation",
  public = list(
    derive_key = function(password_string, salt_raw, iterations = 10000) {
      if (!is.character(password_string) || length(password_string) != 1) {
        stop("Password must be a single character string.")
      }
      if (!is.raw(salt_raw)) {
        stop("Salt must be a raw vector.")
      }
      if (!is.numeric(iterations) || iterations < 1) {
        stop("Iterations must be a positive number.")
      }

      password_raw <- charToRaw(password_string)
      key <- NULL

      if (exists("pbkdf2", where = asNamespace("openssl"), inherits = FALSE)) {
        pbkdf2_fn <- get("pbkdf2", envir = asNamespace("openssl"))
        key <- tryCatch({
          formal_names <- names(formals(pbkdf2_fn))

          if (all(c("password", "salt", "iter", "size", "hashfun") %in% formal_names)) {
            do.call(pbkdf2_fn, list(
              password = password_raw,
              salt = salt_raw,
              iter = as.integer(iterations),
              size = 32L,
              hashfun = openssl::sha256
            ))
          } else if (all(c("password", "salt", "iter", "keylen", "hashfun") %in% formal_names)) {
            do.call(pbkdf2_fn, list(
              password = password_raw,
              salt = salt_raw,
              iter = as.integer(iterations),
              keylen = 32L,
              hashfun = openssl::sha256
            ))
          } else {
            do.call(pbkdf2_fn, list(
              password_raw,
              salt_raw,
              as.integer(iterations),
              32L,
              openssl::sha256
            ))
          }
        }, error = function(e) {
          NULL
        })
      }

      if (is.null(key) || !is.raw(key) || length(key) < 32) {
        key <- private$pbkdf2_fallback(password_raw, salt_raw, as.integer(iterations), 32L)
      }

      if (!is.raw(key) || length(key) < 32) {
        stop("Failed to derive a 32-byte key.")
      }

      key[seq_len(32)]
    },

    generate_salt = function() {
      openssl::rand_bytes(32)
    },

    hash_password = function(password_string) {
      digest::digest(password_string, algo = "sha256", serialize = FALSE)
    },

    verify_password = function(password_string, stored_hash) {
      if (is.null(stored_hash) || is.na(stored_hash) || !nzchar(stored_hash)) {
        return(FALSE)
      }
      identical(self$hash_password(password_string), stored_hash)
    }
  ),
  private = list(
    pbkdf2_fallback = function(password_raw, salt_raw, iterations, output_len) {
      hash_len <- 32L
      block_count <- ceiling(output_len / hash_len)
      output <- raw(0)

      for (i in seq_len(block_count)) {
        block_index <- private$int_to_be4(i)
        u <- digest::hmac(
          key = password_raw,
          object = c(salt_raw, block_index),
          algo = "sha256",
          serialize = FALSE,
          raw = TRUE
        )
        t <- u

        if (iterations > 1L) {
          for (j in 2:iterations) {
            u <- digest::hmac(
              key = password_raw,
              object = u,
              algo = "sha256",
              serialize = FALSE,
              raw = TRUE
            )
            t <- private$raw_xor(t, u)
          }
        }

        output <- c(output, t)
      }

      output[seq_len(output_len)]
    },

    int_to_be4 = function(i) {
      as.raw(c(
        bitwAnd(bitwShiftR(i, 24), 255),
        bitwAnd(bitwShiftR(i, 16), 255),
        bitwAnd(bitwShiftR(i, 8), 255),
        bitwAnd(i, 255)
      ))
    },

    raw_xor = function(a, b) {
      as.raw(bitwXor(as.integer(a), as.integer(b)))
    }
  )
)
