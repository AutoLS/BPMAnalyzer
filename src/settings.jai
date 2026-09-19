/*
settings.jai -- the analysis knobs, and the result they give.

Every one of these was a constant chosen by measurement, and on most tracks
the choice does not matter. On some it is the whole answer: a tempo prior
centred on 120 beats per minute is right about most music and wrong about a
track that is at 250, and nothing inside the program can tell which of those
it is looking at. The person listening can, in about a second.

So they are here, with the result shown next to them, and a button that puts
them all back. The idea is not that the defaults are wrong -- they are the
best single answer across everything measured -- but that a single answer is
the wrong shape for this problem.

Two kinds of setting, and they behave differently:

  the analysis   re-runs the stages when changed, which takes a second or so
  the reporting  applies at once, because it only decides which of the
                 curve's wobbles to call a tempo change

A change is acted on when the control is let go rather than while it is being
dragged. Re-analysing sixty times a second would get nothing done.
*/

#import "Basic";

setting_float :: (label: string, value: *float64, speed: float,
                  low: float64, high: float64, format: string) -> bool
                  {
    shown := cast(float) value.*;
    ImGui.DragFloat(label.data, *shown, speed, cast(float) low, cast(float) high, format.data);
    value.* = cast(float64) shown;

    return ImGui.IsItemDeactivatedAfterEdit();
}

setting_int :: (label: string, value: *s64, speed: float, low: s32, high: s32) -> bool
{
    shown := cast(s32) value.*;
    ImGui.DragInt(label.data, *shown, speed, low, high);
    value.* = cast(s64) shown;

    return ImGui.IsItemDeactivatedAfterEdit();
}

setting_f32 :: (label: string, value: *float32, speed: float,
                low: float64, high: float64, format: string) -> bool
                {
    ImGui.DragFloat(label.data, value, speed, cast(float) low, cast(float) high, format.data);

    return ImGui.IsItemDeactivatedAfterEdit();
}

setting_s32 :: (label: string, value: *s32, speed: float, low: s32, high: s32) -> bool
{
    ImGui.DragInt(label.data, value, speed, low, high);

    return ImGui.IsItemDeactivatedAfterEdit();
}

setting_bool :: (label: string, value: *bool) -> bool
{
    _ = ImGui.Checkbox(label.data, value);

    return ImGui.IsItemDeactivatedAfterEdit();
}

settings_need_reanalysis: bool;

draw_settings :: ()
{
    if !ImGui.CollapsingHeader("Analysis settings".data, ImGui.TreeNodeFlags.DefaultOpen)
    {
        if settings_need_reanalysis request_reanalysis();
        return;
    }

    ImGui.TextDisabled("Change one and the analysis runs again.");
    ImGui.Separator();

    ImGui.PushItemWidth(320.0);
    defer ImGui.PopItemWidth();

    ImGui.Text("Tempo prior");
    ImGui.Indent();

    if setting_float("Preferred tempo", *app.settings.octave.prior.center_bpm, 0.5, 40.0, 300.0, "%.0f")
        settings_need_reanalysis = true;

    if setting_float("How far it reaches (octaves)", *app.settings.octave.prior.sigma_octaves, 0.01, 0.25, 3.0, "%.2f")
        settings_need_reanalysis = true;

    if setting_float("How strongly it pulls", *app.settings.octave.prior.weight, 0.01, 0.0, 2.0, "%.2f")
        settings_need_reanalysis = true;

    ImGui.Unindent();

    ImGui.Separator();
    ImGui.Text("Tempogram");
    ImGui.Indent();

    if setting_float("Window (seconds)", *app.settings.tempogram.window_seconds, 0.05, 1.0, 12.0, "%.2f")
        settings_need_reanalysis = true;

    if setting_s32("Harmonics read", *app.settings.tempogram.comb_harmonics, 0.1, 1, 8)
        settings_need_reanalysis = true;

    if setting_f32("Harmonic weighting", *app.settings.tempogram.harmonic_decay, 0.01, 0.0, 2.0, "%.2f")
        settings_need_reanalysis = true;

    ImGui.Unindent();

    ImGui.Separator();
    ImGui.Text("Tracker");
    ImGui.Indent();

    if setting_float("Tempo-change penalty", *app.settings.tempo.smoothing, 0.005, 0.005, 2.0, "%.3f")
        settings_need_reanalysis = true;

    if setting_float("Flip threshold (octaves)", *app.settings.octave.minimum_jump_octaves, 0.01, 0.2, 1.0, "%.2f")
        settings_need_reanalysis = true;

    ImGui.Unindent();

    ImGui.Separator();
    ImGui.Text("What counts as a change");
    ImGui.Indent();

    _ = setting_float("Smallest change (BPM)", *app.settings.osu.minimum_change_bpm, 0.1, 0.0, 30.0, "%.1f");
    _ = setting_int("How long it must hold (ms)", *app.settings.osu.minimum_hold_ms, 10.0, 0, 20000);

    ImGui.Unindent();

    ImGui.Separator();

    if smooth_tempo.loaded
    {
        changes: [..] Osu_Timing_Point;
        defer release_array(*changes);
        collect_osu_timing_points(*smooth_tempo, app.settings.osu, *changes);

        ImGui.Text("Now: % BPM, % change(s)", whole_bpm(tempo_curve_median_bpm(*smooth_tempo)),
                   changes.count - 1);
        ImGui.SameLine();
        ImGui.TextDisabled("(octave stage: % shifted of % segment(s))",
                           octave_report.shifted_segments, octave_report.segment_count);
    }
    else
    {
        ImGui.TextDisabled("Nothing analyzed yet.");
    }

    ImGui.Separator();

    ImGui.BeginDisabled(!settings_need_reanalysis);
    if ImGui.Button("Re-analyze") request_reanalysis();
    ImGui.EndDisabled();

    ImGui.SameLine();
    if ImGui.Button("Reset to defaults")
    {
        app.settings = .{};
        settings_need_reanalysis = false;
        request_reanalysis();
    }

    ImGui.SameLine();
    if settings_need_reanalysis ImGui.TextDisabled("(changed -- not analysed yet)");
}