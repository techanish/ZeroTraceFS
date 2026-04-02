ContainerManager <- R6::R6Class(
  "ContainerManager",
  public = list(
    container_path = NULL,

    initialize = function(container_path = fs::path("data", "container.rds")) {
      self$container_path <- fs::path_abs(container_path)
      parent_dir <- dirname(self$container_path)
      if (!dir.exists(parent_dir)) {
        dir.create(parent_dir, recursive = TRUE, showWarnings = FALSE)
      }
    },

    save_state = function(vfs, auth, triggers, audit) {
      payload <- list(
        vfs_data = vfs$serialize(),
        auth_data = auth$serialize(),
        trigger_data = triggers$serialize(),
        audit_data = audit$serialize(),
        version = "1.0.0",
        created_at = Sys.time()
      )

      saveRDS(payload, self$container_path)
      invisible(TRUE)
    },

    load_state = function(container_path = self$container_path) {
      if (!file.exists(container_path)) {
        stop(sprintf("Container file not found: %s", container_path))
      }

      state <- readRDS(container_path)
      required <- c("vfs_data", "auth_data", "trigger_data", "audit_data")
      missing <- setdiff(required, names(state))
      if (length(missing) > 0) {
        stop(sprintf("Container state is missing fields: %s", paste(missing, collapse = ", ")))
      }
      state
    },

    container_exists = function() {
      file.exists(self$container_path)
    },

    destroy_container = function() {
      if (!file.exists(self$container_path)) {
        return(TRUE)
      }

      if (exists("SecureWiper", inherits = TRUE)) {
        wiper <- SecureWiper$new()
        return(wiper$wipe_file(self$container_path))
      }

      unlink(self$container_path, force = TRUE)
      !file.exists(self$container_path)
    }
  )
)
