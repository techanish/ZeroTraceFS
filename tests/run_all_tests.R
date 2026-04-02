source("setup.R")
run_setup(".")

test_scripts <- c(
  "tests/test_encryption.R",
  "tests/test_auth.R",
  "tests/test_triggers.R",
  "tests/test_wipe.R",
  "tests/test_sync.R",
  "tests/test_filesystem.R"
)

for (script in test_scripts) {
  source(script)
}

test_functions <- list(
  run_test_encryption = run_test_encryption,
  run_test_auth = run_test_auth,
  run_test_triggers = run_test_triggers,
  run_test_wipe = run_test_wipe,
  run_test_sync = run_test_sync,
  run_test_filesystem = run_test_filesystem
)

results <- list()
total_passed <- 0L
total_failed <- 0L

for (name in names(test_functions)) {
  fn <- test_functions[[name]]
  res <- tryCatch(fn(), error = function(e) {
    message(sprintf("[FATAL] %s -> %s", name, e$message))
    list(passed = 0L, failed = 1L)
  })

  results[[name]] <- res
  total_passed <- total_passed + as.integer(res$passed)
  total_failed <- total_failed + as.integer(res$failed)
}

cat("\n================ TEST SUMMARY ================\n")
cat(sprintf("Total Passed: %d\n", total_passed))
cat(sprintf("Total Failed: %d\n", total_failed))
cat("==============================================\n")

if (total_failed > 0) {
  stop(sprintf("Test suite failed with %d failing tests.", total_failed))
}

cat("All tests passed successfully.\n")
