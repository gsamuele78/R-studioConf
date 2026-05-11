# tests/fixtures/r_lint/luana_occurrence.R
# Anonymized fixture: <user_c> — credential-leak fixture.
# Expected findings: R020 (hardcoded credential — REDACTED here), R016 (relative read.csv)
# NOTE: real credential redacted to "<REDACTED-CRED>"; the regex must still flag the assignment shape.

library(rgbif)

# Read input dataset (relative path)
dol1 <- read.csv("data/occurrences/dol1.csv", header = TRUE)

# ⚠️ HARDCODED CREDENTIAL (intentional fixture, redacted) — R020 must fire
# In R, named function arguments use `=` (not `<-`); auto-formatters preserve this.
occurrences <- occ_download(
    user = "<REDACTED-USER>",
    pwd = "<REDACTED-CRED>",
    email = "<REDACTED-EMAIL>"
)

# Better pattern (kept here as comment, not flagged):
#   pwd <- Sys.getenv("GBIF_PWD")
#   # then in ~/.Renviron (chmod 600):  GBIF_PWD=...
