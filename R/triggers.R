TriggerEngine <- R6::R6Class(
  "TriggerEngine",
  public = list(
    global_ttl_seconds = NULL,
    system_start_time = NULL,
    dead_man_switch_interval = NULL,
    last_heartbeat = NULL,

    initialize = function(global_ttl_seconds = NULL, dead_man_switch_interval = NULL) {
      self$global_ttl_seconds <- if (is.null(global_ttl_seconds)) NULL else as.numeric(global_ttl_seconds)
      self$dead_man_switch_interval <- if (is.null(dead_man_switch_interval)) NULL else as.numeric(dead_man_switch_interval)
      self$system_start_time <- Sys.time()
      self$last_heartbeat <- Sys.time()
    },

    check_file_triggers = function(file_metadata) {
      now <- Sys.time()

      if (!is.null(file_metadata$ttl_seconds)) {
        ttl_anchor <- file_metadata$last_access_at %||% file_metadata$last_read_at %||% file_metadata$created_at
        if (is.null(ttl_anchor) || all(is.na(ttl_anchor))) {
          ttl_anchor <- now
        }
        anchor_time <- suppressWarnings(as.POSIXct(ttl_anchor, tz = "UTC"))
        if (is.na(anchor_time)) {
          anchor_time <- now
        }
        age <- as.numeric(difftime(now, anchor_time, units = "secs"))
        age <- max(0, age)
        if (age >= as.numeric(file_metadata$ttl_seconds)) {
          return(list(triggered = TRUE, reason = "Per-file TTL expired"))
        }
      }

      if (!is.null(file_metadata$max_reads)) {
        if (as.integer(file_metadata$read_count) > as.integer(file_metadata$max_reads)) {
          return(list(triggered = TRUE, reason = "Read limit exceeded"))
        }
      }

      if (!is.null(file_metadata$deadline)) {
        if (now >= as.POSIXct(file_metadata$deadline, tz = "UTC")) {
          return(list(triggered = TRUE, reason = "Date deadline reached"))
        }
      }

      list(triggered = FALSE, reason = "")
    },

    check_global_triggers = function() {
      now <- Sys.time()

      if (!is.null(self$global_ttl_seconds)) {
        uptime <- as.numeric(difftime(now, self$system_start_time, units = "secs"))
        uptime <- max(0, uptime)
        if (uptime > as.numeric(self$global_ttl_seconds)) {
          return(list(triggered = TRUE, reason = "Global vault TTL expired"))
        }
      }

      if (!is.null(self$dead_man_switch_interval)) {
        stale_for <- as.numeric(difftime(now, self$last_heartbeat, units = "secs"))
        if (stale_for > as.numeric(self$dead_man_switch_interval)) {
          return(list(triggered = TRUE, reason = "Dead man's switch triggered"))
        }
      }

      list(triggered = FALSE, reason = "")
    },

    check_all = function(vfs) {
      global_result <- self$check_global_triggers()
      file_results <- list()

      if (!global_result$triggered) {
        for (fname in vfs$get_all_filenames()) {
          meta <- vfs$get_metadata(fname)
          if (is.null(meta) || isTRUE(meta$is_destroyed)) {
            next
          }
          trigger_result <- self$check_file_triggers(meta)
          if (isTRUE(trigger_result$triggered)) {
            file_results[[length(file_results) + 1L]] <- list(
              filename = fname,
              reason = trigger_result$reason
            )
          }
        }
      }

      list(
        global = global_result,
        files = file_results
      )
    },

    update_heartbeat = function() {
      self$last_heartbeat <- Sys.time()
      invisible(TRUE)
    },

    set_global_ttl = function(seconds) {
      self$global_ttl_seconds <- if (is.null(seconds) || seconds <= 0) NULL else as.numeric(seconds)
      invisible(TRUE)
    },

    set_dead_man_switch = function(seconds) {
      self$dead_man_switch_interval <- if (is.null(seconds) || seconds <= 0) NULL else as.numeric(seconds)
      self$last_heartbeat <- Sys.time()
      invisible(TRUE)
    },

    serialize = function() {
      list(
        global_ttl_seconds = self$global_ttl_seconds,
        system_start_time = private$format_time(self$system_start_time),
        dead_man_switch_interval = self$dead_man_switch_interval,
        last_heartbeat = private$format_time(self$last_heartbeat)
      )
    },

    deserialize = function(data) {
      self$global_ttl_seconds <- data$global_ttl_seconds %||% NULL
      self$system_start_time <- private$parse_time(data$system_start_time)
      self$dead_man_switch_interval <- data$dead_man_switch_interval %||% NULL
      self$last_heartbeat <- private$parse_time(data$last_heartbeat)
      invisible(self)
    }
  ),
  private = list(
    format_time = function(x) {
      if (is.null(x) || all(is.na(x))) {
        return(NA_character_)
      }
      format(as.POSIXct(x, tz = "UTC"), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
    },

    parse_time = function(x) {
      if (is.null(x) || all(is.na(x))) {
        return(Sys.time())
      }

      if (inherits(x, "POSIXt")) {
        return(as.POSIXct(x, tz = "UTC"))
      }

      if (is.numeric(x)) {
        return(as.POSIXct(as.numeric(x), origin = "1970-01-01", tz = "UTC"))
      }

      text <- as.character(x)[1]
      parsed <- suppressWarnings(as.POSIXct(text, format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC"))
      if (is.na(parsed)) {
        parsed <- suppressWarnings(as.POSIXct(text, tz = "UTC"))
      }
      if (is.na(parsed)) {
        return(Sys.time())
      }
      parsed
    }
  )
)

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}
