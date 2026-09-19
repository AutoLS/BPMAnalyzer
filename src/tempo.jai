/*
tempo.jai -- stage 4: the tempo curve.

The tempogram says how much each tempo explains the music at each moment, but
reading it column by column gives a jumpy answer: the brightest cell hops
between a tempo and its multiples, and a single loud bar can move it
anywhere. What we want is one tempo per moment that is allowed to drift but
not to teleport.

That is a shortest-path problem. Every (column, tempo bin) is a node; the
path runs through one node per column, left to right, and Viterbi finds the
cheapest one.

  cost of standing in a cell   = -log(tempogram value), so bright is cheap
  cost of moving between cells  = a penalty on the size of the jump, measured
                                  in bins

Because the tempo grid is log-spaced, distance in bins *is* distance in
log-tempo, so 60->120 costs exactly what 120->240 costs: both are one octave,
which is 72 bins. Nothing special has to be done to get that; it falls out of
the grid.

The penalty shape matters. Squared (the default) makes a 4% move cost a
hundred times more than a 0.4% move, so the tracker happily follows a real
drift of a fraction of a percent per column but will not hop to another
ridge. Linear only makes it cost ten times more.

This file uses release_array from tempogram.jai, so that has to be loaded
first.
*/

#import "Basic";
#import "Math";

Transition_Shape :: enum
{
    LINEAR;
    QUADRATIC;
}

Tempo_Track_Settings :: struct
{
    observation_floor: float32 = 1.0e-3;

    smoothing: float64 = 0.25;

    transition_shape: Transition_Shape = .QUADRATIC;

    max_jump_bins: s32 = 24;
}

Tempo_Curve :: struct
{
    loaded:       bool;
    bpms:         [..] float32;
    bins:         [..] s32;
    strengths:    [..] float32;
    column_count: s64;
    cost:         float64;

    first_column_frame:  s64;
    column_hop_frames:   s32;
    envelope_frame_rate: float64;

    settings: Tempo_Track_Settings;
}

free_tempo_curve :: (curve: *Tempo_Curve)
{
    if curve.bpms.data != null array_reset(*curve.bpms);
    if curve.bins.data != null array_reset(*curve.bins);
    if curve.strengths.data != null array_reset(*curve.strengths);
    curve.column_count = 0;
    curve.loaded = false;
}

tempo_curve_time :: (curve: *Tempo_Curve, column: s64) -> float64
{
    frames := curve.first_column_frame + column * cast(s64) curve.column_hop_frames;
    return cast(float64) frames / curve.envelope_frame_rate;
}

tempo_curve_time_ms :: (curve: *Tempo_Curve, column: s64) -> float64
{
    return tempo_curve_time(curve, column) * 1000.0;
}

tempo_curve_column_at_time_ms :: (curve: *Tempo_Curve, milliseconds: float64) -> s64
{
    if !curve.loaded return 0;

    seconds := milliseconds / 1000.0;
    frames := seconds * curve.envelope_frame_rate;
    column := cast(s64) ((frames - cast(float64) curve.first_column_frame) / cast(float64) curve.column_hop_frames + 0.5);

    if column < 0 column = 0;
    if column > curve.column_count - 1 column = curve.column_count - 1;
    return column;
}

tempo_at_time_ms :: (curve: *Tempo_Curve, milliseconds: float64) -> float64
{
    if !curve.loaded return 0.0;
    return cast(float64) curve.bpms[tempo_curve_column_at_time_ms(curve, milliseconds)];
}

tempo_at_envelope_frame :: (curve: *Tempo_Curve, frame: s64) -> float64
{
    if !curve.loaded || curve.column_count < 1 return 0.0;

    offset := cast(float64) (frame - curve.first_column_frame) / cast(float64) curve.column_hop_frames;
    column := cast(s64) (offset + 0.5);

    if column < 0 column = 0;
    if column > curve.column_count - 1 column = curve.column_count - 1;

    return cast(float64) curve.bpms[column];
}

transition_cost :: (distance: s64, settings: Tempo_Track_Settings) -> float64
{
    if distance <= 0 return 0.0;

    step := cast(float64) distance;
    if settings.transition_shape == .QUADRATIC return settings.smoothing * step * step;
    return settings.smoothing * step;
}

track_tempo :: (tempogram: *Tempogram, settings: Tempo_Track_Settings = .{}) -> (Tempo_Curve, string)
{
    result: Tempo_Curve;

    if !tempogram.loaded return result, "track_tempo: there is no tempogram to track.";
    if tempogram.column_count < 1 return result, "track_tempo: the tempogram has no columns.";
    if tempogram.tempo_bins < 1 return result, "track_tempo: the tempogram has no tempo bins.";

    bins    := cast(s64) tempogram.tempo_bins;
    columns := tempogram.column_count;

    costs: [..] float32;
    array_resize(*costs, columns * bins, false);
    defer release_array(*costs);

    floor := cast(float64) settings.observation_floor;
    if floor <= 0.0 floor = 1.0e-9;

    for i: 0 .. columns * bins - 1
    {
        value := cast(float64) tempogram.values[i];
        if value < floor value = floor;
        costs[i] = cast(float32) (-log(value));
    }

    max_jump := cast(s64) settings.max_jump_bins;
    if max_jump < 0 max_jump = 0;
    if max_jump > bins - 1 max_jump = bins - 1;

    current:  [..] float64;
    previous: [..] float64;
    array_resize(*current, bins, false);
    array_resize(*previous, bins, false);
    defer release_array(*current);
    defer release_array(*previous);

    came_from: [..] s32;
    array_resize(*came_from, columns * bins, false);
    defer release_array(*came_from);

    for bin: 0 .. bins - 1 previous[bin] = cast(float64) costs[bin];

    for column: 1 .. columns - 1
    {
        row := column * bins;

        for bin: 0 .. bins - 1
        {
            from := bin - max_jump;
            if from < 0 from = 0;

            to := bin + max_jump;
            if to > bins - 1 to = bins - 1;

            best_cost: float64 = 1.0e300;
            best_from: s64 = from;

            for candidate: from .. to
            {
                distance := candidate - bin;
                if distance < 0 distance = -distance;

                total := previous[candidate] + transition_cost(distance, settings);
                if total < best_cost
                {
                    best_cost = total;
                    best_from = candidate;
                }
            }

            current[bin] = best_cost + cast(float64) costs[row + bin];
            came_from[row + bin] = cast(s32) best_from;
        }

        swap := previous;
        previous = current;
        current = swap;
    }

    state: s64 = 0;
    best_final: float64 = 1.0e300;
    for bin: 0 .. bins - 1
    {
        if previous[bin] < best_final
        {
            best_final = previous[bin];
            state = bin;
        }
    }

    array_resize(*result.bpms, columns, false);
    array_resize(*result.bins, columns, false);
    array_resize(*result.strengths, columns, false);

    column := columns - 1;
    while true
    {
        result.bins[column]      = cast(s32) state;
        result.bpms[column]      = tempogram.bpms[state];
        result.strengths[column] = tempogram.values[column * bins + state];

        if column == 0 break;
        state = came_from[column * bins + state];
        column -= 1;
    }

    result.loaded       = true;
    result.column_count = columns;
    result.cost         = best_final;

    result.first_column_frame  = tempogram.first_column_frame;
    result.column_hop_frames   = tempogram.column_hop_frames;
    result.envelope_frame_rate = tempogram.envelope_frame_rate;
    result.settings            = settings;

    return result, "";
}

tempo_curve_max_step :: (curve: *Tempo_Curve) -> float64
{
    if !curve.loaded || curve.column_count < 2 return 0.0;

    worst: float64 = 0;
    for column: 1 .. curve.column_count - 1
    {
        step := abs(cast(float64) curve.bpms[column] - cast(float64) curve.bpms[column - 1]);
        if step > worst worst = step;
    }
    return worst;
}

tempo_curve_statistics :: (curve: *Tempo_Curve) -> (mean_bpm: float64, min_bpm: float64, max_bpm: float64)
{
    if !curve.loaded || curve.column_count < 1 return 0.0, 0.0, 0.0;

    total: float64 = 0;
    low:  float64 = 1.0e300;
    high: float64 = -1.0e300;

    for column: 0 .. curve.column_count - 1
    {
        value := cast(float64) curve.bpms[column];
        total += value;
        if value < low low = value;
        if value > high high = value;
    }

    return total / cast(float64) curve.column_count, low, high;
}