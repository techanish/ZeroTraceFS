SecureWiper <- R6::R6Class(
  "SecureWiper",
  public = list(
    wipe_file = function(filepath) {
      tryCatch({
        if (!file.exists(filepath)) {
          return(FALSE)
        }

        size <- file.info(filepath)$size
        if (is.na(size) || size <= 0) {
          unlink(filepath, force = TRUE)
          return(TRUE)
        }

        size <- as.integer(size)

        for (i in 1:3) {
          private$overwrite_pass(filepath, size, random_fill = TRUE)
        }

        private$overwrite_pass(filepath, size, random_fill = FALSE)

        trunc_con <- file(filepath, open = "wb")
        close(trunc_con)

        unlink(filepath, force = TRUE)
        !file.exists(filepath)
      }, error = function(e) {
        warning(sprintf("wipe_file failed for %s: %s", filepath, e$message))
        FALSE
      })
    },

    wipe_directory = function(dirpath) {
      if (!dir.exists(dirpath)) {
        return(TRUE)
      }

      files <- fs::dir_ls(dirpath, recurse = TRUE, type = "file", all = TRUE)
      ok <- TRUE
      if (length(files) > 0) {
        for (f in files) {
          result <- self$wipe_file(f)
          ok <- isTRUE(ok && result)
        }
      }

      dirs <- fs::dir_ls(dirpath, recurse = TRUE, type = "directory", all = TRUE)
      if (length(dirs) > 0) {
        dirs <- sort(as.character(dirs), decreasing = TRUE)
        for (d in dirs) {
          if (dir.exists(d)) {
            unlink(d, recursive = FALSE, force = TRUE)
          }
        }
      }

      ok
    },

    wipe_memory_object = function(obj_name, envir = parent.frame()) {
      if (!exists(obj_name, envir = envir, inherits = FALSE)) {
        return(FALSE)
      }

      obj <- get(obj_name, envir = envir, inherits = FALSE)
      serialized <- serialize(obj, connection = NULL)
      randomized <- openssl::rand_bytes(length(serialized))
      assign(obj_name, randomized, envir = envir)
      rm(list = obj_name, envir = envir)
      invisible(gc())
      TRUE
    },

    destroy_crypto_artifacts = function(file_entry) {
      if (is.null(file_entry) || !is.list(file_entry)) {
        return(file_entry)
      }

      if (!is.null(file_entry$key) && is.raw(file_entry$key)) {
        file_entry$key <- openssl::rand_bytes(length(file_entry$key))
        file_entry$key <- NULL
      }
      if (!is.null(file_entry$iv) && is.raw(file_entry$iv)) {
        file_entry$iv <- openssl::rand_bytes(length(file_entry$iv))
        file_entry$iv <- NULL
      }
      if (!is.null(file_entry$salt) && is.raw(file_entry$salt)) {
        file_entry$salt <- openssl::rand_bytes(length(file_entry$salt))
        file_entry$salt <- NULL
      }

      file_entry
    },

    full_system_wipe = function(mount_path, container_path) {
      mount_ok <- self$wipe_directory(mount_path)
      container_ok <- TRUE
      if (!is.null(container_path) && nzchar(container_path) && file.exists(container_path)) {
        container_ok <- self$wipe_file(container_path)
      }
      invisible(gc())

      list(
        mount_wiped = mount_ok,
        container_wiped = container_ok,
        completed = isTRUE(mount_ok && container_ok)
      )
    }
  ),
  private = list(
    overwrite_pass = function(filepath, size, random_fill = TRUE) {
      chunk_size <- 1024L * 1024L
      con <- file(filepath, open = "r+b")
      on.exit(close(con), add = TRUE)

      seek(con, where = 0, origin = "start")
      remaining <- as.integer(size)

      while (remaining > 0L) {
        n <- min(chunk_size, remaining)
        bytes <- if (isTRUE(random_fill)) openssl::rand_bytes(n) else raw(n)
        writeBin(bytes, con, useBytes = TRUE)
        remaining <- remaining - n
      }

      flush(con)
      invisible(TRUE)
    }
  )
)
