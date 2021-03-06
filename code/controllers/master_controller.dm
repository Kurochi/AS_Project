//simplified MC that is designed to fail when procs 'break'. When it fails it's just replaced with a new one.
//It ensures master_controller.process() is never doubled up by killing the MC (hence terminating any of its sleeping procs)
//WIP, needs lots of work still

var/global/datum/controller/game_controller/master_controller //Set in world.New()

var/global/controller_iteration = 0
var/global/last_tick_timeofday = world.timeofday
var/global/last_tick_duration = 0

var/global/air_processing_killed = 0
var/global/pipe_processing_killed = 0

datum/controller/game_controller
	var/processing = 0
	var/breather_ticks = 2		//a somewhat crude attempt to iron over the 'bumps' caused by high-cpu use by letting the MC have a breather for this many ticks after every loop
	var/minimum_ticks = 20		//The minimum length of time between MC ticks

	var/air_cost 		= 0
	var/sun_cost		= 0
	var/mobs_cost		= 0
	var/diseases_cost	= 0
	var/machines_cost	= 0
	var/objects_cost	= 0
	var/networks_cost	= 0
	var/powernets_cost	= 0
	var/nano_cost		= 0
	var/events_cost		= 0
	var/ticker_cost		= 0
	var/total_cost		= 0

	var/last_thing_processed
	var/mob/list/expensive_mobs = list()

	var/list/shuttle_list	                    // For debugging and VV
	var/datum/ore_distribution/asteroid_ore_map // For debugging and VV.


datum/controller/game_controller/New()
	//There can be only one master_controller. Out with the old and in with the new.
	if(master_controller != src)
		log_debug("Rebuilding Master Controller")
		if(istype(master_controller))
			Recover()
			del(master_controller)
		master_controller = src

	if(!job_master)
		job_master = new /datum/controller/occupations()
		job_master.SetupOccupations()
		job_master.LoadJobs("config/jobs.txt")
		world << "\red \b Job setup complete"

	if(!syndicate_code_phrase)		syndicate_code_phrase	= generate_code_phrase()
	if(!syndicate_code_response)	syndicate_code_response	= generate_code_phrase()
	if(!emergency_shuttle)			emergency_shuttle = new /datum/emergency_shuttle_controller()
	if(!shuttle_controller)			shuttle_controller = new /datum/shuttle_controller()

datum/controller/game_controller/proc/setup()
	world.tick_lag = 0.3

	/* Used for away missions - no point running it at the moment.
	spawn(20)
		createRandomZlevel()
	*/
	if(!air_master)
		air_master = new /datum/controller/air_system()
		air_master.Setup()

	if(!ticker)
		ticker = new /datum/controller/gameticker()

	setup_objects()
	setupgenetics()
	setupfactions()
	setup_economy()
	SetupXenoarch()

	transfer_controller = new

	for(var/i=0, i<max_secret_rooms, i++)
		make_mining_asteroid_secret()

	spawn(0)
		if(ticker)
			ticker.pregame()

	lighting_controller.initializeLighting()


datum/controller/game_controller/proc/setup_objects()
	world << "\red \b Initializing objects"
	sleep(-1)
	for(var/atom/movable/object in world)
		object.initialize()

	world << "\red \b Initializing pipe networks"
	sleep(-1)
	for(var/obj/machinery/atmospherics/machine in machines)
		machine.build_network()

	world << "\red \b Initializing atmos machinery."
	sleep(-1)
	for(var/obj/machinery/atmospherics/unary/U in machines)
		if(istype(U, /obj/machinery/atmospherics/unary/vent_pump))
			var/obj/machinery/atmospherics/unary/vent_pump/T = U
			T.broadcast_status()
		else if(istype(U, /obj/machinery/atmospherics/unary/vent_scrubber))
			var/obj/machinery/atmospherics/unary/vent_scrubber/T = U
			T.broadcast_status()

	//Create the mining ore distribution map.
	asteroid_ore_map = new /datum/ore_distribution()
	asteroid_ore_map.populate_distribution_map()

	//Shitty hack to fix mining turf overlays, for some reason New() is not being called.
	for(var/turf/simulated/floor/plating/airless/asteroid/T in world)
		T.updateMineralOverlays()
		T.name = "asteroid"

	//Set up spawn points.
	populate_spawn_points()

	// Sort the machinery list so it doesn't cause a lagspike at roundstart
	process_machines_sort()

	world << "\red \b Initializations complete."
	sleep(-1)


datum/controller/game_controller/proc/process()
	processing = 1
	spawn(0)

		while(1)	//far more efficient than recursively calling ourself
			if(!Failsafe)	new /datum/controller/failsafe()

			var/currenttime = world.timeofday
			last_tick_duration = (currenttime - last_tick_timeofday) / 10
			last_tick_timeofday = currenttime

			if(processing)
				var/timer
				var/start_time = world.timeofday
				controller_iteration++

				vote.process()
				transfer_controller.process()
				shuttle_controller.process()
				process_newscaster()

				//MAKING OOC ANNOUNCEMENTS
				announcements()

				//AIR
				if(!air_processing_killed)
					timer = world.timeofday
					last_thing_processed = air_master.type

					if(!air_master.Tick()) //Runtimed.
						air_master.failed_ticks++
						if(air_master.failed_ticks > 5)
							world << "<font color='red'><b>RUNTIMES IN ATMOS TICKER.  Killing air simulation!</font></b>"
							world.log << "### ZAS SHUTDOWN"
							message_admins("ZASALERT: unable to run [air_master.tick_progress], shutting down!")
							log_admin("ZASALERT: unable run zone/process() -- [air_master.tick_progress]")
							air_processing_killed = 1
							air_master.failed_ticks = 0

					air_cost = (world.timeofday - timer) / 10

				sleep(breather_ticks)

				//SUN
				timer = world.timeofday
				last_thing_processed = sun.type
				sun.calc_position()
				sun_cost = (world.timeofday - timer) / 10

				sleep(breather_ticks)

				//MOBS
				timer = world.timeofday
				process_mobs()
				mobs_cost = (world.timeofday - timer) / 10

				sleep(breather_ticks)

				//DISEASES
				timer = world.timeofday
				process_diseases()
				diseases_cost = (world.timeofday - timer) / 10

				sleep(breather_ticks)

				//MACHINES
				timer = world.timeofday
				process_machines()
				machines_cost = (world.timeofday - timer) / 10

				sleep(breather_ticks)

				//OBJECTS
				timer = world.timeofday
				process_objects()
				objects_cost = (world.timeofday - timer) / 10

				sleep(breather_ticks)

				//PIPENETS
				if(!pipe_processing_killed)
					timer = world.timeofday
					process_pipenets()
					networks_cost = (world.timeofday - timer) / 10

				sleep(breather_ticks)

				//POWERNETS
				timer = world.timeofday
				process_powernets()
				powernets_cost = (world.timeofday - timer) / 10

				sleep(breather_ticks)

				//NANO UIS
				timer = world.timeofday
				process_nano()
				nano_cost = (world.timeofday - timer) / 10

				sleep(breather_ticks)

				//EVENTS
				timer = world.timeofday
				process_events()
				events_cost = (world.timeofday - timer) / 10

				//TICKER
				timer = world.timeofday
				last_thing_processed = ticker.type
				ticker.process()
				ticker_cost = (world.timeofday - timer) / 10

				//TIMING
				total_cost = air_cost + sun_cost + mobs_cost + diseases_cost + machines_cost + objects_cost + networks_cost + powernets_cost + nano_cost + events_cost + ticker_cost

				var/end_time = world.timeofday
				if(end_time < start_time)	//why not just use world.time instead?
					start_time -= 864000    //deciseconds in a day
				sleep( round(minimum_ticks - (end_time - start_time),1) )
			else
				sleep(10)

datum/controller/game_controller/proc/process_mobs()
	var/i = 1
	expensive_mobs.Cut()
	while(i<=mob_list.len)
		var/mob/M = mob_list[i]
		if(M)
			var/clock = world.timeofday
			last_thing_processed = M.type
			M.Life()
			if((world.timeofday - clock) > 1)
				expensive_mobs += M
			i++
			continue
		mob_list.Cut(i,i+1)

datum/controller/game_controller/proc/process_diseases()
	var/i = 1
	while(i<=active_diseases.len)
		var/datum/disease/Disease = active_diseases[i]
		if(Disease)
			last_thing_processed = Disease.type
			Disease.process()
			i++
			continue
		active_diseases.Cut(i,i+1)

datum/controller/game_controller/proc/process_machines()
	process_machines_sort()
	process_machines_process()

/var/global/machinery_sort_required = 0
datum/controller/game_controller/proc/process_machines_sort()
	if(machinery_sort_required)
		machinery_sort_required = 0
		machines = dd_sortedObjectList(machines)

datum/controller/game_controller/proc/process_machines_process()
	for(var/obj/machinery/Machine in machines)
		last_thing_processed = Machine.type
		if(Machine.process() != PROCESS_KILL)
			if(Machine)
				Machine.power_change()
				if(Machine.use_power)
					Machine.auto_use_power()
				continue
		machines -= Machine


datum/controller/game_controller/proc/process_objects()
	var/i = 1
	while(i<=processing_objects.len)
		var/obj/Object = processing_objects[i]
		if(Object)
			last_thing_processed = Object.type
			Object.process()
			i++
			continue
		processing_objects.Cut(i,i+1)

datum/controller/game_controller/proc/process_pipenets()
	last_thing_processed = /datum/pipe_network
	var/i = 1
	while(i<=pipe_networks.len)
		var/datum/pipe_network/Network = pipe_networks[i]
		if(Network)
			Network.process()
			i++
			continue
		pipe_networks.Cut(i,i+1)

/datum/controller/game_controller/proc/process_powernets()
	last_thing_processed = /datum/powernet
	for(var/datum/powernet/Powernet in powernets)
		Powernet.reset()

datum/controller/game_controller/proc/process_nano()
	last_thing_processed = /datum/nanoui
	var/i = 1
	while(i<=nanomanager.processing_uis.len)
		var/datum/nanoui/ui = nanomanager.processing_uis[i]
		if(ui)
			ui.process()
			i++
			continue
		nanomanager.processing_uis.Cut(i,i+1)

datum/controller/game_controller/proc/process_events()
	last_thing_processed = /datum/event
	event_manager.process()

datum/controller/game_controller/proc/announcements()
	var/announcement

	if( controller_iteration % 300 == 0 )// Make an announcement every 10 minutes
		announcement = pick("<font color='green'><big><img src=\ref['icons/misc/news.png']></img></big><b> Come join our <a href='http://steamcommunity.com/groups/apcom'>steam group</a> for event notifications and for playing games outside of a space station!</font><br></b>",
								"<font color='green'><big><img src=\ref['icons/misc/news.png']></img></big><b> Make sure to check out our <a href='http://apollo-community.org/'>forums</a>. Many people post many important things there!<br></font></b>",
								"<font color='green'><big><img src=\ref['icons/misc/news.png']></img></big><b> Be sure check out our <a href='https://github.com/stuicey/AS_Project/'>source repository</a>. We're always welcoming new developers, and we'd love you have you on board!<br></font></b>",
								"<font color='green'><big><img src=\ref['icons/misc/news.png']></img></big><b> Got a little spare change jingling in your pockets? We'd love it if you <a href='http://apollo-community.org/viewtopic.php?f=29&t=34'>tossed it our way</a>!<br></font></b>",
								"<font color='green'><big><img src=\ref['icons/misc/news.png']></img></big><b> Feel free to come and hop on our <a href='http://apollo-community.org/viewforum.php?f=32'>teamspeak</a> and chat with us!<br></font></b>",
								"<font color='green'><big><img src=\ref['icons/misc/news.png']></img></big><b> Make sure to read the <a href='http://apollo-community.org/viewtopic.php?f=4&t=6'>full rules</a>, otherwise you may get in trouble!<br></font></b>",
								"<font color='green'><big><img src=\ref['icons/misc/news.png']></img></big><b> We have community meetings every Saturday at 4 PM EST in our <a href='http://apollo-community.org/viewforum.php?f=32'>teamspeak</a>. Got a problem? Bring it up there!<br></font></b>",
								"<font color='green'><big><img src=\ref['icons/misc/news.png']></img></big><b> Enjoy the game, and have a great day!<br></font></b>",
								"<font color='green'><big><img src=\ref['icons/misc/news.png']></img></big><b> Find a bug or exploit? Let us know on our <a href='https://github.com/stuicey/AS_Project/issues?q=is%3Aopen+is%3Aissue'>bugtracker</a>!<br></font></b>" )
		world << "<br>"
		world << announcement


datum/controller/game_controller/proc/Recover()		//Mostly a placeholder for now.
	var/msg = "## DEBUG: [time2text(world.timeofday)] MC restarted. Reports:\n"
	for(var/varname in master_controller.vars)
		switch(varname)
			if("tag","bestF","type","parent_type","vars")	continue
			else
				var/varval = master_controller.vars[varname]
				if(istype(varval,/datum))
					var/datum/D = varval
					msg += "\t [varname] = [D.type]\n"
				else
					msg += "\t [varname] = [varval]\n"
	world.log << msg

