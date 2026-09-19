/*
adjust.jai -- the Adjust tab: check the timing by ear and eye, and fix it.

What the analysis produces is a tempo every 93 ms, which is too much
to look at and often a few BPM out; what a person can work with is
the waveform with a beat grid laid over it and
playback to hear whether the grid lands on the music. So the tab is:

  * the waveform, drawn with the grid of the timing points on top
  * playback, with the playhead drawn where the music has got to
  * the points themselves, to move, retune, add and delete

The loop is: play it, see the grid drift off the waveform, drag the point
that starts the drifting stretch onto the beat, play it again. Everything
edits the timing model in timing.jai, which started as the analysis and stops
being the analysis the moment the user touches it.

This file uses the renderer in plot.jai, the view in plots.jai, the peaks in
waveform.jai, the points in timing.jai and the transport in playback.jai, so
all of those have to be loaded first.
*/

#import "Basic";
#import "Math";
#import "GL";

Adjust_State :: struct
{
    grid: Timing_Grid_Settings;

    dragging: s64;

    follow: bool;

    keep_pitch: bool;

    volume: float;

    scrub_active:       bool;
    scrub_held_ms:      float64;
    scrub_since_ms:     float64;

    scrub_was_playing:  bool;

    follow_last_ms:     float64;
}

adjust: Adjust_State;

ADJUST_SNAP_MS: float64 : 60.0;

ADJUST_GRAB_PX :: 7.0;

ADJUST_FOLLOW_FRACTION: float64 : 0.3;

ADJUST_SCRUB_DELAY_MS:  float64 : 400.0;
ADJUST_SCRUB_RAMP_MS:   float64 : 800.0;
ADJUST_SCRUB_REPEAT_MS: float64 : 90.0;
ADJUST_SCRUB_MAX_DOUBLINGS :: 6;

adjust_reset :: ()
{
    adjust.grid.beats_per_bar = 4;
    adjust.grid.show_beats    = true;
    adjust.dragging           = -1;
    adjust.follow             = true;

    adjust.volume             = 0.1;
    adjust.keep_pitch         = true;

    adjust.scrub_active   = false;
    adjust.scrub_held_ms  = 0.0;
    adjust.scrub_since_ms = 0.0;

    adjust.scrub_was_playing = false;
    adjust.follow_last_ms    = 0.0;
}

adjust_time_at_x :: (window: Plot_Window, x: float) -> float64
{
    span := window.end_ms - window.start_ms;
    if window.plot_width <= 0.0 return window.start_ms;

    fraction := cast(float64) ((x - window.x0) / window.plot_width);
    if fraction < 0.0 fraction = 0.0;
    if fraction > 1.0 fraction = 1.0;

    return window.start_ms + span * fraction;
}

adjust_mouse_in_plot :: (window: Plot_Window, mouse: ImGui.ImVec2) -> bool
{
    if mouse.x < window.x0 || mouse.x > window.x0 + window.plot_width return false;
    if mouse.y < window.y0 || mouse.y > window.y0 + window.plot_height return false;
    return true;
}

C_STRING_MAX :: 256;

c_string_buffer: [C_STRING_MAX]u8;

c_string :: (text: string) -> *u8
{
    count := text.count;
    if count > C_STRING_MAX - 1 count = C_STRING_MAX - 1;

    memcpy(c_string_buffer.data, text.data, count);
    c_string_buffer[count] = 0;

    return c_string_buffer.data;
}

adjust_transport :: (track_end_ms: float64)
{
    playing := playback_is_playing();

    button_label: *u8 = "Play".data;
    if playing
    {
        button_label = "Pause".data;
    }
    else if playback_is_paused()
    {
        button_label = "Resume".data;
    }

    if ImGui.Button(button_label) playback_toggle();

    ImGui.SameLine();
    if ImGui.Button("Stop".data) playback_stop();

    ImGui.SameLine();
    if ImGui.Button("-5s".data) playback_seek(playback_position_ms() - 5000.0);
    ImGui.SameLine();
    if ImGui.Button("-1s".data) playback_seek(playback_position_ms() - 1000.0);
    ImGui.SameLine();
    if ImGui.Button("+1s".data) playback_seek(playback_position_ms() + 1000.0);
    ImGui.SameLine();
    if ImGui.Button("+5s".data) playback_seek(playback_position_ms() + 5000.0);

    ImGui.SameLine();
    ImGui.Text("   % / %", audio_duration_string(playback_position_ms() / 1000.0),
                           audio_duration_string(track_end_ms / 1000.0));

    _ = ImGui.SliderFloat("Volume".data, *adjust.volume, 0.0, 1.0, "%.2f".data);
    playback_set_volume(cast(float64) adjust.volume);

    _ = ImGui.Checkbox("Follow the playhead".data, *adjust.follow);

    ImGui.Text("Speed");
    ImGui.SameLine();

    current := playback_rate_index();
    for index: 0 .. PLAYBACK_RATES.count - 1
    {
        if index > 0 ImGui.SameLine();

        if ImGui.RadioButton(PLAYBACK_RATE_NAMES[index].data, current == cast(s32) index)
        {
            playback_set_rate_index(cast(s32) index);
        }
    }

    ImGui.SameLine();
    if ImGui.Checkbox("Keep pitch".data, *adjust.keep_pitch)
    {
        playback_set_keep_pitch(adjust.keep_pitch);
    }
}

adjust_hotkeys :: (track_end_ms: float64)
{
    if ImGui.GetIO().WantTextInput return;

    if ImGui.IsKeyPressed(ImGui.Key.Space, false) playback_toggle();

    if ImGui.IsKeyPressed(ImGui.Key.Delete, false)
    {
        if timing.selected >= 0 && timing.selected < timing.points.count
        {
            timing_remove(*timing, timing.selected);
        }
    }

    adjust_scrub(track_end_ms);
}

adjust_scrub :: (track_end_ms: float64)
{
    back    := ImGui.IsKeyDown(ImGui.Key.LeftArrow);
    forward := ImGui.IsKeyDown(ImGui.Key.RightArrow);

    if !back && !forward
    {
        if adjust.scrub_active && adjust.scrub_was_playing
        {
            playback_resume();
        }

        adjust.scrub_active      = false;
        adjust.scrub_was_playing = false;
        adjust.scrub_held_ms     = 0.0;
        adjust.scrub_since_ms    = 0.0;
        return;
    }

    delta_ms := cast(float64) ImGui.GetIO().DeltaTime * 1000.0;
    if delta_ms < 0.0 delta_ms = 0.0;
    if delta_ms > 100.0 delta_ms = 100.0;

    first := !adjust.scrub_active;

    if first
    {
        adjust.scrub_was_playing = playback_is_playing();

        if adjust.scrub_was_playing playback_pause();
    }

    adjust.scrub_active = true;
    adjust.scrub_held_ms += delta_ms;

    move := false;

    if first
    {
        move = true;
        adjust.scrub_since_ms = 0.0;
    }
    else if adjust.scrub_held_ms >= ADJUST_SCRUB_DELAY_MS
    {
        adjust.scrub_since_ms += delta_ms;
        if adjust.scrub_since_ms >= ADJUST_SCRUB_REPEAT_MS
        {
            adjust.scrub_since_ms -= ADJUST_SCRUB_REPEAT_MS;
            move = true;
        }
    }

    if !move return;

    doublings: s64 = 0;
    if adjust.scrub_held_ms > ADJUST_SCRUB_DELAY_MS
    {
        doublings = cast(s64) ((adjust.scrub_held_ms - ADJUST_SCRUB_DELAY_MS) / ADJUST_SCRUB_RAMP_MS);
        if doublings < 0 doublings = 0;
        if doublings > ADJUST_SCRUB_MAX_DOUBLINGS doublings = ADJUST_SCRUB_MAX_DOUBLINGS;
    }

    divisions: s64 = 1;
    for 0 .. doublings - 1 divisions *= 2;

    at := playback_position_ms();

    target := timing_step_beats(*timing, at, divisions, forward, track_end_ms);

    if target < 0.0 target = 0.0;
    if target > track_end_ms target = track_end_ms;
    if target == at return;

    playback_seek(target);
}

adjust_waveform :: (track_end_ms: float64, height: float)
{
    origin := ImGui.GetCursorScreenPos();
    width  := ImGui.GetContentRegionAvail().x;
    if width < 96.0 return;

    window := plot_window("adjust_waveform", PLOT_VIEW_WAVEFORM, origin.x, origin.y, width, height,
                          0.0, track_end_ms, adjust.dragging < 0);

    if window.plot_width < 16.0 || window.plot_height < 16.0 return;

    x0 := window.x0;
    y0 := window.y0;
    w  := window.plot_width;
    h  := window.plot_height;

    plot_quad(x0, y0, x0 + w, y0 + h, PLOT_BACKGROUND);

    if waveform.loaded
    {
        draw_waveform(*waveform, x0, y0, w, h, window.start_ms, window.end_ms, PLOT_WAVE);
    }

    if timing.loaded
    {
        if adjust.grid.show_beats
        {
            beats := timing_beats_in_range(*timing, window.start_ms, window.end_ms, track_end_ms);
            defer release_array(*beats);

            for beats
            {
                marker_x := time_to_x(window, x0, w, it);

                owner := timing_index_at(*timing, it);
                on_the_one := false;

                if owner >= 0
                {
                    point := timing.points[owner];
                    if point.bpm > 0.0
                    {
                        period := 60000.0 / point.bpm;
                        step := cast(s64) ((it - point.time_ms) / period + 0.5);
                        if adjust.grid.beats_per_bar > 0 && step % adjust.grid.beats_per_bar == 0
                        {
                            on_the_one = true;
                        }
                    }
                }

                colour := PLOT_BEAT_GRID;
                thickness: float = 1.0;
                if on_the_one
                {
                    colour = PLOT_BAR_GRID; thickness = 2.0;
                }

                plot_line(marker_x, y0, marker_x, y0 + h, thickness, colour);
            }
        }

        for index: 0 .. timing.points.count - 1
        {
            point := timing.points[index];
            if point.time_ms < window.start_ms || point.time_ms > window.end_ms continue;

            marker_x := time_to_x(window, x0, w, point.time_ms);
            colour := PLOT_TIMING_POINT;
            if index == timing.selected colour = PLOT_TIMING_CHOSEN;

            plot_line(marker_x, y0, marker_x, y0 + h, 2.0, colour);

            plot_quad(marker_x - 3.0, y0, marker_x + 3.0, y0 + 5.0, colour);
        }
    }

    {
        play_ms := playback_position_ms();
        if play_ms >= window.start_ms && play_ms <= window.end_ms
        {
            marker_x := time_to_x(window, x0, w, play_ms);
            plot_line(marker_x, y0, marker_x, y0 + h, 2.0, PLOT_PLAYHEAD);
        }
    }

    plot_border(x0, y0, w, h);

    mouse := ImGui.GetMousePos();

    if ImGui.IsMouseClicked(.Left) && adjust_mouse_in_plot(window, mouse)
    {
        milliseconds := adjust_time_at_x(window, mouse.x);

        grabbed: s64 = -1;
        for index: 0 .. timing.points.count - 1
        {
            marker_x := time_to_x(window, x0, w, timing.points[index].time_ms);
            if abs(mouse.x - marker_x) <= ADJUST_GRAB_PX
            {
                grabbed = index; break;
            }
        }

        if grabbed >= 0
        {
            adjust.dragging  = grabbed;
            timing.selected  = grabbed;
        }
        else
        {
            playback_seek(milliseconds);
            timing.selected = timing_index_at(*timing, milliseconds);
        }
    }

    if adjust.dragging >= 0
    {
        if ImGui.IsMouseDown(.Left)
        {
            timing_set_time(*timing, adjust.dragging, adjust_time_at_x(window, mouse.x));
        }
        else
        {
            adjust.dragging = -1;
        }
    }

    if ImGui.IsMouseClicked(.Left) && ImGui.GetIO().KeyCtrl && adjust_mouse_in_plot(window, mouse)
    {
        milliseconds := adjust_time_at_x(window, mouse.x);
        near := adjust_nearest_beat(milliseconds, track_end_ms);
        bpm := timing_bpm_at(*timing, milliseconds);
        if bpm <= 0.0 && timing.points.count > 0 bpm = timing.points[0].bpm;
        timing_add(*timing, near, bpm);
    }

    if adjust.follow
    {
        play_ms := playback_position_ms();
        moved := play_ms != adjust.follow_last_ms;
        adjust.follow_last_ms = play_ms;

        if moved && (play_ms < window.start_ms || play_ms > window.end_ms)
        {
            span := window.end_ms - window.start_ms;
            plot_view_set(PLOT_VIEW_WAVEFORM, play_ms - span * ADJUST_FOLLOW_FRACTION,
                          play_ms - span * ADJUST_FOLLOW_FRACTION + span);
        }
    }
}

adjust_nearest_beat :: (milliseconds: float64, track_end_ms: float64) -> float64
{
    if !timing.loaded return milliseconds;

    beats := timing_beats_in_range(*timing, milliseconds - ADJUST_SNAP_MS,
                                   milliseconds + ADJUST_SNAP_MS, track_end_ms);
    defer release_array(*beats);

    best := milliseconds;
    best_distance: float64 = ADJUST_SNAP_MS;

    for beats
    {
        distance := abs(it - milliseconds);
        if distance < best_distance
        {
            best_distance = distance;
            best = it;
        }
    }

    return best;
}

adjust_point_controls :: (track_end_ms: float64)
{
    if !timing.loaded return;

    ImGui.Separator();
    ImGui.Text("Timing points (%):", timing.points.count);

    play_ms := playback_position_ms();

    if ImGui.Button("Add at playhead".data)
    {
        bpm := timing_bpm_at(*timing, play_ms);
        if bpm <= 0.0 && timing.points.count > 0 bpm = timing.points[0].bpm;
        timing_add(*timing, adjust_nearest_beat(play_ms, track_end_ms), bpm);
    }

    ImGui.SameLine();
    if ImGui.Button("Delete selected".data) timing_remove(*timing, timing.selected);

    ImGui.SameLine();
    if ImGui.Button("Back to default".data)
    {
        seed_timing_from_curve(*timing, *smooth_tempo);
        playback_seek(0.0);
    }

    ImGui.SameLine();
    if timing.edited ImGui.TextDisabled("(edited)");

    if timing.selected >= 0 && timing.selected < timing.points.count
    {
        point := timing.points[timing.selected];

        edit_time := cast(float) point.time_ms;
        if ImGui.DragFloat("Time (ms)".data, *edit_time, 1.0, 0.0, cast(float) track_end_ms, "%.1f".data)
        {
            timing_set_time(*timing, timing.selected, cast(float64) edit_time);
        }

        edit_bpm := cast(float) point.bpm;
        if ImGui.DragFloat("BPM".data, *edit_bpm, 1, cast(float) TIMING_MIN_BPM, cast(float) TIMING_MAX_BPM, "%.0f".data)
        {
            timing_set_bpm(*timing, timing.selected, cast(float64) edit_bpm);
        }

        ImGui.SameLine();
        if ImGui.SmallButton("-10".data) timing_set_time(*timing, timing.selected, point.time_ms - 10.0);
        ImGui.SameLine();
        if ImGui.SmallButton("-1".data)  timing_set_time(*timing, timing.selected, point.time_ms - 1.0);
        ImGui.SameLine();
        if ImGui.SmallButton("+1".data)  timing_set_time(*timing, timing.selected, point.time_ms + 1.0);
        ImGui.SameLine();
        if ImGui.SmallButton("+10".data) timing_set_time(*timing, timing.selected, point.time_ms + 10.0);

        ImGui.SameLine();
        if ImGui.SmallButton("set to playhead".data) timing_set_time(*timing, timing.selected, play_ms);

        ImGui.SameLine();
        if ImGui.SmallButton("snap".data)
        {
            timing_set_time(*timing, timing.selected,
                            adjust_nearest_beat(point.time_ms, track_end_ms));
        }
    }

    ImGui.Separator();
    ImGui.Text("Whole track");

    offset := cast(float) adjust_offset_ms;
    if ImGui.DragFloat("Shift all (ms)".data, *offset, 0.5, -2000.0, 2000.0, "%.1f".data)
    {
        timing_shift_all(*timing, cast(float64) offset - adjust_offset_ms);
        adjust_offset_ms = cast(float64) offset;
    }

    scale := cast(float) adjust_scale;
    if ImGui.DragFloat("Scale all (x)".data, *scale, 0.001, 0.5, 2.0, "%.4f".data)
    {
        if adjust_scale > 0.0 timing_scale_all(*timing, cast(float64) scale / adjust_scale);
        adjust_scale = cast(float64) scale;
    }

    ImGui.SameLine();
    if ImGui.SmallButton("x2".data)
    {
        timing_scale_all(*timing, 2.0);  adjust_scale = 1.0;
    }
    ImGui.SameLine();
    if ImGui.SmallButton("/2".data)
    {
        timing_scale_all(*timing, 0.5);  adjust_scale = 1.0;
    }
    ImGui.SameLine();
    if ImGui.SmallButton("reset".data)
    {
        adjust_offset_ms = 0.0; adjust_scale = 1.0;
    }

    ImGui.Separator();
    if ImGui.BeginChild("timing_points", ImGui.ImVec2.{ 0.0, 140.0 }, true)
    {
        for index: 0 .. timing.points.count - 1
        {
            point := timing.points[index];

            chosen := index == timing.selected;

            text := tprint("%  %   % BPM", audio_duration_string(point.time_ms / 1000.0),
                           cast(s64) point.time_ms, decimals(point.bpm, 3));

            selectable_size := ImGui.ImVec2.{ 0.0, 0.0 };
            if ImGui.Selectable(c_string(text), chosen, .None, *selectable_size)
            {
                timing.selected = index;

                playback_play_from(point.time_ms);
            }
        }
    }
    ImGui.EndChild();

    ImGui.Separator();

    if ImGui.Button("Export timing points (.txt)".data)
    {
        ok, message := write_timing_points_txt(timing.points, audio_file.path);

        set_export_status(message);
        if !ok log_error("%\n", message);

        if ok reveal_in_explorer(timing_points_txt_path(audio_file.path), window);
    }

    ImGui.SameLine();
    if export_status.count > 0 ImGui.Text("%", export_status);
}

adjust_offset_ms: float64;
adjust_scale:     float64 = 1.0;

prepare_adjust_tab :: ()
{
    if waveform.loaded free_waveform(*waveform);
    if analysis_audio.loaded waveform = build_waveform(*analysis_audio);

    seed_timing_from_curve(*timing, *smooth_tempo);
    adjust_reset();

    ok, error := playback_open(*audio_file);
    if !ok log_error("Could not open '%' for playback: %\n", audio_file.path, error);

    playback_set_volume(cast(float64) adjust.volume);

}

update_adjust_tab :: ()
{
    if !audio_file.loaded return;

    track_end_ms := audio_file.duration * 1000.0;
    if onset_envelope.loaded track_end_ms = onset_envelope.duration * 1000.0;

    adjust_hotkeys(track_end_ms);

    adjust_transport(track_end_ms);

    ImGui.Separator();
    _ = ImGui.Checkbox("Show the beat grid".data, *adjust.grid.show_beats);

    ImGui.SameLine();
    beats_per_bar := cast(s32) adjust.grid.beats_per_bar;
    if ImGui.DragInt("Beats per bar".data, *beats_per_bar, 0.1, 1, 16)
    {
        adjust.grid.beats_per_bar = beats_per_bar;
    }

    adjust_waveform(track_end_ms, plot_height_for(220.0));
    adjust_point_controls(track_end_ms);
}