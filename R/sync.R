SyncEngine <- R6::R6Class(
  "SyncEngine",
  public = list(
    mount_path = NULL,
    vfs = NULL,
    encryption = NULL,
    master_password = NULL,
    file_hashes = NULL,
    file_access_times = NULL,
    last_scan = NULL,

    initialize = function(mount_path, vfs, master_password, encryption = NULL) {
      self$mount_path <- fs::path_abs(mount_path)
      self$vfs <- vfs
      self$master_password <- master_password
      self$encryption <- encryption %||% EncryptionEngine$new()
      self$file_hashes <- character(0)
      self$file_access_times <- list()
      self$last_scan <- Sys.time()

      if (!fs::dir_exists(self$mount_path)) {
        fs::dir_create(self$mount_path, recurse = TRUE)
      }
    },

    populate_mount = function() {
      if (!fs::dir_exists(self$mount_path)) {
        fs::dir_create(self$mount_path, recurse = TRUE)
      }

      filenames <- self$vfs$get_all_filenames()
      self$file_hashes <- character(0)
      self$file_access_times <- list()

      for (fname in filenames) {
        target_path <- fs::path(self$mount_path, fname)
        content_raw <- self$vfs$peek_file(fname, self$master_password)

        con <- file(target_path, "wb")
        writeBin(content_raw, con)
        close(con)

        self$file_hashes[fname] <- self$get_file_hash(target_path)
        self$file_access_times[[fname]] <- self$get_file_access_time(target_path)
      }

      self$last_scan <- Sys.time()
      invisible(TRUE)
    },

    scan_changes = function() {
      file_paths <- fs::dir_ls(self$mount_path, type = "file", recurse = FALSE)
      current_names <- basename(file_paths)

      current_hashes <- character(0)
      if (length(file_paths) > 0) {
        for (i in seq_along(file_paths)) {
          current_hashes[current_names[[i]]] <- self$get_file_hash(file_paths[[i]])
        }
      }

      previous_names <- names(self$file_hashes)
      new_files <- setdiff(current_names, previous_names)
      deleted_files <- setdiff(previous_names, current_names)

      common <- intersect(current_names, previous_names)
      modified_files <- common[vapply(common, function(fname) {
        !identical(unname(current_hashes[[fname]]), unname(self$file_hashes[[fname]]))
      }, logical(1))]

      private$latest_hashes <- current_hashes

      list(
        new = new_files,
        modified = modified_files,
        deleted = deleted_files
      )
    },

    sync_new_file = function(filename) {
      src <- fs::path(self$mount_path, filename)
      if (!file.exists(src)) {
        return(FALSE)
      }

      size <- file.info(src)$size
      con <- file(src, "rb")
      on.exit(close(con), add = TRUE)
      content <- if (is.na(size) || size == 0) raw(0) else readBin(con, what = "raw", n = size)

      self$vfs$add_file(filename, content, self$master_password)
      self$file_hashes[filename] <- self$get_file_hash(src)
      self$file_access_times[[filename]] <- self$get_file_access_time(src)
      TRUE
    },

    sync_modified_file = function(filename) {
      src <- fs::path(self$mount_path, filename)
      if (!file.exists(src)) {
        return(FALSE)
      }

      size <- file.info(src)$size
      con <- file(src, "rb")
      on.exit(close(con), add = TRUE)
      content <- if (is.na(size) || size == 0) raw(0) else readBin(con, what = "raw", n = size)

      self$vfs$update_file(filename, content, self$master_password)
      self$file_hashes[filename] <- self$get_file_hash(src)
      self$file_access_times[[filename]] <- self$get_file_access_time(src)
      TRUE
    },

    sync_deleted_file = function(filename) {
      self$vfs$remove_file(filename)
      if (filename %in% names(self$file_hashes)) {
        self$file_hashes <- self$file_hashes[setdiff(names(self$file_hashes), filename)]
      }
      if (!is.null(self$file_access_times[[filename]])) {
        self$file_access_times[[filename]] <- NULL
      }
      TRUE
    },

    detect_reads = function(ignore_files = character(0)) {
      file_paths <- fs::dir_ls(self$mount_path, type = "file", recurse = FALSE)
      if (length(file_paths) == 0) {
        self$file_access_times <- list()
        return(character(0))
      }

      reads <- character(0)
      current_names <- basename(file_paths)
      keep_names <- current_names

      for (i in seq_along(file_paths)) {
        fpath <- file_paths[[i]]
        fname <- current_names[[i]]

        access_now <- self$get_file_access_time(fpath)
        previous <- self$file_access_times[[fname]]

        if (is.null(previous)) {
          self$file_access_times[[fname]] <- access_now
          next
        }

        if (fname %in% ignore_files) {
          self$file_access_times[[fname]] <- access_now
          next
        }

        if (!is.na(access_now) && !is.na(previous) && isTRUE(access_now > previous)) {
          if (isTRUE(self$vfs$file_exists(fname))) {
            reads <- c(reads, fname)
          }
        }

        self$file_access_times[[fname]] <- access_now
      }

      stale <- setdiff(names(self$file_access_times), keep_names)
      if (length(stale) > 0) {
        for (fname in stale) {
          self$file_access_times[[fname]] <- NULL
        }
      }

      unique(reads)
    },

    sync_all = function() {
      changes <- self$scan_changes()

      for (fname in changes$new) {
        try(self$sync_new_file(fname), silent = TRUE)
      }

      for (fname in changes$modified) {
        try(self$sync_modified_file(fname), silent = TRUE)
      }

      for (fname in changes$deleted) {
        try(self$sync_deleted_file(fname), silent = TRUE)
      }

      ignore_reads <- unique(c(changes$new, changes$modified))
      read_events <- self$detect_reads(ignore_files = ignore_reads)

      self$last_scan <- Sys.time()
      changes$read <- read_events
      changes
    },

    clear_mount = function() {
      if (!fs::dir_exists(self$mount_path)) {
        return(TRUE)
      }

      if (exists("SecureWiper", inherits = TRUE)) {
        wiper <- SecureWiper$new()
        wiper$wipe_directory(self$mount_path)
      } else {
        files <- fs::dir_ls(self$mount_path, recurse = TRUE, type = "file")
        if (length(files) > 0) {
          unlink(files)
        }
      }

      self$file_hashes <- character(0)
      self$file_access_times <- list()
      TRUE
    },

    remove_from_mount = function(filename) {
      target <- fs::path(self$mount_path, filename)
      if (!file.exists(target)) {
        return(FALSE)
      }

      if (exists("SecureWiper", inherits = TRUE)) {
        wiper <- SecureWiper$new()
        wiper$wipe_file(target)
      } else {
        unlink(target)
      }

      if (filename %in% names(self$file_hashes)) {
        self$file_hashes <- self$file_hashes[setdiff(names(self$file_hashes), filename)]
      }
      if (!is.null(self$file_access_times[[filename]])) {
        self$file_access_times[[filename]] <- NULL
      }

      TRUE
    },

    get_file_hash = function(filepath) {
      if (!file.exists(filepath)) {
        return(NA_character_)
      }
      digest::digest(file = filepath, algo = "sha256")
    },

    get_file_access_time = function(filepath) {
      if (!file.exists(filepath)) {
        return(NA_real_)
      }
      info <- file.info(filepath)
      atime <- info$atime
      if (is.null(atime) || is.na(atime)) {
        return(NA_real_)
      }
      as.numeric(as.POSIXct(atime, tz = "UTC"))
    }
  ),
  private = list(
    latest_hashes = character(0)
  )
)

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}
