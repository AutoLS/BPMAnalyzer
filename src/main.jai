#import "Basic";
#import "String";
#import "Windows";
#import "System";
#import "Deep_Copy";
#import "Hash_Table";
#import "Math";
#load "ui.jai";
#load "input.jai";
#load "util.jai";
#load "audio.jai";
#load "preprocess.jai";
#load "onset.jai";
#load "tempogram.jai";
#load "tempo.jai";
#load "octave.jai";
#load "smooth.jai";
#load "beats.jai";
#load "downbeat.jai";
#load "report.jai";
#load "playback.jai";
#load "timing.jai";
#load "project.jai";
#load "osu.jai";
#load "plot.jai";
#load "graphs.jai";
#load "waveform.jai";
#load "adjust.jai";
#load "save.jai";
#load "settings.jai";

Analysis_Settings :: struct
{
    preprocess: Preprocess_Settings;
    onset:      Onset_Settings;
    tempogram:  Tempogram_Settings;
    tempo:      Tempo_Track_Settings;
    octave:     Octave_Settings;
    smooth:     Smooth_Settings;
    beat:       Beat_Settings;

    osu: Osu_Settings;
}

App :: struct
{
    window: *SDL_Window;

    settings: Analysis_Settings;

    audio_file:     Audio_File;
    analysis_audio: Preprocessed_Audio;

    onset_envelope: Onset_Envelope;
    tempogram:      Tempogram;
    tempo_curve:    Tempo_Curve;
    final_tempo:    Tempo_Curve;
    octave_report:  Octave_Correction;
    smooth_tempo:   Tempo_Curve;
    beat_grid:      Beat_Grid;
    kick_envelope:  Onset_Envelope;
    downbeat_track: Downbeat_Track;

    checked_tempo:    Tempo_Curve;
    tempo_validation: Tempo_Validation;
    validated:        bool;

    waveform:     Waveform;
    timing:       Timing_Edit;
    project_path: string;

    export_status: string;
}

app: App;

using app;

Pending_Action :: enum
{
    NONE;
    NEW_FILE;
    OPEN_FILE;
    REANALYSE;
}

pending_action:   Pending_Action;
pending_question: Pending_Action;
show_save_prompt: bool;

set_export_status :: (text: string)
{
	replacement := copy_string(text);

	if export_status.count > 0 free(export_status);
	export_status = replacement;
}

BPM_CHANGES_SHOWN :: 30;

show_tempo_changes :: (curve: *Tempo_Curve)
{
	if !curve.loaded return;

	points: [..] Osu_Timing_Point;
	defer release_array(*points);

	collect_osu_timing_points(curve, .{}, *points);

	ImGui.Separator();

	ImGui.Text("Final BPM: %", whole_bpm(tempo_curve_median_bpm(curve)));

	if points.count == 0 return;

	ImGui.Text("BPM changes: %", points.count);
}

analyse_loaded_audio :: ()
{
	if analysis_audio.loaded free_preprocessed_audio(*analysis_audio);

	staged, stage_error := preprocess_audio(*audio_file, app.settings.preprocess);
	if stage_error.count > 0
	{
		log_error("Could not preprocess '%': %\n", audio_file.path, stage_error);
		return;
	}
	analysis_audio = staged;

	if onset_envelope.loaded free_onset_envelope(*onset_envelope);

	envelope, envelope_error := compute_onset_envelope(*analysis_audio, app.settings.onset);
	if envelope_error.count > 0
	{
		log_error("Could not analyse '%': %\n", audio_file.path, envelope_error);
		return;
	}
	onset_envelope = envelope;

	if tempogram.loaded free_tempogram(*tempogram);

	tempo_map, tempo_error := tempogram_from_envelope(*onset_envelope, app.settings.tempogram);
	if tempo_error.count > 0
	{
		log_error("Could not build a tempogram for '%': %\n", audio_file.path, tempo_error);
		return;
	}
	tempogram = tempo_map;

	plot_build_tempogram_texture(*tempogram);

	if tempo_curve.loaded free_tempo_curve(*tempo_curve);

	tracked, track_error := track_tempo(*tempogram, app.settings.tempo);
	if track_error.count > 0
	{
		log_error("Could not track the tempo of '%': %\n", audio_file.path, track_error);
		return;
	}
	tempo_curve = tracked;

	if final_tempo.loaded free_tempo_curve(*final_tempo);

	fixed, correction, octave_error := correct_octave_errors(*tempo_curve, *tempogram, app.settings.octave);
	if octave_error.count > 0
	{
		log_error("Could not correct the octave of '%': %\n", audio_file.path, octave_error);
		return;
	}
	final_tempo = fixed;
	octave_report = correction;

	if smooth_tempo.loaded free_tempo_curve(*smooth_tempo);

	smoothed, smooth_error := smooth_tempo_curve(*final_tempo, app.settings.smooth);
	if smooth_error.count > 0
	{
		log_error("Could not smooth the tempo of '%': %\n", audio_file.path, smooth_error);
		return;
	}
	smooth_tempo = smoothed;

	if beat_grid.loaded free_beat_grid(*beat_grid);

	beats, beat_error := track_beats(*onset_envelope, *smooth_tempo, app.settings.beat);
	if beat_error.count > 0
	{
		log_error("Could not place beats for '%': %\n", audio_file.path, beat_error);
		return;
	}
	beat_grid = beats;

	find_downbeats();

	if checked_tempo.loaded free_tempo_curve(*checked_tempo);
	validated = false;

	checked, validation, validation_error := validate_tempo_curve(*smooth_tempo, *tempogram);
	if validation_error.count > 0
	{
		log_error("Could not validate '%': %\n", audio_file.path, validation_error);
		return;
	}

	checked_tempo = checked;
	tempo_validation = validation;
	validated = true;

	print("%: %\n", audio_file.path,
			 tempo_summary(*checked_tempo, *tempo_validation, *beat_grid, onset_envelope.frame_rate));
}

find_downbeats :: ()
{
	if kick_envelope.loaded free_onset_envelope(*kick_envelope);
	if downbeat_track.loaded free_downbeat_track(*downbeat_track);

	kicks, kick_error := create_kick_onset_envelope(*analysis_audio);
	if kick_error.count > 0
	{
		log_error("Could not isolate the kick band of '%': %\n", audio_file.path, kick_error);
		return;
	}
	kick_envelope = kicks;

	meter, _, _ := estimate_meter(*beat_grid, *kick_envelope, DEFAULT_METERS, .{});

	downbeat_settings: Downbeat_Settings;
	downbeat_settings.beats_per_bar = ifx meter >= 2 then meter else 4;

	downbeats, downbeat_error := track_downbeats(*beat_grid, *kick_envelope, downbeat_settings);
	if downbeat_error.count > 0
	{
		log_error("Could not find the downbeats of '%': %\n", audio_file.path, downbeat_error);
		return;
	}

	downbeat_track = downbeats;
}

main :: ()
{
	SDL_Init(SDL_INIT_VIDEO);

	window = SDL_CreateWindow
	(
		"BPM Analyzer", 
		SDL_WINDOWPOS_CENTERED,
		SDL_WINDOWPOS_CENTERED, 
		1280, 720,
		SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE
	);

	if window == null 
	{
		print("Could not create window: %\n", to_string(SDL_GetError()));
		return;
	}

	SDL_SetWindowMinimumSize(window, 720, 460);

	print("IMGUI Version: %\n", to_string(ImGui.GetVersion()));
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, xx SDL_GL_CONTEXT_PROFILE_CORE);
	gl_context := SDL_GL_CreateContext(window);
    if !gl_context 
	{
        print( "Could not create OpenGL context: %\n", to_string(SDL_GetError()));
        return;
    }

	gl_load(*gl, SDL_GL_GetProcAddress);

	if !plot_init() print("Could not set up the plot renderer.\n");

    ImGui.CreateContext();
    ImGui_ImplSdl_Init(window);

	ImGui.StyleColorsClassic();

	io := ImGui.GetIO();

	running := true;
	is_quit: bool;
	clear_color : Vector4 = .{ 0, 0, 0, 1.00 };
	main_tool_active: bool;

	while running
	{
		reset_temporary_storage();
		reset_controller_input(*global_input.keyboard);

		event: SDL_Event;
        while SDL_PollEvent(*event) 
		{
            ImGui_ImplSdl_ProcessEvent(*event);
            if event.type == SDL_QUIT   is_quit = true;
            if event.type == SDL_WINDOWEVENT && 
			   event.window.event == SDL_WINDOWEVENT_CLOSE && 
			   event.window.windowID == SDL_GetWindowID(window) 
			{
				running = false;
            }

			if event.type ==
			{
				case SDL_KEYDOWN; #through;
				case SDL_KEYUP;
				{
					is_down: bool = event.key.state == SDL_PRESSED;
					was_down: bool;

					if event.key.state == SDL_RELEASED
					{
						was_down = true;
					}
					else if event.key.repeat != 0
					{
						was_down = true;
					}

					if event.key.repeat == 0
					{
						key := event.key.keysym.scancode;

						button_state := table_find_pointer(*global_input.keyboard.keys, key);
						if button_state 
						{
							process_keypress(button_state, is_down, was_down);
						}
						else
						{
							new_state: Button_State;
							process_keypress(*new_state, is_down, was_down);
							table_add(*global_input.keyboard.keys, key, new_state);
						}
					}
				}
			}
        }

		ImGui_ImplSdl_NewFrame(window);

		plot_begin_frame(io.DisplaySize.x, io.DisplaySize.y);

		ImGui.NewFrame();

		run_pending_action();

		ImGui.SetNextWindowPos(ImGui.ImVec2.{ 0, 0 }, .Always);
		ImGui.SetNextWindowSize(ImGui.ImVec2.{ io.DisplaySize.x, io.DisplaySize.y }, .Always);

		ImGui.Begin("Template", *main_tool_active, 
					IMGUI_WINDOW_FLAGS.NoTitleBar | 
					IMGUI_WINDOW_FLAGS.MenuBar |
					IMGUI_WINDOW_FLAGS.NoMove |
					IMGUI_WINDOW_FLAGS.NoResize |
					IMGUI_WINDOW_FLAGS.NoBackground);
		if ImGui.BeginMenuBar()
		{
			defer ImGui.EndMenuBar();
			if ImGui.BeginMenu("File")
			{
				defer ImGui.EndMenu();

				if ImGui.MenuItem("New", "Ctrl+N")     request_new();
				if ImGui.MenuItem("Open..", "Ctrl+O")  request_open();

				ImGui.Separator();

				if ImGui.MenuItem("Save", "Ctrl+S")    project_save(false);
				if ImGui.MenuItem("Save as..")         project_save(true);
			}
		}

		{
			hotkey_io := ImGui.GetIO();
			if hotkey_io.KeyCtrl && !hotkey_io.WantTextInput
			{
				if ImGui.IsKeyPressed(ImGui.Key.N, false) request_new();
				if ImGui.IsKeyPressed(ImGui.Key.O, false) request_open();
				if ImGui.IsKeyPressed(ImGui.Key.S, false) project_save(false);
			}
		}

		draw_save_prompt();

		if ImGui.Button("Load audio file...") request_new();

        if audio_file.loaded 
        {
            if ImGui.BeginTabBar("MainTabBar", ImGui.TabBarFlags.None)
            {
                defer ImGui.EndTabBar();
                if ImGui.BeginTabItem("Analyzer")
                {
                    defer ImGui.EndTabItem();
                    update_analyzer_tab();
                    show_tempo_changes(*smooth_tempo);
                }

                if ImGui.BeginTabItem("Editor")
                {
                    defer ImGui.EndTabItem();
                    update_adjust_tab();
                }
            }
        }

		ImGui.End();

		ImGui.Render();
        glViewport(0, 0, xx (io.DisplaySize.x * io.DisplayFramebufferScale.x),
                          xx (io.DisplaySize.y * io.DisplayFramebufferScale.y));
        glClearColor(clear_color.x, clear_color.y, clear_color.z, clear_color.w);
        glClear(GL_COLOR_BUFFER_BIT);

		plot_flush();

        ImGui_ImplSdl_RenderDrawLists(ImGui.GetDrawData());
        SDL_GL_SwapWindow(window);
	} 
}

update_analyzer_tab :: ()
{
    if audio_file.loaded
    {
        ImGui.Text("File: %", audio_file.path);
        ImGui.Text("Source: %   % Hz   % channels   %",
                    audio_format_name(audio_file.format),
                    audio_file.sample_rate,
                    audio_file.channel_count,
                    audio_duration_string(audio_file.duration));

        draw_settings();
    }

    if analysis_audio.loaded
    {
        ImGui.Text("Analysis signal: % Hz mono, % frames, %, peak % (gain %)",
                    analysis_audio.sample_rate,
                    analysis_audio.frame_count,
                    audio_duration_string(analysis_audio.duration),
                    analysis_audio.peak,
                    analysis_audio.gain);
    }

    if onset_envelope.loaded
    {
        ImGui.Text("Onset envelope: % frames at %/s (% ms per frame), %",
                    onset_envelope.frame_count,
                    onset_envelope.frame_rate,
                    1000.0 / onset_envelope.frame_rate,
                    audio_duration_string(onset_envelope.duration));

        plot_envelope_with_beats(*onset_envelope, *beat_grid, *downbeat_track, *smooth_tempo, plot_height_for(110.0));

        ImGui.TextDisabled("Scroll over a graph to zoom, drag to move along the track, double-click to fit it all back in.");
    }

    if tempogram.loaded
    {
        dominant, _ := tempogram_dominant_tempo(*tempogram);
        column_ms := 1000.0 * cast(float64) tempogram.column_hop_frames / tempogram.envelope_frame_rate;

        ImGui.Text("Tempogram: % columns x % tempo bins (% ms per column, % to % BPM)",
                    tempogram.column_count,
                    tempogram.tempo_bins,
                    decimals(column_ms, 0),
                    cast(s64) tempogram.min_bpm,
                    cast(s64) tempogram.max_bpm);
        ImGui.Text("Strongest tempo over the whole track: % BPM", decimals(dominant, 1));

        plot_tempogram_with_curve(*tempogram, *smooth_tempo, plot_height_for(240.0));
    }

    if tempo_curve.loaded
    {
        mean, low, high := tempo_curve_statistics(*tempo_curve);
        step := tempo_curve_max_step(*tempo_curve);

        ImGui.Text("Tempo curve: mean % BPM, % to % BPM, biggest step % BPM per column",
                    decimals(mean, 1), decimals(low, 1), decimals(high, 1), decimals(step, 2));
    }

    if final_tempo.loaded
    {
        mean, low, high := tempo_curve_statistics(*final_tempo);
        was, _, _ := tempo_curve_statistics(*tempo_curve);

        ImGui.Text("Octave correction: % segment(s), % shifted, % metrical jump(s), % -> % BPM (fit % -> %)",
                    octave_report.segment_count,
                    octave_report.shifted_segments,
                    octave_report.metrical_jumps,
                    decimals(was, 1),
                    decimals(mean, 1),
                    decimals(octave_report.fit_before, 2),
                    decimals(octave_report.fit_after, 2));
    }

    if smooth_tempo.loaded
    {
        mean, low, high := tempo_curve_statistics(*smooth_tempo);

        ImGui.Text("Smoothed: mean % BPM, % to % BPM, roughness % BPM per column (was %)",
                    decimals(mean, 1), decimals(low, 1), decimals(high, 1),
                    decimals(tempo_curve_roughness(*smooth_tempo), 3),
                    decimals(tempo_curve_roughness(*final_tempo), 3));

        plot_tempo_curve(*smooth_tempo, plot_height_for(130.0));
    }

    if beat_grid.loaded
    {
        interval := beat_grid_mean_interval_ms(*beat_grid, onset_envelope.frame_rate);
        agreement := beat_grid_agreement(*beat_grid, *onset_envelope);

        ImGui.Text("Beats: % of them, mean spacing % ms (about % BPM), %x the envelope's average",
                    beat_grid.count, decimals(interval, 0), decimals(60000.0 / interval, 1), decimals(agreement, 1));
    }

    if downbeat_track.loaded
    {
        ImGui.Text("Bars: %/4, % downbeats, mean kick strength on the one % (overall %)",
                    downbeat_track.beats_per_bar,
                    downbeat_track.downbeat_beats.count,
                    decimals(downbeat_track.mean_downbeat_strength, 3),
                    decimals(signal_peak(kick_envelope.values), 3));
    }

    if validated
    {
        ImGui.Text("Checked: median % BPM, mean %, range % to %",
                    decimals(tempo_validation.median_bpm, 1),
                    decimals(tempo_validation.mean_bpm, 1),
                    decimals(tempo_validation.min_bpm, 1),
                    decimals(tempo_validation.max_bpm, 1));

        ImGui.Text("Problems: % out of range (masked), % jumps over 20\%, % of those unsupported by the map",
                    tempo_validation.out_of_range,
                    tempo_validation.jumps,
                    tempo_validation.unsupported_jumps);

    }
}