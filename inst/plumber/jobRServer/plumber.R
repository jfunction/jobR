#
# This is a Plumber API. You can run the API by clicking
# the 'Run API' button above.
#
# Find out more about building APIs with Plumber here:
#
#    https://www.rplumber.io/
#

# NOTES/Snippets I might want later:
# Include a file in the response:
# include_file(file, res, content_type = getContentType(tools::file_ext(file)))


library(plumber)

#* @apiTitle JobR Server API
#* @apiDescription Manages connection between JobR clients and the JobRServer






# /projects ####
#* Return a list of projects
#* @get /projects
function() {
  projectsDir <- jobR::jobrServerProjectsDir()
  as.character(fs::path_file(fs::dir_ls(projectsDir)))
}

# /projects/new ####
#* Upload a new project
#* @param userSecret:chr
#* @post /projects/new
function(req) {
  projectName="TestProject"
  formContents <- mime::parse_multipart(req)
  dfFile <- as.list(head(formContents$file,1))
  pathZipSrc=dfFile$datapath  # When the user uploads a zipfile, this is the source location
  # TODO: sanitize pathZipSrc
  isProjectIDValid = length(grep(pattern = "^[a-zA-Z0-9]+[.]zip$", x = dfFile$name))==1
  # TODO: Consider: Could also enforce a max strlen
  if (!isProjectIDValid) {
    return("FAIL: Invalid Project Name, only alphanumeric allowed")
  } else {
    projectName <- sub(x=dfFile$name, pattern="\\.zip", replacement="")
    userSecret <- formContents$userSecret
    # TODO: Test making the directory, saving the zipfile and setupProjectDB
    # projectsDir <- "C:/Users/User/AppData/Local/Temp/_jobRTestDir/projects"  # TODO: Make this dynamic
    projectDir <- jobR::jobrServerProjectDir(projectName)
    if (dir.exists(projectDir)) {
      return("FAIL: Project with that name already exists on this server")
    } else {
      fs::dir_create(projectDir)
      fs::file_copy(pathZipSrc, fs::path_join(c(projectDir,paste0(projectName,".zip"))), overwrite=TRUE)
      userSecret <- jobR::getLocalSecret() # TODO: FIXME: Get this from the user in future... for now no security is ok.
      jobR::setupProjectDB(projectName=projectName, userSecret = userSecret)
      jobR::jobrServerProjectJobsetParmsDir(projectName = projectName)
      jobR::jobrServerProjectJobsetResultsDir(projectName = projectName)
      return("SUCCESS")
    }
  }
}

# /projects/<>/download ####
#* Download a project zip file
#* @serializer contentType list(type="application/zip")
#* @get /projects/<projectID:chr>/download
function(projectID) {
  zipname <- paste0(projectID,".zip")
  fname <- file.path(jobR::jobrServerProjectDir(projectID), zipname)
  fileContents <- readBin(fname, what='raw', n=file.info(fname)$size)
  result <- plumber::as_attachment(fileContents, filename=zipname)
  result
}

# /projects/<>/jobsets ####
#* List jobsets for a project
#* @get /projects/<projectID:chr>/jobsets
function(projectID) {
  # TODO: SANITIZE
  dbFilename <- jobR::jobrServerProjectDB(projectID)
  jobR::dbGetJobsets(dbFilename)
}

# /projects/<>/jobsets/new ####
#* Upload a jobset .rds file
#* @post /projects/<projectID:chr>/jobsets/new
#* @serializer json
#* @parser multi
#* @param file:file An rds file corresponding to the job inputs
#* @param name:chr A unique alphanumeric name
#* @param chunksize:int Number of jobs to process per resultset
#* @param comment:chr A comment generally used to contextualise this jobset
function(req) {# Not entirely sure how to do this.
  projectID <- req$args$projectID
  formContents <- mime::parse_multipart(req)
  dfFile <- as.list(head(formContents$file,1))
  filePath <- dfFile$datapath
  seed <- jobR::seedBytes2Decimal(jobR:::makeRandomSeedBytes())
  print(seed)#TODO: Remove print statement
  set.seed(seed)
  guid <- jobR::makeRandomID(n=1, len = 5)

  # num_jobs = nrow(readRDS(filePath))

  dstPath <- file.path(jobR::jobrServerProjectJobsetParmsDir(projectID), paste0(guid,".rds"))
  file.copy(filePath, dstPath)
  file.remove(filePath)
  # print(list(dbFilename = jobR::jobrServerProjectDB(projectName = projectID),
  #            guid = guid,
  #            name = formContents$name,
  #            chunksize = as.integer(formContents$chunksize),
  #            comment = formContents$comment))

  jobR::dbAddJobset(dbFilename = jobR::jobrServerProjectDB(projectName = projectID),
                    guid = guid,
                    name = formContents$name,
                    chunksize = as.integer(formContents$chunksize),
                    comment = formContents$comment)
  return(list(guid=guid, msg="Success"))
}

# /projects/<>/jobsets/<> GET ####
#* Get a chunk index to be processed
#* @serializer rds
#* @get /projects/<projectID:chr>/jobsets/<jobsetGUID:chr>
function(projectID, jobsetGUID) {
  # TODO get an actual index
  dbFilename = jobR::jobrServerProjectDB(projectName = projectID)
  jobset <- jobR::dbGetJobsetUnconsumed(dbFilename, guid=jobsetGUID)
  if (jobset$chunkIndex==-1) {
    return(list(jobs=NULL, msg="SUCCESS", jobIndex=-1))
  }
  df <- as.data.frame(jobset$df)
  # browser()
  jobIndex <- jobset$chunkIndex
  userSecret = "TODO"  # TODO: Make this a param
  jobR::dbAddEvent(dbFilename = dbFilename, userSecret = userSecret, jobsetGUID = jobsetGUID, jobIndex = jobIndex, jobStatus = "sent")
  # Hang on, does this send back the rds file as well as some other parameters?
  # Maybe instead of giving the jobIndex we give a token? Then we can be more sure when we're tracking outstanding jobsets what came from where?
  return(list(jobs=df, msg="SUCCESS", jobIndex=jobIndex))
}

# /projects/<>/jobsets/<> POST ####
#* Upload a set of results
#* @parser multi
#* @post /projects/<projectID:chr>/jobsets/<jobsetGUID:chr>/<jobIndex:int>
function(projectID, jobsetGUID, jobIndex, req) {
  dbFilename = jobR::jobrServerProjectDB(projectName = projectID)
  formContents <- mime::parse_multipart(req)
  dfResult <- readRDS(formContents$file$datapath)
  resultsDir <- file.path(jobR::jobrServerProjectJobsetResultsDir(projectID),
                          jobsetGUID)
  if (!dir.exists(resultsDir)) dir.create(resultsDir, recursive = T)
  fname <- file.path(resultsDir,
                     sprintf('%03d.rds', jobIndex))
  file.copy(formContents$file$datapath, fname)
  file.remove(formContents$file$datapath)
  userSecret = "TODO"
  jobR::dbAddEvent(dbFilename = dbFilename,
                   userSecret = userSecret,
                   jobsetGUID = jobsetGUID,
                   jobIndex = jobIndex,
                   jobStatus = "received")
  return("SUCCESS")
}

# /projects/<>/jobset/<>/events ####
#* Get all events for this particular jobsetGUID
#* @get /projects/<projectID:chr>/jobsets/<jobsetGUID:chr>/events
#* @serializer json
function(projectID, jobsetGUID) {
  dbFilename = jobR::jobrServerProjectDB(projectName = projectID)
  result <- jobR::dbGetEvents(dbFilename)
  result <- result[result$jobset_guid==jobsetGUID,,drop=F]
  result
}

# /projects/<>/jobset/<>/results ####
#* Get all results for this particular jobsetGUID
#* @get /projects/<projectID:chr>/jobsets/<jobsetGUID:chr>/results
#* @serializer contentType list(type="application/zip")
function(projectID, jobsetGUID) {
  dirResults <- file.path(jobR::jobrServerProjectJobsetResultsDir(projectName = projectID),
                          jobsetGUID)
  # What you think? Zip it and send? Do the processing on the server before sending?
  # What if results are not all in yet?
  # For now I'm gonna zip it and send
  fname <- paste0(jobsetGUID,'.zip')
  zip::zipr(zipfile = fname, files = dirResults, recurse = T)
  fileContents <- readBin(fname, what='raw', n=file.info(fname)$size)
  result <- plumber::as_attachment(fileContents, filename=fname)
  file.remove(fname)
  result
}

# /projects/<>/events ####
#* Get all events for this project
#* @get /projects/<projectID:chr>/events
function(projectID) {
  dbFilename = jobR::jobrServerProjectDB(projectName = projectID)
  result <- jobR::dbGetEvents(dbFilename)
  result
}

# /inspect ####
# Leaving this code here for later.
# @post /inspect
function(name, data) {
  print('---------')
  print(name)
  print('=-=-=-=-=')
  print(data)

  file_info <- data.frame(
    filename = name,
    mtime = file.info(data)$mtime,
    ctime = file.info(data)$ctime
  )
  return(file_info)
}
