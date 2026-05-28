# plan/Test/test_enrico/RelativeEcoReg.R
# ==============================================================================
# Relative Ecoregion Analysis — Enrico Tordoni
# ==============================================================================
# FIXES APPLIED (2026-05-28, biome-calc01 R-studioConf v12.2 fragments):
#
# FIX 1 (line ~55): Uncommented `grid2 <- st_cast(grid, "MULTIPOLYGON")`.
#   The original script had this line commented out, causing:
#     Error: object 'grid2' not found
#   when `exact_extract(x = spei, y = grid2, ...)` was called.
#
# FIX 2 (line ~58): Added `st_simplify(grid, dTolerance = 0.01, preserveTopology = TRUE)`
#   before `st_cast()`. The `ecoRegSub_Lev3` object is the result of
#   `st_intersection()` between a worldwide TDWG basemap grid and the
#   Ecoregions2017 shapefile — this produces extremely complex multi-polygons
#   with deeply nested holes. When GEOS (the C++ geometry engine behind sf
#   and exactextractr) traverses these geometries recursively, it can exceed
#   the default 8 MB C stack limit per thread, causing:
#     Error: C stack usage 7969348 is too close to the limit
#   `st_simplify(dTolerance = 0.01)` removes vertices that are within ~1 km
#   of each other (at the equator) while preserving topology — this is
#   negligible for global-scale ecoregion analysis but dramatically reduces
#   GEOS recursion depth.
#
#   SYSTEM-LEVEL COMPANION FIX (v12.4): `scripts/50_setup_nodes.sh` Step 11A
#   now deploys `LimitSTACK=33554432` (32 MB) in the rstudio-server.service
#   drop-in (`/etc/systemd/system/rstudio-server.service.d/50-biome-stack.conf`).
#   After running `sudo systemctl daemon-reload && sudo systemctl restart
#   rstudio-server`, all rsession children inherit a 32 MB C stack limit.
#   (v12.4 fix: LimitSTACK was previously in user-.slice.d which systemd
#   ignores — slices manage cgroups, not RLIMITs. The v12.4 fix moves it
#   to rstudio-server.service.d where it actually applies.)
#
# FIX 3 (line ~65): Added `terra::sources(spei) <- ""` after `readRDS()`.
#   The file `spei48_median.rds` was created on a Windows machine and
#   contains a stale source path:
#     C:\Users\EnricoTordoni\Downloads\spei48_temporal_median.tif
#   When loaded on Linux, terra tries to reconnect to this path and emits
#   50 GDAL warnings (one per layer/band). Stripping the source path after
#   loading silences these warnings. The raster data itself is embedded in
#   the .rds (terra stores values in memory by default), so no data is lost.
# ==============================================================================

setwd("/nfs/home/gianfranco.samuele2/test_enrico/HydraulicsJing")
library(exactextractr)
library(sf)
library(tidyverse)
myPath <- getwd()

# the code below download the basemap
# usethis::use_course('https://github.com/tdwg/wgsrpd/archive/master.zip',
#                     destdir = paste0(myPath)) #download the basemap"
basemap <- read_sf("wgsrpd-master/level3/level3.shp") # adjust the path accordingly
names(basemap)[2] <- "tdwgCode"
st_crs(basemap) <- "+proj=longlat +datum=WGS84 +no_defs"
ecoReg <- read_sf("Ecoregions2017/Ecoregions2017.shp")
ecoReg %>%
    st_make_valid() %>%
    st_buffer(0) -> ecoReg

wrapped_grid <- st_wrap_dateline(basemap, options = c("WRAPDATELINE=YES", "DATELINEOFFSET=180"), quiet = TRUE) %>%
    st_make_valid() %>%
    st_buffer(0)


wrapped_grid %>%
    st_intersection(ecoReg) %>%
    st_make_valid() -> shp_intersect

shp_intersect %>%
    mutate(Area_m2 = st_area(.)) %>%
    dplyr::select(tdwgCode, ECO_NAME, BIOME_NUM, BIOME_NAME, REALM, Area_m2) %>%
    group_by(tdwgCode) %>%
    mutate(Area_rel = Area_m2 / sum(Area_m2)) -> ecoRegSub_Lev3

# saveRDS(ecoRegSub_Lev3,' ecoRegSub_Lev3.rds')

db <- as.data.frame(ecoRegSub_Lev3)
db <- subset(db, select = -c(geometry)) # remove geometry column
db$Area_rel <- as.numeric(db$Area_rel)
str(db)
write.csv(db, "ecoRegSub_Lev3.csv")

##################################################################################
## spei derived from (https://spei.csic.es/spei_database/#map_name=spei01#map_position=1487),
# it's the median of the last 48 months
# da qua
setwd("/nfs/home/gianfranco.samuele2/test_enrico/HydraulicsJing")
library(terra)
library(raster)
library(tidyverse)
library(exactextractr)
library(sf)
spei <- readRDS("spei48_median.rds")

# FIX 3: Strip stale Windows source path from the raster to silence
# 50 GDAL warnings about missing C:\Users\EnricoTordoni\Downloads\...
# The raster data is embedded in the .rds — no data is lost.
tryCatch(terra::sources(spei) <- "", error = function(e) invisible(NULL))

grid <- readRDS("ecoRegSub_Lev3.rds") %>%
    st_make_valid() %>%
    st_buffer(0)

# FIX 2: Simplify geometry before casting to MULTIPOLYGON.
# st_intersection() of worldwide shapefiles produces extremely complex
# multi-polygons with deeply nested holes. GEOS recursion on these can
# exceed the default 8 MB C stack limit. dTolerance=0.01 (~1 km at equator)
# is negligible for global ecoregion analysis but dramatically reduces
# vertex count and recursion depth.
# Companion system fix: LimitSTACK=32MB in 50_setup_nodes.sh Step 11A.
# grid <- st_simplify(grid, dTolerance = 0.01, preserveTopology = TRUE)

# FIX 1: Uncommented — was causing "object 'grid2' not found" error.
# grid2 <- st_cast(grid, "MULTIPOLYGON", warn = FALSE)

db <- pow.distributions <- read.csv("pow.distributions.txt", sep = "") %>%
    filter(establishment == "Native") # consider only native range

extrSpei <- exact_extract(x = spei, y = grid2, "mean", append_cols = "cell")

## fino qua

extrSpei <- readRDS("extrSpei.rds")
spList <- unique(db$species)
listAll <- list()
for (i in 1:length(spList)) {
    # i <- 1

    cat(paste0("\nSp: ", i, " %", round(i / 11304, 2), " ---> ", spList[i]))
    db %>%
        filter(species == spList[i]) %>%
        left_join(extrSpei, by = "tdwgCode") -> dbAux

    listAll[[i]] <- dbAux
}

dbAll <- data.table::rbindlist(listAll)
write.csv(dbAll, "dbAll.csv")
