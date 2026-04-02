display_banner <- function() {
  banner <- c(
    "========================================================",
    "                ZERO TRACE FILE SYSTEM                 ",
    "                    ZeroTraceFS Vault                  ",
    "       Self-Destructing Encrypted File System          ",
    "",
    "            AES-256-CBC | Trigger-Driven Wipe          ",
    "========================================================"
  )
  cat(crayon::cyan(paste(banner, collapse = "\n")), "\n")
}

format_time_remaining <- function(seconds) {
  if (is.null(seconds) || is.na(seconds) || is.infinite(seconds)) {
    return("N/A")
  }
  if (seconds <= 0) {
    return("expired")
  }

  total <- as.integer(seconds)
  h <- total %/% 3600
  m <- (total %% 3600) %/% 60
  s <- total %% 60
  sprintf("%02dh %02dm %02ds", h, m, s)
}

color_status <- function(status) {
  status_text <- as.character(status)
  if (tolower(status_text) %in% c("ok", "healthy", "safe", "active")) {
    return(crayon::green(status_text))
  }
  if (tolower(status_text) %in% c("warning", "degraded", "caution")) {
    return(crayon::yellow(status_text))
  }
  crayon::red(status_text)
}

display_status <- function(vfs, triggers, auth, last_sync = NULL) {
  now <- Sys.time()
  file_count <- length(vfs$get_all_filenames())
  uptime_seconds <- as.numeric(difftime(now, triggers$system_start_time, units = "secs"))

  if (!is.null(triggers$global_ttl_seconds)) {
    ttl_remaining <- triggers$global_ttl_seconds - uptime_seconds
    ttl_status <- if (ttl_remaining > 300) "ok" else if (ttl_remaining > 0) "warning" else "critical"
    ttl_text <- sprintf("%s (%s)", format_time_remaining(ttl_remaining), color_status(ttl_status))
  } else {
    ttl_text <- "Disabled"
  }

  if (!is.null(triggers$dead_man_switch_interval)) {
    deadman_remaining <- triggers$dead_man_switch_interval -
      as.numeric(difftime(now, triggers$last_heartbeat, units = "secs"))
    deadman_status <- if (deadman_remaining > 60) "active" else if (deadman_remaining > 0) "warning" else "critical"
    deadman_text <- sprintf("%s (%s)", format_time_remaining(deadman_remaining), color_status(deadman_status))
  } else {
    deadman_text <- "Disabled"
  }

  cli::cli_h2("Vault Status Dashboard")
  cat(sprintf("Files in vault:           %d\n", file_count))
  cat(sprintf("Global TTL remaining:     %s\n", ttl_text))
  cat(sprintf("Dead man's switch:        %s\n", deadman_text))
  cat(sprintf("Failed auth attempts:     %d / %d\n", auth$failed_attempts, auth$max_attempts))
  cat(sprintf("System uptime:            %s\n", format_time_remaining(uptime_seconds)))
  cat(sprintf("Last sync:                %s\n", if (is.null(last_sync)) "N/A" else as.character(last_sync)))
}

display_file_list <- function(vfs) {
  df <- vfs$list_files()
  cli::cli_h2("Vault File List")
  if (nrow(df) == 0) {
    cat(crayon::yellow("No files currently in vault.\n"))
    return(invisible(df))
  }
  print(df, row.names = FALSE)
  invisible(df)
}

display_menu <- function() {
  cli::cli_h2("Commands")
  cat("Terminal commands:\n")
  cat("[1]  status\n")
  cat("[2]  list\n")
  cat("[3]  add <filepath>\n")
  cat("[4]  read <filename>\n")
  cat("[5]  set-ttl <filename> <minutes>\n")
  cat("[6]  set-reads <filename> <max>\n")
  cat("[7]  set-deadline <filename> <YYYY-mm-dd HH:MM:SS>\n")
  cat("[8]  audit\n")
  cat("[9]  export <filename> <dest>\n")
  cat("[10] destroy <filename>\n")
  cat("[11] destroy-all\n")
  cat("[12] lock\n")
  cat("[13] change-password\n")
  cat("[14] quit\n")
  cat("\nExplorer mode:\n")
  cat("Drop command JSON files into .zerotracefs/commands while main.R is running.\n")
}

prompt_password <- function(message = "Enter password: ") {
  if (exists("askPassword", where = asNamespace("utils"), inherits = FALSE)) {
    pw <- tryCatch(utils::askPassword(message), error = function(e) NA_character_)
    if (!is.na(pw)) {
      return(pw)
    }
  }
  cat("(Input may be visible in this terminal.)\n")
  readline(message)
}

prompt_input <- function(message = "Input: ") {
  readline(message)
}
