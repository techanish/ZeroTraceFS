source("setup.R")
run_setup(".")
source(file.path("R", "auth.R"))

run_test_auth <- function() {
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

  run_case("Correct password returns granted", {
    auth <- AuthManager$new(max_attempts = 5L)
    auth$setup("master123", "panic999")
    stopifnot(identical(auth$authenticate("master123"), "granted"))
  })

  run_case("Wrong password returns denied and increments counter", {
    auth <- AuthManager$new(max_attempts = 5L)
    auth$setup("master123", "panic999")
    result <- auth$authenticate("wrong-pass")
    stopifnot(identical(result, "denied"))
    stopifnot(auth$failed_attempts == 1L)
  })

  run_case("Duress password returns duress", {
    auth <- AuthManager$new(max_attempts = 5L)
    auth$setup("master123", "panic999")
    stopifnot(identical(auth$authenticate("panic999"), "duress"))
  })

  run_case("Lockout after max attempts", {
    auth <- AuthManager$new(max_attempts = 3L)
    auth$setup("master123", "panic999")
    stopifnot(identical(auth$authenticate("a"), "denied"))
    stopifnot(identical(auth$authenticate("b"), "denied"))
    stopifnot(identical(auth$authenticate("c"), "lockout"))
    stopifnot(isTRUE(auth$is_lockout_triggered()))
  })

  run_case("Password change works", {
    auth <- AuthManager$new(max_attempts = 5L)
    auth$setup("master123", "panic999")
    changed <- auth$change_password("master123", "newmaster456")
    stopifnot(isTRUE(changed))
    stopifnot(identical(auth$authenticate("newmaster456"), "granted"))
  })

  run_case("Counter resets after successful auth", {
    auth <- AuthManager$new(max_attempts = 5L)
    auth$setup("master123", "panic999")
    auth$authenticate("wrong")
    auth$authenticate("wrong2")
    stopifnot(auth$failed_attempts == 2L)
    stopifnot(identical(auth$authenticate("master123"), "granted"))
    stopifnot(auth$failed_attempts == 0L)
  })

  message(sprintf("Auth tests complete: %d passed, %d failed", passed, failed))
  list(passed = passed, failed = failed)
}
