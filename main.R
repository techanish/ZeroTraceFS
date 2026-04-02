source("setup.R")
source(file.path("R", "encryption.R"))
source(file.path("R", "key_derivation.R"))
source(file.path("R", "auth.R"))
source(file.path("R", "filesystem.R"))
source(file.path("R", "sync.R"))
source(file.path("R", "triggers.R"))
source(file.path("R", "wipe.R"))
source(file.path("R", "audit.R"))
source(file.path("R", "container.R"))
source(file.path("R", "ui.R"))

if (!exists("%||%", mode = "function")) {
  `%||%` <- function(x, y) {
    if (is.null(x)) y else x
  }
}

run_zerotracefs <- function() {
  paths <- run_setup(".")
  display_banner()

  wiper <- SecureWiper$new()
  container_manager <- ContainerManager$new(paths$container_path)
  vfs <- VirtualFileSystem$new()
  auth <- AuthManager$new(max_attempts = 5L)
  trigger_engine <- TriggerEngine$new()
  audit <- AuditLogger$new()

  master_password <- NULL
  sync_engine <- NULL
  control_mode <- "explorer"
  last_external_action <- NA_character_
  last_external_error <- NA_character_
  opened_temp_files <- list()

  apply_trigger_actions <- function() {
    results <- trigger_engine$check_all(vfs)

    if (isTRUE(results$global$triggered)) {
      audit$log_event("TRIGGER_FIRE", sprintf("Global trigger fired: %s", results$global$reason), NA_character_)
      cli::cli_alert_danger(sprintf("GLOBAL TRIGGER: %s -> DESTROYING ENTIRE VAULT", results$global$reason))

      for (fname in vfs$get_all_filenames()) {
        entry <- vfs$files[[fname]]
        vfs$files[[fname]] <- wiper$destroy_crypto_artifacts(entry)
      }
      vfs$files <- list()

      wipe_result <- wiper$full_system_wipe(paths$mount_path, paths$container_path)
      audit$log_event("WIPE_COMPLETE", sprintf("Global wipe complete. mount=%s container=%s", wipe_result$mount_wiped, wipe_result$container_wiped), NA_character_)
      cat(crayon::yellow("Vault is empty\n"))
      return(TRUE)
    }

    if (length(results$files) > 0) {
      for (item in results$files) {
        fname <- item$filename
        if (!vfs$file_exists(fname)) {
          next
        }

        audit$log_event("TRIGGER_FIRE", sprintf("%s", item$reason), fname)
        cli::cli_alert_warning(sprintf("TRIGGER: %s for %s -> DESTROYING", item$reason, fname))

        if (!is.null(sync_engine)) {
          try(sync_engine$remove_from_mount(fname), silent = TRUE)
        }

        entry <- vfs$files[[fname]]
        vfs$files[[fname]] <- wiper$destroy_crypto_artifacts(entry)
        vfs$remove_file(fname)
        audit$log_event("DESTRUCTION", sprintf("Destroyed due to trigger: %s", item$reason), fname)
      }
    }

    FALSE
  }

  destroy_single_file <- function(filename, reason = "Manual destroy") {
    if (!vfs$file_exists(filename)) {
      cli::cli_alert_warning(sprintf("File not found in vault: %s", filename))
      return(FALSE)
    }

    if (!is.null(sync_engine)) {
      try(sync_engine$remove_from_mount(filename), silent = TRUE)
    }

    entry <- vfs$files[[filename]]
    vfs$files[[filename]] <- wiper$destroy_crypto_artifacts(entry)
    vfs$remove_file(filename)
    audit$log_event("DESTRUCTION", reason, filename)
    cli::cli_alert_success(sprintf("Secure wipe complete: %s", filename))
    TRUE
  }

  save_everything <- function() {
    container_manager$save_state(vfs, auth, trigger_engine, audit)
  }

  data_frame_to_rows <- function(df) {
    if (is.null(df) || nrow(df) == 0) {
      return(list())
    }
    lapply(seq_len(nrow(df)), function(i) {
      as.list(df[i, , drop = FALSE])
    })
  }

  build_runtime_snapshot <- function() {
    now <- Sys.time()
    file_names <- vfs$get_all_filenames()
    uptime_seconds <- as.numeric(difftime(now, trigger_engine$system_start_time, units = "secs"))

    global_ttl_remaining <- if (is.null(trigger_engine$global_ttl_seconds)) {
      NA_real_
    } else {
      as.numeric(trigger_engine$global_ttl_seconds - uptime_seconds)
    }

    deadman_remaining <- if (is.null(trigger_engine$dead_man_switch_interval)) {
      NA_real_
    } else {
      as.numeric(trigger_engine$dead_man_switch_interval - as.numeric(difftime(now, trigger_engine$last_heartbeat, units = "secs")))
    }

    pending_commands <- tryCatch({
      length(fs::dir_ls(paths$commands_path, recurse = FALSE, type = "file", glob = "*.json"))
    }, error = function(e) {
      0L
    })

    list(
      timestamp = format(now, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      control_mode = control_mode,
      system = list(
        uptime_seconds = uptime_seconds,
        last_sync = if (is.null(sync_engine)) NA_character_ else as.character(sync_engine$last_scan)
      ),
      files = list(
        count = length(file_names),
        names = file_names
      ),
      auth = list(
        failed_attempts = as.integer(auth$failed_attempts),
        max_attempts = as.integer(auth$max_attempts),
        remaining_attempts = as.integer(auth$get_remaining_attempts())
      ),
      triggers = list(
        global_ttl_seconds = if (is.null(trigger_engine$global_ttl_seconds)) NA_real_ else as.numeric(trigger_engine$global_ttl_seconds),
        global_ttl_remaining_seconds = global_ttl_remaining,
        dead_man_switch_interval_seconds = if (is.null(trigger_engine$dead_man_switch_interval)) NA_real_ else as.numeric(trigger_engine$dead_man_switch_interval),
        dead_man_remaining_seconds = deadman_remaining,
        last_heartbeat = as.character(trigger_engine$last_heartbeat)
      ),
      external_commands = list(
        pending = as.integer(pending_commands),
        last_action = last_external_action,
        last_error = last_external_error
      )
    )
  }

  write_runtime_status <- function() {
    status_file <- fs::path(paths$control_path, "status.json")
    snapshot <- build_runtime_snapshot()
    jsonlite::write_json(snapshot, status_file, auto_unbox = TRUE, pretty = TRUE, null = "null")
    invisible(status_file)
  }

  safe_read_file_raw <- function(path) {
    size <- file.info(path)$size
    con <- file(path, "rb")
    on.exit(close(con), add = TRUE)
    if (is.na(size) || size <= 0) {
      return(raw(0))
    }
    readBin(con, what = "raw", n = size)
  }

  sanitize_payload <- function(payload) {
    if (is.null(payload)) {
      return(NULL)
    }

    if (!is.list(payload)) {
      return(payload)
    }

    sanitized <- payload
    secret_keys <- c("password", "master_password", "passphrase", "secret")
    payload_names <- names(sanitized)

    if (!is.null(payload_names)) {
      for (nm in payload_names) {
        if (tolower(nm) %in% secret_keys) {
          sanitized[[nm]] <- "<redacted>"
        }
      }
    }

    sanitized
  }

  ensure_vault_file <- function(filename) {
    fname <- basename(filename)
    if (isTRUE(vfs$file_exists(fname))) {
      return(TRUE)
    }

    mount_candidate <- fs::path(paths$mount_path, fname)
    if (!file.exists(mount_candidate)) {
      return(FALSE)
    }

    synced <- tryCatch(sync_engine$sync_new_file(fname), error = function(e) FALSE)
    if (isTRUE(synced) && isTRUE(vfs$file_exists(fname))) {
      audit$log_event("FILE_CREATE", "Auto-synced file from mount for Explorer command", fname)
      return(TRUE)
    }

    FALSE
  }

  register_temp_open_file <- function(path, ttl_seconds = 120L) {
    expires <- as.numeric(Sys.time()) + as.numeric(ttl_seconds)
    opened_temp_files[[as.character(path)]] <<- expires
    invisible(TRUE)
  }

  cleanup_temp_open_files <- function(force = FALSE) {
    if (length(opened_temp_files) == 0) {
      return(invisible(FALSE))
    }

    now_value <- as.numeric(Sys.time())
    candidates <- names(opened_temp_files)
    if (length(candidates) == 0) {
      return(invisible(FALSE))
    }

    for (path in candidates) {
      expiry <- opened_temp_files[[path]]
      should_cleanup <- isTRUE(force) || is.null(expiry) || is.na(expiry) || (now_value >= as.numeric(expiry))
      if (!isTRUE(should_cleanup)) {
        next
      }

      if (file.exists(path)) {
        try({
          wiper$wipe_file(path)
        }, silent = TRUE)
        try(unlink(path, force = TRUE), silent = TRUE)
      }

      opened_temp_files[[path]] <<- NULL
    }

    invisible(TRUE)
  }

  open_temp_file_with_default_app <- function(filename, content_raw, keep_seconds = 120L) {
    temp_dir <- fs::path(paths$control_path, "open_temp")
    if (!dir.exists(temp_dir)) {
      dir.create(temp_dir, recursive = TRUE, showWarnings = FALSE)
    }

    suffix <- substr(digest::digest(paste0(filename, Sys.time(), runif(1)), algo = "sha256", serialize = FALSE), 1, 8)
    temp_name <- sprintf("%s_%s", suffix, basename(filename))
    temp_path <- fs::path(temp_dir, temp_name)

    con <- file(temp_path, "wb")
    writeBin(content_raw, con)
    close(con)

    register_temp_open_file(temp_path, ttl_seconds = keep_seconds)

    opened <- tryCatch({
      if (.Platform$OS.type == "windows") {
        shell.exec(normalizePath(temp_path, winslash = "\\", mustWork = FALSE))
      } else {
        utils::browseURL(sprintf("file://%s", normalizePath(temp_path, mustWork = FALSE)))
      }
      TRUE
    }, error = function(e) {
      FALSE
    })

    list(
      opened = opened,
      path = as.character(temp_path),
      expires_in_seconds = as.integer(keep_seconds)
    )
  }

  resolve_vault_filename <- function(target) {
    if (is.null(target) || !nzchar(as.character(target))) {
      stop("Missing file target.")
    }
    basename(as.character(target))
  }

  archive_command_result <- function(command_file, payload, status, message, result_data = NULL) {
    stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
    key <- digest::digest(paste0(command_file, Sys.time(), runif(1)), algo = "sha256", serialize = FALSE)
    out_name <- sprintf("%s_%s_%s.json", stamp, substr(key, 1, 8), status)
    out_path <- fs::path(paths$processed_commands_path, out_name)

    result <- list(
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      source_file = basename(command_file),
      status = status,
      message = message,
      payload = sanitize_payload(payload),
      data = result_data
    )

    jsonlite::write_json(result, out_path, auto_unbox = TRUE, pretty = TRUE, null = "null")
    unlink(command_file, force = TRUE)
    invisible(out_path)
  }

  process_external_commands <- function() {
    command_files <- fs::dir_ls(paths$commands_path, recurse = FALSE, type = "file", glob = "*.json")
    if (length(command_files) == 0) {
      return(list(stop = FALSE))
    }

    command_files <- sort(as.character(command_files))
    stop_requested <- FALSE

    for (command_file in command_files) {
      payload <- NULL
      tryCatch({
        payload <- jsonlite::fromJSON(command_file, simplifyVector = TRUE)
        action <- tolower(trimws(as.character(payload$action %||% "")))

        if (!nzchar(action)) {
          stop("Command payload must include a non-empty 'action'.")
        }

        last_external_action <<- action
        last_external_error <<- NA_character_

        if (identical(action, "status")) {
          snapshot <- build_runtime_snapshot()
          archive_command_result(command_file, payload, "ok", "Status captured", snapshot)
          cli::cli_alert_info("Explorer command applied: status")
        } else if (identical(action, "list")) {
          listing <- vfs$list_files()
          data <- list(
            count = nrow(listing),
            files = data_frame_to_rows(listing)
          )
          archive_command_result(command_file, payload, "ok", sprintf("Listed %d file(s)", nrow(listing)), data)
          cli::cli_alert_info(sprintf("Explorer command applied: list (%d)", nrow(listing)))
        } else if (identical(action, "audit")) {
          n_recent <- suppressWarnings(as.integer(payload$recent %||% payload$n %||% 20L))
          if (is.na(n_recent) || n_recent < 1) {
            n_recent <- 20L
          }
          recent <- audit$get_recent(n_recent)
          data <- list(
            count = nrow(recent),
            entries = data_frame_to_rows(recent)
          )
          archive_command_result(command_file, payload, "ok", sprintf("Fetched %d audit entries", nrow(recent)), data)
          cli::cli_alert_info(sprintf("Explorer command applied: audit (%d)", nrow(recent)))
        } else if (identical(action, "read")) {
          filename <- resolve_vault_filename(payload$target %||% payload$filename)
          if (!isTRUE(ensure_vault_file(filename))) {
            stop(sprintf("File not found in vault: %s", filename))
          }

          content <- vfs$read_file(filename, master_password)
          text_preview <- tryCatch(rawToChar(content), error = function(e) NULL)
          is_text <- !is.null(text_preview) && !grepl("[^[:print:]\r\n\t]", text_preview)

          preview <- if (is_text) {
            substr(text_preview, 1, 2000)
          } else {
            paste(head(as.character(content), 128), collapse = " ")
          }

          data <- list(
            filename = filename,
            bytes = as.integer(length(content)),
            preview_type = if (is_text) "text" else "hex",
            preview = preview
          )

          audit$log_event("FILE_READ", "File read via Explorer", filename)
          archive_command_result(command_file, payload, "ok", sprintf("Read %s", filename), data)
          cli::cli_alert_info(sprintf("Explorer command applied: read %s", filename))

          apply_trigger_actions()
        } else if (identical(action, "export")) {
          filename <- resolve_vault_filename(payload$target %||% payload$filename)
          if (!isTRUE(ensure_vault_file(filename))) {
            stop(sprintf("File not found in vault: %s", filename))
          }

          destination <- as.character(payload$destination %||% payload$dest %||% payload$output %||% "")
          if (!nzchar(destination)) {
            destination <- fs::path(paths$control_path, "exports")
          }

          content <- vfs$peek_file(filename, master_password)
          export_path <- if (dir.exists(destination)) fs::path(destination, filename) else destination
          parent_dir <- dirname(export_path)
          if (!dir.exists(parent_dir)) {
            dir.create(parent_dir, recursive = TRUE, showWarnings = FALSE)
          }

          con <- file(export_path, "wb")
          writeBin(content, con)
          close(con)

          audit$log_event("FILE_READ", sprintf("Exported via Explorer to %s", export_path), filename)
          data <- list(filename = filename, export_path = as.character(export_path), bytes = as.integer(length(content)))
          archive_command_result(command_file, payload, "ok", sprintf("Exported %s", filename), data)
          cli::cli_alert_success(sprintf("Explorer command applied: export %s", filename))

        } else if (identical(action, "open-secure")) {
          filename <- resolve_vault_filename(payload$target %||% payload$filename)
          if (!isTRUE(ensure_vault_file(filename))) {
            stop(sprintf("File not found in vault: %s", filename))
          }

          entered_password <- as.character(payload$password %||% "")
          if (!nzchar(entered_password)) {
            stop("open-secure requires a password.")
          }

          auth_result <- auth$authenticate(entered_password)
          if (identical(auth_result, "duress")) {
            audit$log_event("AUTH_DURESS", "Duress password used in open-secure", filename)
            save_everything()
            wiper$full_system_wipe(paths$mount_path, paths$container_path)
            archive_command_result(command_file, payload, "ok", "Duress password accepted. Vault destroyed.")
            stop_requested <- TRUE
            next
          }

          if (identical(auth_result, "lockout")) {
            audit$log_event("AUTH_FAIL", "Authentication lockout reached via open-secure", filename)
            save_everything()
            wiper$full_system_wipe(paths$mount_path, paths$container_path)
            archive_command_result(command_file, payload, "ok", "Authentication lockout reached. Vault destroyed.")
            stop_requested <- TRUE
            next
          }

          if (!identical(auth_result, "granted")) {
            save_everything()
            stop(sprintf("Invalid password. %d attempts remaining.", auth$get_remaining_attempts()))
          }

          content <- vfs$read_file(filename, master_password)
          open_result <- open_temp_file_with_default_app(filename, content, keep_seconds = 180L)
          audit$log_event("FILE_READ", "Opened securely from Explorer with password", filename)

          archive_command_result(
            command_file,
            payload,
            "ok",
            sprintf("Opened securely: %s", filename),
            list(
              filename = filename,
              temporary_path = open_result$path,
              opened = isTRUE(open_result$opened),
              expires_in_seconds = open_result$expires_in_seconds
            )
          )
          cli::cli_alert_success(sprintf("Explorer command applied: open-secure %s", filename))

          apply_trigger_actions()

        } else if (identical(action, "set-ttl")) {
          filename <- resolve_vault_filename(payload$target %||% payload$filename)
          minutes <- suppressWarnings(as.numeric(payload$minutes %||% payload$value))
          if (is.na(minutes) || minutes <= 0) {
            stop("set-ttl requires a positive 'minutes' value.")
          }
          if (!isTRUE(ensure_vault_file(filename))) {
            stop(sprintf("File not found in vault: %s", filename))
          }

          vfs$set_trigger(filename, "ttl_seconds", minutes * 60)
          audit$log_event("TRIGGER_SET", sprintf("Set TTL to %.2f minutes via Explorer", minutes), filename)
          archive_command_result(command_file, payload, "ok", sprintf("TTL set for %s", filename))
          cli::cli_alert_success(sprintf("Explorer command applied: set-ttl %s %.2f", filename, minutes))
        } else if (identical(action, "set-reads")) {
          filename <- resolve_vault_filename(payload$target %||% payload$filename)
          max_reads <- suppressWarnings(as.integer(payload$max_reads %||% payload$value))
          if (is.na(max_reads) || max_reads < 1) {
            stop("set-reads requires integer 'max_reads' >= 1.")
          }
          if (!isTRUE(ensure_vault_file(filename))) {
            stop(sprintf("File not found in vault: %s", filename))
          }

          vfs$set_trigger(filename, "max_reads", max_reads)
          audit$log_event("TRIGGER_SET", sprintf("Set max reads to %d via Explorer", max_reads), filename)
          archive_command_result(command_file, payload, "ok", sprintf("Read limit set for %s", filename))
          cli::cli_alert_success(sprintf("Explorer command applied: set-reads %s %d", filename, max_reads))
        } else if (identical(action, "set-deadline")) {
          filename <- resolve_vault_filename(payload$target %||% payload$filename)
          deadline_text <- as.character(payload$deadline %||% payload$value %||% "")
          deadline <- as.POSIXct(deadline_text, tz = "UTC")
          if (is.na(deadline)) {
            deadline <- as.POSIXct(deadline_text)
          }
          if (is.na(deadline)) {
            stop("set-deadline requires parseable 'deadline' datetime.")
          }
          if (!isTRUE(ensure_vault_file(filename))) {
            stop(sprintf("File not found in vault: %s", filename))
          }

          vfs$set_trigger(filename, "deadline", deadline)
          audit$log_event("TRIGGER_SET", sprintf("Set deadline to %s via Explorer", as.character(deadline)), filename)
          archive_command_result(command_file, payload, "ok", sprintf("Deadline set for %s", filename))
          cli::cli_alert_success(sprintf("Explorer command applied: set-deadline %s", filename))
        } else if (identical(action, "destroy")) {
          filename <- resolve_vault_filename(payload$target %||% payload$filename)
          if (!isTRUE(ensure_vault_file(filename))) {
            stop(sprintf("File not found in vault: %s", filename))
          }
          ok <- destroy_single_file(filename, reason = "Manual file destruction via Explorer")
          if (!isTRUE(ok)) {
            stop(sprintf("Destroy failed for %s", filename))
          }
          archive_command_result(command_file, payload, "ok", sprintf("Destroyed %s", filename))
          cli::cli_alert_warning(sprintf("Explorer command applied: destroy %s", filename))
        } else if (identical(action, "destroy-all")) {
          audit$log_event("DESTRUCTION", "Manual full vault destruction via Explorer", NA_character_)
          for (fname in vfs$get_all_filenames()) {
            entry <- vfs$files[[fname]]
            vfs$files[[fname]] <- wiper$destroy_crypto_artifacts(entry)
          }
          vfs$files <- list()
          cleanup_temp_open_files(force = TRUE)
          wiper$full_system_wipe(paths$mount_path, paths$container_path)
          archive_command_result(command_file, payload, "ok", "Full vault destruction complete")
          cli::cli_alert_danger("Explorer command applied: destroy-all")
          stop_requested <- TRUE
        } else if (identical(action, "import")) {
          source_path <- as.character(payload$source %||% payload$path %||% payload$target %||% "")
          if (!nzchar(source_path) || !file.exists(source_path)) {
            stop("import requires an existing file path in 'source' or 'path'.")
          }

          content <- safe_read_file_raw(source_path)
          filename <- basename(source_path)
          vfs$add_file(filename, content, master_password)
          mount_target <- fs::path(paths$mount_path, filename)
          con <- file(mount_target, "wb")
          writeBin(content, con)
          close(con)
          sync_engine$file_hashes[filename] <- sync_engine$get_file_hash(mount_target)

          audit$log_event("FILE_CREATE", "Imported file into vault via Explorer", filename)
          archive_command_result(command_file, payload, "ok", sprintf("Imported %s", filename))
          cli::cli_alert_success(sprintf("Explorer command applied: import %s", filename))
        } else if (identical(action, "lock")) {
          cleanup_temp_open_files(force = TRUE)
          sync_engine$clear_mount()
          audit$log_event("SYSTEM_STOP", "Vault locked via Explorer", NA_character_)
          save_everything()
          archive_command_result(command_file, payload, "ok", "Vault locked")
          cli::cli_alert_success("Explorer command applied: lock")
          stop_requested <- TRUE
        } else if (identical(action, "quit")) {
          audit$log_event("SYSTEM_STOP", "Secure shutdown requested via Explorer", NA_character_)
          save_everything()
          cleanup_temp_open_files(force = TRUE)
          sync_engine$clear_mount()
          archive_command_result(command_file, payload, "ok", "Secure shutdown complete")
          cli::cli_alert_success("Explorer command applied: quit")
          stop_requested <- TRUE
        } else {
          stop(sprintf("Unknown action: %s", action))
        }
      }, error = function(e) {
        last_external_error <<- e$message
        archive_command_result(command_file, payload, "error", e$message)
        cli::cli_alert_danger(sprintf("Explorer command failed: %s", e$message))
      })

      if (isTRUE(stop_requested)) {
        break
      }
    }

    list(stop = stop_requested)
  }

  on.exit({
    try(cleanup_temp_open_files(force = TRUE), silent = TRUE)
    if (!is.null(sync_engine)) {
      try(sync_engine$clear_mount(), silent = TRUE)
    }
    try(wiper$wipe_memory_object("master_password", environment()), silent = TRUE)
  }, add = TRUE)

  if (!container_manager$container_exists()) {
    answer <- tolower(trimws(prompt_input("No existing vault found. Create new vault? (y/n): ")))
    if (!(answer %in% c("y", "yes"))) {
      cat("Vault creation cancelled.\n")
      return(invisible(FALSE))
    }

    repeat {
      master_password <- prompt_password("Set master password: ")
      confirm <- prompt_password("Confirm master password: ")
      if (!nzchar(master_password)) {
        cli::cli_alert_warning("Master password cannot be empty.")
        next
      }
      if (!identical(master_password, confirm)) {
        cli::cli_alert_warning("Passwords do not match. Try again.")
        next
      }
      break
    }

    repeat {
      duress_password <- prompt_password("Set duress password (triggers full destruction): ")
      if (!nzchar(duress_password)) {
        cli::cli_alert_warning("Duress password cannot be empty.")
        next
      }
      if (identical(duress_password, master_password)) {
        cli::cli_alert_warning("Duress password must be different from master password.")
        next
      }
      break
    }

    dead_man_hours <- suppressWarnings(as.numeric(prompt_input("Set dead man's switch interval in hours (0 to disable): ")))
    if (is.na(dead_man_hours) || dead_man_hours < 0) {
      dead_man_hours <- 0
    }

    global_ttl_hours <- suppressWarnings(as.numeric(prompt_input("Set global vault TTL in hours (0 for no limit): ")))
    if (is.na(global_ttl_hours) || global_ttl_hours < 0) {
      global_ttl_hours <- 0
    }

    auth$setup(master_password, duress_password)
    trigger_engine$set_dead_man_switch(dead_man_hours * 3600)
    trigger_engine$set_global_ttl(global_ttl_hours * 3600)

    audit$log_event("SYSTEM_START", "New vault initialized", NA_character_)
    save_everything()
    cli::cli_alert_success("Vault initialized and saved to data/container.rds")
  } else {
    state <- container_manager$load_state(paths$container_path)
    vfs$deserialize(state$vfs_data)
    auth$deserialize(state$auth_data)
    trigger_engine$deserialize(state$trigger_data)
    audit$deserialize(state$audit_data)

    repeat {
      candidate <- prompt_password("Enter vault password: ")
      auth_result <- auth$authenticate(candidate)

      if (identical(auth_result, "granted")) {
        master_password <- candidate
        audit$log_event("AUTH_SUCCESS", "Vault unlocked successfully", NA_character_)
        break
      }

      if (identical(auth_result, "duress")) {
        audit$log_event("AUTH_DURESS", "Duress password accepted", NA_character_)
        save_everything()
        wiper$full_system_wipe(paths$mount_path, paths$container_path)
        cat(crayon::yellow("Vault is empty\n"))
        return(invisible(FALSE))
      }

      if (identical(auth_result, "lockout")) {
        audit$log_event("AUTH_FAIL", "Authentication lockout reached", NA_character_)
        save_everything()
        wiper$full_system_wipe(paths$mount_path, paths$container_path)
        cat(crayon::yellow("Vault is empty\n"))
        return(invisible(FALSE))
      }

      audit$log_event("AUTH_FAIL", "Incorrect password", NA_character_)
      save_everything()
      cli::cli_alert_danger(sprintf("Wrong password. %d attempts remaining.", auth$get_remaining_attempts()))
    }
  }

  sync_engine <- SyncEngine$new(
    mount_path = paths$mount_path,
    vfs = vfs,
    master_password = master_password,
    encryption = EncryptionEngine$new()
  )

  sync_engine$clear_mount()
  sync_engine$populate_mount()

  cli::cli_alert_success("Vault mounted. Monitoring mount/ every cycle.")
  cli::cli_alert_info(sprintf("Explorer command inbox: %s", paths$commands_path))
  cli::cli_alert_info(sprintf("Explorer command results: %s", paths$processed_commands_path))

  mode_env <- tolower(trimws(Sys.getenv("ZTFS_CONTROL_MODE", unset = "")))
  control_mode <- if (mode_env %in% c("terminal", "t", "1")) "terminal" else "explorer"
  cli::cli_alert_info(sprintf("Control mode active: %s", control_mode))
  if (identical(control_mode, "explorer")) {
    cli::cli_alert_info("Set ZTFS_CONTROL_MODE=terminal before launch if you want typed terminal commands.")
  }

  write_runtime_status()

  cycle_counter <- 0L

  repeat {
    cycle_counter <- cycle_counter + 1L
    changes <- sync_engine$sync_all()
    trigger_engine$update_heartbeat()
    cleanup_temp_open_files(force = FALSE)

    external_cmd_result <- process_external_commands()
    if (isTRUE(external_cmd_result$stop)) {
      break
    }

    if (length(changes$new) > 0) {
      for (fname in changes$new) {
        fpath <- fs::path(paths$mount_path, fname)
        fsize <- if (file.exists(fpath)) file.info(fpath)$size else NA_real_
        cli::cli_alert_success(sprintf("File encrypted: %s (%s bytes, AES-256-CBC)", fname, ifelse(is.na(fsize), "0", as.character(as.integer(fsize)))))
        audit$log_event("FILE_CREATE", "File added and encrypted", fname)
      }
    }

    if (length(changes$modified) > 0) {
      for (fname in changes$modified) {
        cli::cli_alert_info(sprintf("File updated and re-encrypted: %s", fname))
        audit$log_event("FILE_MODIFY", "File modified and re-encrypted", fname)
      }
    }

    if (length(changes$deleted) > 0) {
      for (fname in changes$deleted) {
        cli::cli_alert_warning(sprintf("File deleted from mount and removed from vault: %s", fname))
        audit$log_event("FILE_DELETE", "File deleted from mount", fname)
      }
    }

    if (!is.null(changes$read) && length(changes$read) > 0) {
      for (fname in changes$read) {
        if (isTRUE(vfs$note_file_read(fname))) {
          cli::cli_alert_info(sprintf("Read detected from mount open: %s", fname))
          audit$log_event("FILE_READ", "Read detected from mount access", fname)
        }
      }
    }

    global_wipe_done <- apply_trigger_actions()
    if (isTRUE(global_wipe_done)) {
      break
    }

    save_everything()
    write_runtime_status()

    if (identical(control_mode, "explorer")) {
      if ((cycle_counter %% 5L) == 0L) {
        display_status(vfs, trigger_engine, auth, last_sync = sync_engine$last_scan)
      }
      Sys.sleep(3)
      next
    }

    display_status(vfs, trigger_engine, auth, last_sync = sync_engine$last_scan)
    display_menu()

    cat("\n")
    cmd <- trimws(readline("Command (or press Enter to continue monitoring): "))
    if (!nzchar(cmd)) {
      Sys.sleep(3)
      next
    }

    parts <- strsplit(cmd, "\\s+")[[1]]
    action <- tolower(parts[1])

    if (identical(action, "status")) {
      display_status(vfs, trigger_engine, auth, last_sync = sync_engine$last_scan)
    } else if (identical(action, "list")) {
      display_file_list(vfs)
    } else if (identical(action, "add")) {
      filepath <- trimws(sub("^add\\s+", "", cmd, ignore.case = TRUE))
      if (!nzchar(filepath) || !file.exists(filepath)) {
        cli::cli_alert_warning("Usage: add <filepath>")
      } else {
        content <- safe_read_file_raw(filepath)
        fname <- basename(filepath)
        vfs$add_file(fname, content, master_password)
        out_path <- fs::path(paths$mount_path, fname)
        con <- file(out_path, "wb")
        writeBin(content, con)
        close(con)
        sync_engine$file_hashes[fname] <- sync_engine$get_file_hash(out_path)
        audit$log_event("FILE_CREATE", "Imported file into vault", fname)
        cli::cli_alert_success(sprintf("Imported: %s", fname))
      }
    } else if (identical(action, "read")) {
      filename <- trimws(sub("^read\\s+", "", cmd, ignore.case = TRUE))
      if (!nzchar(filename) || !vfs$file_exists(filename)) {
        cli::cli_alert_warning("Usage: read <filename>")
      } else {
        content <- vfs$read_file(filename, master_password)
        text_preview <- tryCatch(rawToChar(content), error = function(e) NULL)
        cat("\n--- FILE CONTENT START ---\n")
        if (is.null(text_preview) || grepl("[^[:print:]\r\n\t]", text_preview)) {
          cat(sprintf("Binary content (%d bytes). Hex preview: %s\n", length(content), paste(head(as.character(content), 32), collapse = " ")))
        } else {
          cat(text_preview, "\n")
        }
        cat("--- FILE CONTENT END ---\n")
        audit$log_event("FILE_READ", "File read command executed", filename)
        apply_trigger_actions()
      }
    } else if (identical(action, "set-ttl")) {
      if (length(parts) < 3) {
        cli::cli_alert_warning("Usage: set-ttl <filename> <minutes>")
      } else {
        filename <- parts[2]
        minutes <- suppressWarnings(as.numeric(parts[3]))
        if (is.na(minutes) || minutes <= 0) {
          cli::cli_alert_warning("Minutes must be greater than 0.")
        } else {
          vfs$set_trigger(filename, "ttl_seconds", minutes * 60)
          audit$log_event("TRIGGER_SET", sprintf("Set TTL to %.2f minutes", minutes), filename)
          cli::cli_alert_success(sprintf("TTL set for %s", filename))
        }
      }
    } else if (identical(action, "set-reads")) {
      if (length(parts) < 3) {
        cli::cli_alert_warning("Usage: set-reads <filename> <max>")
      } else {
        filename <- parts[2]
        max_reads <- suppressWarnings(as.integer(parts[3]))
        if (is.na(max_reads) || max_reads < 1) {
          cli::cli_alert_warning("Max reads must be >= 1.")
        } else {
          vfs$set_trigger(filename, "max_reads", max_reads)
          audit$log_event("TRIGGER_SET", sprintf("Set max reads to %d", max_reads), filename)
          cli::cli_alert_success(sprintf("Read limit set for %s", filename))
        }
      }
    } else if (identical(action, "set-deadline")) {
      if (length(parts) < 4) {
        cli::cli_alert_warning("Usage: set-deadline <filename> <YYYY-mm-dd HH:MM:SS>")
      } else {
        filename <- parts[2]
        dt_string <- paste(parts[-c(1, 2)], collapse = " ")
        deadline <- as.POSIXct(dt_string, tz = "UTC")
        if (is.na(deadline)) {
          deadline <- as.POSIXct(dt_string)
        }
        if (is.na(deadline)) {
          cli::cli_alert_warning("Could not parse datetime.")
        } else {
          vfs$set_trigger(filename, "deadline", deadline)
          audit$log_event("TRIGGER_SET", sprintf("Set deadline to %s", as.character(deadline)), filename)
          cli::cli_alert_success(sprintf("Deadline set for %s", filename))
        }
      }
    } else if (identical(action, "audit")) {
      log_df <- audit$get_log()
      if (nrow(log_df) == 0) {
        cat("No audit entries yet.\n")
      } else {
        print(log_df, row.names = FALSE)
      }
    } else if (identical(action, "export")) {
      if (length(parts) < 3) {
        cli::cli_alert_warning("Usage: export <filename> <dest>")
      } else {
        filename <- parts[2]
        destination <- trimws(sub(paste0("^export\\s+", filename, "\\s+"), "", cmd, ignore.case = TRUE))
        if (!vfs$file_exists(filename) || !nzchar(destination)) {
          cli::cli_alert_warning("Usage: export <filename> <dest>")
        } else {
          content <- vfs$peek_file(filename, master_password)
          export_path <- if (dir.exists(destination)) fs::path(destination, basename(filename)) else destination
          parent_dir <- dirname(export_path)
          if (!dir.exists(parent_dir)) {
            dir.create(parent_dir, recursive = TRUE, showWarnings = FALSE)
          }
          con <- file(export_path, "wb")
          writeBin(content, con)
          close(con)
          audit$log_event("FILE_READ", sprintf("Exported to %s", export_path), filename)
          cli::cli_alert_success(sprintf("Exported %s", export_path))
        }
      }
    } else if (identical(action, "destroy")) {
      filename <- trimws(sub("^destroy\\s+", "", cmd, ignore.case = TRUE))
      if (!nzchar(filename)) {
        cli::cli_alert_warning("Usage: destroy <filename>")
      } else {
        destroy_single_file(filename, reason = "Manual file destruction")
      }
    } else if (identical(action, "destroy-all")) {
      confirm <- trimws(prompt_input("Type DESTROY to confirm full vault wipe: "))
      if (identical(confirm, "DESTROY")) {
        audit$log_event("DESTRUCTION", "Manual full vault destruction", NA_character_)
        for (fname in vfs$get_all_filenames()) {
          entry <- vfs$files[[fname]]
          vfs$files[[fname]] <- wiper$destroy_crypto_artifacts(entry)
        }
        vfs$files <- list()
        wiper$full_system_wipe(paths$mount_path, paths$container_path)
        cli::cli_alert_success("Full vault destruction complete.")
        break
      } else {
        cli::cli_alert_warning("Cancelled full destruction.")
      }
    } else if (identical(action, "lock")) {
      sync_engine$clear_mount()
      audit$log_event("SYSTEM_STOP", "Vault locked", NA_character_)
      save_everything()
      cli::cli_alert_success("Vault locked. Mount wiped, encrypted backend retained.")
      break
    } else if (identical(action, "change-password")) {
      old_pw <- prompt_password("Enter current master password: ")
      new_pw <- prompt_password("Enter new master password: ")
      confirm_pw <- prompt_password("Confirm new master password: ")

      if (!identical(new_pw, confirm_pw) || !nzchar(new_pw)) {
        cli::cli_alert_warning("New password confirmation failed.")
      } else if (!identical(digest::digest(old_pw, algo = "sha256", serialize = FALSE), auth$master_hash)) {
        cli::cli_alert_warning("Current password is incorrect.")
      } else {
        filenames <- vfs$get_all_filenames()
        decrypted <- list()
        failed <- FALSE

        for (fname in filenames) {
          plaintext <- tryCatch(vfs$peek_file(fname, old_pw), error = function(e) NULL)
          if (is.null(plaintext)) {
            failed <- TRUE
            break
          }
          decrypted[[fname]] <- plaintext
        }

        if (isTRUE(failed)) {
          cli::cli_alert_danger("Failed to re-key files. Password unchanged.")
        } else {
          for (fname in names(decrypted)) {
            vfs$update_file(fname, decrypted[[fname]], new_pw)
          }

          if (isTRUE(auth$change_password(old_pw, new_pw))) {
            master_password <- new_pw
            sync_engine$master_password <- new_pw
            sync_engine$populate_mount()
            audit$log_event("PASSWORD_CHANGE", "Master password changed successfully", NA_character_)
            cli::cli_alert_success("Master password changed and vault re-keyed.")
          } else {
            cli::cli_alert_danger("Password change failed.")
          }
        }
      }
    } else if (identical(action, "quit")) {
      audit$log_event("SYSTEM_STOP", "Secure shutdown requested", NA_character_)
      save_everything()
      sync_engine$clear_mount()
      cli::cli_alert_success("Secure shutdown complete.")
      break
    } else {
      cli::cli_alert_warning("Unknown command. Type one of the listed commands.")
    }

    save_everything()
    Sys.sleep(3)
  }

  invisible(TRUE)
}

run_zerotracefs()
