#' jobr Configuration Directory
#'
#' Forms the path to a location on disk where user-level configuration data for
#' the package is stored.
#'
#' @param subDir An optional subdirectory to be included as the last element of
#'   the path.
#'
#' @return The path to the configuration directory.
#'
#' @keywords internal
jobrConfigDir <- function(subDir = NULL) {

  # Compute the name of the configuration directory using the standard R method
  configDir <- applicationConfigDir()

  # Form the target and append the optional subdirectory if given
  target <- configDir
  if (!is.null(subDir)) {
    target <- file.path(target, subDir)
  }

  # Create the path if it doesn't exist
  dir.create(target, recursive = TRUE, showWarnings = FALSE)

  # Return completed path
  target
}

#' Application Configuration Directory
#'
#' Returns the root path used to store per user configuration data. Does not
#' create the path; use \code{jobrConfigDir} for most cases.
#'
#' @return A string containing the path of the configuration folder.
#'
#' @keywords internal
applicationConfigDir <- function()  {
  rappdirs::user_config_dir(appname='jobr', appauthor='R', roaming=T)
}

#' jobr Data Directory
#'
#' Forms the path to a location on disk where user-level project data for
#' the package is stored.
#'
#' @param subDir An optional subdirectory to be included as the last element of
#'   the path.
#'
#' @return The path to the data directory.
#'
#' @keywords internal
jobrDataDir <- function(subDir = NULL) {

  # Compute the name of the data directory using the standard R method
  dataDir <- applicationDataDir()

  # Form the target and append the optional subdirectory if given
  target <- dataDir
  if (!is.null(subDir)) {
    target <- file.path(target, subDir)
  }

  # Create the path if it doesn't exist
  dir.create(target, recursive = TRUE, showWarnings = FALSE)

  # Return completed path
  target
}

#' Application Data Directory
#'
#' Returns the root path used to store per user project data. Does not
#' create the path; use \code{jobrDataDir} for most cases.
#'
#' @return A string containing the path of the data folder.
#'
#' @keywords internal
applicationDataDir <- function()  {
  rappdirs::user_data_dir(appname='jobr', appauthor='R', roaming=T)
}


#' Client working directory
#'
#' @return path to directory where client data is stored
#' @export
#'
#' @examples
jobrClientWorkingDir <- function() {
  jobrDataDir("client")
}

#' Server working directory
#'
#' @return path to directory where server data is stored
#' @export
#'
#' @examples
jobrServerDir <- function() {
  jobrDataDir("server")
}

jobrServerDB <- function() {
  file.path(jobrServerDir(), 'server.sqlite')
}

jobrServerProjectsDir <- function() {
  result <- file.path(jobrServerDir(), 'projects')
  if (!dir.exists(result)) dir.create(result)
  result
}

jobrServerProjectDir <- function(projectName) {
  file.path(jobrServerProjectsDir(), projectName)
}

jobrServerProjectDB <- function(projectName) {
  # TODO: sanitize
  file.path(jobrServerProjectDir(projectName), 'project.sqlite')
}

jobrServerProjectJobsetParmsDir <- function(projectName) {
  # TODO: sanitize
  result <- file.path(jobrServerProjectDir(projectName), 'JobsetParms')
  if (!dir.exists(result)) dir.create(result)
  result
}

jobrServerProjectJobsetResultsDir <- function(projectName) {
  # TODO: sanitize
  result <- file.path(jobrServerProjectDir(projectName), 'JobsetResults')
  if (!dir.exists(result)) dir.create(result)
  result
}
