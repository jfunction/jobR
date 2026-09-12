# Some notes on using sqlite
# To make a primary key just say "PRIMARY KEY" after the datatype
# and optionally specify --Autoincrement
# To make a foreign key, eg an artist has many tracks, do this:
# `FOREIGN KEY(trackartist) REFERENCES artist(artistid)`
# To ensure something can't be null just do `NOT NULL`

# We need a server.sqlite in the main folder
# Then in each Projects/{ProjectName} folder we need the project.sqlite
# The server.sqlite just looks like this:
# user_id <int>, user_secret <char>, user_name <char>, created <date>

# As a rule of thumb - everything is in snake_case!
# Database file names: snake_case
# Table names: snake_case
# Column names: snake_case

makeDBBase <- function(db, tableName, otherCols, idCol="job_id", autoincrement=T) {
  # TODO: warn user if any names in otherCols are not snake case (or maybe just lowercase)
  sqlTypesList <- DBI::dbDataType(db, otherCols)
  parmNames <- names(sqlTypesList)
  parmTypes <- unname(sqlTypesList)
  otherColsSQLText <- paste(parmNames, parmTypes, sep=" ", collapse = ",\n  ")

  AIText <- ifelse(autoincrement,"-- Autoincrement","")

  if (ncol(otherCols)>0) {
    SqlCmd <- glue::glue("CREATE TABLE {tableName}
(
  {idCol} INTEGER PRIMARY KEY, {AIText}
  {otherColsSQLText}
)")
  } else {
    stop("Need to supply at least one column to the otherCols tibble!")
  }
  DBI::dbExecute(db, SqlCmd)
}
#' setupDB
#'
#' @return
#' @export
#'
#' @examples

setupServerDB <- function(userName, userSecret=NULL) {
  if (is.null(userSecret)) userSecret <- getLocalSecret()
  workingDir <- jobrServerDir()
  dbFilename <- fs::path_join(c(workingDir, "server.sqlite"))
  if (!dir.exists(workingDir)) {
    warning("Expected the working directory to exist. Doing nothing.")
  } else if (file.exists(dbFilename)) {
    warning("Database server.sqlite already exists. Doing nothing. Delete it if you don't want it.")
  } else {
    dbCreateTableUsers(dbFilename)
    dbAddUser(dbFilename, userName=userName, userSecret=userSecret)
  }
}

#' Setup a project.sqlite database for a given project which exists on disk
#'
#' @param projectName unique alphanumeric project name
#' @param userSecret the jobR secret associated with the project owner
#'
#' @return
#' @export
#'
#' @examples
setupProjectDB <- function(projectName, userSecret) {
  workingDir <- jobrServerDir()
  # FIXME: Sanitise inputs?
  projectDir <- jobrServerProjectDir(projectName)
  dbFilename <- jobrServerProjectDB(projectName)
  if (!dir.exists(projectDir)) {
    warning("Expected the project directory to exist. Doing nothing.")
  } else if (file.exists(dbFilename)) {
    warning("Database project.sqlite already exists. Doing nothing. Delete it if you don't want it.")
  } else {
    dbCreateTableUsers(dbFilename)
    # dbAddUser(dbFilename, userName=userName, userSecret=userSecret)
    dbCreateTableJobsets(dbFilename)
    dbCreateTableEvents(dbFilename)
  }
}

# Create Tables ####

# server.sqlite is for server admins only
# project.sqlite is for project owners and job consumers but this is overridden if you're a server owner
# Both have a `users` table with:
# user_id <int>, user_secret <char>, user_name <char>, created <date>
# Additionally project.sqlite has an `events` table to monitor when jobs were sent/received/cancelled and to/from/by which users
# Assume if the user is not in the project.sqlite `users` table that they are in the servers server.sqlite database
dbCreateTableUsers <- function(dbFilename) {
  db <- DBI::dbConnect(RSQLite::SQLite(), dbname = dbFilename)
  makeDBBase(db=db,
             tableName="users",
             idCol="user_id",
             otherCols = head(tibble::tibble(
               user_secret="", # token words
               user_name="",
               created=Sys.time()
             ), 0))
  DBI::dbDisconnect(db)
}

dbCreateTableJobsets <- function(dbFilename) {
  db <- DBI::dbConnect(RSQLite::SQLite(), dbname = dbFilename)
  makeDBBase(db=db,
             tableName="jobsets",
             idCol = "jobset_id",
             otherCols = head(tibble::tibble(
               name = "",
               guid = "",
               num_jobs = 0,
               chunksize = 1,
               comment = "",
               created = Sys.time()),0))
  DBI::dbDisconnect(db)
}

# inside project.sqlite:
dbCreateTableEvents <- function(dbFilename) {
  db <- DBI::dbConnect(RSQLite::SQLite(), dbname = dbFilename)
  makeDBBase(db=db,
             tableName="events",
             idCol = "event_id",
             otherCols = head(tibble::tibble(
               user_token = "",
               jobset_guid = "",
               jobset_chunk_index = 1,
               event_type = "", # sent/received/[server/client]cancelled
               timestamp = Sys.time()),0))
  DBI::dbDisconnect(db)
}

# Get Tables/Results ####

dbGetUsers <- function(dbFilename) {
  db <- DBI::dbConnect(RSQLite::SQLite(), dbname = dbFilename)
  result <- DBI::dbReadTable(db, 'users')
  DBI::dbDisconnect(db)
  result
}

dbGetUsersFromSecret <- function(projectName, userSecret) {
  db.serv <- DBI::dbConnect(RSQLite::SQLite(), dbname = jobrServerDB())
  db.proj <- DBI::dbConnect(RSQLite::SQLite(), dbname = jobrServerProjectDB(projectName))
  dfUsersServ <- DBI::dbGetQuery(db.serv, "SELECT * FROM users WHERE user_secret = ?", params=userSecret)
  dfUsersProj <- DBI::dbGetQuery(db.proj, "SELECT * FROM users WHERE user_secret = ?", params=userSecret)
  dfUsersServ$isServ=T
  dfUsersProj$isServ=F
  rbind(dfUsersServ,dfUsersProj)
}

dbGetJobsets <- function(dbFilename) {
  db <- DBI::dbConnect(RSQLite::SQLite(), dbname = dbFilename)
  result <- DBI::dbReadTable(db, 'jobsets')
  DBI::dbDisconnect(db)
  result
}

dbGetEvents <- function(dbFilename) {
  db <- DBI::dbConnect(RSQLite::SQLite(), dbname = dbFilename)
  result <- DBI::dbReadTable(db, 'events')
  DBI::dbDisconnect(db)
  result
}

#' Get an unconsumed jobset for clientside processing
#'
#' @param dbFilename
#' @param guid
#'
#' @return list(chunkIndex, dfJobset)
#' @export
#'
#' @examples
dbGetJobsetUnconsumed <- function(dbFilename, guid) {
  # NULL means don't filter just get any available jobset.
  tbJobsets <- dbGetJobsets(dbFilename)
  tbJobsets <- tbJobsets[tbJobsets$guid==guid,,drop=F]

  tbEvents <- dbGetEvents(dbFilename)
  tbEvents <- tbEvents[tbEvents$jobset_guid==guid,,drop=F]
  print('1---')
  print(tbJobsets)
  print('2---')
  print(tbEvents)
  print('3---')
  # 3 possibilities for each possible jobset
  # 1) it has already been processed
  idJobsRecieved <- sort(unique(tbEvents$jobset_chunk_index[tbEvents$event_type=='received']))
  # 2) it was sent but not (yet) received, ie pending
  # FIXME: What about cancelled jobs?
  idJobsSent <- sort(unique(tbEvents$jobset_chunk_index[tbEvents$event_type=='sent']))
  idJobsPending <- setdiff(idJobsSent, idJobsRecieved)
  # 3) it has never been sent
  # FIXME: What about cancelled jobs?
  chunksize <- head(tbJobsets$chunksize,1) # jobRTestProject/L2S8H
  nChunks <- floor(tbJobsets$num_jobs/tbJobsets$chunksize)
  idJobsUnsent <- setdiff(1:nChunks, idJobsSent)
  print(glue::glue("*-------SUMMARY:--------------*"))
  print(glue::glue("- Jobs received: {paste0(idJobsRecieved,collapse=',')}"))
  print(glue::glue("- Jobs pending: {paste0(idJobsPending,collapse=',')}"))
  print(glue::glue("- Jobs unsent: {paste0(idJobsUnsent,collapse=',')}"))


  if (length(idJobsUnsent)>1) {
    chunkIndex <- head(idJobsUnsent, 1)
  } else {
    if (length(idJobsPending)>0) {
      chunkIndex <- head(idJobsPending, 1)
    } else {
      warning("uncaught exception where all jobs were already recieved!")
      chunkIndex <- -1
    }
  }
  if (chunkIndex==-1) {
    return(list(chunkIndex=-1, df=data.frame(msg="Jobset complete")))
  }

  projectName <- stringr::str_match(dbFilename,pattern="/projects/([^/]+)/")[[2]]
  fname <- file.path(jobrServerProjectJobsetParmsDir(projectName), paste0(guid,'.rds'))
  dfJobset <- readRDS(fname)
  print(glue::glue("- Raw dfJobset from {fname}:"))
  print(head(dfJobset))
  chunksize <- head(tbJobsets$chunksize, 1)
  chunkstart <- chunksize*(chunkIndex-1) + 1
  chunkend <- min(chunkstart+chunksize-1, nrow(dfJobset))
  print(glue::glue("- ChunkIndex = {chunkIndex}"))
  print(glue::glue("- dfJobset[{chunkstart}:{chunkend},,drop=F]:"))
  print(dfJobset[chunkstart:chunkend,,drop=F])
  print(glue::glue('*-----------------------------*'))
  list(chunkIndex=chunkIndex, df=dfJobset[chunkstart:chunkend,,drop=F])
}

sortIndicesByPriority <- function(numChunks, tbEvents, tbResults) {
  # Take all valid chunkIDs from tbJobsets
  tbJobset
}

# Add to Tables ####

dbAddUser <- function(dbFilename, userName, userSecret) {
  # FIXME: Sanitize inputs! Check user_secret is valid!
  row=data.frame(user_secret=userSecret,
                 user_name=userName,
                 created=Sys.time())
  db <- DBI::dbConnect(RSQLite::SQLite(), dbname = dbFilename)
  DBI::dbAppendTable(db, 'users', row)
  DBI::dbDisconnect(db)
}

dbAddJobset <- function(dbFilename, guid, name, chunksize, comment) {
  # TODO: Decide if the db* methods should be doing things like getting num_jobs from disk
  # Confirm it exists on disk
  projectName <- stringr::str_match(dbFilename,pattern="/projects/([^/]+)/")[[2]]
  fpath <- file.path(jobrServerProjectJobsetParmsDir(projectName = projectName), paste0(guid, ".rds"))
  if (!file.exists(fpath)) {
    warning("Jobset file does not exist so will not add to the database")
    return(FALSE)
  }
  num_jobs <- nrow(readRDS(fpath))
  db <- DBI::dbConnect(RSQLite::SQLite(), dbname = dbFilename)
  row <- data.frame(name = name,
                    guid = guid,
                    num_jobs = num_jobs,
                    chunksize = chunksize,
                    comment = comment,
                    created = Sys.time()
  )
  DBI::dbAppendTable(db, 'jobsets', row)
  DBI::dbDisconnect(db)
}

dbAddEvent <- function(dbFilename, userSecret, jobsetGUID, jobIndex, jobStatus) {
  # Make sure jobStatus is one of sent/received/[server/client]cancelled
  # FIXME: sanitize! Check user has rights? if received check the user was sent it? Not cancelled? Think of other checks.
  db <- DBI::dbConnect(RSQLite::SQLite(), dbname = dbFilename)
  # dfProjectUsers <- DBI::dbGetQuery(db, "SELECT * FROM users WHERE user_secret = ?", params=userSecret)
  # if (length(dfProjectUsers)==0) {
  #
  # }
  # event_id           user_token         jobset_guid        jobset_chunk_index event_type         timestamp
  row <- data.frame(user_token=paste0(userSecret,collapse='-'),
                    jobset_guid=jobsetGUID,
                    jobset_chunk_index=jobIndex,
                    event_type=jobStatus,
                    timestamp=Sys.time())
  DBI::dbAppendTable(db, 'events', row)
  DBI::dbDisconnect(db)
}
