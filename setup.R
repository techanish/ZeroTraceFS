required_packages <- c(
  "R6",
  "openssl",
  "digest",
  "jsonlite",
  "fs",
  "later",
  "cli",
  "crayon"
)

install_and_load_packages <- function(packages = required_packages) {
  repos <- getOption("repos")
  if (is.null(repos) || is.na(repos["CRAN"]) || repos["CRAN"] == "@CRAN@") {
    options(repos = c(CRAN = "https://cloud.r-project.org"))
  }

  for (pkg in packages) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      message(sprintf("Installing missing package: %s", pkg))
      install.packages(pkg, dependencies = TRUE)
    }
  }

  invisible(lapply(packages, function(pkg) {
    suppressPackageStartupMessages(library(pkg, character.only = TRUE))
  }))
}

initialize_project_dirs <- function(base_path = ".") {
  mount_path <- fs::path(base_path, "mount")
  data_path <- fs::path(base_path, "data")
  control_path <- fs::path(base_path, ".zerotracefs")
  commands_path <- fs::path(control_path, "commands")
  processed_commands_path <- fs::path(control_path, "processed")

  if (!fs::dir_exists(mount_path)) {
    fs::dir_create(mount_path, recurse = TRUE)
  }
  if (!fs::dir_exists(data_path)) {
    fs::dir_create(data_path, recurse = TRUE)
  }
  if (!fs::dir_exists(control_path)) {
    fs::dir_create(control_path, recurse = TRUE)
  }
  if (!fs::dir_exists(commands_path)) {
    fs::dir_create(commands_path, recurse = TRUE)
  }
  if (!fs::dir_exists(processed_commands_path)) {
    fs::dir_create(processed_commands_path, recurse = TRUE)
  }

  if (.Platform$OS.type != "windows") {
    try(Sys.chmod(mount_path, mode = "700"), silent = TRUE)
    try(Sys.chmod(data_path, mode = "700"), silent = TRUE)
    try(Sys.chmod(control_path, mode = "700"), silent = TRUE)
    try(Sys.chmod(commands_path, mode = "700"), silent = TRUE)
    try(Sys.chmod(processed_commands_path, mode = "700"), silent = TRUE)
  }

  list(
    mount_path = fs::path_abs(mount_path),
    data_path = fs::path_abs(data_path),
    container_path = fs::path_abs(fs::path(data_path, "container.rds")),
    control_path = fs::path_abs(control_path),
    commands_path = fs::path_abs(commands_path),
    processed_commands_path = fs::path_abs(processed_commands_path)
  )
}

run_setup <- function(base_path = ".") {
  options(stringsAsFactors = FALSE)
  install_and_load_packages(required_packages)
  initialize_project_dirs(base_path)
}
