/*
osu.jai -- exporting the tempo curve as osu! timing points.

The curve is one tempo per 93 ms column, and most of those columns repeat the
tempo of the one before. A timing point is only needed where the tempo
actually changes.

The BPM is rounded to a whole number first, and runs are compared on the
rounded values, because those are what the file ends up containing: two
columns reading 149.6 and 150.4 are both "150" once written, and a timing
point between them would only restate the beat length already in force.

Rounding alone is not enough, though. The analysed curve wobbles a BPM or two
either side of a steady tempo, and every one of those wobbles becomes a
"change" once it is rounded -- measured on a 6:50 track, 459 timing points of
which 406 lasted under 250 ms. So a stretch of tempo only becomes a timing
point if it holds for minimum_hold_ms. A transition that ramps, which is what
a tempo change looks like once a two-second analysis window has smoothed it,
collapses to a single point where the new tempo settles.

osu! stores the beat length rather than the tempo -- milliseconds per beat,
so 60000/BPM -- and a timing point line is:

  time,beatLength,meter,sampleSet,sampleIndex,volume,uninherited,effects

'uninherited' is 1 for a red (tempo) line and 0 for a green (slider
velocity) line. Everything written here is a tempo line.

This file uses Tempo_Curve from tempo.jai and release_array from
tempogram.jai, so those have to be loaded first.
*/

#import "Basic";
#import "String";
#import "File";

OSU_METER        :: 4;
OSU_SAMPLE_SET   :: 1;
OSU_SAMPLE_INDEX :: 0;
OSU_VOLUME       :: 100;
OSU_EFFECTS      :: 0;

OSU_BEAT_MS :: 60000.0;

Osu_Settings :: struct
{
    minimum_change_bpm: float64 = 5.0;

    minimum_hold_ms: s64 = 4000;
}

Osu_Tempo_Run :: struct
{
    column:      s64;
    last_column: s64;
    bpm:         s64;
}

median_bpm_between :: (curve: *Tempo_Curve, from: s64, to: s64) -> float64
{
    if from > to return 0.0;

    count := to - from + 1;

    values: [..] float32;
    defer release_array(*values);
    array_resize(*values, count, false);
    for i: 0 .. count - 1 values[i] = curve.bpms[from + i];

    for i: 1 .. count - 1
    {
        value := values[i];
        j := i - 1;
        while j >= 0 && values[j] > value
        {
            values[j + 1] = values[j];
            j -= 1;
        }
        values[j + 1] = value;
    }

    return cast(float64) values[count / 2];
}

osu_tempo_runs :: (curve: *Tempo_Curve, settings: Osu_Settings) -> [..] Osu_Tempo_Run
{
    runs: [..] Osu_Tempo_Run;
    if curve.column_count == 0 return runs;

    tolerance := settings.minimum_change_bpm;

    current := cast(float64) curve.bpms[0];
    start: s64 = 0;
    column: s64 = 1;

    while column < curve.column_count
    {
        if abs(cast(float64) curve.bpms[column] - current) <= tolerance
        {
            column += 1;
            continue;
        }

        away_end := column;
        while away_end < curve.column_count
              && abs(cast(float64) curve.bpms[away_end] - current) > tolerance
              {
            away_end += 1;
        }

        held := tempo_curve_time_ms(curve, away_end - 1) - tempo_curve_time_ms(curve, column);
        if held < cast(float64) settings.minimum_hold_ms
        {
            column = away_end;
            continue;
        }

        previous := median_bpm_between(curve, start, column - 1);
        if previous <= 0.0 previous = current;

        array_add(*runs, Osu_Tempo_Run.{ start, column - 1, osu_round_bpm(previous) });

        current = median_bpm_between(curve, column, away_end - 1);
        if current <= 0.0 current = cast(float64) curve.bpms[column];

        start  = column;
        column = column + 1;
    }

    last := median_bpm_between(curve, start, curve.column_count - 1);
    if last <= 0.0 last = current;

    array_add(*runs, Osu_Tempo_Run.{ start, curve.column_count - 1, osu_round_bpm(last) });

    return runs;
}

Osu_Timing_Point :: struct
{
    time_ms: s64;
    bpm:     s64;
}

osu_file_name :: (path: string) -> string
{
    start := 0;
    for index: 0 .. path.count - 1
    {
        if path[index] == #char "/" || path[index] == #char "\\" start = index + 1;
    }

    return slice(path, start, path.count - start);
}

osu_base_name :: (path: string) -> string
{
    name := osu_file_name(path);

    end := name.count;
    for index: 0 .. name.count - 1
    {
        if name[index] == #char "." end = index;
    }
    if end <= 0 end = name.count;

    return slice(name, 0, end);
}

osu_round_bpm :: (bpm: float64) -> s64
{
    if bpm <= 0.0 return 0;
    return cast(s64) (bpm + 0.5);
}

format_beat_length :: (beat_ms: float64) -> string
{
    text := tprint("%", FormatFloat.{ value = beat_ms, trailing_width = 12, zero_removal = .NO });

    end := text.count;
    while end > 0 && text[end - 1] == #char "0" end -= 1;
    if end > 0 && text[end - 1] == #char "." end -= 1;

    return slice(text, 0, end);
}

collect_osu_timing_points :: (curve: *Tempo_Curve, settings: Osu_Settings,
                              points: *[..] Osu_Timing_Point) -> s64
                              {
    if curve.column_count == 0 return 0;

    runs := osu_tempo_runs(curve, settings);
    defer release_array(*runs);

    if runs.count == 0 return 0;

    settled: s64 = 0;
    skipped: s64 = 0;

    longest: s64 = 0;
    longest_held: float64 = -1.0;

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
        if held < cast(float64) settings.minimum_hold_ms
        {
            skipped += 1; continue;
        }

        array_add(points, Osu_Timing_Point.{ cast(s64) (start + 0.5), runs[index].bpm });
        settled = runs[index].bpm;
    }

    if points.count == 0
    {
        array_add(points, Osu_Timing_Point.{
            cast(s64) (tempo_curve_time_ms(curve, runs[longest].column) + 0.5),
            runs[longest].bpm,
        });
    }

    return skipped;
}

build_osu_text :: (points: [] Osu_Timing_Point, audio_path: string) -> string
{
    builder: String_Builder;
    init_string_builder(*builder);

    file_name := osu_file_name(audio_path);
    title     := osu_base_name(audio_path);

    append(*builder, "osu file format v14\n");

    append(*builder, "\n[General]\n");
    print_to_builder(*builder, "AudioFilename: %\n", file_name);
    append(*builder, "AudioLeadIn: 0\n");
    append(*builder, "PreviewTime: -1\n");
    append(*builder, "Countdown: 0\n");
    append(*builder, "SampleSet: Normal\n");
    append(*builder, "StackLeniency: 0.7\n");
    append(*builder, "Mode: 0\n");
    append(*builder, "LetterboxInBreaks: 0\n");
    append(*builder, "WidescreenStoryboard: 0\n");

    append(*builder, "\n[Editor]\n");
    append(*builder, "DistanceSpacing: 1\n");
    append(*builder, "BeatDivisor: 4\n");
    append(*builder, "GridSize: 4\n");
    append(*builder, "TimelineZoom: 1\n");

    append(*builder, "\n[Metadata]\n");
    print_to_builder(*builder, "Title:%\n", title);
    print_to_builder(*builder, "TitleUnicode:%\n", title);
    append(*builder, "Artist:\n");
    append(*builder, "ArtistUnicode:\n");
    append(*builder, "Creator:BPMAnalyzer\n");
    append(*builder, "Version:\n");
    append(*builder, "Source:\n");
    append(*builder, "Tags:\n");
    append(*builder, "BeatmapID:0\n");
    append(*builder, "BeatmapSetID:-1\n");

    append(*builder, "\n[Difficulty]\n");
    append(*builder, "HPDrainRate:5\n");
    append(*builder, "CircleSize:4\n");
    append(*builder, "OverallDifficulty:5\n");
    append(*builder, "ApproachRate:5\n");
    append(*builder, "SliderMultiplier:1.4\n");
    append(*builder, "SliderTickRate:1\n");

    append(*builder, "\n[Events]\n");
    append(*builder, "//Background and Video events\n");
    append(*builder, "//Break Periods\n");
    append(*builder, "//Storyboard Layer 0 (Background)\n");
    append(*builder, "//Storyboard Layer 1 (Fail)\n");
    append(*builder, "//Storyboard Layer 2 (Pass)\n");
    append(*builder, "//Storyboard Layer 3 (Foreground)\n");
    append(*builder, "//Storyboard Layer 4 (Overlay)\n");
    append(*builder, "//Storyboard Sound Samples\n");

    append(*builder, "\n[TimingPoints]\n");
    for points
    {
        print_to_builder(*builder, "%,%,%,%,%,%,1,%\n",
                         it.time_ms, format_beat_length(OSU_BEAT_MS / cast(float64) it.bpm),
                         OSU_METER, OSU_SAMPLE_SET, OSU_SAMPLE_INDEX, OSU_VOLUME, OSU_EFFECTS);
    }

    append(*builder, "\n[HitObjects]\n");

    return builder_to_string(*builder);
}

write_osu_timing_file :: (curve: *Tempo_Curve, audio_path: string,
                          output_folder: string = "output",
                          settings: Osu_Settings = .{}) -> (bool, string)
                          {
    if !curve.loaded return false, "there is no tempo curve to export yet.";
    if audio_path.count == 0 return false, "there is no audio file name to build the export name from.";

    points: [..] Osu_Timing_Point;
    defer release_array(*points);

    skipped := collect_osu_timing_points(curve, settings, *points);
    if points.count == 0 return false, "the tempo curve has no tempo to export.";

    if !make_directory_if_it_does_not_exist(output_folder)
    {
        return false, tprint("could not create the '%' folder.", output_folder);
    }

    path := tprint("%/%_timing.osu", output_folder, osu_base_name(audio_path));

    text := build_osu_text(points, audio_path);
    defer free(text);

    if !write_entire_file(path, text) return false, tprint("could not write %.", path);

    if skipped > 0
    {
        return true, tprint("wrote % -- % timing points (% stretches under % ms ignored).",
                            path, points.count, skipped, settings.minimum_hold_ms);
    }

    return true, tprint("wrote % -- % timing points.", path, points.count);
}

build_timing_points_text :: (points: [] Timing_Point) -> string
{
    builder: String_Builder;
    init_string_builder(*builder);

    append(*builder, "[TimingPoints]\n");

    for points
    {
        if it.bpm <= 0.0 continue;

        print_to_builder(*builder, "%,%,%,%,%,%,1,%\n",
                         cast(s64) (it.time_ms + 0.5),
                         format_beat_length(OSU_BEAT_MS / it.bpm),
                         OSU_METER, OSU_SAMPLE_SET, OSU_SAMPLE_INDEX, OSU_VOLUME, OSU_EFFECTS);
    }

    return builder_to_string(*builder);
}

write_timing_points_txt :: (points: [] Timing_Point, audio_path: string,
                            output_folder: string = "output") -> (bool, string)
                            {
    if points.count == 0 return false, "there are no timing points to export.";
    if audio_path.count == 0 return false, "there is no audio file name to build the export name from.";

    if !make_directory_if_it_does_not_exist(output_folder)
    {
        return false, tprint("could not create the '%' folder.", output_folder);
    }

    path := timing_points_txt_path(audio_path, output_folder);

    text := build_timing_points_text(points);
    defer free(text);

    if !write_entire_file(path, text) return false, tprint("could not write %.", path);

    return true, tprint("wrote % -- % timing points.", path, points.count);
}

timing_points_txt_path :: (audio_path: string, output_folder: string = "output") -> string
{
    return tprint("%/%_timing.txt", output_folder, osu_base_name(audio_path));
}