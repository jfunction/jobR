#' runServer
#'
#' @param port The port to host the server on
#' @param workingDir The directory where the server can store data
#'
#' @return
#' @export
#'
#' @examples
runServer <- function(port=7085, userName="Admin") {
  # TODO: Sanitize userName
  workingDir <- jobrServerDir()
  projectsDir <- jobrServerProjectsDir()
  pathUsersDB <- jobrServerDB()
  if (!dir.exists(workingDir)) dir.create(workingDir)
  if (!dir.exists(projectsDir)) dir.create(projectsDir)
  userSecret <- jobR:::getLocalSecret()
  if (!file.exists(pathUsersDB)) {
    cat("Setting up users database for the first time\n")
    setupServerDB(userName=userName, userSecret=userSecret)
  } else {
    users <- dbGetUsers(dbFilename = pathUsersDB)
    validUsers <- users[users$user_name==userName]
    if (nrow(validUsers)==0) {
      return("Error: No user with this userName, server will not run.")
    }
    userSecret <- head(validUsers$user_secret, 1) # shouldn't need head here but being safe.
  }
  cat(glue::glue("Your jobr secret password is:\n{userSecret}\n\n"))

  cat("Server will start now...\n")
  # TODO: Not sure this environment stuff is still required? Needs some love
  envir <- new.env(parent = .GlobalEnv)
  envir$workingDir <- workingDir
  envir$userSecret <- userSecret
  pr <- plumber::plumb_api('jobR','jobRServer')
  plumber::pr_run(pr, port=port)
}

if (FALSE) {
  jobR::runServer(workingDir = fs::path_join(c("C:/Users/User/AppData/Local/Temp",
                                               "_jobRTestDir")))

  # To setup
  setupJobr <- function() {

  }
}


if (FALSE) { # TEST runServer setup logic
  # initial setup - make a fresh start of things
  source("misc/idConversions.R")
  workingDir <- fs::path_join(c("C:/Users/User/AppData/Local/Temp",
                                "_jobRTestDir"))
  if(dir.exists(workingDir)) fs::dir_delete(workingDir)

  projectsDir <- fs::path_join(c(workingDir, "projects"))
  pathUsersDB <- fs::path_join(c(workingDir, "server.sqlite"))
  if (!dir.exists(workingDir)) fs::dir_create(workingDir)
  if (!dir.exists(projectsDir)) fs::dir_create(projectsDir)
  if (!file.exists(pathUsersDB)) {
    cat("Setting up users database for the first time")
    serverSeedBytes <- c("92", "11", "a2", "2d") # makeRandomSeedBytes()
    serverSeed <- seedBytes2Decimal(serverSeedBytes)
    userSecret <- seed2words(serverSeed, asList=F)
    cat(glue::glue("Your secret password is:\n{userSecret}"))
    setupServerDB(workingDir, userName="Admin", userSecret=userSecret)
  } # else confirm directory is in a good state?
  # test creating a new project
  projectName="TestProject"
  pathZipSrc=""  # When the user uploads a zipfile, this is the source location
  # TODO: sanitize pathZipSrc
  projectDir <- fs::path_join(c(projectsDir, projectName))
  if (!dir.exists(projectDir)) {
    fs::dir_create(projectDir)
    fs::file_copy(pathZipSrc, fs::path_join(c(projectDir,paste0(projectName,".zip"))), overwrite=TRUE)
    userSecret <- getLocalSecret() # TODO: FIXME: Get this from the user in future... for now no security is ok.
    setupProjectDB(projectName=projectName, userSecret = userSecret)
    jobrServerProjectJobsetParmsDir(projectName)
    jobrServerProjectJobsetResultsDir(projectName)
  }
}

if (FALSE) { # Test server new project setup logic
  # Need to have a zipfile, a (valid) client token and a client name
}
