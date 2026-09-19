/*
report.jai -- the last stage: check the answer, and say what it is.

Everything up to here has produced a tempo curve and a beat grid. This
checks them for the two failure modes that are worth catching automatically,
and then writes out what was found.

  1. values outside a plausible range -- a tempo of 12 or 900 BPM is not a
     tempo, it is an artefact, and it should not reach the report
  2. jumps between neighbouring columns -- a real tempo does not move 20% in
     93 milliseconds, but a tracker can, unless the tempogram actually
     supports the move

Nothing here tries to be clever about fixing the curve. Out-of-range values
are held at the last good tempo, because that is the least surprising thing
to do with them, and everything else is counted and reported rather than
silently smoothed away.
*/

#import "Basic";
#import "Math";
#import "File";

Validation_Settings :: struct
{
    min_bpm: float64 = 40.0;
    max_bpm: float64 = 300.0;

    max_jump_ratio: float64 = 1.2;

    supported_fraction: float32 = 0.5;
}

Tempo_Validation :: struct
{
    columns: s64;

    out_of_range:   s64;
    jumps:          s64;
    unsupported_jumps: s64;

    median_bpm: float64;
    mean_bpm:   float64;
    min_bpm:    float64;
    max_bpm:    float64;

    worst_jump_column: s64;
    worst_jump_ratio:  float64;
}

tempo_curve_median_bpm :: (curve: *Tempo_Curve) -> float64
{
    if !curve.loaded || curve.column_count < 1 return 0.0;

    values: [..] float32;
    array_resize(*values, curve.column_count, false);
    defer release_array(*values);
    for 0 .. curve.column_count - 1 values[it] = curve.bpms[it];

    gap := curve.column_count / 2;
    while gap > 0
    {
        for i: gap .. curve.column_count - 1
        {
            value := values[i];
            j := i;
            while j >= gap && values[j - gap] > value
            {
                values[j] = values[j - gap];
                j -= gap;
            }
            values[j] = value;
        }
        gap /= 2;
    }

    middle := curve.column_count / 2;
    if curve.column_count % 2 == 1 return cast(float64) values[middle];
    return (cast(float64) values[middle - 1] + cast(float64) values[middle]) * 0.5;
}

validate_tempo_curve :: (curve: *Tempo_Curve, tempogram: *Tempogram, settings: Validation_Settings = .{})
    -> (Tempo_Curve, Tempo_Validation, string)
    {

    checked: Tempo_Curve;
    report:  Tempo_Validation;

    if !curve.loaded return checked, report, "validate_tempo_curve: there is no tempo curve to check.";
    if curve.column_count < 1 return checked, report, "validate_tempo_curve: the curve is empty.";

    count := curve.column_count;

    checked.loaded       = true;
    checked.column_count = count;
    checked.cost         = curve.cost;
    checked.first_column_frame  = curve.first_column_frame;
    checked.column_hop_frames   = curve.column_hop_frames;
    checked.envelope_frame_rate = curve.envelope_frame_rate;
    checked.settings            = curve.settings;

    array_resize(*checked.bpms, count, false);
    array_resize(*checked.bins, count, false);
    array_resize(*checked.strengths, count, false);

    report.columns = count;
    report.worst_jump_ratio = 1.0;

    last_good: float32 = 120.0;

    for column: 0 .. count - 1
    {
        value := curve.bpms[column];

        if cast(float64) value < settings.min_bpm || cast(float64) value > settings.max_bpm
        {
            report.out_of_range += 1;
            value = last_good;
        }
        else
        {
            last_good = value;
        }

        checked.bpms[column]      = value;
        checked.bins[column]      = curve.bins[column];
        checked.strengths[column] = curve.strengths[column];
    }

    for column: 1 .. count - 1
    {
        before := cast(float64) checked.bpms[column - 1];
        after  := cast(float64) checked.bpms[column];
        if before <= 0.0 || after <= 0.0 continue;

        ratio := ifx after > before then after / before else before / after;

        if ratio > report.worst_jump_ratio
        {
            report.worst_jump_ratio  = ratio;
            report.worst_jump_column = column;
        }

        if ratio <= settings.max_jump_ratio continue;
        report.jumps += 1;

        supported := false;
        if tempogram.loaded && column < tempogram.column_count
        {
            strength := tempogram_strength_at_bpm(tempogram, column, after);

            peak: float32 = 0;
            row := column * cast(s64) tempogram.tempo_bins;
            for bin: 0 .. cast(s64) tempogram.tempo_bins - 1
            {
                if tempogram.values[row + bin] > peak peak = tempogram.values[row + bin];
            }

            if peak > 0.0 && strength >= settings.supported_fraction * peak supported = true;
        }

        if !supported report.unsupported_jumps += 1;
    }

    total: float64 = 0;
    low:  float64 = 1.0e300;
    high: float64 = -1.0e300;

    for column: 0 .. count - 1
    {
        value := cast(float64) checked.bpms[column];
        total += value;
        if value < low low = value;
        if value > high high = value;
    }

    report.mean_bpm   = total / cast(float64) count;
    report.min_bpm    = low;
    report.max_bpm    = high;
    report.median_bpm = tempo_curve_median_bpm(*checked);

    return checked, report, "";
}

write_tempo_curve_csv :: (curve: *Tempo_Curve, path: string) -> bool
{
    if !curve.loaded return false;

    builder: String_Builder;
    init_string_builder(*builder);

    append(*builder, "time_ms,bpm,strength\n");
    for column: 0 .. curve.column_count - 1
    {
        print_to_builder(*builder, "%,%,%\n",
                         cast(s64) tempo_curve_time_ms(curve, column),
                         curve.bpms[column],
                         curve.strengths[column]);
    }

    text := builder_to_string(*builder);
    defer free(text);

    return write_entire_file(path, text);
}

write_beats_csv :: (beats: *Beat_Grid, downbeats: *Downbeat_Track, path: string) -> bool
{
    if !beats.loaded return false;

    builder: String_Builder;
    init_string_builder(*builder);

    append(*builder, "time_ms,bpm");
    if downbeats.loaded append(*builder, ",position_in_bar");
    append(*builder, "\n");

    for index: 0 .. beats.count - 1
    {
        print_to_builder(*builder, "%,%", cast(s64) beats.times_ms[index], beats.bpms[index]);
        if downbeats.loaded print_to_builder(*builder, ",%", downbeats.positions[index]);
        append(*builder, "\n");
    }

    text := builder_to_string(*builder);
    defer free(text);

    return write_entire_file(path, text);
}

whole_bpm :: (bpm: float64) -> s64
{
    if bpm <= 0.0 return 0;
    return cast(s64) (bpm + 0.5);
}

tempo_summary :: (curve: *Tempo_Curve, validation: *Tempo_Validation, beats: *Beat_Grid, frame_rate: float64) -> string
{
    if !curve.loaded return "no tempo curve";

    interval := beat_grid_mean_interval_ms(beats, frame_rate);

    return tprint("% BPM median (% to %), % columns; % beats, one every % ms; % out-of-range values, % suspicious jumps",
                  whole_bpm(validation.median_bpm),
                  whole_bpm(validation.min_bpm),
                  whole_bpm(validation.max_bpm),
                  validation.columns,
                  beats.count,
                  cast(s64) interval,
                  validation.out_of_range,
                  validation.unsupported_jumps);
}