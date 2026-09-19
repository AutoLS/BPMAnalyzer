/*
waveform.jai -- a peak envelope of the track, for drawing.

The samples themselves are no use for drawing: a six minute track is eight
million of them and a window is twelve hundred pixels wide, so most of them
can never be seen. What a drawing needs is the loudest positive and the
loudest negative value in each slice of time, and that is what this keeps --
one min/max pair per few milliseconds, built once when the file is loaded.

Drawing then walks the window's pixel columns and takes the extremes of the
handful of pairs behind each one, which is a few thousand comparisons a frame
rather than eight million.

This file uses Plot_RGBA and plot_quad from plot.jai, so that has to be
loaded first.
*/

#import "Basic";
#import "Math";

WAVEFORM_BUCKET_SAMPLES :: 64;

Waveform :: struct
{
    loaded: bool;

    minimum: [..] float32;
    maximum: [..] float32;

    bucket_samples: s64;
    sample_rate:    u32;
    frame_count:    s64;
    duration:       float64;
}

build_waveform :: (audio: *Preprocessed_Audio) -> Waveform
{
    result: Waveform;
    if !audio.loaded || audio.frame_count < 1 return result;

    bucket := cast(s64) WAVEFORM_BUCKET_SAMPLES;
    if bucket < 1 bucket = 1;

    count := (audio.frame_count + bucket - 1) / bucket;
    array_resize(*result.minimum, count, false);
    array_resize(*result.maximum, count, false);

    for index: 0 .. count - 1
    {
        from := index * bucket;
        to   := from + bucket;
        if to > audio.frame_count to = audio.frame_count;

        lowest:  float32 = 0.0;
        highest: float32 = 0.0;

        for i: from .. to - 1
        {
            value := audio.samples[i];
            if value < lowest  lowest  = value;
            if value > highest highest = value;
        }

        result.minimum[index] = lowest;
        result.maximum[index] = highest;
    }

    result.bucket_samples = bucket;
    result.sample_rate    = audio.sample_rate;
    result.frame_count    = audio.frame_count;
    result.duration       = audio.duration;
    result.loaded         = true;

    return result;
}

free_waveform :: (waveform: *Waveform)
{
    if waveform.minimum.data != null array_reset(*waveform.minimum);
    if waveform.maximum.data != null array_reset(*waveform.maximum);

    waveform.loaded = false;
}

waveform_bucket_at_ms :: (waveform: *Waveform, milliseconds: float64) -> s64
{
    index := cast(s64) (milliseconds / 1000.0 * cast(float64) waveform.sample_rate
                        / cast(float64) waveform.bucket_samples);

    count := waveform.minimum.count;
    if index < 0 index = 0;
    if index > count - 1 index = count - 1;
    return index;
}

draw_waveform :: (waveform: *Waveform, x0: float, y0: float, width: float, height: float,
                  view_start_ms: float64, view_end_ms: float64, colour: Plot_RGBA) -> float32
                  {
    if !waveform.loaded || width < 1.0 || height < 1.0 return 0.0;

    span := view_end_ms - view_start_ms;
    if span <= 0.0 return 0.0;

    columns := cast(s64) width;
    if columns < 1 return 0.0;

    peak: float32 = 0.0;

    first_bucket := waveform_bucket_at_ms(waveform, view_start_ms);
    last_bucket  := waveform_bucket_at_ms(waveform, view_end_ms);

    for bucket: first_bucket .. last_bucket
    {
        value := waveform.maximum[bucket];
        if -waveform.minimum[bucket] > value value = -waveform.minimum[bucket];
        if value > peak peak = value;
    }

    if peak <= 0.0 return 0.0;

    middle := y0 + height * 0.5;
    half   := height * 0.5;

    for column: 0 .. columns - 1
    {
        from_ms := view_start_ms + span * cast(float64) column / cast(float64) columns;
        to_ms   := view_start_ms + span * cast(float64) (column + 1) / cast(float64) columns;

        from := waveform_bucket_at_ms(waveform, from_ms);
        to   := waveform_bucket_at_ms(waveform, to_ms);
        if to < from to = from;

        lowest:  float32 = 0.0;
        highest: float32 = 0.0;

        for bucket: from .. to
        {
            if waveform.minimum[bucket] < lowest  lowest  = waveform.minimum[bucket];
            if waveform.maximum[bucket] > highest highest = waveform.maximum[bucket];
        }

        x := x0 + cast(float) column;
        y_top    := middle - (highest / peak) * half;
        y_bottom := middle - (lowest  / peak) * half;
        if y_bottom - y_top < 1.0 y_bottom = y_top + 1.0;

        plot_quad(x, y_top, x + 1.0, y_bottom, colour);
    }

    return peak;
}