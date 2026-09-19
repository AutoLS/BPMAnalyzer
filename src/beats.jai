/*
beats.jai -- stage 7: placing beats using the tempo curve.

The tempo curve says how fast the music is at every moment, but not where the
beats actually fall. This finds them.

A beat sequence is good when two things are true at once, and they pull
against each other:

  the beats land on onsets          -- so they are worth hearing
  the gaps between them match the   -- so they are evenly spaced at the
  tempo curve                          tempo the music is actually at

That is a shortest-path problem again. A state is a beat at frame q together
with the tempo implied by the gap that arrived there, which is what lets the
transition penalise a jump in tempo as well as a mismatch against the curve.

  reward   being at q            = the onset envelope there
  penalty  the arriving gap      = how far its tempo is from the curve at q
  penalty  changing tempo        = how far that tempo is from the previous gap's

The tempo-change penalty is what permits a gradual accelerando while
forbidding a leap, and because the mismatch is measured against the *curve*
rather than a fixed period, the tracker follows rubato without being told
about it in advance.

The gap is quantised onto a small log-spaced tempo grid, so the state space
stays at (frames x tempi) instead of (frames x frames).
*/

#import "Basic";
#import "Math";

Beat_Settings :: struct
{
    min_bpm:    float64 = 40.0;
    max_bpm:    float64 = 300.0;
    tempo_bins: s32 = 48;

    onset_weight: float64 = 1.0;

    mismatch_weight: float64 = 6.0;

    change_weight: float64 = 1.0;

    tolerance_frames: s32 = 2;

    onset_lead_ms: float64 = 25.0;
}

Beat_Grid :: struct
{
    loaded: bool;

    frames:   [..] s64;
    times_ms: [..] float64;
    bpms:     [..] float32;

    count: s64;
    score: float64;
}

free_beat_grid :: (grid: *Beat_Grid)
{
    if grid.frames.data != null array_reset(*grid.frames);
    if grid.times_ms.data != null array_reset(*grid.times_ms);
    if grid.bpms.data != null array_reset(*grid.bpms);
    grid.count = 0;
    grid.loaded = false;
}

beat_grid_mean_interval_ms :: (grid: *Beat_Grid, frame_rate: float64) -> float64
{
    if !grid.loaded || grid.count < 2 return 0.0;
    return (grid.times_ms[grid.count - 1] - grid.times_ms[0]) / cast(float64) (grid.count - 1);
}

beat_likelihoods :: (envelope_values: [] float32, tolerance: s64) -> [..] float32
{
    result: [..] float32;
    if envelope_values.count == 0 return result;

    array_resize(*result, envelope_values.count, false);
    if tolerance < 0 tolerance = 0;

    weight_total: float64 = 0;
    for offset: -tolerance .. tolerance weight_total += cast(float64) (tolerance + 1 - abs(offset));

    for frame: 0 .. envelope_values.count - 1
    {
        total: float64 = 0;

        for offset: -tolerance .. tolerance
        {
            at := frame + offset;
            if at < 0 || at >= envelope_values.count continue;

            weight := cast(float64) (tolerance + 1 - abs(offset));
            total += cast(float64) envelope_values[at] * weight;
        }

        result[frame] = cast(float32) (total / weight_total);
    }

    return result;
}

track_beats :: (envelope: *Onset_Envelope, curve: *Tempo_Curve, settings: Beat_Settings = .{})
    -> (Beat_Grid, string)
    {

    result: Beat_Grid;

    if !envelope.loaded return result, "track_beats: there is no onset envelope to place beats on.";
    if !curve.loaded return result, "track_beats: a tempo curve is needed to space the beats.";
    if envelope.frame_count < 2 return result, "track_beats: the envelope is too short.";
    if settings.tempo_bins < 2 return result, "track_beats: need at least two tempo bins.";
    if settings.min_bpm <= 0.0 || settings.max_bpm <= settings.min_bpm
    {
        return result, "track_beats: the tempo range is empty.";
    }

    frames    := envelope.frame_count;
    frame_rate := envelope.frame_rate;
    bins      := cast(s64) settings.tempo_bins;

    states := bins + 1;
    start_state := bins;

    tempo:     [..] float64;
    log_tempo: [..] float64;
    gap:       [..] s64;
    array_resize(*tempo, bins, false);
    array_resize(*log_tempo, bins, false);
    array_resize(*gap, bins, false);
    defer release_array(*tempo);
    defer release_array(*log_tempo);
    defer release_array(*gap);

    span := log(settings.max_bpm / settings.min_bpm);
    for bin: 0 .. bins - 1
    {
        value := settings.min_bpm * exp(span * cast(float64) bin / cast(float64) (bins - 1));
        tempo[bin] = value;
        log_tempo[bin] = log(value) / log(2.0);

        frames_for_gap := cast(s64) (60.0 * frame_rate / value + 0.5);
        if frames_for_gap < 1 frames_for_gap = 1;
        gap[bin] = frames_for_gap;
    }

    change_penalty: [..] float64;
    array_resize(*change_penalty, states * bins, false);
    defer release_array(*change_penalty);

    for to: 0 .. bins - 1
    {
        for from: 0 .. bins - 1
        {
            difference := log_tempo[to] - log_tempo[from];
            change_penalty[to * states + from] = settings.change_weight * difference * difference;
        }
        change_penalty[to * states + start_state] = 0.0;
    }

    likelihood := beat_likelihoods(envelope.values, cast(s64) settings.tolerance_frames);
    defer release_array(*likelihood);

    curve_log_tempo: [..] float64;
    array_resize(*curve_log_tempo, frames, false);
    defer release_array(*curve_log_tempo);

    for frame: 0 .. frames - 1
    {
        bpm := tempo_at_envelope_frame(curve, envelope.first_frame + frame);
        curve_log_tempo[frame] = ifx bpm > 0.0 then log(bpm) / log(2.0) else 0.0;
    }

    best: [..] float64;
    came_from: [..] s32;
    array_resize(*best, frames * states, false);
    array_resize(*came_from, frames * states, false);
    defer release_array(*best);
    defer release_array(*came_from);

    for i: 0 .. frames * states - 1 best[i] = -1.0e300;

    for frame: 0 .. frames - 1
    {
        reward := settings.onset_weight * cast(float64) likelihood[frame];
        row := frame * states;

        for bin: 0 .. bins - 1
        {
            previous := frame - gap[bin];

            if previous < 0
            {
                best[row + bin] = reward;
                came_from[row + bin] = -1;
                continue;
            }

            previous_row := previous * states;

            best_previous: float64 = -1.0e300;
            best_state: s64 = -1;

            for state: 0 .. states - 1
            {
                score := best[previous_row + state];
                if score <= -1.0e299 continue;

                candidate := score - change_penalty[bin * states + state];
                if candidate > best_previous
                {
                    best_previous = candidate;
                    best_state = state;
                }
            }

            if best_state < 0 continue;

            mismatch := log_tempo[bin] - curve_log_tempo[frame];
            best[row + bin] = best_previous + reward - settings.mismatch_weight * mismatch * mismatch;
            came_from[row + bin] = cast(s32) best_state;
        }
    }

    last_frame: s64 = -1;
    last_state: s64 = -1;
    best_score: float64 = -1.0e300;

    for frame: 0 .. frames - 1
    {
        row := frame * states;
        for bin: 0 .. bins - 1
        {
            if best[row + bin] > best_score
            {
                best_score = best[row + bin];
                last_frame = frame;
                last_state = bin;
            }
        }
    }

    if last_frame < 0 return result, "track_beats: no beat path could be built.";

    reversed: [..] s64;
    array_reserve(*reversed, 1024);
    defer release_array(*reversed);

    frame := last_frame;
    state := last_state;
    while frame >= 0
    {
        array_add(*reversed, frame);

        if state == start_state break;

        parent := came_from[frame * states + state];
        if parent < 0 break;

        frame -= gap[state];
        state = parent;

        if frame < 0 break;
    }

    count := reversed.count;
    array_resize(*result.frames, count, false);
    array_resize(*result.times_ms, count, false);
    array_resize(*result.bpms, count, false);

    for i: 0 .. count - 1
    {
        beat := reversed[count - 1 - i];
        result.frames[i] = beat;
        result.times_ms[i] = frame_time(envelope, beat) * 1000.0 + settings.onset_lead_ms;
    }

    for i: 0 .. count - 1
    {
        if i + 1 < count
        {
            interval := cast(float64) (result.frames[i + 1] - result.frames[i]);
            result.bpms[i] = cast(float32) (60.0 * frame_rate / interval);
        }
        else
        {
            result.bpms[i] = result.bpms[i - 1];
        }
    }

    result.loaded = true;
    result.count  = count;
    result.score  = best_score;

    return result, "";
}

beat_grid_agreement :: (grid: *Beat_Grid, envelope: *Onset_Envelope) -> float64
{
    if !grid.loaded || grid.count < 1 || !envelope.loaded || envelope.frame_count < 1 return 0.0;

    envelope_mean: float64 = 0;
    for 0 .. envelope.frame_count - 1 envelope_mean += cast(float64) envelope.values[it];
    envelope_mean /= cast(float64) envelope.frame_count;
    if envelope_mean <= 0.0 return 0.0;

    on_beat: float64 = 0;
    for beat: 0 .. grid.count - 1
    {
        frame := grid.frames[beat];
        if frame < 0 || frame >= envelope.frame_count continue;
        on_beat += cast(float64) envelope.values[frame];
    }
    on_beat /= cast(float64) grid.count;

    return on_beat / envelope_mean;
}

beat_grid_errors_ms :: (grid: *Beat_Grid, expected_ms: [] float64, tolerance_ms: float64)
    -> (s64, float64, float64)
    {

    if !grid.loaded || grid.count < 1 || expected_ms.count < 1 return 0, 0.0, 0.0;

    matched: s64 = 0;
    total: float64 = 0;
    worst: float64 = 0;

    for beat: 0 .. grid.count - 1
    {
        best := 1.0e300;
        for expected: expected_ms
        {
            distance := abs(grid.times_ms[beat] - expected);
            if distance < best best = distance;
        }

        total += best;
        if best > worst worst = best;
        if best <= tolerance_ms matched += 1;
    }

    return matched, worst, total / cast(float64) grid.count;
}