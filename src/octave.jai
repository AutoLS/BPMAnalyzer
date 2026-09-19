/*
octave.jai -- stage 5: fixing the octave.

The tempo curve can settle on the wrong member of a tempo's harmonic family:
a track whose beat is 83 BPM also has strong periodicity at 167 and 250, and
which one the tracker picks depends on tiny differences in the map. Nothing
downstream can recover from that, so it is worth fixing here.

The procedure is the one you would use by hand:

  1. take log2 of every BPM in the curve
  2. a real tempo change is a small step in log2; a flip is a step of about
     +-1.0 (an octave), or +-0.585 for a fifth
  3. split the curve at every step big enough to be a candidate flip, giving
     a handful of segments
  4. for each segment, try shifting it by each of the metrical ratios --
     half, third, double, triple -- and score the result two ways:
        how well the shifted curve fits the tempogram, and
        how plausible the tempo is in the first place
  5. keep the shift that scores best, while insisting that neighbouring
     segments still meet each other afterwards

Step 5 is what turns "one side has to be doubled so the two sides match" into
something solvable: the segments are joined by a penalty on the step left at
each boundary, and a small Viterbi over the segments finds the cheapest
combination. With a single segment -- which is the common case, a track that
is simply at the wrong octave throughout -- it degenerates to picking the
best ratio for the whole curve.

The tempo prior in step 4 is the part that actually decides most cases. The
tempogram cannot: 83 and 250 BPM are both genuinely bright when the beat is
at 83, so "which fits the map better" is close to a coin toss. What breaks
the tie is that music is far more often near 120 BPM than near 250.

This file uses release_array and tempo_bin_at from tempogram.jai, so that has
to be loaded first.
*/

#import "Basic";
#import "Math";

Tempo_Prior :: struct
{
    center_bpm:    float64 = 120.0;
    sigma_octaves: float64 = 1.0;

    weight: float64 = 1.0;
}

OCTAVE_RATIOS :: float64.[ 0.25, 1.0 / 3.0, 0.5, 1.0, 2.0, 3.0, 4.0 ];

OCTAVE_RATIO_UNITY :: 3;

Octave_Settings :: struct
{
    minimum_jump_octaves: float64 = 0.4;

    tolerance_octaves: float64 = 0.17;

    continuity_weight: float64 = 0.3;

    prior: Tempo_Prior;

    min_bpm: float64 = 30.0;
    max_bpm: float64 = 300.0;
}

Octave_Correction :: struct
{
    segment_count:    s64;
    shifted_segments: s64;
    metrical_jumps:   s64;

    fit_before:   float64;
    fit_after:    float64;
    score_before: float64;
    score_after:  float64;
}

log2 :: (value: float64) -> float64
{
    return log(value) / log(2.0);
}

prior_cost :: (bpm: float64, prior: Tempo_Prior) -> float64
{
    if prior.weight <= 0.0 || prior.sigma_octaves <= 0.0 return 0.0;

    distance := log2(bpm / prior.center_bpm) / prior.sigma_octaves;
    return prior.weight * 0.5 * distance * distance;
}

is_metrical_step :: (from_bpm: float64, to_bpm: float64, tolerance: float64) -> bool
{
    if from_bpm <= 0.0 || to_bpm <= 0.0 return false;

    step := log2(to_bpm / from_bpm);
    ratios := float64.[ 0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.5, 2.0, 3.0, 4.0 ];

    for ratios
    {
        if abs(step - log2(it)) <= tolerance return true;
    }
    return false;
}

segment_fit :: (curve: *Tempo_Curve, tempogram: *Tempogram, first: s64, last: s64, ratio: float64) -> float64
{
    total: float64 = 0;
    for column: first .. last
    {
        bpm := cast(float64) curve.bpms[column] * ratio;
        total += cast(float64) tempogram_strength_at_bpm(tempogram, column, bpm);
    }

    return total / cast(float64) (last - first + 1);
}

correct_octave_errors :: (curve: *Tempo_Curve, tempogram: *Tempogram, settings: Octave_Settings = .{})
    -> (Tempo_Curve, Octave_Correction, string)
    {

    result:  Tempo_Curve;
    summary: Octave_Correction;

    if !curve.loaded return result, summary, "correct_octave_errors: there is no tempo curve to correct.";
    if !tempogram.loaded return result, summary, "correct_octave_errors: the tempogram is needed to score the shifts.";
    if curve.column_count != tempogram.column_count
    {
        return result, summary, "correct_octave_errors: the curve and the tempogram have different lengths.";
    }

    columns := curve.column_count;
    ratios  := OCTAVE_RATIOS.count;

    log_bpms: [..] float64;
    array_resize(*log_bpms, columns, false);
    defer release_array(*log_bpms);

    for column: 0 .. columns - 1
    {
        bpm := cast(float64) curve.bpms[column];
        log_bpms[column] = ifx bpm > 0.0 then log2(bpm) else 0.0;
    }

    segment_of: [..] s64;
    segment_first: [..] s64;
    segment_last: [..] s64;
    array_resize(*segment_of, columns, false);
    array_resize(*segment_first, columns, false);
    array_resize(*segment_last, columns, false);
    defer release_array(*segment_of);
    defer release_array(*segment_first);
    defer release_array(*segment_last);

    segments: s64 = 1;
    segment_first[0] = 0;
    segment_of[0] = 0;

    for column: 1 .. columns - 1
    {
        if abs(log_bpms[column] - log_bpms[column - 1]) >= settings.minimum_jump_octaves
        {
            segment_last[segments - 1] = column - 1;
            segment_first[segments] = column;
            segments += 1;

            if is_metrical_step(cast(float64) curve.bpms[column - 1], cast(float64) curve.bpms[column], settings.tolerance_octaves)
            {
                summary.metrical_jumps += 1;
            }
        }
        segment_of[column] = segments - 1;
    }
    segment_last[segments - 1] = columns - 1;
    summary.segment_count = segments;

    fit: [..] float64;
    array_resize(*fit, segments * ratios, false);
    defer release_array(*fit);

    prior: [..] float64;
    array_resize(*prior, segments * ratios, false);
    defer release_array(*prior);

    for segment: 0 .. segments - 1
    {
        first := segment_first[segment];
        last  := segment_last[segment];

        middle := (first + last) / 2;
        base_bpm := cast(float64) curve.bpms[middle];

        for r: 0 .. ratios - 1
        {
            shifted := base_bpm * OCTAVE_RATIOS[r];

            if shifted < settings.min_bpm || shifted > settings.max_bpm
            {
                fit[segment * ratios + r] = -1.0;
                prior[segment * ratios + r] = 0.0;
                continue;
            }

            fit[segment * ratios + r] = segment_fit(curve, tempogram, first, last, OCTAVE_RATIOS[r]);
            prior[segment * ratios + r] = prior_cost(shifted, settings.prior);
        }
    }

    current:  [..] float64;
    previous: [..] float64;
    came_from: [..] s32;
    array_resize(*current, ratios, false);
    array_resize(*previous, ratios, false);
    array_resize(*came_from, segments * ratios, false);
    defer release_array(*current);
    defer release_array(*previous);
    defer release_array(*came_from);

    for r: 0 .. ratios - 1
    {
        previous[r] = ifx fit[r] < 0.0 then 1.0e300 else (prior[r] - fit[r]);
    }

    for segment: 1 .. segments - 1
    {
        before := segment_last[segment - 1];
        after  := segment_first[segment];

        for r: 0 .. ratios - 1
        {
            if fit[segment * ratios + r] < 0.0
            {
                current[r] = 1.0e300;
                came_from[segment * ratios + r] = 0;
                continue;
            }

            best_cost: float64 = 1.0e300;
            best_from: s64 = 0;

            for previous_ratio: 0 .. ratios - 1
            {
                if fit[(segment - 1) * ratios + previous_ratio] < 0.0 continue;

                before_bpm := cast(float64) curve.bpms[before] * OCTAVE_RATIOS[previous_ratio];
                after_bpm  := cast(float64) curve.bpms[after]  * OCTAVE_RATIOS[r];

                step := log2(after_bpm / before_bpm);
                penalty := settings.continuity_weight * step * step;

                candidate := previous[previous_ratio] + penalty;
                if candidate < best_cost
                {
                    best_cost = candidate;
                    best_from = previous_ratio;
                }
            }

            current[r] = best_cost + prior[segment * ratios + r] - fit[segment * ratios + r];
            came_from[segment * ratios + r] = cast(s32) best_from;
        }

        swap := previous;
        previous = current;
        current = swap;
    }

    chosen: [..] s64;
    array_resize(*chosen, segments, false);
    defer release_array(*chosen);

    state: s64 = 0;
    best_final: float64 = 1.0e300;
    for r: 0 .. ratios - 1
    {
        if previous[r] < best_final
        {
            best_final = previous[r];
            state = r;
        }
    }

    segment := segments - 1;
    while true
    {
        chosen[segment] = state;
        if segment == 0 break;
        state = came_from[segment * ratios + state];
        segment -= 1;
    }

    result.loaded       = true;
    result.column_count = columns;
    result.cost         = curve.cost;
    result.first_column_frame  = curve.first_column_frame;
    result.column_hop_frames   = curve.column_hop_frames;
    result.envelope_frame_rate = curve.envelope_frame_rate;
    result.settings            = curve.settings;

    array_resize(*result.bpms, columns, false);
    array_resize(*result.bins, columns, false);
    array_resize(*result.strengths, columns, false);

    before_total: float64 = 0;
    after_total:  float64 = 0;

    for column: 0 .. columns - 1
    {
        ratio := OCTAVE_RATIOS[chosen[segment_of[column]]];
        bpm := cast(float64) curve.bpms[column] * ratio;

        result.bpms[column] = cast(float32) bpm;
        result.bins[column] = cast(s32) (tempo_bin_at(tempogram.settings, bpm) + 0.5);

        if result.bins[column] < 0 result.bins[column] = 0;
        if result.bins[column] > tempogram.tempo_bins - 1 result.bins[column] = tempogram.tempo_bins - 1;

        result.strengths[column] = tempogram_strength_at_bpm(tempogram, column, bpm);

        before_total += cast(float64) curve.strengths[column];
        after_total  += cast(float64) result.strengths[column];
    }

    for segment_index: 0 .. segments - 1
    {
        if chosen[segment_index] != OCTAVE_RATIO_UNITY
        {
            summary.shifted_segments += 1;
        }
    }

    summary.fit_before = before_total / cast(float64) columns;
    summary.fit_after  = after_total / cast(float64) columns;

    before_prior: float64 = 0;
    after_prior:  float64 = 0;
    for column: 0 .. columns - 1
    {
        before_prior += prior_cost(cast(float64) curve.bpms[column], settings.prior);
        after_prior  += prior_cost(cast(float64) result.bpms[column], settings.prior);
    }

    summary.score_before = summary.fit_before - before_prior / cast(float64) columns;
    summary.score_after  = summary.fit_after  - after_prior  / cast(float64) columns;

    return result, summary, "";
}