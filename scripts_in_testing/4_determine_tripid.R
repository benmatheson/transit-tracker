library(gtfsdrilldown);library(dplyr);library(lubridate);library(tidyr);library(leaflet) 
# use the gps and gtfs to find which possible trip ids, then assign them based on some logic. Ends up with a object of trip_ids with gps "id".

#fake data
gps_data <- data.frame(route = rep("75", 2), direction = rep(1, 2), lat = c(61.221720, 61.180904), lon = c(-149.733576, -149.822776), datetime = rep(ymd_hms("2017-03-19 15:48:35"), 2))
load("gtfs_obj.Rdata")
gtfs_today <- gtfs_drilldown(gtfs_obj, today = structure(17243, class = "Date"))

lat_factor <- 2.1#  1/cos(gps_data$lat[1] * pi * 2)
# just work on one route for now
gps_data <- gps_data %>% filter(route == "75", direction == 1)
# number of trips currently on the route and direction
n_trips <- nrow(gps_data)
# capture as a time object for the day
current_time <- 
  hours(hour(gps_data$datetime[1])) + minutes(minute(gps_data$datetime[1])) + seconds(second(gps_data$datetime[1]))

# get the trip ids for this route and direction (filter trips.txt)
trip_ids_now <-   # (filter stop_times.txt)
  gtfs_today$today_stop_times %>% 
  filter(trip_id %in% (gtfs_today$todays_trips %>% filter(route_id == gps_data$route, direction_id == gps_data$direction) %>% .$trip_id)) %>% 
  group_by(trip_id) %>% 
  filter(min(stop_sequence) == stop_sequence) %>% 
  ungroup() %>% 
  filter(hms(departure_time) < current_time) %>% 
  arrange(desc(departure_time)) %>%
  filter(row_number() %in% 1:n_trips) %>% 
  .$trip_id
# get route with all stops
set_of_stops_in_active_trip_ids <- 
  gtfs_obj$stop_times_df  %>% 
  filter(trip_id %in% trip_ids_now) %>% 
  inner_join(gtfs_obj$stops_df, by = "stop_id") %>% 
  select(stop_lat, stop_lon, stop_id, stop_sequence, trip_id, departure_time)

# set up the possible combinations of distances for trip id and bus gps points
gtfs_gps_join_prep 	<- set_of_stops_in_active_trip_ids[rep(1:nrow(set_of_stops_in_active_trip_ids), n_trips),] # duplicate the dataframe
gps_data_new 		<- gps_data[rep(1:nrow(gps_data), n_trips),] 
gtfs_gps_join_prep$primary_id 	<- paste(gtfs_gps_join_prep$trip_id, # add the key for the combination 
                                        rep(1:n_trips, each=nrow(set_of_stops_in_active_trip_ids)), sep="-") 
gps_data_new$primary_id 		<- paste(trip_ids_now, 
                                   rep(1:n_trips, each=nrow(gps_data)), sep = "-")
gps_data_new$trip_id 		<- paste(trip_ids_now)

# combine gps and gtfs tables
calc_trip_id_table <- inner_join(gtfs_gps_join_prep, gps_data_new %>% select(-trip_id), by = "primary_id") %>%
  mutate(dist = sqrt((((stop_lat - lat) * lat_factor)^2) + 
                       ((stop_lon - lon)^2))) %>% 
  group_by(trip_id) 
# get stops_for most recent and next stop and bind them into one object
A_Stop <- rbind(
  calc_trip_id_table %>% 
    filter(min(dist) == dist) %>% filter(row_number() == 1) %>%  mutate(point_type = "most_recent"),
  calc_trip_id_table %>% filter(!min(dist) == dist) %>% 
    filter(min(dist) == dist) %>% filter(row_number() == 1) %>%  mutate(point_type = "next_stop"  )) %>% 
  group_by(trip_id) %>% filter(min(stop_sequence) == stop_sequence) %>%
  select(gps_lat = lat, gps_lon = lon, A_lat = stop_lat, A_lon = stop_lon, departure_time, trip_id, datetime, stop_sequence)
# 
surrounding_stops <- 
  inner_join(A_Stop, gtfs_today$today_stop_times %>% select(-departure_time),         by = "trip_id") %>% 
  inner_join((gtfs_today$all_stop_sequences %>% ungroup() %>% select(stop_lat, stop_lon, stop_id)), by = "stop_id") %>% select(-stop_id) %>%
  filter(stop_sequence.y > stop_sequence.x) %>%
  arrange(stop_sequence.y) %>% 
  filter(row_number() == 1) %>% 
  select(B_lat = stop_lat, B_lon = stop_lon, A_lat, A_lon, gps_lat, gps_lon, departure_time, arrival_time, trip_id, stop_sequence = stop_sequence.x) %>%
  mutate(A_dist = sqrt((((A_lat - gps_lat) * lat_factor)^2) + ((A_lon - gps_lon)^2)),
         B_dist = sqrt((((B_lat - gps_lat) * lat_factor)^2) + ((B_lon - gps_lon)^2)),
         ratio_complete = A_dist / (A_dist + B_dist),
         delay = round(seconds(current_time - hms(departure_time))  + (seconds((hms(arrival_time) - hms(departure_time))) * ratio_complete)))

surrounding_stops %>% select(trip_id, stop_sequence, delay)

leaflet(surrounding_stops) %>% addTiles() %>% 
  addCircles(~A_lon, ~A_lat, radius = ~A_dist * 50000, weight = 1, color = "green") %>%
  addMarkers(~gps_lon, ~gps_lat) %>% 
  addCircles(~B_lon, ~B_lat, radius = ~B_dist * 50000, weight = 1, color = "red") %>%
  addPolylines(data = inner_join((gtfs_today$today_stop_times   %>% filter(trip_id %in% surrounding_stops$trip_id)), 
                                 (gtfs_today$all_stop_sequences  %>% ungroup()%>% select(-stop_sequence)), by = "stop_id") %>% 
                 group_by(stop_sequence) %>% 
                 filter(row_number() == 1), lng = ~stop_lon, lat = ~stop_lat, color = "yellow") 