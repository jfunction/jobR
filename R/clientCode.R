#### Get Projects ####
#' Get Projects
#'
#' @param serverURL
#'
#' @return list of project names on the server
#' @export
#'
#' @examples
getProjects <- function(serverURL) {
  res <- httr::content(
    httr::GET(url=fs::path_join(c(serverURL, "projects")), encode="raw"),
    as="parsed")
  res
}

#### Upload Project ####
#' Upload Project
#'
#' @param serverURL
#' @param projectDir
#'
#' @return list with a message SUCCESS
#' @export
#'
#' @examples
uploadProject <- function(serverURL, projectDir=".") {
  absProjDir <- fs::path_abs(projectDir)
  pathJobR <- file.path(absProjDir, "JobR.R")
  if (!file.exists(pathJobR)) {
    warning(paste0("JobR.R does not exist at '", pathJobR, "'"))
    return(FALSE)
  }
  # TODO: cleaner if this is a new environment and we ensure jobRManifest defined
  source(pathJobR)
  zipfile <- paste0(fs::path_join(parts = c(tempdir(), projectName)), ".zip")
  zip::zipr(zipfile=zipfile, files = jobRManifest)
  file.obj <- httr::upload_file(path = zipfile)
  endpoint <- fs::path_join(c(serverURL,"projects/new"))
  res <- httr::POST(endpoint, body = list(file=file.obj))
  out <- httr::content(res, as="parsed")
  fs::file_delete(zipfile)
  out
}

#### Download Project ####
#' Download Project
#'
#' @param projectName
#'
#' @return
#' @export
#'
#' @examples
downloadProject <- function(projectName) {
  clientWorkingDir <- jobrClientWorkingDir()
  dst <- paste0(fs::path_join(c(tempdir(), projectName)), ".zip")
  endpoint <- fs::path_join(c(serverURL,"projects", projectName, "download"))
  res <- httr::GET(url=endpoint,
                   encode="raw",
                   httr::write_disk(dst, overwrite = TRUE))
  if(res$status_code!=200) {
    warning(paste0(
      "Assuming there is an issue, please report this with the status code: ",
      res$status_code))
    return("")
  } else {
    exdir <- fs::path_join(c(clientWorkingDir, "projects", projectName))
    zip::unzip(zipfile = dst, exdir = exdir)
    fs::file_delete(path = dst)  # fs::file_move(dst, new_path = exdir)
    return(exdir)
  }
}

#### Upload job set ####
#' Upload a job set
#'
#' @param serverURL
#' @param projectName
#' @param jobset
#' @param name
#' @param chunksize
#' @param comment
#'
#' @return list with a `guid` and `msg`
#' @export
#'
#' @examples
submitJobset <- function(serverURL, projectName, jobset, name, chunksize, comment) {
  jobsetFile <- tempfile()
  saveRDS(object=jobset, file=jobsetFile)
  file.obj <- httr::upload_file(path = jobsetFile)
  endpoint <- fs::path_join(c(serverURL, "projects", projectName, "jobsets/new"))
  res <- httr::POST(endpoint,
                    body = list(file=file.obj,
                                name=name,
                                chunksize=chunksize,
                                comment=comment))

  out <- httr::content(res, as="parsed")
  fs::file_delete(jobsetFile)
  out
}

#### View jobsets ####
#' View jobsets
#'
#' @param serverURL
#' @param projectName
#'
#' @return
#' @export
#'
#' @examples
getJobsets <- function(serverURL, projectName) {
  res <- httr::content(
    httr::GET(url=fs::path_join(c(serverURL,"projects", projectName, "jobsets")), encode="raw"),
    as="parsed")
  res
}

#### Get a jobset ####
#' Get a jobset
#'
#' @param serverURL
#' @param projectName
#' @param jobsetName
#'
#' @return list with `$jobs` and `$jobIndex` which is -1 if there are no more jobs
#' @export
#'
#' @examples
getJobset <- function(serverURL, projectName, jobsetName) {
  # TODO: Better naming/file handling here
  dst <- paste0(fs::path_join(c(tempdir(), projectName)), "ResultThingy.rds")
  endpoint <- fs::path_join(c(serverURL,"projects", projectName, "jobsets", jobsetName))
  res <- httr::GET(url=endpoint,
                   encode="raw",
                   httr::write_disk(dst, overwrite = TRUE))

  if(res$status_code!=200) {
    warning(paste0(
      "Assuming there is an issue, please report this with the status code: ",
      res$status_code))
    return("")
  } else {
    result <- readRDS(dst)
    file.remove(dst)
    return(result)
  }
}

#### Run a job ####
#' Run a job
#'
#' @param projectName
#' @param dfJobs
#' @param clientEnv
#'
#' @return results of running the job with `runJob` on this chunk
#' @export
#'
#' @examples
runOnce <- function(projectName, dfJobs, clientEnv=NULL) {
  clientWorkingDir <- jobR::jobrClientWorkingDir()
  exdir <- file.path(clientWorkingDir, 'projects', projectName)
  jobRPath <- file.path(exdir, 'jobR.R')
  # file.exists(jobRPath)
  if(is.null(clientEnv))
    clientEnv <- new.env()
  source(file=jobRPath, local=clientEnv, chdir=T)
  results <- withr::with_environment(clientEnv,{
    lapply(1:nrow(dfJobs), function(i) {
      parms <- dfJobs[i,,drop=F]
      #print(parms)
      result <- do.call(runJob,parms)
      #print(result)
      list(index=i, parms=parms, result=result)
    })
  })
  return(results)
}

#### Send results to the server ####
#' Send results to the server
#'
#' @param serverURL
#' @param projectName
#' @param jobsetName
#' @param chunkIndex
#' @param results
#'
#' @return list with "SUCCESS"
#' @export
#'
#' @examples
submitJobsetResult <- function(serverURL, projectName, jobsetName, chunkIndex, results) {
  clientWorkingDir <- jobR::jobrClientWorkingDir()
  resultsDir <- file.path(clientWorkingDir, 'results', projectName, jobsetName)
  if (!dir.exists(resultsDir)) dir.create(resultsDir, recursive = T)
  resultsFile <- file.path(resultsDir, sprintf('%03d.rds', chunkIndex))
  saveRDS(results, file=resultsFile)

  file.obj <- httr::upload_file(path = resultsFile, type = 'rds')
  endpoint <- fs::path_join(c(serverURL, "projects", projectName, "jobsets", jobsetName, chunkIndex))
  res <- httr::POST(endpoint,
                    body = list(file=file.obj))

  out <- httr::content(res, as="parsed")
  out
}

#### Run until done ####
#' Run chunks until there are none left
#'
#' @param serverURL
#' @param projectName
#' @param jobsetName
#'
#' @return
#' @export
#'
#' @examples
runUntilDone <- function(serverURL, projectName, jobsetName=NULL) {
  clientEnv <- new.env()
  processAllJobsets <- is.null(jobsetName)
  loopForJobsets <- T
  processedJobsets <- c()
  while (loopForJobsets) {
    # Fetch all jobsets and keep running them
    if (processAllJobsets) {
      jobsets <- do.call(rbind,lapply(getJobsets(serverURL, projectName), as.data.frame))
      jobsets <- jobsets[order(jobsets$chunksize, decreasing=FALSE)]
      jobsetsToProcess <- setdiff(jobsets$guid,processedJobsets)
      if (length(jobsetsToProcess)>0) {
        jobsetName <- jobsetsToProcess[[1]]
        processedJobsets <- c(processedJobsets, jobsetName)
      } else {
        return()
      }
    } else {
      loopForJobsets <- F
    }

    print(glue::glue("Processing {projectName}/{jobsetName}..."))
    jobsetChunk <- getJobset(serverURL, projectName, jobsetName)
    chunkIndex <- jobsetChunk$jobIndex
    while (chunkIndex>0) {
      print(glue::glue("  {projectName}/{jobsetName}: Processing chunk {chunkIndex}..."))
      results <- runOnce(projectName, jobsetChunk$jobs, clientEnv)
      submitJobsetResult(serverURL, projectName, jobsetName, chunkIndex, results)
      jobsetChunk <- getJobset(serverURL, projectName, jobsetName)
      chunkIndex <- jobsetChunk$jobIndex
    }
    print("Completed all the work :)")
  }
}


#### Ask for job results ####
#' Ask for job results
#'
#' @param projectName
#' @param jobsetGUID
#'
#' @return location where results were unzipped to
#' @export
#'
#' @examples
downloadResults <- function(serverURL, projectName, jobsetGUID) {
  dst <- paste0(fs::path_join(c(tempdir(), jobsetGUID)), ".zip")
  if(!file.exists(dst)) {
    endpoint <- fs::path_join(c(serverURL,
                                "projects", projectName,
                                "jobsets", jobsetGUID,
                                "results"))
    res <- httr::GET(url=endpoint,
                     encode="raw",
                     httr::write_disk(dst, overwrite = TRUE))
    if(res$status_code!=200) {
      warning(paste0(
        "Assuming there is an issue, please report this with the status code: ",
        res$status_code))
      return("")
    }
  }
  clientWorkingDir <- jobR::jobrClientWorkingDir()
  resultsDir <- file.path(clientWorkingDir, 'results', projectName, jobsetName)
  zip::unzip(dst, exdir = resultsDir)
  # fs::file_delete(path = dst)  # fs::file_move(dst, new_path = exdir)
  return(resultsDir)
}

#' Combine results
#'
#' @param projectName
#' @param jobsetGUID
#'
#' @return data.frame with column for combined results
#' @export
#'
#' @examples
combineResults <- function(projectName, jobsetGUID) {
  clientWorkingDir <- jobR::jobrClientWorkingDir()
  resultsDir <- file.path(clientWorkingDir, 'results', projectName, jobsetName)
  rdsFnames <- dir(resultsDir, pattern = '\\d+.rds')
  results <- lapply(file.path(resultsDir,rdsFnames), function(fname){
    do.call(rbind,
            lapply(readRDS(fname),as.data.frame)
    )
  })
  do.call(rbind, results)
}
