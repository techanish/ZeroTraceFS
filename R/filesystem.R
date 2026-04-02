VirtualFileSystem <- R6::R6Class(
  "VirtualFileSystem",
  public = list(
    files = NULL,

    initialize = function() {
      self$files <- list()
      private$encryption <- EncryptionEngine$new()
      private$key_derivation <- KeyDerivation$new()
    },

    add_file = function(filename, content_raw, master_password) {
      if (!is.raw(content_raw)) {
        stop("content_raw must be a raw vector.")
      }
      if (!nzchar(filename)) {
        stop("filename must not be empty.")
      }

      fname <- basename(filename)
      if (self$file_exists(fname)) {
        return(self$update_file(fname, content_raw, master_password))
      }

      salt <- private$key_derivation$generate_salt()
      key <- private$key_derivation$derive_key(master_password, salt, iterations = private$key_iterations)
      iv <- private$encryption$generate_iv()
      ciphertext <- private$encryption$encrypt(content_raw, key, iv)

      metadata <- private$make_metadata(fname, content_raw)
      self$files[[fname]] <- list(
        ciphertext = ciphertext,
        iv = iv,
        salt = salt,
        key = key,
        metadata = metadata
      )

      invisible(TRUE)
    },

    read_file = function(filename, master_password) {
      private$decrypt_entry(filename, master_password, increment_read = TRUE)
    },

    peek_file = function(filename, master_password) {
      private$decrypt_entry(filename, master_password, increment_read = FALSE)
    },

    note_file_read = function(filename, read_time = Sys.time()) {
      fname <- basename(filename)
      if (!self$file_exists(fname)) {
        return(FALSE)
      }

      entry <- self$files[[fname]]
      if (isTRUE(entry$metadata$is_destroyed)) {
        return(FALSE)
      }

      entry$metadata$read_count <- as.integer(entry$metadata$read_count + 1L)
      entry$metadata$last_read_at <- as.POSIXct(read_time, tz = "UTC")
      self$files[[fname]] <- entry
      TRUE
    },

    update_file = function(filename, content_raw, master_password) {
      if (!is.raw(content_raw)) {
        stop("content_raw must be a raw vector.")
      }
      if (!self$file_exists(filename)) {
        stop(sprintf("File not found in VFS: %s", filename))
      }

      fname <- basename(filename)
      salt <- private$key_derivation$generate_salt()
      key <- private$key_derivation$derive_key(master_password, salt, iterations = private$key_iterations)
      iv <- private$encryption$generate_iv()
      ciphertext <- private$encryption$encrypt(content_raw, key, iv)

      entry <- self$files[[fname]]
      entry$ciphertext <- ciphertext
      entry$iv <- iv
      entry$salt <- salt
      entry$key <- key
      entry$metadata$modified_at <- Sys.time()
      entry$metadata$file_size <- as.integer(length(content_raw))
      entry$metadata$file_hash <- digest::digest(content_raw, algo = "sha256", serialize = FALSE)
      entry$metadata$is_destroyed <- FALSE

      self$files[[fname]] <- entry
      invisible(TRUE)
    },

    remove_file = function(filename) {
      fname <- basename(filename)
      if (!self$file_exists(fname)) {
        return(FALSE)
      }
      self$files[[fname]] <- NULL
      TRUE
    },

    list_files = function() {
      if (length(self$files) == 0) {
        return(data.frame(
          filename = character(0),
          created_at = character(0),
          modified_at = character(0),
          last_read_at = character(0),
          read_count = integer(0),
          file_size = integer(0),
          ttl_seconds = numeric(0),
          max_reads = integer(0),
          deadline = character(0),
          stringsAsFactors = FALSE
        ))
      }

      rows <- lapply(names(self$files), function(fname) {
        meta <- self$files[[fname]]$metadata
        data.frame(
          filename = meta$filename,
          created_at = as.character(meta$created_at),
          modified_at = as.character(meta$modified_at),
          last_read_at = if (is.null(meta$last_read_at)) NA_character_ else as.character(meta$last_read_at),
          read_count = as.integer(meta$read_count),
          file_size = as.integer(meta$file_size),
          ttl_seconds = if (is.null(meta$ttl_seconds)) NA_real_ else as.numeric(meta$ttl_seconds),
          max_reads = if (is.null(meta$max_reads)) NA_integer_ else as.integer(meta$max_reads),
          deadline = if (is.null(meta$deadline)) NA_character_ else as.character(meta$deadline),
          stringsAsFactors = FALSE
        )
      })

      do.call(rbind, rows)
    },

    get_metadata = function(filename) {
      fname <- basename(filename)
      if (!self$file_exists(fname)) {
        return(NULL)
      }
      self$files[[fname]]$metadata
    },

    set_trigger = function(filename, trigger_type, value) {
      fname <- basename(filename)
      if (!self$file_exists(fname)) {
        stop(sprintf("File not found in VFS: %s", fname))
      }

      entry <- self$files[[fname]]
      if (identical(trigger_type, "ttl_seconds")) {
        entry$metadata$ttl_seconds <- if (is.null(value)) NULL else as.numeric(value)
      } else if (identical(trigger_type, "max_reads")) {
        entry$metadata$max_reads <- if (is.null(value)) NULL else as.integer(value)
      } else if (identical(trigger_type, "deadline")) {
        entry$metadata$deadline <- if (is.null(value)) NULL else as.POSIXct(value, tz = "UTC")
      } else {
        stop("Unsupported trigger_type. Use ttl_seconds, max_reads, or deadline.")
      }

      self$files[[fname]] <- entry
      invisible(TRUE)
    },

    file_exists = function(filename) {
      fname <- basename(filename)
      !is.null(self$files[[fname]])
    },

    get_all_filenames = function() {
      names(self$files)
    },

    serialize = function() {
      serialized_files <- lapply(self$files, function(entry) {
        entry$metadata <- private$serialize_metadata(entry$metadata)
        entry
      })

      list(
        files = serialized_files,
        key_iterations = private$key_iterations
      )
    },

    deserialize = function(data) {
      private$key_iterations <- as.integer(data$key_iterations %||% 10000L)
      restored <- data$files %||% list()
      restored <- lapply(restored, function(entry) {
        entry$metadata <- private$deserialize_metadata(entry$metadata)
        entry
      })
      self$files <- restored
      invisible(self)
    }
  ),
  private = list(
    encryption = NULL,
    key_derivation = NULL,
    key_iterations = 10000L,

    make_metadata = function(filename, content_raw) {
      now <- Sys.time()
      list(
        filename = filename,
        created_at = now,
        modified_at = now,
        last_read_at = NULL,
        read_count = 0L,
        file_size = as.integer(length(content_raw)),
        file_hash = digest::digest(content_raw, algo = "sha256", serialize = FALSE),
        ttl_seconds = NULL,
        max_reads = NULL,
        deadline = NULL,
        is_destroyed = FALSE
      )
    },

    decrypt_entry = function(filename, master_password, increment_read) {
      fname <- basename(filename)
      if (!self$file_exists(fname)) {
        stop(sprintf("File not found in VFS: %s", fname))
      }

      entry <- self$files[[fname]]
      if (isTRUE(entry$metadata$is_destroyed)) {
        stop(sprintf("File is marked destroyed: %s", fname))
      }

      derived_key <- private$key_derivation$derive_key(
        master_password,
        entry$salt,
        iterations = private$key_iterations
      )

      if (!identical(derived_key, entry$key)) {
        stop("Invalid master password for file decryption.")
      }

      plaintext <- private$encryption$decrypt(entry$ciphertext, derived_key, entry$iv)
      if (isTRUE(increment_read)) {
        entry$metadata$read_count <- as.integer(entry$metadata$read_count + 1L)
        entry$metadata$last_read_at <- Sys.time()
        self$files[[fname]] <- entry
      }
      plaintext
    },

    serialize_metadata = function(meta) {
      meta$created_at <- as.character(meta$created_at)
      meta$modified_at <- as.character(meta$modified_at)
      meta$last_read_at <- if (is.null(meta$last_read_at)) NA_character_ else as.character(meta$last_read_at)
      meta$deadline <- if (is.null(meta$deadline)) NA_character_ else as.character(meta$deadline)
      meta
    },

    deserialize_metadata = function(meta) {
      meta$created_at <- as.POSIXct(meta$created_at, tz = "UTC")
      meta$modified_at <- as.POSIXct(meta$modified_at, tz = "UTC")
      if (!is.null(meta$last_read_at) && !all(is.na(meta$last_read_at))) {
        meta$last_read_at <- as.POSIXct(meta$last_read_at, tz = "UTC")
      } else {
        meta$last_read_at <- NULL
      }
      if (!is.null(meta$deadline) && !all(is.na(meta$deadline))) {
        meta$deadline <- as.POSIXct(meta$deadline, tz = "UTC")
      } else {
        meta$deadline <- NULL
      }
      meta
    }
  )
)

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}
