/*
smooth.jai -- stage 6: smoothing the tempo curve.

The Viterbi path is already fairly steady, but it is built from one
autocorrelation per 93 ms window, and those windows overlap, so what is left
is a low-level jitter plus the occasional column where the tracker briefly
locked onto a subdivision. Smoothing removes the second without flattening
real tempo movement.

Median first, and that is the important one: a median can delete a spike
outright, where a moving average would only dilute it into its neighbours.
A short moving average afterwards is optional and only takes the edge off.

The warning that comes with this is not over-smoothing. A wide median will
happily flatten an accelerando, so the kernel has to stay narrower than the
fastest real tempo change expected.

The Kalman alternative, for comparison
--------------------------------------
Model log2(BPM) as a random walk observed through noise:

    x[t] = x[t-1] + w,   w ~ N(0, Q)      how fast the tempo may drift
    z[t] = x[t] + v,     v ~ N(0, R)      how noisy the windowed estimates are

Running the filter forward gives the causal estimate, and the RTS pass
backwards gives the smoothed one -- a proper 1-D smoother, and the exact
optimum for this model. What it adds over a median is that it uses every
observation to estimate every state, weighting each by how much it can be
trusted, so it follows a smooth ramp better while leaving isolated spikes
alone.

Both are here; the median and moving average are the default because they
have no parameters to get wrong.
*/

#import "Basic";
#import "Math";

Tempo_Smoothing :: enum
{
    MEDIAN_AND_MOVING_AVERAGE;
    KALMAN;
}

Smooth_Settings :: struct
{
    method: Tempo_Smoothing = .MEDIAN_AND_MOVING_AVERAGE;

    median_frames: s32 = 5;

    moving_average_frames: s32 = 3;

    drift_octaves_per_second: float64 = 0.02;

    measurement_octaves: float64 = 0.02;
}

smoothing_log2 :: (value: float64) -> float64
{
    return log(value) / log(2.0);
}

moving_average :: (values: [] float64, half_window: s64) -> [..] float64
{
    result: [..] float64;
    if values.count == 0 return result;

    array_resize(*result, values.count, false);

    prefix: [..] float64;
    array_resize(*prefix, values.count + 1, false);
    defer release_array(*prefix);

    prefix[0] = 0;
    for i: 0 .. values.count - 1 prefix[i + 1] = prefix[i] + values[i];

    for i: 0 .. values.count - 1
    {
        from := i - half_window;
        if from < 0 from = 0;

        to := i + half_window + 1;
        if to > values.count to = values.count;

        result[i] = (prefix[to] - prefix[from]) / cast(float64) (to - from);
    }

    return result;
}

kalman_smooth_log_bpms :: (observed: [] float64, column_seconds: float64,
                           drift_octaves_per_second: float64, measurement_octaves: float64) -> [..] float64
                           {
    result: [..] float64;
    count := observed.count;
    if count == 0 return result;

    array_resize(*result, count, false);
    if count == 1
    {
        result[0] = observed[0];
        return result;
    }

    drift := drift_octaves_per_second * column_seconds;
    process_noise := drift * drift;
    measurement_noise := measurement_octaves * measurement_octaves;
    if measurement_noise <= 0.0 measurement_noise = 1.0e-12;

    filtered:   [..] float64;
    filtered_variance: [..] float64;
    predicted:  [..] float64;
    predicted_variance: [..] float64;
    array_resize(*filtered, count, false);
    array_resize(*filtered_variance, count, false);
    array_resize(*predicted, count, false);
    array_resize(*predicted_variance, count, false);
    defer release_array(*filtered);
    defer release_array(*filtered_variance);
    defer release_array(*predicted);
    defer release_array(*predicted_variance);

    estimate := observed[0];
    variance := measurement_noise;

    for i: 0 .. count - 1
    {
        if i > 0
        {
            estimate = filtered[i - 1];
            variance = filtered_variance[i - 1] + process_noise;
        }

        predicted[i] = estimate;
        predicted_variance[i] = variance;

        gain := variance / (variance + measurement_noise);
        filtered[i] = estimate + gain * (observed[i] - estimate);
        filtered_variance[i] = (1.0 - gain) * variance;
    }

    result[count - 1] = filtered[count - 1];

    i := count - 2;
    while true
    {
        gain := filtered_variance[i] / predicted_variance[i + 1];
        result[i] = filtered[i] + gain * (result[i + 1] - predicted[i + 1]);

        if i == 0 break;
        i -= 1;
    }

    return result;
}

smooth_tempo_curve :: (curve: *Tempo_Curve, settings: Smooth_Settings = .{}) -> (Tempo_Curve, string)
{
    result: Tempo_Curve;

    if !curve.loaded return result, "smooth_tempo_curve: there is no tempo curve to smooth.";
    if curve.column_count < 1 return result, "smooth_tempo_curve: the tempo curve is empty.";

    count := curve.column_count;

    result.loaded       = true;
    result.column_count = count;
    result.cost         = curve.cost;
    result.first_column_frame  = curve.first_column_frame;
    result.column_hop_frames   = curve.column_hop_frames;
    result.envelope_frame_rate = curve.envelope_frame_rate;
    result.settings            = curve.settings;

    array_resize(*result.bpms, count, false);
    array_resize(*result.bins, count, false);
    array_resize(*result.strengths, count, false);

    for column: 0 .. count - 1
    {
        result.bpms[column]      = curve.bpms[column];
        result.bins[column]      = curve.bins[column];
        result.strengths[column] = curve.strengths[column];
    }

    if settings.method == .KALMAN
    {
        column_seconds := cast(float64) curve.column_hop_frames / curve.envelope_frame_rate;

        observed: [..] float64;
        array_resize(*observed, count, false);
        defer release_array(*observed);
        for column: 0 .. count - 1
        {
            bpm := cast(float64) curve.bpms[column];
            observed[column] = ifx bpm > 0.0 then smoothing_log2(bpm) else 0.0;
        }

        smoothed := kalman_smooth_log_bpms(observed, column_seconds,
                                           settings.drift_octaves_per_second,
                                           settings.measurement_octaves);
        defer release_array(*smoothed);

        for column: 0 .. count - 1
        {
            result.bpms[column] = cast(float32) exp(smoothed[column] * log(2.0));
        }

        return result, "";
    }

    if settings.median_frames >= 3
    {
        radius := cast(s64) settings.median_frames / 2;

        medians := median_filter(result.bpms, radius);
        for column: 0 .. count - 1 result.bpms[column] = medians[column];
        release_array(*medians);
    }

    if settings.moving_average_frames >= 3
    {
        half_window := cast(s64) settings.moving_average_frames / 2;

        values: [..] float64;
        array_resize(*values, count, false);
        defer release_array(*values);
        for column: 0 .. count - 1
        {
            bpm := cast(float64) result.bpms[column];
            values[column] = ifx bpm > 0.0 then smoothing_log2(bpm) else 0.0;
        }

        averaged := moving_average(values, half_window);
        defer release_array(*averaged);

        for column: 0 .. count - 1
        {
            result.bpms[column] = cast(float32) exp(averaged[column] * log(2.0));
        }
    }

    return result, "";
}

tempo_curve_roughness :: (curve: *Tempo_Curve) -> float64
{
    if !curve.loaded || curve.column_count < 2 return 0.0;

    total: float64 = 0;
    for column: 1 .. curve.column_count - 1
    {
        total += abs(cast(float64) curve.bpms[column] - cast(float64) curve.bpms[column - 1]);
    }

    return total / cast(float64) (curve.column_count - 1);
}