source("setup.R")
run_setup(".")
source(file.path("R", "wipe.R"))

run_test_wipe <- function() {
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

  wiper <- SecureWiper$new()

  run_case("File is completely removed after wipe", {
    f <- tempfile(fileext = ".txt")
    writeLines("Top Secret", f)
    stopifnot(file.exists(f))
    result <- wiper$wipe_file(f)
    stopifnot(isTRUE(result))
    stopifnot(!file.exists(f))
  })

  run_case("File content is not recoverable after wipe", {
    f <- tempfile(fileext = ".bin")
    con <- file(f, "wb")
    writeBin(openssl::rand_bytes(2048), con)
    close(con)

    result <- wiper$wipe_file(f)
    stopifnot(isTRUE(result))

    recovered <- tryCatch({
      readBin(f, what = "raw", n = 10)
    }, error = function(e) NULL)

    stopifnot(is.null(recovered))
  })

  run_case("Directory wipe removes all files", {
    d <- tempfile(pattern = "wipe_dir_")
    dir.create(d)
    writeLines("a", file.path(d, "a.txt"))
    writeLines("b", file.path(d, "b.txt"))
    writeLines("c", file.path(d, "c.txt"))

    result <- wiper$wipe_directory(d)
    stopifnot(isTRUE(result))
    remaining <- list.files(d, recursive = TRUE, all.files = TRUE, no.. = TRUE)
    stopifnot(length(remaining) == 0)

    unlink(d, recursive = TRUE, force = TRUE)
  })

  run_case("Zero-byte file handling", {
    f <- tempfile(fileext = ".zero")
    file.create(f)
    stopifnot(file.info(f)$size == 0)
    result <- wiper$wipe_file(f)
    stopifnot(isTRUE(result))
    stopifnot(!file.exists(f))
  })

  message(sprintf("Wipe tests complete: %d passed, %d failed", passed, failed))
  list(passed = passed, failed = failed)
}
