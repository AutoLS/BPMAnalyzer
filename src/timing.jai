/*
timing.jai -- the timing points, and the user's edits to them.

The analysis produces a tempo for every 93 ms column, which is far more
detail than anyone wants to look at. What a person edits is a handful of
points: from this moment on, the tempo is this, until the next point says
otherwise. That is the same shape the .osu export writes, and this is the
same collapsing, so the two agree about where the tempo changes are.

They differ in one thing on purpose. The export rounds each tempo to a whole
BPM, because that is what the file format wants; this keeps the precise value
the analysis measured. The whole point of the editor is to let someone
correct the analysis by hand, and they cannot see what to correct if the
number has already been rounded away.

A point's time is absolute and editing its tempo does not move the points
after it. That is how osu! reads a timing point, and it is the behaviour a
person expects: changing the tempo of one stretch re-spaces the beats inside
that stretch and leaves the rest of the track where it was.
*/

#import "Basic";
#import "Math";

TIMING_MIN_BPM :: 1.0;
TIMING_MAX_BPM :: 1000.0;

TIMING_MAX_BEATS :: 20000;

Timing_Point :: struct
{
    time_ms: float64;
    bpm:     float64;
}

Timing_Edit :: struct
{
    loaded: bool;

    points: [..] Timing_Point;
    edited: bool;

    selected: s64;
}

free_timing_edit :: (edit: *Timing_Edit)
{
    if edit.points.data != null array_reset(*edit.points);

    edit.loaded   = false;
    edit.edited   = false;
    edit.selected = -1;
}

seed_timing_from_curve :: (edit: *Timing_Edit, curve: *Tempo_Curve, settings: Osu_Settings = .{})
{
    free_timing_edit(edit);

    if !curve.loaded || curve.column_count == 0 return;

    runs := osu_tempo_runs(curve, settings);
    defer release_array(*runs);

    if runs.count == 0 return;

    longest: s64 = 0;
    longest_held: float64 = -1.0;

    settled: s64 = 0;

    for index: 0 .. runs.count - 1
    {
        start := tempo_curve_time_ms(curve, runs[index].column);

        end := tempo_curve_time_ms(curve, curve.column_count - 1);
        if index + 1 < runs.count end = tempo_curve_time_ms(curve, runs[index + 1].column);

        held := end - start;
        if held > longest_held
        {
            longest_held = held; longest = index;
        }

        if runs[index].bpm == settled continue;
        if held < cast(float64) settings.minimum_hold_ms continue;

        array_add(*edit.points, Timing_Point.{ start, timing_whole_bpm(run_mean_bpm(curve, runs[index])) });
        settled = runs[index].bpm;
    }

    if edit.points.count == 0
    {
        array_add(*edit.points, Timing_Point.{
            tempo_curve_time_ms(curve, runs[longest].column),
            timing_whole_bpm(run_mean_bpm(curve, runs[longest])),
        });
    }

    edit.loaded   = true;
    edit.edited   = false;
    edit.selected = 0;
}

run_mean_bpm :: (curve: *Tempo_Curve, run: Osu_Tempo_Run) -> float64
{
    total: float64 = 0.0;
    count: s64 = 0;

    for column: run.column .. run.last_column
    {
        bpm := cast(float64) curve.bpms[column];
        if bpm <= 0.0 continue;
        total += bpm;
        count += 1;
    }

    if count == 0 return 0.0;
    return total / cast(float64) count;
}

timing_whole_bpm :: (bpm: float64) -> float64
{
    if bpm <= 0.0 return 0.0;
    return cast(float64) cast(s64) (bpm + 0.5);
}

timing_index_at :: (edit: *Timing_Edit, milliseconds: float64) -> s64
{
    found: s64 = -1;

    for index: 0 .. edit.points.count - 1
    {
        if edit.points[index].time_ms <= milliseconds found = index;
        else break;
    }

    return found;
}

timing_bpm_at :: (edit: *Timing_Edit, milliseconds: float64) -> float64
{
    index := timing_index_at(edit, milliseconds);
    if index < 0 return 0.0;
    return edit.points[index].bpm;
}

timing_next_time :: (edit: *Timing_Edit, index: s64, track_end_ms: float64) -> float64
{
    if index + 1 < edit.points.count return edit.points[index + 1].time_ms;
    return track_end_ms;
}

timing_mark_edited :: (edit: *Timing_Edit)
{
    edit.edited = true;
}

timing_add :: (edit: *Timing_Edit, milliseconds: float64, bpm: float64) -> s64
{
    if bpm <= 0.0 return -1;

    for index: 0 .. edit.points.count - 1
    {
        if abs(edit.points[index].time_ms - milliseconds) <= 1.0
        {
            edit.points[index].bpm = bpm;
            edit.selected = index;
            timing_mark_edited(edit);
            return index;
        }
    }

    where: s64 = edit.points.count;
    for index: 0 .. edit.points.count - 1
    {
        if edit.points[index].time_ms > milliseconds
        {
            where = index; break;
        }
    }

    array_add(*edit.points, Timing_Point.{ milliseconds, bpm });

    index := edit.points.count - 1;
    while index > where
    {
        edit.points[index] = edit.points[index - 1];
        index -= 1;
    }
    edit.points[where] = Timing_Point.{ milliseconds, bpm };

    edit.selected = where;
    timing_mark_edited(edit);
    return where;
}

timing_remove :: (edit: *Timing_Edit, index: s64)
{
    if index < 0 || index >= edit.points.count return;
    if edit.points.count <= 1 return;

    for i: index .. edit.points.count - 2 edit.points[i] = edit.points[i + 1];

    array_resize(*edit.points, edit.points.count - 1, false);

    if edit.selected >= edit.points.count edit.selected = edit.points.count - 1;
    timing_mark_edited(edit);
}

timing_set_time :: (edit: *Timing_Edit, index: s64, milliseconds: float64)
{
    if index < 0 || index >= edit.points.count return;
    if milliseconds < 0.0 milliseconds = 0.0;

    edit.points[index].time_ms = milliseconds;
    timing_mark_edited(edit);
}

timing_set_bpm :: (edit: *Timing_Edit, index: s64, bpm: float64)
{
    if index < 0 || index >= edit.points.count return;

    if bpm < TIMING_MIN_BPM bpm = TIMING_MIN_BPM;
    if bpm > TIMING_MAX_BPM bpm = TIMING_MAX_BPM;

    edit.points[index].bpm = bpm;
    timing_mark_edited(edit);
}

timing_shift_all :: (edit: *Timing_Edit, milliseconds: float64)
{
    if milliseconds == 0.0 return;

    for index: 0 .. edit.points.count - 1
    {
        edit.points[index].time_ms += milliseconds;
        if edit.points[index].time_ms < 0.0 edit.points[index].time_ms = 0.0;
    }

    timing_mark_edited(edit);
}

timing_scale_all :: (edit: *Timing_Edit, factor: float64)
{
    if factor <= 0.0 return;

    for index: 0 .. edit.points.count - 1
    {
        bpm := edit.points[index].bpm * factor;
        if bpm < TIMING_MIN_BPM bpm = TIMING_MIN_BPM;
        if bpm > TIMING_MAX_BPM bpm = TIMING_MAX_BPM;
        edit.points[index].bpm = bpm;
    }

    timing_mark_edited(edit);
}

timing_beats_in_range :: (edit: *Timing_Edit, from_ms: float64, to_ms: float64,
                          track_end_ms: float64) -> [..] float64
                          {
    beats: [..] float64;
    if !edit.loaded || to_ms <= from_ms return beats;

    for index: 0 .. edit.points.count - 1
    {
        point := edit.points[index];
        if point.bpm <= 0.0 continue;

        segment_start := point.time_ms;
        segment_end   := timing_next_time(edit, index, track_end_ms);

        if segment_end <= from_ms || segment_start >= to_ms continue;

        period := 60000.0 / point.bpm;
        if period <= 0.0 continue;

        step: s64 = 0;
        if segment_start < from_ms
        {
            step = cast(s64) ((from_ms - segment_start) / period);
            if step < 0 step = 0;
        }

        time := segment_start + cast(float64) step * period;

        while time < segment_end && time <= to_ms
        {
            if time >= from_ms array_add(*beats, time);

            if beats.count >= TIMING_MAX_BEATS return beats;

            time += period;
        }

        if beats.count >= TIMING_MAX_BEATS return beats;
    }

    return beats;
}

timing_step_beats :: (edit: *Timing_Edit, at: float64, count: s64,
                      forward: bool, track_end_ms: float64) -> float64
                      {
    if !edit.loaded || edit.points.count == 0 return at;
    if count < 1 return at;

    bpm := timing_bpm_at(edit, at);
    if bpm <= 0.0 return at;

    period := 60000.0 / bpm;

    window := period * (cast(float64) count + 4.0);
    if window < period * 8.0 window = period * 8.0;

    beats := timing_beats_in_range(edit, at - window, at + window, track_end_ms);
    defer release_array(*beats);
    if beats.count == 0 return at;

    tolerance := period * 0.001;

    if forward
    {
        first: s64 = -1;
        for index: 0 .. beats.count - 1
        {
            if beats[index] > at + tolerance
            {
                first = index; break;
            }
        }
        if first < 0 return at;

        target := first + count - 1;
        if target > beats.count - 1 target = beats.count - 1;

        return beats[target];
    }

    last: s64 = -1;
    for index: 0 .. beats.count - 1
    {
        if beats[index] >= at - tolerance break;
        last = index;
    }
    if last < 0 return at;

    target := last - (count - 1);
    if target < 0 target = 0;

    return beats[target];
}

Timing_Grid_Settings :: struct
{
    beats_per_bar: s32 = 4;
    show_beats:    bool = true;
}