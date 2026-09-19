/*
graphs.jai -- the three graphs, built on the renderer in plot.jai.

  the onset envelope with the beats and downbeats marked on it
  the tempogram as a heatmap with the tempo curve drawn over it
  the tempo curve on its own, against a BPM grid

Each one reserves its space in the ImGui layout with an invisible button, so
the labels and buttons around it keep flowing normally, and then draws its
axes with ImGui text at fixed screen positions.

All three are the same track on the same time axis and they all draw the one
window from plot.jai, so zooming or dragging any of them moves the other two
with it and they stay lined up. What each graph does is turn that window of
milliseconds into the slice of its own data that falls inside it: a range of
envelope frames, a sub-rectangle of the heatmap texture, a run of tempo
columns.
*/

#import "Basic";
#import "Math";
#import "GL";

two_digits :: (value: s64) -> string
{
    if value < 10 return tprint("0%", value);
    return tprint("%", value);
}

format_clock :: (seconds: float64) -> string
{
    total := cast(s64) seconds;
    if total < 0 total = 0;
    return tprint("%:%", total / 60, two_digits(total % 60));
}

plot_border :: (x: float, y: float, width: float, height: float)
{
    plot_line(x, y, x + width, y, 1.0, PLOT_BORDER);
    plot_line(x, y + height, x + width, y + height, 1.0, PLOT_BORDER);
    plot_line(x, y, x, y + height, 1.0, PLOT_BORDER);
    plot_line(x + width, y, x + width, y + height, 1.0, PLOT_BORDER);
}

plot_y_label :: (x_right: float, y_centre: float, text: string)
{
    size := ImGui.CalcTextSize(text);
    plot_label(x_right - size.x, y_centre - size.y * 0.5, text);
}

plot_time_axis :: (x0: float, y_bottom: float, width: float,
                   start_seconds: float64, end_seconds: float64, ticks: s64 = 6)
                   {
    span := end_seconds - start_seconds;
    if span <= 0.0 || ticks < 1 return;

    for tick: 0 .. ticks
    {
        fraction := cast(float64) tick / cast(float64) ticks;
        x := x0 + width * cast(float) fraction;

        plot_line(x, y_bottom, x, y_bottom + 4.0, 1.0, PLOT_BORDER);

        text := format_clock(start_seconds + span * fraction);
        size := ImGui.CalcTextSize(text);

        label_x := x - size.x * 0.5;
        if label_x < x0 - PLOT_MARGIN_LEFT + 2.0 label_x = x0 - PLOT_MARGIN_LEFT + 2.0;
        if label_x + size.x > x0 + width + PLOT_MARGIN_RIGHT label_x = x0 + width + PLOT_MARGIN_RIGHT - size.x;

        plot_label(label_x, y_bottom + 5.0, text);
    }
}

envelope_frame_at_ms :: (envelope: *Onset_Envelope, milliseconds: float64) -> s64
{
    hop := cast(s64) (milliseconds / 1000.0
                      * cast(float64) envelope.sample_rate / cast(float64) envelope.hop_size);

    index := hop - envelope.first_frame;
    if index < 0 index = 0;
    if index > envelope.frame_count - 1 index = envelope.frame_count - 1;
    return index;
}

downsample_slice :: (values: [] float32, from: s64, to: s64, columns: s64) -> [..] float32
{
    result: [..] float32;
    if values.count == 0 || columns < 1 return result;

    if from < 0 from = 0;
    if to > values.count to = values.count;
    if to <= from return result;

    count := to - from;

    if count <= columns
    {
        array_resize(*result, count, false);
        for i: 0 .. count - 1 result[i] = values[from + i];
        return result;
    }

    array_resize(*result, columns, false);
    for column: 0 .. columns - 1
    {
        start := from + column * count / columns;
        end   := from + (column + 1) * count / columns;
        if end <= start end = start + 1;

        peak: float32 = 0;
        for i: start .. end - 1 if values[i] > peak peak = values[i];

        result[column] = peak;
    }

    return result;
}

visible_log_bpms :: (curve: *Tempo_Curve, start_ms: float64, end_ms: float64,
                     fallback_log: float64) -> [..] float32
                     {
    result: [..] float32;
    if !curve.loaded || curve.column_count < 2 return result;

    first := tempo_curve_column_at_time_ms(curve, start_ms);
    last  := tempo_curve_column_at_time_ms(curve, end_ms);
    if first < 0 first = 0;
    if last > curve.column_count - 1 last = curve.column_count - 1;
    if last <= first return result;

    array_resize(*result, last - first + 1, false);
    for column: first .. last
    {
        bpm := cast(float64) curve.bpms[column];
        result[column - first] = ifx bpm > 0.0 then cast(float32) log(bpm) else cast(float32) fallback_log;
    }

    return result;
}

time_to_x :: (window: Plot_Window, x0: float, width: float, milliseconds: float64) -> float
{
    span := window.end_ms - window.start_ms;
    if span <= 0.0 return x0;
    return x0 + width * cast(float) ((milliseconds - window.start_ms) / span);
}

plot_readout :: (curve: *Tempo_Curve, window: Plot_Window,
                 x0: float, y0: float, width: float, height: float)
                 {
    if !window.hovered return;

    mouse := ImGui.GetMousePos();

    plot_line(mouse.x, y0, mouse.x, y0 + height, 1.0, PLOT_CURSOR);

    fraction := cast(float64) ((mouse.x - x0) / width);
    if fraction < 0.0 fraction = 0.0;
    if fraction > 1.0 fraction = 1.0;

    milliseconds := window.start_ms + (window.end_ms - window.start_ms) * fraction;

    if !curve.loaded
    {
        ImGui.SetTooltip("% ms", cast(s64) milliseconds);
        return;
    }

    bpm := tempo_at_time_ms(curve, milliseconds);

    ImGui.SetTooltip("(%, %)   %", cast(s64) milliseconds, whole_bpm(bpm),
                     format_clock(milliseconds / 1000.0));
}

plot_envelope_with_beats :: (envelope: *Onset_Envelope, beats: *Beat_Grid,
                             downbeats: *Downbeat_Track, curve: *Tempo_Curve,
                             height: float = 96.0)
                             {
    if !envelope.loaded || !plot.ready return;

    origin := ImGui.GetCursorScreenPos();
    width  := ImGui.GetContentRegionAvail().x;
    if width < 96.0 return;

    duration_ms := envelope.duration * 1000.0;
    window := plot_window("envelope_plot", PLOT_VIEW_ENVELOPE, origin.x, origin.y, width, height, 0.0, duration_ms);
    if window.plot_width < 16.0 || window.plot_height < 16.0 return;

    x0 := window.x0;
    y0 := window.y0;
    plot_width  := window.plot_width;
    plot_height := window.plot_height;

    plot_quad(x0, y0, x0 + plot_width, y0 + plot_height, PLOT_BACKGROUND);

    for line: 1 .. 3
    {
        gy := y0 + plot_height * cast(float) line / 4.0;
        plot_line(x0, gy, x0 + plot_width, gy, 1.0, PLOT_GRID);
    }

    from := envelope_frame_at_ms(envelope, window.start_ms);
    to   := envelope_frame_at_ms(envelope, window.end_ms) + 1;

    values := downsample_slice(envelope.values, from, to, cast(s64) plot_width);
    defer release_array(*values);

    if values.count > 1
    {
        slice_from := time_to_x(window, x0, plot_width, frame_time_ms(envelope, from));
        slice_to   := time_to_x(window, x0, plot_width, frame_time_ms(envelope, to - 1));
        if slice_to > slice_from
        {
            plot_series_filled(slice_from, y0, slice_to - slice_from, plot_height,
                               values, 0.0, 1.0, PLOT_ENVELOPE);
        }
    }

    if beats.loaded
    {
        for index: 0 .. beats.count - 1
        {
            frame := beats.frames[index];
            if frame < 0 || frame >= envelope.frame_count continue;

            milliseconds := frame_time_ms(envelope, frame);
            if milliseconds < window.start_ms || milliseconds > window.end_ms continue;

            marker_x := time_to_x(window, x0, plot_width, milliseconds);

            colour := PLOT_BEAT;
            thickness: float = 1.0;

            if downbeats.loaded && index < downbeats.positions.count && downbeats.positions[index] == 1
            {
                colour = PLOT_DOWNBEAT;
                thickness = 2.0;
            }

            plot_line(marker_x, y0, marker_x, y0 + plot_height, thickness, colour);
        }
    }

    plot_border(x0, y0, plot_width, plot_height);
    plot_readout(curve, window, x0, y0, plot_width, plot_height);

    plot_y_label(x0 - 6.0, y0 + 7.0, "1");
    plot_y_label(x0 - 6.0, y0 + plot_height - 7.0, "0");
    plot_time_axis(x0, y0 + plot_height, plot_width,
                   window.start_ms / 1000.0, window.end_ms / 1000.0);
}

plot_tempogram_with_curve :: (tempogram: *Tempogram, curve: *Tempo_Curve, height: float = 220.0)
{
    if !tempogram.loaded || !plot.ready return;

    origin := ImGui.GetCursorScreenPos();
    width  := ImGui.GetContentRegionAvail().x;
    if width < 96.0 return;

    texture_start := tempogram_column_time_ms(tempogram, 0);
    texture_end   := tempogram_column_time_ms(tempogram, tempogram.column_count - 1);

    window := plot_window("tempogram_plot", PLOT_VIEW_TEMPOGRAM, origin.x, origin.y, width, height, 0.0, texture_end);
    if window.plot_width < 16.0 || window.plot_height < 16.0 return;

    x0 := window.x0;
    y0 := window.y0;
    plot_width  := window.plot_width;
    plot_height := window.plot_height;

    if plot_texture_valid && texture_end > texture_start
    {
        left  := ifx window.start_ms > texture_start then window.start_ms else texture_start;
        right := ifx window.end_ms   < texture_end   then window.end_ms   else texture_end;

        if right > left
        {
            texture_span := texture_end - texture_start;
            u0 := cast(float) ((left  - texture_start) / texture_span);
            u1 := cast(float) ((right - texture_start) / texture_span);
            if u0 < 0.0 u0 = 0.0;
            if u1 > 1.0 u1 = 1.0;

            plot_textured_quad(time_to_x(window, x0, plot_width, left), y0,
                               time_to_x(window, x0, plot_width, right), y0 + plot_height,
                               u0, 0.0, u1, 1.0);
        }
    }
    else
    {
        plot_quad(x0, y0, x0 + plot_width, y0 + plot_height, PLOT_BACKGROUND);
    }

    min_log := log(tempogram.min_bpm);
    max_log := log(tempogram.max_bpm);

    if curve.loaded && curve.column_count > 1
    {
        logged := visible_log_bpms(curve, window.start_ms, window.end_ms, min_log);
        defer release_array(*logged);

        if logged.count > 1
        {
            first := tempo_curve_column_at_time_ms(curve, window.start_ms);
            last  := tempo_curve_column_at_time_ms(curve, window.end_ms);

            curve_from := time_to_x(window, x0, plot_width, tempo_curve_time_ms(curve, first));
            curve_to   := time_to_x(window, x0, plot_width, tempo_curve_time_ms(curve, last));

            if curve_to > curve_from
            {
                plot_series(curve_from, y0, curve_to - curve_from, plot_height, logged, 0.0,
                            cast(float32) min_log, cast(float32) max_log, 2.0, PLOT_CURVE);
            }
        }
    }

    plot_border(x0, y0, plot_width, plot_height);
    plot_readout(curve, window, x0, y0, plot_width, plot_height);

    for bpm: float64.[ 60.0, 120.0, 240.0 ]
    {
        if bpm < tempogram.min_bpm || bpm > tempogram.max_bpm continue;

        fraction := (log(bpm) - min_log) / (max_log - min_log);
        label_y := y0 + plot_height * (1.0 - cast(float) fraction);

        plot_y_label(x0 - 6.0, label_y, tprint("%", cast(s64) bpm));
    }

    plot_time_axis(x0, y0 + plot_height, plot_width,
                   window.start_ms / 1000.0, window.end_ms / 1000.0);
}

plot_tempo_curve :: (curve: *Tempo_Curve, height: float = 110.0,
                     min_bpm: float64 = 40.0, max_bpm: float64 = 300.0)
                     {
    if !curve.loaded || !plot.ready return;

    origin := ImGui.GetCursorScreenPos();
    width  := ImGui.GetContentRegionAvail().x;
    if width < 96.0 return;

    min_log := log(min_bpm);
    max_log := log(max_bpm);

    last_ms := tempo_curve_time_ms(curve, curve.column_count - 1);
    window := plot_window("tempo_curve_plot", PLOT_VIEW_CURVE, origin.x, origin.y, width, height, 0.0, last_ms);
    if window.plot_width < 16.0 || window.plot_height < 16.0 return;

    x0 := window.x0;
    y0 := window.y0;
    plot_width  := window.plot_width;
    plot_height := window.plot_height;

    plot_quad(x0, y0, x0 + plot_width, y0 + plot_height, PLOT_BACKGROUND);

    for bpm: float64.[ 60.0, 120.0, 240.0 ]
    {
        if bpm < min_bpm || bpm > max_bpm continue;

        fraction := (log(bpm) - min_log) / (max_log - min_log);
        gy := y0 + plot_height * (1.0 - cast(float) fraction);

        plot_line(x0, gy, x0 + plot_width, gy, 1.0, PLOT_GRID);
    }

    logged := visible_log_bpms(curve, window.start_ms, window.end_ms, min_log);
    defer release_array(*logged);

    if logged.count > 1
    {
        first := tempo_curve_column_at_time_ms(curve, window.start_ms);
        last  := tempo_curve_column_at_time_ms(curve, window.end_ms);

        curve_from := time_to_x(window, x0, plot_width, tempo_curve_time_ms(curve, first));
        curve_to   := time_to_x(window, x0, plot_width, tempo_curve_time_ms(curve, last));

        if curve_to > curve_from
        {
            plot_series(curve_from, y0, curve_to - curve_from, plot_height, logged, 0.0,
                        cast(float32) min_log, cast(float32) max_log, 2.0, PLOT_CURVE);
        }
    }

    plot_border(x0, y0, plot_width, plot_height);
    plot_readout(curve, window, x0, y0, plot_width, plot_height);

    for bpm: float64.[ 60.0, 120.0, 240.0 ]
    {
        if bpm < min_bpm || bpm > max_bpm continue;

        fraction := (log(bpm) - min_log) / (max_log - min_log);
        plot_y_label(x0 - 6.0, y0 + plot_height * (1.0 - cast(float) fraction), tprint("%", cast(s64) bpm));
    }

    plot_time_axis(x0, y0 + plot_height, plot_width,
                   window.start_ms / 1000.0, window.end_ms / 1000.0);
}