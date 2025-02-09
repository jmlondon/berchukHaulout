create_source_data <- function(locs_sf, timeline_data) {

  loc_qual_tbl <- tribble(
    ~quality, ~error_radius,
    "3", 250,
    "2", 500,
    "1", 1500,
    "0", 2500,
    "A", 2500,
    "B", 2500
  )

  locs_daily <- locs_sf %>%
    dplyr::filter(quality %in% c("3","2","1","0","A","B")) %>%
    left_join(loc_qual_tbl, by = "quality") %>%
    st_transform(3571) %>%
    mutate(x = st_coordinates(.)[,"X"],
           y = st_coordinates(.)[,"Y"]) %>%
    st_set_geometry(NULL) %>%
    mutate(error_radius.x = ifelse(is.na(error_radius.x),
                                          error_radius.y,
                                          error_radius.x)) %>%
    rename(error_radius = error_radius.x) %>%
    dplyr::select(-error_radius.y) %>%
    mutate(error_radius = ifelse(type %in% c("GPS","FastGPS"),
                                        50,error_radius),
                  error_radius = ifelse(type %in% c("User"),
                                        50,error_radius)) %>%
    group_by(speno,unique_day,age,sex,species) %>%
    summarise(x = weighted.mean(x,1/error_radius),
                     y = weighted.mean(y,1/error_radius))

  tbl_percent_locs <- timeline_data %>%
    ungroup() %>%
    # let's make sure we only have hourly summarized timeline data
    group_by(speno,species,sex,age,unique_day,n_tags,
             timeline_hour = lubridate::hour(timeline_start_dt)) %>%
    reframe( #using reframe here b/c summarize creates a warning about more (or less) than 1 row per `summarise()`
      timeline_start_dt = lubridate::floor_date(timeline_start_dt, "hours"),
      percent_dry = mean(percent_dry)
    ) %>%
    ungroup() %>%
    dplyr::select(-timeline_hour) %>%
    # now join with daily locations
    full_join(locs_daily,
                     by = c("speno","unique_day","age",
                            "sex","species")) %>%
    arrange(speno,unique_day,timeline_start_dt) %>%
    group_by(speno) %>% 
    tidyr::nest() %>%
    mutate(start_idx = purrr::map_int(data,~ which.max(!is.na(.x$x))),
           data = purrr::map2(data, start_idx, ~ slice(.x, .y:nrow(.x)))) %>%
    dplyr::select(-start_idx) %>%
    tidyr::unnest(cols = c(data)) %>%
    mutate(fill_xy = ifelse(is.na(x), TRUE, FALSE)) %>%
    group_by(speno) %>%
    tidyr::fill(x,y) %>%
    ungroup() %>%
    dplyr::filter(!is.na(percent_dry)) %>%
    dplyr::filter(!speno %in% c("EB2005_5995")) %>% #peard bay capture; only 1 day of data
    dplyr::filter(!is.na(x)) %>%
    st_as_sf(coords = c("x","y")) %>%
    st_set_crs(3571) %>%
    rename(haulout_dt = timeline_start_dt) %>%
    
    dplyr::select(speno,species,age,sex,haulout_dt,percent_dry,n_tags,fill_xy)


  tryCatch({
    con <- dbConnect(RPostgres::Postgres(),
                     dbname = 'pep', 
                     host = Sys.getenv('PEP_PG_IP'),
                     user = keyringr::get_kc_account("pgpep_sa"),
                     password = keyringr::decrypt_kc_pw("pgpep_sa")
                     )
  },
  error = function(cond) {
    print("Unable to connect to Database.")
  })
  on.exit(dbDisconnect(con))

  st_write(obj = tbl_percent_locs,
           dsn = con,
           delete_layer = TRUE,
           layer = SQL("telem.res_iceseal_haulout")
  )

  dbExecute(con, "ALTER TABLE telem.res_iceseal_haulout RENAME COLUMN geometry TO geom")
  dbExecute(con, "ALTER TABLE IF EXISTS telem.res_iceseal_haulout OWNER TO pep_manage_telem")
  dbExecute(con, "SELECT telem.fxn_iceseal_pred_idx();")
  dbExecute(con, "SELECT telem.fxn_iceseal_haulout_cov();")

  qry <- {
    "SELECT *
  FROM telem.res_iceseal_haulout_cov
  WHERE
  EXTRACT(MONTH FROM haulout_dt) IN (3,4,5,6,7) AND
  rast_vwnd IS NOT NULL AND
  species != 'Ph'"
  }

  sf::st_read(con, query = qry)
}
