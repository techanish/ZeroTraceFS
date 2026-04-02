AuthManager <- R6::R6Class(
  "AuthManager",
  public = list(
    master_hash = NULL,
    duress_hash = NULL,
    failed_attempts = 0L,
    max_attempts = 5L,
    is_locked = FALSE,
    last_auth_time = NULL,

    initialize = function(max_attempts = 5L) {
      self$max_attempts <- as.integer(max_attempts)
      self$failed_attempts <- 0L
      self$is_locked <- FALSE
      self$last_auth_time <- NULL
    },

    setup = function(master_password, duress_password) {
      if (!nzchar(master_password) || !nzchar(duress_password)) {
        stop("Master and duress passwords must not be empty.")
      }
      if (identical(master_password, duress_password)) {
        stop("Master and duress passwords must be different.")
      }

      self$master_hash <- digest::digest(master_password, algo = "sha256", serialize = FALSE)
      self$duress_hash <- digest::digest(duress_password, algo = "sha256", serialize = FALSE)
      self$failed_attempts <- 0L
      self$is_locked <- FALSE
      self$last_auth_time <- Sys.time()
      invisible(TRUE)
    },

    authenticate = function(input_password) {
      if (isTRUE(self$is_locked)) {
        return("lockout")
      }

      input_hash <- digest::digest(input_password, algo = "sha256", serialize = FALSE)

      if (!is.null(self$master_hash) && identical(input_hash, self$master_hash)) {
        self$reset_attempts()
        self$last_auth_time <- Sys.time()
        return("granted")
      }

      if (!is.null(self$duress_hash) && identical(input_hash, self$duress_hash)) {
        self$last_auth_time <- Sys.time()
        return("duress")
      }

      self$failed_attempts <- as.integer(self$failed_attempts + 1L)
      if (self$failed_attempts >= self$max_attempts) {
        self$is_locked <- TRUE
        self$last_auth_time <- Sys.time()
        return("lockout")
      }

      "denied"
    },

    get_remaining_attempts = function() {
      max(0L, as.integer(self$max_attempts - self$failed_attempts))
    },

    reset_attempts = function() {
      self$failed_attempts <- 0L
      self$is_locked <- FALSE
      invisible(TRUE)
    },

    change_password = function(old_password, new_password) {
      if (!nzchar(old_password) || !nzchar(new_password)) {
        return(FALSE)
      }
      if (identical(old_password, new_password)) {
        return(FALSE)
      }

      old_hash <- digest::digest(old_password, algo = "sha256", serialize = FALSE)
      if (!identical(old_hash, self$master_hash)) {
        return(FALSE)
      }

      self$master_hash <- digest::digest(new_password, algo = "sha256", serialize = FALSE)
      self$last_auth_time <- Sys.time()
      TRUE
    },

    is_lockout_triggered = function() {
      isTRUE(self$failed_attempts >= self$max_attempts)
    },

    serialize = function() {
      list(
        master_hash = self$master_hash,
        duress_hash = self$duress_hash,
        failed_attempts = self$failed_attempts,
        max_attempts = self$max_attempts,
        is_locked = self$is_locked,
        last_auth_time = if (is.null(self$last_auth_time)) NA_character_ else format(self$last_auth_time, tz = "UTC", usetz = TRUE)
      )
    },

    deserialize = function(data) {
      self$master_hash <- data$master_hash
      self$duress_hash <- data$duress_hash
      self$failed_attempts <- as.integer(data$failed_attempts %||% 0L)
      self$max_attempts <- as.integer(data$max_attempts %||% 5L)
      self$is_locked <- isTRUE(data$is_locked)
      self$last_auth_time <- private$parse_time(data$last_auth_time)
      invisible(self)
    }
  ),
  private = list(
    parse_time = function(x) {
      if (is.null(x) || length(x) == 0 || all(is.na(x))) {
        return(NULL)
      }
      as.POSIXct(x, tz = "UTC")
    }
  )
)

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}
