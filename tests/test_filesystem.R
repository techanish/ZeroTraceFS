source("setup.R")
run_setup(".")
source(file.path("R", "encryption.R"))
source(file.path("R", "key_derivation.R"))
source(file.path("R", "filesystem.R"))

run_test_filesystem <- function() {
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

  run_case("Add file and retrieve it", {
    vfs <- VirtualFileSystem$new()
    payload <- charToRaw("classified")
    vfs$add_file("doc.txt", payload, "master123")
    recovered <- vfs$peek_file("doc.txt", "master123")
    stopifnot(identical(payload, recovered))
  })

  run_case("File metadata correctly tracked", {
    vfs <- VirtualFileSystem$new()
    payload <- charToRaw("metadata payload")
    vfs$add_file("meta.txt", payload, "master123")
    meta <- vfs$get_metadata("meta.txt")
    stopifnot(meta$filename == "meta.txt")
    stopifnot(meta$file_size == length(payload))
    stopifnot(!is.null(meta$created_at))
    stopifnot(!is.null(meta$modified_at))
  })

  run_case("Read count increments", {
    vfs <- VirtualFileSystem$new()
    vfs$add_file("readme.txt", charToRaw("123"), "master123")
    vfs$read_file("readme.txt", "master123")
    vfs$read_file("readme.txt", "master123")
    meta <- vfs$get_metadata("readme.txt")
    stopifnot(meta$read_count == 2L)
  })

  run_case("Remove file works", {
    vfs <- VirtualFileSystem$new()
    vfs$add_file("gone.txt", charToRaw("gone"), "master123")
    stopifnot(vfs$file_exists("gone.txt"))
    vfs$remove_file("gone.txt")
    stopifnot(!vfs$file_exists("gone.txt"))
  })

  run_case("List files returns correct data", {
    vfs <- VirtualFileSystem$new()
    vfs$add_file("a.txt", charToRaw("a"), "master123")
    vfs$add_file("b.txt", charToRaw("b"), "master123")
    df <- vfs$list_files()
    stopifnot(nrow(df) == 2)
    stopifnot(all(c("a.txt", "b.txt") %in% df$filename))
  })

  message(sprintf("Filesystem tests complete: %d passed, %d failed", passed, failed))
  list(passed = passed, failed = failed)
}
