# Start, set up trials_df -----
library(apsimx)
library(tidyverse)
library(daymetr)
library(data.table)
library(soilDB)
library(spData)
library(here)
library(parallel)  # For parallel computing
Sys.setlocale("LC_ALL", "English_United States")
start_time <- Sys.time() # track running time

codes_dir <- here() #where the folder with the codes is
#codes_dir <- "C:/Users/cmg3/Documents/GitHub/SCT"
results_dir <- paste0(codes_dir,"/apsimx_output") #folder where the output goes
#results_dir <- ("C:/Users/cmg3/Documents/GitHub/SCT/apsimx_output") 
setwd(results_dir) 

crop <- readLines("C:/Users/cmg3/Documents/GitHub/SCT/selected_crop.txt")
#crop <- "Soy" 

trials_df <- read_csv(paste0(codes_dir,"/apsimx_output/output/input.csv")) 
trials_df <- mutate(trials_df, ID = row_number()) %>% rename(X = Longitude, Y = Latitude)
locs_df <- select(trials_df, X, Y) %>% distinct() %>% mutate(ID_Loc = row_number())
trials_df <- left_join(trials_df, locs_df)

#set up progress log
writeLines("Progress Log:", "progress.log") #Create file
CON <- file("progress.log", "a")    #Open connection to append

#require year as part of the input
writeLines("Parse dates", CON)

prev_year <- as.numeric(substr(Sys.time(),1,4)) - 1
yesterday <- as.character(today() - days(1))

trials_df <- suppressWarnings(mutate(trials_df, Year = as.numeric(str_extract(Planting, "\\b\\d{4}\\b"))))
trials_df <- suppressWarnings(mutate(trials_df, PlantingDate = as_date(as.character(trials_df$Planting), format = "%Y-%m-%d")))
trials_df <- mutate(trials_df, 
  Year = ifelse(is.na(PlantingDate), Year, format(PlantingDate,"%Y")), 
  Year = ifelse(is.na(Year), prev_year, Year), #if no year, use last year with full data
  # if no planting date, use beginning and end of year as boundaries
  sim_start = if_else(is.na(PlantingDate), as_date(paste0(as.character(Year),"-01-01")), as_date(PlantingDate %m-% months(1))), 
  sim_end = if_else(is.na(PlantingDate), as_date(paste0(as.character(Year),"-12-31")), as_date(PlantingDate %m+% months(10))))

# Get what maturities of cultivar we'll use
writeLines("Set maturities", CON)

if (crop == "Soy"){
  trials_df <- trials_df %>% mutate(gen1 = floor(Genetics), gen2 = Genetics - gen1) %>%
    mutate(gen1 = case_when( 
      gen1 >= 10 ~ "10",
      gen1 <= -2 ~ "000",
      gen1 == -1 ~ "00",
      gen1 == 0 ~ "0",
      gen1 >= 1 & Genetics <= 9 ~ as.character(gen1)
    )) %>% mutate(gen2 = case_when( 
      gen1 >= 8 ~ "Generic_MG",
      gen2 >= 0 & gen2 < 0.33 ~ "early",
      gen2 >= 0.33 & gen2 < 0.66 ~ "mid",
      gen2 >= 0.66 ~ "late"
    )) %>% mutate(Mat = paste0(gen2,gen1)) %>% 
    select(-gen1, -gen2)
}

if (crop == "Maize"){
  trials_df <- trials_df %>% mutate(lett = str_to_upper(str_extract(Genetics,"^[A-Za-z]")), 
                                    num = as.numeric(str_extract(Genetics,"\\d+")))
  trials_df <- trials_df %>% mutate(lett = ifelse(is.na(lett), "B", lett))
  corn_mats <- c(80,90,95,100,103,105,108,110,112,115,120,130)
  trials_df <- trials_df %>% rowwise() %>%
    mutate(num = corn_mats[which.min(abs(corn_mats - num))[1]]) %>%
    mutate(Mat = paste0(lett,"_",as.character(num)))
  trials_df <- select(trials_df, -lett, -num)
}

# Get weather, make met files -----

# For each location, collect weather data for years from minimum (first requested year, ten years before now) to most recent full year
locyear_df <- trials_df %>% select(X,Y,ID_Loc, sim_start) %>% 
  mutate(first_year = year(sim_start)) %>% 
  select(-sim_start) %>% unique() %>% group_by(ID_Loc,X,Y) %>%
  summarize(first_year = min(first_year)) %>%
  mutate(first_year = min(first_year, prev_year - 10), last_year = prev_year) 

unlink("met",recursive = T) ; dir.create("met")

# Setup for parallel processing
no_cores <- detectCores() - 2  # Reserve 2 cores for the system
cl <- makeCluster(no_cores)
clusterExport(cl, varlist = c("locyear_df","yesterday","get_daymet2_apsim_met","get_power_apsim_met",
                              "napad_apsim_met", "impute_apsim_met", "write_apsim_met"), envir = environment())


# Ensure the directory exists for weather data
dir.create("met", recursive = TRUE, showWarnings = FALSE)

parLapply(cl, seq_len(nrow(locyear_df)), function(idx) {
  locyear_tmp <- locyear_df[idx, ]
  try({
    #met_tmp <- get_daymet2_apsim_met(lonlat = c(locyear_tmp$X, locyear_tmp$Y), 
    #                                 years = c(as.integer(locyear_tmp$first_year), as.integer(locyear_tmp$last_year)), 
    #                                 silent = TRUE)
    met_tmp <- get_power_apsim_met(lonlat = c(locyear_tmp$X, locyear_tmp$Y),
                        dates = c(paste0(locyear_tmp$first_year,"-01-01"), yesterday))
  
    na_met_tmp <- tryCatch(napad_apsim_met(met_tmp), error = function(e) met_tmp)
    imp_met_tmp <- tryCatch(impute_apsim_met(na_met_tmp), warning = function(w) na_met_tmp)
    attr(imp_met_tmp, "site") <- attr(met_tmp, "site")
    attr(imp_met_tmp, "latitude") <- attr(met_tmp, "latitude")
    attr(imp_met_tmp, "longitude") <- attr(met_tmp, "longitude")
    write_apsim_met(imp_met_tmp, wrt.dir = "met", paste0("loc_", locyear_tmp$ID_Loc, ".met"))
  })
})


# Get soil, make soil file -----
soil_profile_list = list()
unlink("soils",recursive = T) ; dir.create("soils")
locs_df$got_soil <- NA

ids_needs_soil <- locs_df[locs_df$got_soil == F | is.na(locs_df$got_soil),]$ID_Loc
for (id in ids_needs_soil){
  locs_tmp <- locs_df[locs_df$ID_Loc == id,]
  tryCatch({
    soil_profile_tmp <- tryCatch(get_ssurgo_soil_profile(lonlat = c(locs_tmp$X,locs_tmp$Y), fix = T),
                                 error = function(e){soil_profile_tmp <- list(get_isric_soil_profile(lonlat = c(locs_tmp$X,locs_tmp$Y), fix = T))})
    
    horizon <- soil_profile_tmp[[1]]$soil 
    
    soilwat <- soilwat_parms() #creating SWCON in SoilWater parameters
    PO <- 1-horizon$BD/2.65
    soilwat$SWCON <- (PO-horizon$DUL)/PO
    soilwat$SWCON <- ifelse(soilwat$SWCON < 0, 0, soilwat$SWCON)
    soilwat$Thickness <- horizon$Thickness 
    soil_profile_tmp[[1]]$soilwat <- soilwat
    
    initwat <- initialwater_parms() #set initial water to reasonable values
    initwat$InitialValues <- horizon$DUL
    initwat$Thickness <- horizon$Thickness
    soil_profile_tmp[[1]]$initialwater <- initwat
    
    oc_min <- 0.001 #set minimum carbon content in soils
    given_oc <- soil_profile_tmp[[1]][["soil"]]$Carbon
    soil_profile_tmp[[1]][["soil"]]$Carbon <- ifelse(given_oc < oc_min, oc_min, given_oc) 
    
    write_rds(soil_profile_tmp, file = paste0("soils/soil_profile_",id))
    soil_profile_list[[as.character(id)]] <- soil_profile_tmp[[1]]
    locs_df[locs_df$ID_Loc == id,"got_soil"] <- T
    print(paste0("loc: ",id,"   ",round(which(ids_needs_soil == id)/length(ids_needs_soil),4)))
  }, error = function(e){
    locs_df[locs_df$ID_Loc == id,"got_soil"] <<- F
    print(paste0("loc: ",id,"   ",round(which(ids_needs_soil == id)/length(ids_needs_soil),4),"  FAIL"))
  })
}
write_rds(soil_profile_list, "soils/soil_profile_list.rds")


# Create APSIM files -----
unlink("apsim", recursive = TRUE)
dir.create("apsim")
file.copy(from = paste0(codes_dir, "/template_models/", crop, "_Template.apsimx"),
          to = paste0(crop, "_.apsimx"), overwrite = TRUE)

# Prepare for parallel processing

clusterExport(cl, c("trials_df", "codes_dir", "crop", "edit_apsimx", "edit_apsimx_replace_soil_profile", 
                    "paste0", "dir.create", "file.copy", "tryCatch", "print"))

# Parallel APSIM files creation
apsimxfilecreate <- parLapply(cl, 1:nrow(trials_df), function(trial_n) {
  trial_tmp <- trials_df[trial_n,]
  if(!dir.exists(paste0("apsim/trial_",trial_n))) {dir.create(paste0("apsim/trial_",trial_n))}
  source_dir <- paste0("apsim/trial_",trial_n)
  write_dir <-  paste0("apsim/trial_",trial_n)
  filename <- paste0(crop, "_", trial_n,".apsimx")
  edit_apsimx(file = paste0(crop,"_.apsimx"), wrt.dir = write_dir, edit.tag = trial_n,
              node = "Clock", parm = "Start", value = paste0(trial_tmp$sim_start,"T00:00:00"), verbose = F)
  edit_apsimx(file = filename,  src.dir = source_dir, wrt.dir = write_dir, overwrite = T,
              node = "Clock", parm = "End", value = paste0(trial_tmp$sim_end,"T00:00:00"), verbose = F)
  edit_apsimx(file = filename, src.dir = source_dir, wrt.dir = write_dir, overwrite = T,
              node = "Weather", value = paste0(getwd(),"/met/loc_",trial_tmp$ID_Loc,".met"), verbose = F)
  if (is.na(trial_tmp$PlantingDate)) {
    edit_apsimx(filename, src.dir = source_dir,  wrt.dir = write_dir, overwrite = T,
                node = "Manager", manager.child = "Sowing",
                parm = "SowDate", value = "NA", verbose = F)
    edit_apsimx(filename, src.dir = source_dir, wrt.dir = write_dir, overwrite = T, node = "Crop", parm = "SowDate", 
                value = "NA", verbose = F)
  } else {
    edit_apsimx(filename, src.dir = source_dir,  wrt.dir = write_dir, overwrite = T,
                node = "Manager", manager.child = "Sowing",
                parm = "SowDate", value = as.character(format(trial_tmp$PlantingDate, "%d-%b")), verbose = F)
    edit_apsimx(filename, src.dir = source_dir, wrt.dir = write_dir, overwrite = T, node = "Crop", parm = "SowDate", 
                value = as.character(format(trial_tmp$PlantingDate, "%d-%b")), verbose = F)
  }
  edit_apsimx(filename, src.dir = source_dir,  wrt.dir = write_dir, overwrite = T,
              node = "Crop", parm = "CultivarName", value = trial_tmp$Mat, verbose = F)
  tryCatch({
    edit_apsimx_replace_soil_profile(file = filename, src.dir = source_dir, wrt.dir = write_dir, overwrite = T,
                                     soil.profile = soil_profile_list[[as.character(trial_tmp$ID_Loc)]], verbose = F)
  }, error = function(e){})
  invisible()
})

# Run APSIM files -----

# Define the number of batches
if (nrow(trials_df) <= 10) {
  num_batches <- 1 # If there are few trials, only run one batch. 
} else {num_batches <- 10} # You can change this to run different percentages at a time

# Calculate the number of trials per batch
batch_size <- ceiling(nrow(trials_df) / num_batches)


clusterExport(cl, c("trials_df", "codes_dir", "crop", "edit_apsimx", "edit_apsimx_replace_soil_profile", 
                    "paste0", "dir.create", "file.copy", "tryCatch", "print", "apsimx", "mutate", 
                    "write_csv", "soil_profile_list"))


# Initialize a list to hold results from all batches
all_results <- list()


# Process each batch
for (batch in 1:num_batches) {
  # Determine the rows for the current batch
  batch_rows <- ((batch - 1) * batch_size + 1):min(nrow(trials_df), batch * batch_size)
  batch_trials <- trials_df[batch_rows, ]
  
  # Split trials for parallel execution
  trial_list <- split(batch_trials, seq(nrow(batch_trials)))
  
  # Run APSIM simulations in parallel for the current batch
  # Run APSIM simulations in parallel
  results <- parLapply(cl, trial_list, function(trial) {
    trial_n <- trial$ID  # Assuming 'ID' is the identifier
    source_dir <- paste0("apsim/trial_", trial_n)
    filename <- paste0(crop, "_", trial_n, ".apsimx")
    output <- data.frame()  # Initialize an empty data frame for the results
    
    # Wrap APSIM simulation and result handling in tryCatch to handle any errors
    tryCatch({
      output_tmp <- apsimx(filename, src.dir = source_dir)
      output_tmp <- mutate(output_tmp, "ID" = trial_n) 
      # Append the output of this trial to the overall results
      # output <- rbind(output, output_tmp)
      # Save individual trial results
      write_csv(output_tmp, file = paste0(source_dir, "/", crop, "_", trial_n, "_out.csv"))
      #return(output)
      return()  
    }, error = function(e){
      cat(paste0("Simulation for trial ", trial_n, " failed with error: ", e$message, "\n"))
      return(NULL)  # Return NULL if there was an error
    })
  })
  
  # Combine the results from this batch and add to the all_results list
  #batch_results <- do.call(rbind, results)
  #all_results[[batch]] <- batch_results
  
  # Print out the progress
  cat(sprintf("Completed batch %d out of %d (%.2f%%)\n", batch, num_batches, 100 * batch / num_batches))
}


# Stop the cluster
stopCluster(cl)


# Summarize Results -----

# Merge Outputs
outfiles <- list.files("apsim/", pattern = "_out", recursive = T)
daily_output <- data.table::rbindlist(lapply(outfiles, function(x){read_csv(paste0("apsim/",x),show_col_types = FALSE)}),use.names = T)
daily_output <- select(daily_output, -any_of(c("CheckpointID", "SimulationID", "SimulationName", "Zone", "Year"))) %>% arrange(ID)

# Get simulated sowing and harvest dates
simsows <- select(daily_output, ID, SimSowDate) %>% filter(!is.na(SimSowDate)) 
simmats <- select(daily_output, ID, SimMatDate) %>% filter(!is.na(SimMatDate)) 
simharvs <- select(daily_output, ID, SimHarvestDate) %>% filter(!is.na(SimHarvestDate)) 
simdates <- left_join(simsows, simmats, by = join_by(ID)) %>% left_join(simharvs, by = join_by(ID))
daily_output <- select(daily_output, -SimSowDate, -SimMatDate, -SimHarvestDate)

# Trim season (daily_output) to one month before planting and one month after death / harvest
simdates <- simdates %>% mutate(StartDate = date(SimSowDate) %m-% weeks(2), EndDate = date(SimHarvestDate) %m+% weeks(2)) %>%
  select(ID, StartDate, SimSowDate, SimMatDate, SimHarvestDate, EndDate)
daily_output <- group_by(daily_output, ID) %>% left_join(select(simdates,ID, StartDate, EndDate), by = join_by(ID)) %>%
  filter(Date >= StartDate & Date <= EndDate) %>% select(-StartDate,-EndDate)

# Create trials_x from trial-specific information
yields <- group_by(daily_output, ID) %>% summarize(Yield_Sim = max(Yieldkgha),  MaxStage = max(Stage))
res <- group_by(daily_output, ID) %>% filter(!is.na(Result)) %>% select(ID, Result)
trials_x <- rename(trials_df, Latitude = Y, Longitude = X)
trials_x <- trials_x %>% select(-sim_start, -sim_end) %>% 
  left_join(yields, by = join_by(ID)) %>% 
  left_join(simdates, by = join_by(ID)) %>% 
  left_join(res, by = join_by(ID)) 
trials_x <- mutate(trials_x, DTM_Sim = as.numeric(SimMatDate - SimSowDate)) %>%
  relocate(DTM_Sim, .after = SimSowDate)
trials_x <- rename(trials_x, MatDate_Sim = SimMatDate, PlantingDate_Sim = SimSowDate, HarvestDate_Sim = SimHarvestDate) 
trials_x <- select(trials_x, -PlantingDate)
trials_x <- relocate(trials_x, ID)

# Periods
if (crop %in% c("Soy","Maize")) {
  max_stage <- 11
} else {
  max_stage <- max(daily_output$Stage)
}

daily_output <- daily_output %>% left_join(select(trials_x, ID, HarvestDate_Sim, PlantingDate_Sim)) %>% 
   mutate(Period = case_when(
   Stage == 1 & (as_date(Date) < PlantingDate_Sim) ~ 1,
   Stage == 1 & (as_date(Date) >= HarvestDate_Sim) ~ max_stage,
   .default = floor(Stage)
 )) %>% select(-PlantingDate_Sim, -HarvestDate_Sim) %>% 
   mutate(Period = factor(Period, ordered = T, levels = as.character(1:max_stage)))

# Add cumulative precipitation and thermal time
daily_output <- daily_output %>% group_by(ID) %>% mutate(AccRain = cumsum(Rain), AccTT = cumsum(ThermalTime))

# daily_output <- daily_output %>% left_join(select(trials_x, ID, MatDate_Sim, Planting)) %>% 
#   mutate(Stage = case_match(
#     Period,
#     "1" ~ "Pre-planting", #germinating
#     "2" ~ "VE", #emerging
#     "3" ~ "V(n)", #vegetative
#     "4" ~ "R1", #early flowering
#     "5" ~ "R3", #early pod development
#     "6" ~ "R5 early", #early grain filling
#     "7" ~ "R5 mid", #mid grain filing
#     "8" ~ "R5 late", #late grain filling
#     "9" ~ "R6", #maturing
#     "10" ~ "R7", #ripening
#     "11" ~ "R8 & Post-harvest", #harvestripe + germinating
#   )) %>% select(-MatDate_Sim) %>% 
#   mutate(Period = factor(Period, ordered = T, levels = as.character(1:11)))

charact_x <- daily_output %>% 
  group_by(Period, ID) %>% select(-Yieldkgha, -Stage) %>% 
  summarize(across(where(is.numeric) & !c(DOY,AccRain,AccTT,AccEmTT), function(x){mean(x,na.omit=T)}), 
            AccRain = sum(Rain), AccTT = sum(ThermalTime), AccEmTT = max(AccEmTT),
            Period_Start_Date = min(Date), Period_End_Date = max(Date)) %>% 
  mutate(Duration = as.numeric(as.period(Period_End_Date - Period_Start_Date, "days"))/86400 + 1, 
         Period_Start_DOY = yday(Period_Start_Date), 
         Period_End_DOY = yday(Period_End_Date)) %>%
  relocate(ID, Period, Rain) %>% 
  relocate(AccRain, .after = Rain) %>% relocate(AccTT, AccEmTT, .after = ThermalTime) %>%
  relocate(Period_Start_DOY, Duration, Period_End_DOY, .after = last_col()) %>%
  arrange(ID) 

#empty data for missing periods 
idp <- tidyr::expand(tibble(charact_x), ID, Period) #full list of ID/Period combinations
idp <- anti_join(idp, charact_x) #which ID/Period combinations are absent in charact_x
col_names <- names(charact_x)[3:length(names(charact_x))]
for (col in col_names) {
  idp[[col]] <- NA
}
idp <- mutate(idp, Duration = 0) #set duration of nonexistant periods to zero
charact_x <- bind_rows(charact_x, idp) %>% arrange(ID, Period)

daily_charact_x <- daily_output

unlink("output",recursive = T) ; dir.create("output")
write_csv(trials_x, "output/trials_x.csv")
write_csv(charact_x, "output/charact_x.csv")
write_csv(daily_charact_x, "output/daily_charact_x.csv")

final_x <- pivot_wider(charact_x, names_from = Period, values_from = Rain:Period_End_DOY) %>% right_join(trials_x,.)
write_csv(final_x, "output/final_x.csv")

#calculate time duration for running the code:
end_time <- Sys.time()
duration <- end_time - start_time
print(duration)

close(CON)      

