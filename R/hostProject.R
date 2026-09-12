#' hostProject
#'
#' @param dir the directory in which the project can be found.
#'
#' @return
#' @export
#'
#' @examples
hostProject <- function(projectID="testProject", dir=".") {
  pathJobR <- fs::path(dir, "jobR.R")
  tmpDir <- fs::path_temp(projectID)
  tmpDirZip <- fs::path_temp(paste0(projectID, '.zip'))
  fs::dir_create(tmpDir)
  source("../jobRTestProject/jobR.R")
  fs::file_copy(manifest, tmpDir, overwrite = TRUE)
  zip::zip(zipfile=tmpDirZip, files = projectID, include_directories=T, recurse = T,
           root = fs::path_temp())
  if (!file.exists(pathJobR)) {
    stop("Expected to find jobR.R in the directory.")
  } else {
    cID <- jobR:::makeRandomID(n=1, len=5)
    return(TRUE)
  }
}
