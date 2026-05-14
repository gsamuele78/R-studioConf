# tests/fixtures/r_lint/USER_C_luana_occurrence.R
# Anonymized fixture: USER_A — credential-leak fixture.
# Expected findings: R020 (hardcoded credential — REDACTED here), R016 (relative read.csv)
# NOTE: real credential redacted to "[REDACTED-CRED]"; the regex must still flag the assignment shape.

library(rgbif)

# Read input dataset (relative path)
dol1 <- read.csv("[ANONYMIZED_DATA_SUBDIR]/occurrences/dol1.csv", header = TRUE)

# ⚠️ HARDCODED CREDENTIAL (intentional fixture, redacted) — R020 must fire
# In R, named function arguments use `=` (not `<-`); auto-formatters preserve this.
occurrences <- occ_download(
    user = "USER_A",
    pwd = "[REDACTED_SECRET]",
    email = "USER_A@example.com"
)

# Better pattern (kept here as comment, not flagged):
#   pwd <- Sys.getenv("GBIF_PWD")
#   # then in ~/.Renviron (chmod 600):  GBIF_PWD=...
