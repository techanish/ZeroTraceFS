source("setup.R")
run_setup(".")
source(file.path("R", "encryption.R"))
source(file.path("R", "key_derivation.R"))
source(file.path("R", "auth.R"))
source(file.path("R", "filesystem.R"))
source(file.path("R", "sync.R"))
source(file.path("R", "triggers.R"))
source(file.path("R", "wipe.R"))
source(file.path("R", "audit.R"))
source(file.path("R", "container.R"))

run_demo_scenario <- function() {
  cat("\n========== ZeroTraceFS Demo Scenario ==========" , "\n")

  paths <- run_setup(".")
  wiper <- SecureWiper$new()

  wiper$wipe_directory(paths$mount_path)
  if (file.exists(paths$container_path)) {
    wiper$wipe_file(paths$container_path)
  }

  vfs <- VirtualFileSystem$new()
  auth <- AuthManager$new(max_attempts = 5L)
  triggers <- TriggerEngine$new()
  audit <- AuditLogger$new()
  container <- ContainerManager$new(paths$container_path)

  auth$setup("demo123", "panic999")
  triggers$set_dead_man_switch(300)
  triggers$set_global_ttl(600)
  audit$log_event("SYSTEM_START", "Demo vault initialized")

  sync_engine <- SyncEngine$new(paths$mount_path, vfs, master_password = "demo123")

  apply_demo_triggers <- function() {
    results <- triggers$check_all(vfs)

    if (isTRUE(results$global$triggered)) {
      cat(sprintf("GLOBAL TRIGGER FIRED: %s\n", results$global$reason))
      for (fname in vfs$get_all_filenames()) {
        vfs$files[[fname]] <- wiper$destroy_crypto_artifacts(vfs$files[[fname]])
      }
      vfs$files <- list()
      wiper$full_system_wipe(paths$mount_path, paths$container_path)
      audit$log_event("WIPE_COMPLETE", "Global wipe complete")
      return(TRUE)
    }

    if (length(results$files) > 0) {
      for (item in results$files) {
        fname <- item$filename
        cat(sprintf("TRIGGER: %s -> DESTROYING %s\n", item$reason, fname))
        sync_engine$remove_from_mount(fname)
        vfs$files[[fname]] <- wiper$destroy_crypto_artifacts(vfs$files[[fname]])
        vfs$remove_file(fname)
        audit$log_event("TRIGGER_FIRE", item$reason, fname)
        audit$log_event("DESTRUCTION", "Destroyed by trigger", fname)
      }
    }

    FALSE
  }

  cat("\n[1] Setup Phase\n")
  cat("Master password: demo123\n")
  cat("Duress password: panic999\n")
  cat("Dead man's switch: 300 seconds\n")
  cat("Global TTL: 600 seconds\n")

  writeLines("This is classified information", file.path(paths$mount_path, "secret_note.txt"))
  writeLines("sk-abc123def456", file.path(paths$mount_path, "api_key.txt"))
  writeLines("Patient: John Doe, SSN: 123-45-6789", file.path(paths$mount_path, "patient_record.txt"))

  cat("\n[2] File Operations\n")
  changes <- sync_engine$sync_all()
  print(changes)

  for (fname in vfs$get_all_filenames()) {
    audit$log_event("FILE_CREATE", "Synced in demo", fname)
  }

  cat("\nEncrypted backend preview (hex):\n")
  for (fname in vfs$get_all_filenames()) {
    hex_preview <- paste(head(as.character(vfs$files[[fname]]$ciphertext), 16), collapse = " ")
    cat(sprintf("- %s: %s ...\n", fname, hex_preview))
  }

  cat("\nDecrypted verification:\n")
  for (fname in vfs$get_all_filenames()) {
    text <- rawToChar(vfs$peek_file(fname, "demo123"))
    cat(sprintf("- %s => %s\n", fname, text))
  }

  cat("\n[3] Trigger Demonstrations\n")
  vfs$set_trigger("api_key.txt", "max_reads", 2)
  cat("Set api_key.txt max_reads = 2\n")

  for (i in 1:2) {
    content <- rawToChar(vfs$read_file("api_key.txt", "demo123"))
    cat(sprintf("Read %d: %s\n", i, content))
    triggers$update_heartbeat()
    apply_demo_triggers()
  }

  cat("Third read should destroy api_key.txt\n")
  try({
    content <- rawToChar(vfs$read_file("api_key.txt", "demo123"))
    cat(sprintf("Read 3: %s\n", content))
  }, silent = TRUE)
  triggers$update_heartbeat()
  apply_demo_triggers()

  vfs$set_trigger("secret_note.txt", "ttl_seconds", 10)
  cat("Set secret_note.txt TTL = 10 seconds\n")
  Sys.sleep(12)
  triggers$update_heartbeat()
  apply_demo_triggers()

  vfs$set_trigger("patient_record.txt", "deadline", Sys.time() + 15)
  cat("Set patient_record.txt deadline = now + 15 seconds\n")
  Sys.sleep(16)
  triggers$update_heartbeat()
  apply_demo_triggers()

  cat("\n[4] Duress Demo\n")
  writeLines("new sensitive payload", file.path(paths$mount_path, "new_file.txt"))
  sync_engine$sync_all()
  audit$log_event("FILE_CREATE", "Created file for duress demo", "new_file.txt")

  result <- auth$authenticate("panic999")
  if (identical(result, "duress")) {
    cat("Duress password entered -> destroying everything\n")
    audit$log_event("AUTH_DURESS", "Duress password accepted")
    for (fname in vfs$get_all_filenames()) {
      vfs$files[[fname]] <- wiper$destroy_crypto_artifacts(vfs$files[[fname]])
    }
    vfs$files <- list()
    wiper$full_system_wipe(paths$mount_path, paths$container_path)
    audit$log_event("WIPE_COMPLETE", "Duress wipe complete")
  }

  cat("\n[5] Summary\n")
  log_df <- audit$get_log()
  print(log_df, row.names = FALSE)

  mount_files <- fs::dir_ls(paths$mount_path, recurse = TRUE, type = "file")
  cat(sprintf("Mount empty: %s\n", length(mount_files) == 0))
  cat(sprintf("Container exists: %s\n", file.exists(paths$container_path)))
  cat(sprintf("VFS file count: %d\n", length(vfs$get_all_filenames())))
  cat("All key/IV/salt material destroyed for removed entries during demo flow.\n")

  cat("\n========== Demo Complete ==========\n")
}

run_demo_scenario()
