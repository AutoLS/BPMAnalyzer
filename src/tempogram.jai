/*
tempogram.jai -- stage 3: the tempo energy map.

  TG[tempo_bin, time_column]

A full time x tempo map: for every moment in the track, how much does each
candidate tempo explain the onset envelope there.

The comb, and why this is fast
------------------------------
The obvious way to build this is to make a comb kernel for each candidate
tempo -- impulses at the beat period, with weaker ones on the subdivisions --
and slide it along the envelope, taking a dot product at every frame.

Filtering the envelope with a comb whose impulses sit at positions p_i with
weights w_i gives

    y(t) = sum_i w_i * e(t - p_i)

and the energy of that output over a window is

    E = sum_t y(t)^2 = sum_{i,j} w_i w_j * ACF(|p_i - p_j|)

i.e. the envelope's autocorrelation, sampled at the distances between the
comb's own impulses. The comb's phase cancels out completely, and all that is
left is the ACF at multiples of the beat period. So instead of one pass per
tempo, we compute one autocorrelation per time window and then read it at the
handful of lags each comb needs. That is the "autocorrelation per frame"
route, and it is what this file does; compute_tempogram_direct() in the test
harness computes the same numbers the slow way and agrees.

Two details fall out of the derivation:

  * The lag-0 term (sum_i w_i^2 * ACF(0)) is left out. It is a constant
    offset that grows with the number of comb impulses, so including it would
    just favour fast tempi.
  * The remaining weights are scaled to sum to 1, otherwise a fast tempo with
    (window/period)^2 lag terms would beat a slow one on term count alone.

Autocorrelation lags are divided by how many samples actually overlapped:
in a 6 second window a lag of 86 frames only overlaps 172 of 258 samples, and
without the correction the tempogram leans towards fast tempi.

This file uses PI_F64 from preprocess.jai and the FFT from onset.jai, so both
have to be loaded first.
*/

#import "Basic";
#import "Math";

Tempogram_Settings :: struct
{
    min_bpm:    float64 = 30.0;
    max_bpm:    float64 = 300.0;
    tempo_bins: s32 = 240;

    window_seconds: float64 = 2.0;
    column_hop_frames: s32 = 4;

    subdivision_weight: float32 = 0.0;
    half_note_weight:   float32 = 0.0;

    harmonic_decay: float32 = 0.0;

    comb_harmonics: s32 = 4;

    compensate_acf_overlap: bool = false;

    octave_weight: float32 = 0.0;
    triple_weight: float32 = 0.0;

    log_compression: bool = true;
    log_gamma:       float32 = 100.0;

    normalize_columns: bool = true;
}

Comb_Tap :: struct
{
    lag:    s32;
    weight: float32;
}

Tempogram :: struct
{
    loaded:       bool;
    values:       [..] float32;
    tempo_bins:   s32;
    column_count: s64;

    bpms:    [..] float32;
    min_bpm: float64;
    max_bpm: float64;

    first_column_frame: s64;
    column_hop_frames:  s32;
    envelope_frame_rate: float64;

    column_peaks: [..] float32;

    settings: Tempogram_Settings;
}

free_tempogram :: (tempogram: *Tempogram)
{
    if tempogram.values.data != null array_reset(*tempogram.values);
    if tempogram.bpms.data != null array_reset(*tempogram.bpms);
    if tempogram.column_peaks.data != null array_reset(*tempogram.column_peaks);
    tempogram.loaded = false;
    tempogram.column_count = 0;
}

tempo_bpm_at :: (settings: Tempogram_Settings, bin: s64) -> float64
{
    if settings.tempo_bins < 2 return settings.min_bpm;

    span := log(settings.max_bpm / settings.min_bpm);
    return settings.min_bpm * exp(span * cast(float64) bin / cast(float64) (settings.tempo_bins - 1));
}

tempo_bin_at :: (settings: Tempogram_Settings, bpm: float64) -> float64
{
    if settings.tempo_bins < 2 return 0.0;
    if bpm <= settings.min_bpm return 0.0;
    if bpm >= settings.max_bpm return cast(float64) (settings.tempo_bins - 1);

    span := log(settings.max_bpm / settings.min_bpm);
    return log(bpm / settings.min_bpm) / span * cast(float64) (settings.tempo_bins - 1);
}

sample_column :: (tempogram: *Tempogram, column: s64, fractional_bin: float64) -> float32
{
    if fractional_bin < 0.0 return 0.0;
    if fractional_bin > cast(float64) (tempogram.tempo_bins - 1) return 0.0;

    low := cast(s64) fractional_bin;
    if low >= cast(s64) tempogram.tempo_bins - 1 return tempogram.values[column * cast(s64) tempogram.tempo_bins + low];

    fraction := cast(float32) (fractional_bin - cast(float64) low);
    base := column * cast(s64) tempogram.tempo_bins + low;

    return tempogram.values[base] * (1.0 - fraction) + tempogram.values[base + 1] * fraction;
}

release_array :: (values: *[..] $T)
{
    if values.data != null array_reset(values);
}

build_comb_profile :: (period: float64, window_frames: s64, max_lag: s64, settings: Tempogram_Settings) -> [..] Comb_Tap
{
    result: [..] Comb_Tap;
    if period < 1.0 || window_frames < 2 return result;

    positions: [..] float64;
    weights:   [..] float32;
    defer release_array(*positions);
    defer release_array(*weights);

    k: s64 = 0;
    while true
    {
        position := cast(float64) k * period;
        if position >= cast(float64) window_frames break;
        array_add(*positions, position);
        array_add(*weights, 1.0);
        k += 1;
    }

    if settings.half_note_weight > 0.0
    {
        k = 0;
        while true
        {
            position := cast(float64) (2 * k) * period;
            if position >= cast(float64) window_frames break;
            array_add(*positions, position);
            array_add(*weights, settings.half_note_weight);
            k += 1;
        }
    }

    if settings.subdivision_weight > 0.0
    {
        k = 0;
        while true
        {
            position := (cast(float64) k + 0.5) * period;
            if position >= cast(float64) window_frames break;
            array_add(*positions, position);
            array_add(*weights, settings.subdivision_weight);
            k += 1;
        }
    }

    count := positions.count;
    if count < 2 return result;

    lags: [..] float32;
    array_resize(*lags, max_lag + 1, false);
    defer release_array(*lags);
    for 0 .. max_lag lags[it] = 0;

    harmonic_limit := period * cast(float64) settings.comb_harmonics;

    for i: 0 .. count - 1
    {
        for j: i + 1 .. count - 1
        {
            lag := abs(positions[j] - positions[i]);
            if lag > harmonic_limit continue;

            low := cast(s64) lag;
            f := lag - cast(float64) low;

            f2 := f * f;
            f3 := f2 * f;

            before := -0.5 * f + f2 - 0.5 * f3;
            at     := 1.0 - 2.5 * f2 + 1.5 * f3;
            after  := 0.5 * f + 2.0 * f2 - 1.5 * f3;
            beyond := -0.5 * f2 + 0.5 * f3;

            pair_weight := 2.0 * weights[i] * weights[j];

            if settings.harmonic_decay > 0.0
            {
                k := lag / period;
                if k < 1.0 k = 1.0;

                pair_weight *= cast(float32) pow(k, -cast(float64) settings.harmonic_decay);
            }

            if low - 1 >= 1 && low - 1 <= max_lag lags[low - 1] += pair_weight * cast(float32) before;
            if low     >= 1 && low     <= max_lag lags[low]     += pair_weight * cast(float32) at;
            if low + 1 >= 1 && low + 1 <= max_lag lags[low + 1] += pair_weight * cast(float32) after;
            if low + 2 >= 1 && low + 2 <= max_lag lags[low + 2] += pair_weight * cast(float32) beyond;
        }
    }

    total: float32 = 0;
    for lags total += it;
    if total <= 0.0 return result;

    scale := 1.0 / total;
    for lag: 1 .. max_lag
    {
        if lags[lag] != 0.0 array_add(*result, Comb_Tap.{cast(s32) lag, lags[lag] * scale});
    }

    return result;
}

round_up_to_power_of_two :: (value: s64) -> s64
{
    result: s64 = 1;
    while result < value result *= 2;
    return result;
}

make_taper :: (size: s32) -> [..] float32
{
    result: [..] float32;
    if size < 1 return result;

    array_resize(*result, size, false);
    if size == 1
    {
        result[0] = 1.0; return result;
    }

    for i: 0 .. cast(s64) size - 1
    {
        result[i] = cast(float32) (0.5 - 0.5 * cos(2.0 * PI_F64 * cast(float64) i / cast(float64) size));
    }

    return result;
}

compute_window_acf :: (plan: *FFT_Plan, values: [] float32, acf: [] float32,
                       real: [] float32, imaginary: [] float32, compensate_overlap: bool)
                       {
    size := cast(s64) plan.size;
    count := values.count;

    for i: 0 .. size - 1
    {
        value: float32 = 0;
        if i < count value = values[i];
        real[i] = value;
        imaginary[i] = 0;
    }

    fft_forward(plan, real, imaginary);

    for k: 0 .. size - 1
    {
        r := real[k];
        i := imaginary[k];
        real[k] = r * r + i * i;
        imaginary[k] = 0;
    }

    fft_forward(plan, real, imaginary);

    inverse_size := 1.0 / cast(float64) size;
    for lag: 0 .. acf.count - 1
    {
        value := cast(float64) real[lag] * inverse_size;

        if compensate_overlap
        {
            overlap := count - lag;
            if overlap < 1 overlap = 1;
            value /= cast(float64) overlap;
        }

        acf[lag] = cast(float32) value;
    }
}

compute_tempogram :: (envelope_values: [] float32, frame_rate: float64, settings: Tempogram_Settings = .{}) -> (Tempogram, string)
{
    result: Tempogram;

    if envelope_values.count < 2 return result, "compute_tempogram: the envelope is too short.";
    if frame_rate <= 0.0 return result, "compute_tempogram: the envelope's frame rate is zero.";
    if settings.tempo_bins < 2 return result, "compute_tempogram: need at least two tempo bins.";
    if settings.min_bpm <= 0.0 || settings.max_bpm <= settings.min_bpm
    {
        return result, "compute_tempogram: the tempo range is empty.";
    }
    if settings.column_hop_frames < 1 return result, "compute_tempogram: the column hop must be positive.";
    if settings.comb_harmonics < 1 return result, "compute_tempogram: need at least one comb harmonic.";

    window_frames := cast(s64) (settings.window_seconds * frame_rate + 0.5);
    if window_frames < 2 window_frames = 2;
    if window_frames > envelope_values.count window_frames = envelope_values.count;

    max_lag := cast(s64) ceil(60.0 * frame_rate / settings.min_bpm) + 1;
    if max_lag > window_frames - 1 max_lag = window_frames - 1;
    if max_lag < 1 return result, "compute_tempogram: the window is shorter than one beat of the slowest tempo.";

    hop := cast(s64) settings.column_hop_frames;
    column_count := ifx envelope_values.count <= window_frames then 1
                    else (envelope_values.count - window_frames) / hop + 1;

    result.min_bpm = settings.min_bpm;
    result.max_bpm = settings.max_bpm;
    result.tempo_bins = settings.tempo_bins;
    result.column_count = column_count;
    result.first_column_frame = window_frames / 2;
    result.column_hop_frames = settings.column_hop_frames;
    result.envelope_frame_rate = frame_rate;
    result.settings = settings;

    array_resize(*result.bpms, settings.tempo_bins, false);
    for bin: 0 .. cast(s64) settings.tempo_bins - 1
    {
        result.bpms[bin] = cast(float32) tempo_bpm_at(settings, bin);
    }

    profiles: [..] Comb_Tap;
    offsets:  [..] s64;
    array_resize(*offsets, cast(s64) settings.tempo_bins + 1, false);
    defer release_array(*profiles);
    defer release_array(*offsets);

    for bin: 0 .. cast(s64) settings.tempo_bins - 1
    {
        offsets[bin] = profiles.count;

        bpm    := tempo_bpm_at(settings, bin);
        period := 60.0 * frame_rate / bpm;

        taps := build_comb_profile(period, window_frames, max_lag, settings);

        for taps array_add(*profiles, it);
    }
    offsets[settings.tempo_bins] = profiles.count;

    transform_size := round_up_to_power_of_two(window_frames + max_lag);
    plan := fft_plan_create(cast(s32) transform_size);
    defer fft_plan_destroy(*plan);
    if plan.size == 0 return .{}, "compute_tempogram: could not build an FFT of the required size.";

    real:      [..] float32;
    imaginary: [..] float32;
    array_resize(*real, transform_size, false);
    array_resize(*imaginary, transform_size, false);
    defer free_float_array(*real);
    defer free_float_array(*imaginary);

    window_values: [..] float32;
    array_resize(*window_values, window_frames, false);
    defer free_float_array(*window_values);

    acf: [..] float32;
    array_resize(*acf, max_lag + 1, false);
    defer free_float_array(*acf);

    taper := make_taper(cast(s32) window_frames);
    defer free_float_array(*taper);

    array_resize(*result.values, column_count * cast(s64) settings.tempo_bins, false);
    array_resize(*result.column_peaks, column_count, false);

    for column: 0 .. column_count - 1
    {
        start := column * hop;

        total: float64 = 0;
        for i: 0 .. window_frames - 1 total += cast(float64) envelope_values[start + i];
        mean := total / cast(float64) window_frames;

        for i: 0 .. window_frames - 1
        {
            window_values[i] = cast(float32) (cast(float64) envelope_values[start + i] - mean) * taper[i];
        }

        compute_window_acf(*plan, window_values, acf, real, imaginary, settings.compensate_acf_overlap);

        row := column * cast(s64) settings.tempo_bins;
        for bin: 0 .. cast(s64) settings.tempo_bins - 1
        {
            score: float32 = 0;

            from := offsets[bin];
            to   := offsets[bin + 1];
            for index: from .. to - 1
            {
                tap := profiles[index];
                score += tap.weight * acf[tap.lag];
            }

            result.values[row + bin] = score;
        }
    }

    rectify_tempogram(*result);
    apply_harmonic_summation(*result);
    apply_log_compression(*result);
    apply_column_normalization(*result);

    result.loaded = true;
    return result, "";
}

tempogram_from_envelope :: (envelope: *Onset_Envelope, settings: Tempogram_Settings = .{}) -> (Tempogram, string)
{
    if !envelope.loaded return .{}, "tempogram_from_envelope: there is no onset envelope to analyse.";

    tempogram, error := compute_tempogram(envelope.values, envelope.frame_rate, settings);
    return tempogram, error;
}

rectify_tempogram :: (tempogram: *Tempogram)
{
    for 0 .. tempogram.values.count - 1
    {
        if tempogram.values[it] < 0.0 tempogram.values[it] = 0;
    }
}

apply_harmonic_summation :: (tempogram: *Tempogram)
{
    settings := tempogram.settings;
    if settings.octave_weight <= 0.0 && settings.triple_weight <= 0.0 return;

    bins := cast(s64) tempogram.tempo_bins;

    column: [..] float32;
    array_resize(*column, bins, false);
    defer free_float_array(*column);

    for index: 0 .. tempogram.column_count - 1
    {
        row := index * bins;
        for bin: 0 .. bins - 1 column[bin] = tempogram.values[row + bin];

        for bin: 0 .. bins - 1
        {
            bpm := cast(float64) tempogram.bpms[bin];

            sum := cast(float32) column[bin];
            if settings.octave_weight > 0.0 sum += settings.octave_weight * sample_column(tempogram, index, tempo_bin_at(settings, bpm * 2.0));
            if settings.triple_weight > 0.0 sum += settings.triple_weight * sample_column(tempogram, index, tempo_bin_at(settings, bpm * 3.0));

            tempogram.values[row + bin] = sum;
        }
    }
}

apply_log_compression :: (tempogram: *Tempogram)
{
    if !tempogram.settings.log_compression return;

    peak := signal_peak(tempogram.values);
    if peak <= 0.0 return;

    gamma := cast(float64) tempogram.settings.log_gamma / cast(float64) peak;

    for 0 .. tempogram.values.count - 1
    {
        value := cast(float64) tempogram.values[it];
        if value <= 0.0
        {
            tempogram.values[it] = 0; continue;
        }
        tempogram.values[it] = cast(float32) log(1.0 + gamma * value);
    }
}

apply_column_normalization :: (tempogram: *Tempogram)
{
    bins := cast(s64) tempogram.tempo_bins;

    for column: 0 .. tempogram.column_count - 1
    {
        row := column * bins;

        peak: float32 = 0;
        for bin: 0 .. bins - 1
        {
            value := tempogram.values[row + bin];
            if value > peak peak = value;
        }

        tempogram.column_peaks[column] = peak;

        if !tempogram.settings.normalize_columns continue;
        if peak <= 0.0 continue;

        scale := 1.0 / peak;
        for bin: 0 .. bins - 1 tempogram.values[row + bin] *= scale;
    }
}

tempogram_column_time :: (tempogram: *Tempogram, column: s64) -> float64
{
    frames := tempogram.first_column_frame + column * cast(s64) tempogram.column_hop_frames;
    return cast(float64) frames / tempogram.envelope_frame_rate;
}

tempogram_column_time_ms :: (tempogram: *Tempogram, column: s64) -> float64
{
    return tempogram_column_time(tempogram, column) * 1000.0;
}

tempogram_best_tempo :: (tempogram: *Tempogram, column: s64) -> (bpm: float64, bin: s64, value: float32)
{
    if !tempogram.loaded || column < 0 || column >= tempogram.column_count return 0.0, 0, 0.0;

    bins := cast(s64) tempogram.tempo_bins;
    row  := column * bins;

    best_bin: s64 = 0;
    best: float32 = -1.0;
    for bin: 0 .. bins - 1
    {
        value := tempogram.values[row + bin];
        if value > best
        {
            best = value;
            best_bin = bin;
        }
    }

    return cast(float64) tempogram.bpms[best_bin], best_bin, best;
}

tempogram_strength_at_bpm :: (tempogram: *Tempogram, column: s64, bpm: float64) -> float32
{
    return sample_column(tempogram, column, tempo_bin_at(tempogram.settings, bpm));
}

tempogram_best_tempo_series :: (tempogram: *Tempogram) -> [..] float32
{
    result: [..] float32;
    if !tempogram.loaded return result;

    array_resize(*result, tempogram.column_count, false);
    for column: 0 .. tempogram.column_count - 1
    {
        bpm, bin, value := tempogram_best_tempo(tempogram, column);
        result[column] = cast(float32) bpm;
    }

    return result;
}

tempogram_dominant_tempo :: (tempogram: *Tempogram) -> (bpm: float64, value: float32)
{
    if !tempogram.loaded return 0.0, 0.0;

    bins := cast(s64) tempogram.tempo_bins;

    totals: [..] float64;
    array_resize(*totals, bins, false);
    defer release_array(*totals);
    for 0 .. bins - 1 totals[it] = 0;

    for column: 0 .. tempogram.column_count - 1
    {
        row := column * bins;
        for bin: 0 .. bins - 1 totals[bin] += cast(float64) tempogram.values[row + bin];
    }

    best_bin: s64 = 0;
    best: float64 = -1.0;
    for bin: 0 .. bins - 1
    {
        if totals[bin] > best
        {
            best = totals[bin]; best_bin = bin;
        }
    }

    return cast(float64) tempogram.bpms[best_bin], cast(float32) best;
}