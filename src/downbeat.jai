/*
downbeat.jai -- stage 8: bars and downbeats.

The beat grid says where the beats are, but not which of them starts the bar.
In most music that is the one the kick drum lands on, so the question becomes:
which phase of the bar puts the strongest low-frequency onsets on position 1?

  1. a second onset envelope, restricted to the kick drum's band
  2. assume a meter -- 4/4 and 3/4 cover most of it
  3. run a DP over the beats assigning each one a position within the bar
  4. penalise assignments that put a quiet beat on the downbeat

The DP here has a strictly cyclic transition -- position p is always followed
by p+1 modulo the bar length -- so there is really only the starting phase to
decide, and the DP is just an orderly way of trying all of them at once. It
is written as a DP anyway because that is where a meter change or a dropped
beat would be handled if they turn out to matter.

This file uses beat_likelihoods from beats.jai, so that has to be loaded
first.
*/

#import "Basic";
#import "Math";

DEFAULT_METERS :: s32.[ 4, 3 ];

Downbeat_Settings :: struct
{
    beats_per_bar: s32 = 4;

    bass_max_hz: float32 = 150.0;

    downbeat_weight: float64 = 1.0;

    contrast_weight: float64 = 0.5;

    tolerance_frames: s32 = 2;
}

Downbeat_Track :: struct
{
    loaded:       bool;
    beats_per_bar: s32;

    positions:     [..] s32;
    strengths:     [..] float32;

    downbeats_ms:  [..] float64;
    downbeat_beats: [..] s64;

    mean_downbeat_strength:  float64;
    total_downbeat_strength: float64;
}

free_downbeat_track :: (track: *Downbeat_Track)
{
    if track.positions.data != null array_reset(*track.positions);
    if track.strengths.data != null array_reset(*track.strengths);
    if track.downbeats_ms.data != null array_reset(*track.downbeats_ms);
    if track.downbeat_beats.data != null array_reset(*track.downbeat_beats);
    track.loaded = false;
}

create_kick_onset_envelope :: (audio: *Preprocessed_Audio, settings: Downbeat_Settings = .{}) -> (Onset_Envelope, string)
{
    if !audio.loaded return .{}, "create_kick_onset_envelope: there is no preprocessed audio to analyse.";

    onset_settings: Onset_Settings;
    onset_settings.max_frequency = settings.bass_max_hz;

    envelope, error := onset_envelope_from_samples(audio.samples, audio.sample_rate, onset_settings);
    return envelope, error;
}

track_downbeats_with_meter :: (beats: *Beat_Grid, strength: [] float32, settings: Downbeat_Settings)
    -> (Downbeat_Track, string)
    {

    track: Downbeat_Track;

    bars := cast(s64) settings.beats_per_bar;
    if bars < 2 return track, "track_downbeats_with_meter: a bar needs at least two beats.";

    count := beats.count;
    if count < bars return track, "track_downbeats_with_meter: fewer beats than one bar.";

    current:  [..] float64;
    previous: [..] float64;
    came_from: [..] s32;
    array_resize(*current, bars, false);
    array_resize(*previous, bars, false);
    array_resize(*came_from, count * bars, false);
    defer release_array(*current);
    defer release_array(*previous);
    defer release_array(*came_from);

    emit :: (beat: s64, position: s64, strength: [] float32, settings: Downbeat_Settings) -> float64
    {
        value := cast(float64) strength[beat];
        if position == 0 return settings.downbeat_weight * value;
        return -settings.contrast_weight * value;
    }

    for position: 0 .. bars - 1
    {
        previous[position] = emit(0, position, strength, settings);
        came_from[position] = -1;
    }

    for beat: 1 .. count - 1
    {
        row := beat * bars;

        for position: 0 .. bars - 1
        {
            from := position - 1;
            if from < 0 from = bars - 1;

            current[position] = previous[from] + emit(beat, position, strength, settings);
            came_from[row + position] = cast(s32) from;
        }

        swap := previous;
        previous = current;
        current = swap;
    }

    state: s64 = 0;
    best_score: float64 = -1.0e300;
    for position: 0 .. bars - 1
    {
        if previous[position] > best_score
        {
            best_score = previous[position];
            state = position;
        }
    }

    array_resize(*track.positions, count, false);

    beat := count - 1;
    while true
    {
        track.positions[beat] = cast(s32) (state + 1);

        if beat == 0 break;
        state = came_from[beat * bars + state];
        beat -= 1;
    }

    downbeat_total: float64 = 0;
    for index: 0 .. count - 1
    {
        if track.positions[index] != 1 continue;

        array_add(*track.downbeats_ms, beats.times_ms[index]);
        array_add(*track.downbeat_beats, index);
        downbeat_total += cast(float64) strength[index];
    }

    if track.downbeat_beats.count == 0
    {
        return track, "track_downbeats_with_meter: no downbeats were assigned.";
    }

    track.loaded       = true;
    track.beats_per_bar = settings.beats_per_bar;
    track.total_downbeat_strength = downbeat_total;
    track.mean_downbeat_strength  = downbeat_total / cast(float64) track.downbeat_beats.count;

    return track, "";
}

track_downbeats :: (beats: *Beat_Grid, kicks: *Onset_Envelope, settings: Downbeat_Settings = .{})
    -> (Downbeat_Track, string)
    {

    track: Downbeat_Track;

    if !beats.loaded return track, "track_downbeats: there is no beat grid.";
    if !kicks.loaded return track, "track_downbeats: there is no kick onset envelope.";
    if beats.count < 2 return track, "track_downbeats: too few beats.";

    likelihood := beat_likelihoods(kicks.values, cast(s64) settings.tolerance_frames);
    defer free_float_array(*likelihood);

    strength: [..] float32;
    array_resize(*strength, beats.count, false);
    defer release_array(*strength);

    for index: 0 .. beats.count - 1
    {
        frame := beats.frames[index];
        if frame < 0 frame = 0;
        if frame >= likelihood.count frame = likelihood.count - 1;

        strength[index] = likelihood[frame];
    }

    result, error := track_downbeats_with_meter(beats, strength, settings);
    if error.count > 0
    {
        free_downbeat_track(*result);
        return .{}, error;
    }

    for 0 .. beats.count - 1 array_add(*result.strengths, strength[it]);

    return result, "";
}

estimate_meter :: (beats: *Beat_Grid, kicks: *Onset_Envelope, candidates: [] s32, settings: Downbeat_Settings = .{})
    -> (s32, float64, [..] float64)
    {

    scores: [..] float64;
    best_score: float64 = -1.0e300;
    best_meter: s32 = 0;

    if !beats.loaded || !kicks.loaded || candidates.count == 0 return 0, 0.0, scores;

    likelihood := beat_likelihoods(kicks.values, cast(s64) settings.tolerance_frames);
    defer free_float_array(*likelihood);

    strength: [..] float32;
    array_resize(*strength, beats.count, false);
    defer release_array(*strength);

    for index: 0 .. beats.count - 1
    {
        frame := beats.frames[index];
        if frame < 0 frame = 0;
        if frame >= likelihood.count frame = likelihood.count - 1;
        strength[index] = likelihood[frame];
    }

    for meter: candidates
    {
        if meter < 2 continue;
        if cast(s64) meter > beats.count continue;

        attempt := settings;
        attempt.beats_per_bar = meter;

        track, error := track_downbeats_with_meter(beats, strength, attempt);
        defer free_downbeat_track(*track);

        if error.count > 0
        {
            array_add(*scores, -1.0e300);
            continue;
        }

        array_add(*scores, track.mean_downbeat_strength);

        if track.mean_downbeat_strength > best_score
        {
            best_score = track.mean_downbeat_strength;
            best_meter = meter;
        }
    }

    return best_meter, best_score, scores;
}