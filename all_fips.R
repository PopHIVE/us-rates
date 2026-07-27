library(tidyverse)
library(tidycensus)

fips_codes_county <- tidycensus::fips_codes %>%
  mutate(fips = paste0(state_code, county_code)) %>%
  dplyr::select(fips, county, state, state_code) %>%
  rename(county_name=county)

fips_codes_state <- tidycensus::fips_codes %>%
  dplyr::select(state, state_code, state_name) %>%
  unique() %>%
  rename(fips = state_code, county_name = state_name)

fips_national = data.frame('fips'='00', 'state_code'='US','state'='US', 'county_name'='United States')

fips_code_combined <-   bind_rows(fips_codes_county,fips_codes_state,fips_national) %>%
  dplyr::select(-state_code) %>%
  rename(geography=fips,
         geography_name = county_name)

vroom::vroom_write(fips_code_combined, './resources/all_fips.csv.gz', delim = ",")
