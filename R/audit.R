AuditLogger <- R6::R6Class(
  "AuditLogger",
  public = list(
    log_entries = NULL,

    initialize = function() {
      self$log_entries <- list()
    },

    log_event = function(event_type, details, filename = NA_character_) {
      entry <- list(
        timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
        event_type = as.character(event_type),
        details = as.character(details),
        filename = if (is.null(filename)) NA_character_ else as.character(filename)
      )
      self$log_entries[[length(self$log_entries) + 1L]] <- entry
      invisible(entry)
    },

    get_log = function() {
      if (length(self$log_entries) == 0) {
        return(data.frame(
          timestamp = character(0),
          event_type = character(0),
          details = character(0),
          filename = character(0),
          stringsAsFactors = FALSE
        ))
      }

      do.call(rbind, lapply(self$log_entries, function(e) {
        data.frame(
          timestamp = e$timestamp,
          event_type = e$event_type,
          details = e$details,
          filename = e$filename,
          stringsAsFactors = FALSE
        )
      }))
    },

    get_recent = function(n = 20L) {
      log_df <- self$get_log()
      if (nrow(log_df) == 0) {
        return(log_df)
      }
      tail(log_df, n = as.integer(n))
    },

    serialize = function() {
      list(log_entries = self$log_entries)
    },

    deserialize = function(data) {
      self$log_entries <- data$log_entries %||% list()
      invisible(self)
    },

    clear = function() {
      self$log_entries <- list()
      invisible(TRUE)
    }
  )
)

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}
