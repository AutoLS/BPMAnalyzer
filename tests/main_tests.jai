#import "Basic";
#import "Math";
#import "String";
#load "../src/audio.jai";
#load "../src/preprocess.jai";
#load "../src/onset.jai";
#load "../src/tempogram.jai";
#load "../src/tempo.jai";
#load "../src/octave.jai";
#load "../src/smooth.jai";
#load "../src/osu.jai";
#load "../src/timing.jai";
#load "../src/util.jai";

TRACKS :: 10;

TRACK_NAMES :: string.[ "test1.ogg", "test2.mp3", "test3.ogg", "test4.ogg", "test5.ogg",
                         "test6.mp3", "test7.mp3", "test8.mp3", "test9.mp3", "test10.mp3" ];
TRACK_BPM   :: float64.[ 158.0, 137.0, 250.0, 150.0, 180.0, 174.0, 300.0, 181.0, 177.0, 142.0 ];

CHANGE_START :: s64.[ 0, 0, 0, 0, 0, 2, 3, 3, 3, 9 ];
CHANGE_COUNT :: s64.[ 0, 0, 0, 0, 2, 1, 0, 0, 6, 2 ];

CHANGE_TIME :: float64.[ 154844.0, 166138.0,
                          69312.0,
                         144436.0, 243742.0, 304758.0, 306869.0, 308969.0, 315017.0,
                          92114.0, 129395.0 ];
CHANGE_BPM :: float64.[     170.0,    180.0,
                              174.0,
                             145.0,    177.0,    112.0,    106.0,     49.0,     57.0,
                             103.0,    142.0 ];

MATCH_WINDOW_MS :: 3500.0;

Analyzed :: struct {
    name:     string;
    envelope: Onset_Envelope;
    tgram:    Tempogram;
    curve:    Tempo_Curve;   
}

analyzed: [..] Analyzed;

track_path :: (index: s32) -> string {
    return tprint("E:/Dev/jai-projects/BPMAnalyzer/tests/%", TRACK_NAMES[index]);
}

median_bpm :: (curve: *Tempo_Curve) -> float64 {
    if !curve.loaded || curve.column_count == 0 return 0.0;

    copy: [..] float32;
    defer release_array(*copy);
    array_resize(*copy, curve.column_count, false);
    for 0 .. curve.column_count - 1 copy[it] = curve.bpms[it];

    for i: 1 .. copy.count - 1 {
        value := copy[i];
        j := i - 1;
        while j >= 0 && copy[j] > value { copy[j + 1] = copy[j]; j -= 1; }
        copy[j + 1] = value;
    }

    return cast(float64) copy[copy.count / 2];
}

analyze :: (index: s32) -> bool {
    audio, load_error := load_audio_file(track_path(index));
    if load_error.count > 0 return false;
    defer free_audio_file(*audio);

    processed, pre_error := preprocess_audio(*audio);
    if pre_error.count > 0 return false;
    defer free_preprocessed_audio(*processed);

    envelope, env_error := compute_onset_envelope(*processed);
    if env_error.count > 0 return false;
    entry: Analyzed;
    entry.name = TRACK_NAMES[index];

    entry.envelope = envelope;

    tgram, tg_error := tempogram_from_envelope(*envelope);
    if tg_error.count > 0 return false;
    entry.tgram = tgram;

    curve, curve_error := track_tempo(*entry.tgram);
    if curve_error.count > 0 return false;
    entry.curve = curve;

    array_add(*analyzed, entry);
    return true;
}

Score :: struct {
    tempo_right:   s64;
    changes_right: s64;
    found:         s64;
    expected:      s64;
    extra:         s64;
    error_total:   float64;
    tempo_wrong:   [..] string;   
}

free_score :: (score: *Score) {
    release_array(*score.tempo_wrong);
}

evaluate :: (label: string, octave_settings: Octave_Settings, osu: Osu_Settings, verbose: bool) -> Score {
    score: Score;

    for entry: analyzed {
        index: s32 = -1;
        for track: 0 .. TRACKS - 1 if TRACK_NAMES[track] == entry.name index = cast(s32) track;
        if index < 0 continue;

        fixed, _, oct_error := correct_octave_errors(*entry.curve, *entry.tgram, octave_settings);
        if oct_error.count > 0 continue;
        defer free_tempo_curve(*fixed);

        smoothed, smooth_error := smooth_tempo_curve(*fixed);
        if smooth_error.count > 0 continue;
        defer free_tempo_curve(*smoothed);

        median   := median_bpm(*smoothed);
        expected := TRACK_BPM[index];
        octaves  := log2(median / expected);

        tempo_ok := abs(octaves) < 0.1 && abs(median - expected) <= 5.0;
        if tempo_ok score.tempo_right += 1;
        else array_add(*score.tempo_wrong, tprint("% %/%", entry.name, decimals(median, 0), decimals(expected, 0)));

        points: [..] Osu_Timing_Point;
        defer release_array(*points);
        collect_osu_timing_points(*smoothed, osu, *points);

        reported := points.count - 1;
        first    := CHANGE_START[index];
        wanted   := CHANGE_COUNT[index];

        matched: s64 = 0;
        error_total: float64 = 0.0;

        for expected_index: 0 .. wanted - 1 {
            want_time := CHANGE_TIME[first + expected_index];

            best_error: float64 = 1.0e30;
            found := false;

            for point_index: 1 .. points.count - 1 {
                gap := abs(cast(float64) points[point_index].time_ms - want_time);
                if gap < best_error best_error = gap;
                if gap <= MATCH_WINDOW_MS found = true;
            }

            if found { matched += 1; error_total += best_error; }
        }

        score.expected    += wanted;
        score.found       += matched;
        score.extra       += reported - matched;
        score.error_total += error_total;

        if wanted == 0 {
            if reported == 0 score.changes_right += 1;
        } else if reported == matched {
            score.changes_right += 1;
        }

        if verbose {
            print("  %  expected %  median %  (% octaves)  %\n",
                  entry.name, decimals(expected, 0), decimals(median, 1),
                  decimals(octaves, 3), ifx tempo_ok then "ok" else "TEMPO WRONG");

            print("      % change(s) reported", reported);
            for point_index: 1 .. points.count - 1 {
                print("  (% %)", points[point_index].time_ms, points[point_index].bpm);
            }
            print("   --  wanted %\n", wanted);
        }
    }

    print("  %  tempo %/%  changes %/%  found %/%  extra %  mean % ms\n",
          label, score.tempo_right, TRACKS, score.changes_right, TRACKS,
          score.found, score.expected, score.extra,
          decimals(ifx score.found > 0 then score.error_total / cast(float64) score.found else 0.0, 0));

    if score.tempo_wrong.count > 0 && !verbose {
        print("      wrong:");
        for score.tempo_wrong print("  %", it);
        print("\n");
    }

    return score;
}

main :: () {
    print("\n=== analysing ===\n");
    for track: 0 .. TRACKS - 1 {
        if analyze(cast(s32) track) print("  %  ok\n", TRACK_NAMES[track]);
        else                      print("  %  FAILED\n", TRACK_NAMES[track]);
    }


    print("\n=== as shipped ===\n");
    {
        score := evaluate("shipped", .{}, .{}, true);
        free_score(*score);
    }


    print("\n=== tempo prior weight ===\n");
    for weights: float64.[ 0.0, 0.1, 0.2, 0.3, 0.5, 1.0 ] {
        os: Octave_Settings;
        os.prior.weight = weights;
        score := evaluate("weight", os, .{}, false);
        free_score(*score);
    }

    print("\n=== tempo prior centre (weight 1.0) ===\n");
    for centres: float64.[ 120.0, 140.0, 160.0, 175.0, 190.0 ] {
        os: Octave_Settings;
        os.prior.center_bpm = centres;
        score := evaluate("centre", os, .{}, false);
        free_score(*score);
    }

    print("\n=== hold (with the shipped prior) ===\n");
    for holds: s64.[ 500, 1500, 2500, 3000, 4000, 6000 ] {
        os: Osu_Settings;
        os.minimum_hold_ms = holds;
        score := evaluate("hold", .{}, os, false);
        free_score(*score);
    }

    print("\n=== comb harmonic weighting (full re-analysis each) ===\n");
    for decays: float32.[ 0.0, 0.25, 0.5, 1.0 ] {
        ts: Tempogram_Settings;
        ts.harmonic_decay = decays;

        right: s64 = 0;
        wrong_list: [..] string;
        defer release_array(*wrong_list);

        for track: 0 .. TRACKS - 1 {
            audio, load_error := load_audio_file(track_path(cast(s32) track));
            if load_error.count > 0 continue;
            defer free_audio_file(*audio);

            processed, pre_error := preprocess_audio(*audio);
            if pre_error.count > 0 continue;
            defer free_preprocessed_audio(*processed);

            envelope, env_error := compute_onset_envelope(*processed);
            if env_error.count > 0 continue;
            defer free_onset_envelope(*envelope);

            tg, tg_error := tempogram_from_envelope(*envelope, ts);
            if tg_error.count > 0 continue;
            defer free_tempogram(*tg);

            cv, cv_error := track_tempo(*tg);
            if cv_error.count > 0 continue;
            defer free_tempo_curve(*cv);

            fx, _, oe := correct_octave_errors(*cv, *tg);
            if oe.count > 0 continue;
            defer free_tempo_curve(*fx);

            sm, se := smooth_tempo_curve(*fx);
            if se.count > 0 continue;
            defer free_tempo_curve(*sm);

            m := median_bpm(*sm);
            e := TRACK_BPM[track];
            if abs(log2(m / e)) < 0.1 && abs(m - e) <= 5.0 right += 1;
            else array_add(*wrong_list, tprint("% %/%", TRACK_NAMES[track], decimals(m, 0), decimals(e, 0)));
        }

        print("  decay %  tempo %/%", decimals(decays, 2), right, TRACKS);
        for wrong_list print("  %", it);
        print("\n");
    }

    print("\n=== prior sigma (centre 120, weight 1.0) ===\n");
    for sigmas: float64.[ 1.0, 1.5, 2.0, 3.0 ] {
        os: Octave_Settings;
        os.prior.sigma_octaves = sigmas;
        score := evaluate("sigma", os, .{}, false);
        free_score(*score);
    }
}