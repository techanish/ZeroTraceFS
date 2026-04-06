source("setup.R")
run_setup(".")
source(file.path("R", "triggers.R"))
source(file.path("R", "filesystem.R"))
source(file.path("R", "encryption.R"))
source(file.path("R", "key_derivation.R"))

run_test_triggers <- function() {
  passed <- 0L
  failed <- 0L

  run_case <- function(name, expr) {
    ok <- tryCatch({
      force(expr)
      TRUE
    }, error = function(e) {
      message(sprintf("[FAIL] %s -> %s", name, e$message))
      FALSE
    })
    if (isTRUE(ok)) {
      message(sprintf("[PASS] %s", name))
      passed <<- passed + 1L
    } else {
      failed <<- failed + 1L
    }
  }

  make_meta <- function() {
    list(
      filename = "x.txt",
      created_at = Sys.time(),
      modified_at = Sys.time(),
      last_access_at = Sys.time(),
      last_read_at = NULL,
      read_count = 0L,
      file_size = 10L,
      file_hash = "abc",
      ttl_seconds = NULL,
      ttl_set_at = NULL,
      max_reads = NULL,
      deadline = NULL,
      is_destroyed = FALSE
    )
  }

  run_case("File TTL triggers after expiration", {
    t <- TriggerEngine$new()
    meta <- make_meta()
    meta$ttl_seconds <- 60
    meta$last_access_at <- Sys.time() - 61
    res <- t$check_file_triggers(meta)
    stopifnot(isTRUE(res$triggered))
    stopifnot(grepl("TTL", res$reason))
  })

  run_case("Read limit triggers on 4th read for max_reads=3", {
    t <- TriggerEngine$new()
    meta <- make_meta()
    meta$max_reads <- 3L
    meta$read_count <- 4L
    res <- t$check_file_triggers(meta)
    stopifnot(isTRUE(res$triggered))
    stopifnot(grepl("Read limit", res$reason))
  })

  run_case("TTL does not use stale creation time when access is recent", {
    t <- TriggerEngine$new()
    meta <- make_meta()
    meta$created_at <- Sys.time() - 3600
    meta$last_access_at <- Sys.time() - 5
    meta$ttl_seconds <- 60
    res <- t$check_file_triggers(meta)
    stopifnot(!isTRUE(res$triggered))
  })

  run_case("Deadline in past triggers immediately", {
    t <- TriggerEngine$new()
    meta <- make_meta()
    meta$deadline <- Sys.time() - 1
    res <- t$check_file_triggers(meta)
    stopifnot(isTRUE(res$triggered))
    stopifnot(grepl("deadline", tolower(res$reason)))
  })

  run_case("Global TTL triggers correctly", {
    t <- TriggerEngine$new(global_ttl_seconds = 10)
    t$system_start_time <- Sys.time() - 20
    res <- t$check_global_triggers()
    stopifnot(isTRUE(res$triggered))
  })

  run_case("Dead man's switch triggers when heartbeat is stale", {
    t <- TriggerEngine$new(dead_man_switch_interval = 30)
    t$last_heartbeat <- Sys.time() - 35
    res <- t$check_global_triggers()
    stopifnot(isTRUE(res$triggered))
    stopifnot(grepl("dead", tolower(res$reason)))
  })

  run_case("No trigger fires when conditions are not met", {
    t <- TriggerEngine$new(global_ttl_seconds = 3600, dead_man_switch_interval = 120)
    meta <- make_meta()
    meta$ttl_seconds <- 120
    meta$last_access_at <- Sys.time() - 30
    meta$max_reads <- 3L
    meta$read_count <- 1L
    meta$deadline <- Sys.time() + 120

    file_res <- t$check_file_triggers(meta)
    global_res <- t$check_global_triggers()
    stopifnot(!isTRUE(file_res$triggered))
    stopifnot(!isTRUE(global_res$triggered))
  })

  run_case("Multiple file triggers return first matched trigger", {
    t <- TriggerEngine$new()
    meta <- make_meta()
    meta$ttl_seconds <- 1
    meta$last_access_at <- Sys.time() - 2
    meta$max_reads <- 1L
    meta$read_count <- 99L
    meta$deadline <- Sys.time() - 1

    res <- t$check_file_triggers(meta)
    stopifnot(isTRUE(res$triggered))
    stopifnot(identical(res$reason, "Per-file TTL expired"))
  })

  run_case("check_all returns file-level trigger list", {
    vfs <- VirtualFileSystem$new()
    vfs$add_file("demo.txt", charToRaw("hello"), "pw")
    vfs$set_trigger("demo.txt", "ttl_seconds", 1)
    vfs$files[["demo.txt"]]$metadata$last_access_at <- Sys.time() - 2

    t <- TriggerEngine$new()
    all_res <- t$check_all(vfs)
    stopifnot(length(all_res$files) == 1)
    stopifnot(identical(all_res$files[[1]]$filename, "demo.txt"))
  })

  message(sprintf("Trigger tests complete: %d passed, %d failed", passed, failed))
  list(passed = passed, failed = failed)
}
