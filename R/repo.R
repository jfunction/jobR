#' @title Host-served package repository
#' @description
#' jobR ships a project's code but not the R packages it needs, so every worker
#' installs those itself, from CRAN, over its own connection. Four workers
#' means four downloads of the same bytes. On a metered or slow link that is
#' the actual bottleneck, and it is a silly one: the host already has the
#' packages, and it is sitting on the far end of a LAN cable.
#'
#' So the host can stock a small CRAN-shaped repository and serve it over the
#' same socket it serves everything else. One download from the internet, then
#' as many LAN transfers as there are workers.
#'
#' It is a real repository, not a bespoke format: a `src/contrib` tree and
#' `bin/<platform>/contrib/<R series>` trees, each with a `PACKAGES` index
#' written by `tools::write_PACKAGES()`. The worker reassembles it locally and
#' installs with `repos = "file:///..."`, so R's own dependency resolution and
#' version checking do the work and nothing here has to reimplement them.
#'
#' A useful consequence of R's layout: a worker only ever reads the directory
#' matching its own R series, so one repository can serve several R versions at
#' once without them interfering.
#'
#' @section What can and cannot be served:
#' Sources are universal but need a toolchain to install, which Windows
#' machines usually lack. Binaries need no toolchain but only work on a
#' matching platform and R series. The host therefore stocks both where it can,
#' and the worker takes whichever it can use.
#'
#' CRAN only builds binaries for the current R and the one before it, so a
#' worker on an older R will be offered sources and will need Rtools. That is a
#' limit of CRAN, not of this code.
#'
#' @name repo
NULL

#' Path to a host's package repository
#'
#' @param work_dir The host's working directory.
#' @return The repository root.
#' @export
repo_path <- function(work_dir) file.path(work_dir, "repo")

#' The R series a binary tree is keyed by
#'
#' @param version An R version; defaults to this machine's.
#' @return For example `"4.5"`.
#' @export
r_series <- function(version = getRversion()) {
  paste(unlist(strsplit(as.character(version), ".", fixed = TRUE))[1:2],
        collapse = ".")
}

#' The subdirectory a package file of a given type belongs in
#'
#' Mirrors CRAN's layout exactly, because R derives these paths itself when it
#' reads a repository and will not find files anywhere else.
#'
#' @param type `"source"`, `"win.binary"` or `"mac.binary"`.
#' @param series R series, for binary types.
#' @return A relative path with forward slashes.
#' @export
repo_subdir <- function(type, series = r_series()) {
  switch(type,
    source       = "src/contrib",
    win.binary   = paste0("bin/windows/contrib/", series),
    mac.binary   = paste0("bin/macosx/contrib/", series),
    stop("unsupported package type: ", type, call. = FALSE)
  )
}

#' Stock a repository with packages and everything they depend on
#'
#' Downloads from CRAN once, on the host, so that workers need not.
#'
#' @param packages Package names.
#' @param dir Repository root, from [repo_path()].
#' @param types Which kinds to stock. Sources are universal; binaries save the
#'   worker a toolchain.
#' @param series R series to stock binaries for. Only versions CRAN still
#'   builds are obtainable.
#' @param repos CRAN mirror to fetch from.
#' @param quiet Suppress progress.
#'
#' @return A data frame of what was stocked, invisibly.
#' @export
repo_stock <- function(packages, dir, types = c("source", .Platform$pkgType),
                       series = r_series(), repos = getOption("repos"),
                       quiet = FALSE) {
  if (!length(packages)) return(invisible(repo_manifest(dir)))
  if (identical(repos, c(CRAN = "@CRAN@")) || !length(repos)) {
    repos <- c(CRAN = "https://cloud.r-project.org")
  }
  types <- unique(types[types %in% c("source", "win.binary", "mac.binary")])
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)

  for (type in types) {
    # Resolve dependencies against the type actually being fetched: a package's
    # requirements can differ between source and binary.
    avail <- tryCatch(utils::available.packages(repos = repos, type = type),
                      error = function(e) NULL)
    if (is.null(avail) || !nrow(avail)) {
      if (!quiet) message("no ", type, " packages available from ", repos[[1]])
      next
    }
    wanted <- intersect(packages, rownames(avail))
    if (!length(wanted)) next
    deps <- unlist(tools::package_dependencies(wanted, db = avail,
                                               recursive = TRUE))
    # Base and recommended packages ship with R; never try to fetch them.
    all_pkgs <- setdiff(unique(c(wanted, deps)), base_packages())
    all_pkgs <- intersect(all_pkgs, rownames(avail))

    dest <- file.path(dir, repo_subdir(type, series))
    dir.create(dest, recursive = TRUE, showWarnings = FALSE)
    if (!quiet) {
      message("stocking ", length(all_pkgs), " ", type, " package(s) into ",
              repo_subdir(type, series))
    }
    utils::download.packages(all_pkgs, destdir = dest, repos = repos,
                             type = type, quiet = quiet)
    tools::write_PACKAGES(dest, type = type)
  }
  invisible(repo_manifest(dir))
}

# Packages that come with R and must never be downloaded.
base_packages <- function() {
  rownames(utils::installed.packages(priority = c("base", "recommended")))
}

#' Everything a repository contains, with hashes
#'
#' The hashes are what let a worker fetch only what it does not already have,
#' which is the entire point on a slow link.
#'
#' @param dir Repository root.
#' @return A data frame of `path` (relative, forward slashes), `size` and
#'   `sha256`. Zero rows if there is no repository.
#' @export
repo_manifest <- function(dir) {
  empty <- data.frame(path = character(), size = numeric(),
                      sha256 = character(), stringsAsFactors = FALSE)
  if (!dir.exists(dir)) return(empty)
  files <- list.files(dir, recursive = TRUE, full.names = FALSE)
  if (!length(files)) return(empty)
  files <- gsub("\\\\", "/", files)
  full <- file.path(dir, files)
  data.frame(
    path   = files,
    size   = file.info(full)$size,
    sha256 = vapply(full, function(f) digest::digest(file = f, algo = "sha256"),
                    character(1), USE.NAMES = FALSE),
    stringsAsFactors = FALSE
  )
}

#' Is a repository-relative path safe to serve?
#'
#' A path arriving from a worker names a file the host will read and return.
#' Anything that could escape the repository root must be refused. The host
#' additionally serves only paths present in its own manifest, so this is the
#' second of two locks rather than the only one.
#'
#' @param path A candidate relative path.
#' @return `TRUE` if the path is safe.
#' @export
repo_path_ok <- function(path) {
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    return(FALSE)
  }
  if (grepl("\\\\", path)) return(FALSE)               # no backslashes
  if (grepl("^([A-Za-z]:|/|~)", path)) return(FALSE)   # no absolute paths
  parts <- unlist(strsplit(path, "/", fixed = TRUE))
  if (any(parts == "..")) return(FALSE)                # no traversal
  if (any(!nzchar(parts))) return(FALSE)               # no empty segments
  TRUE
}

#' What a worker still needs to fetch
#'
#' @param manifest The host's manifest.
#' @param local_dir Where the worker is assembling its copy.
#' @return The rows of `manifest` whose files are absent or differ locally.
#' @export
repo_sync_plan <- function(manifest, local_dir) {
  if (!nrow(manifest)) return(manifest)
  need <- vapply(seq_len(nrow(manifest)), function(i) {
    f <- file.path(local_dir, manifest$path[i])
    if (!file.exists(f)) return(TRUE)
    !identical(digest::digest(file = f, algo = "sha256"), manifest$sha256[i])
  }, logical(1))
  manifest[need, , drop = FALSE]
}

#' A `file://` URL R will accept for a local repository
#'
#' @param dir Local repository root.
#' @return A URL string.
#' @export
repo_url <- function(dir) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  paste0("file:///", gsub("\\\\", "/", normalizePath(dir, winslash = "/",
                                                     mustWork = TRUE)))
}

#' Install packages from a locally assembled repository
#'
#' Tries binaries before sources: a binary needs no toolchain, which most
#' Windows machines do not have.
#'
#' @param packages Packages to install.
#' @param dir Local repository root.
#' @param lib Library to install into.
#' @param quiet Suppress progress.
#'
#' @return The names still missing afterwards.
#' @export
repo_install <- function(packages, dir, lib = .libPaths()[1], quiet = FALSE) {
  if (!length(packages)) return(character())
  url <- repo_url(dir)
  types <- unique(c(if (.Platform$pkgType != "source") .Platform$pkgType,
                    "source"))
  for (type in types) {
    still <- packages_missing(packages, lib = lib)
    if (!length(still)) break
    avail <- tryCatch(utils::available.packages(repos = url, type = type),
                      error = function(e) NULL)
    if (is.null(avail) || !nrow(avail)) next
    have <- intersect(still, rownames(avail))
    if (!length(have)) next
    if (!quiet) message("installing ", length(have), " ", type,
                        " package(s) from the host")
    try(utils::install.packages(have, lib = lib, repos = url, type = type,
                                dependencies = FALSE, quiet = quiet),
        silent = quiet)
  }
  packages_missing(packages, lib = lib)
}

#' Stock a host's repository so workers need not visit CRAN
#'
#' Downloads the project's declared packages, and everything they depend on,
#' once. Workers then fetch them over the same socket they use for work.
#'
#' Call this after [host_new()] and before [jobr_serve()]. It is deliberately
#' explicit rather than automatic: it reaches out to CRAN and can take a while,
#' which should never happen as a side effect of starting a host.
#'
#' @param state A `jobr_host`.
#' @param packages Packages to stock. Defaults to those the project's lockfile
#'   declares.
#' @param types Kinds to stock. Sources work anywhere but need a toolchain;
#'   binaries need none but must match the worker's platform and R series.
#' @param series R series to stock binaries for, defaulting to the host's own.
#'   CRAN only builds binaries for the current R and the one before it.
#' @param repos CRAN mirror.
#' @param quiet Suppress progress.
#'
#' @return The host state, invisibly.
#' @export
host_serve_packages <- function(state, packages = NULL,
                                types = c("source", .Platform$pkgType),
                                series = r_series(),
                                repos = getOption("repos"), quiet = FALSE) {
  if (is.null(packages)) packages <- state$bundle$packages
  if (!length(packages)) {
    if (!quiet) {
      message("the project declares no packages, so there is nothing to stock.",
              "
  Add a Lockfile to jobR.dcf to make its dependencies explicit.")
    }
    return(invisible(state))
  }
  dir <- repo_path(state$work_dir)
  repo_stock(packages, dir, types = types, series = series, repos = repos,
             quiet = quiet)
  man <- repo_manifest(dir)
  if (!quiet) {
    message("serving ", nrow(man), " file(s), ",
            format(round(sum(man$size) / 1024^2, 1), nsmall = 1), " MB")
  }
  invisible(state)
}
