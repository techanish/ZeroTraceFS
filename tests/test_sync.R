source("setup.R")
run_setup(".")
source(file.path("R", "encryption.R"))
source(file.path("R", "key_derivation.R"))
source(file.path("R", "filesystem.R"))
source(file.path("R", "sync.R"))
source(file.path("R", "wipe.R"))

run_test_sync <- function() {
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

  mount <- tempfile(pattern = "ztfs_mount_")
  dir.create(mount)
  on.exit(unlink(mount, recursive = TRUE, force = TRUE), add = TRUE)

  vfs <- VirtualFileSystem$new()
  sync_engine <- SyncEngine$new(mount_path = mount, vfs = vfs, master_password = "master123")

  run_case("New file in mount detected and encrypted", {
    target <- file.path(mount, "new_file.txt")
    writeLines("hello zero trace", target)

    changes <- sync_engine$sync_all()
    stopifnot("new_file.txt" %in% changes$new)
    stopifnot(vfs$file_exists("new_file.txt"))

    entry <- vfs$files[["new_file.txt"]]
    stopifnot(is.raw(entry$ciphertext))
    stopifnot(!identical(entry$ciphertext, charToRaw("hello zero trace\n")))
  })

  run_case("Modified file detected and re-encrypted", {
    target <- file.path(mount, "new_file.txt")
    old_cipher <- vfs$files[["new_file.txt"]]$ciphertext

    writeLines("updated payload", target)
    changes <- sync_engine$sync_all()

    stopifnot("new_file.txt" %in% changes$modified)
    new_cipher <- vfs$files[["new_file.txt"]]$ciphertext
    stopifnot(!identical(old_cipher, new_cipher))
  })

  run_case("Deleted file detected and removed from VFS", {
    target <- file.path(mount, "new_file.txt")
    unlink(target, force = TRUE)

    changes <- sync_engine$sync_all()
    stopifnot("new_file.txt" %in% changes$deleted)
    stopifnot(!vfs$file_exists("new_file.txt"))
  })

  run_case("Sync preserves file content", {
    fname <- "binary_blob.bin"
    target <- file.path(mount, fname)
    raw_blob <- openssl::rand_bytes(4096)

    con <- file(target, "wb")
    writeBin(raw_blob, con)
    close(con)

    sync_engine$sync_all()
    recovered <- vfs$peek_file(fname, "master123")
    stopifnot(identical(raw_blob, recovered))
  })

  message(sprintf("Sync tests complete: %d passed, %d failed", passed, failed))
  list(passed = passed, failed = failed)
}
