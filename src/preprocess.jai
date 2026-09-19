/*
preprocess.jai -- stage 1 of the BPM analysis pipeline.

Turns a decoded Audio_File (interleaved 16-bit, whatever rate and channel
count the decoder produced) into the single signal that every later stage
works on:

  1. decode to PCM      16-bit integers -> floats in [-1, 1]
  2. downmix            average the channels down to mono
  3. resample           to a fixed 22050 Hz
  4. normalize          divide by the peak (or the RMS) so that thresholds
                        mean the same thing for every file

Why these steps:

  * Beat information lives in the mono mix; keeping two channels would only
    double the cost of every later stage.
  * 22050 Hz is plenty.  What defines a beat sits below ~5 kHz, so the extra
    octave of 44.1 kHz buys nothing while doubling the FFT cost.
  * Peak normalization makes every file use the same numbers for "loud" and
    "quiet" instead of depending on how the file happened to be mastered.
*/

#import "Basic";
#import "Math";

PREPROCESS_SAMPLE_RATE :: 22050;

PREPROCESS_KERNEL_HALF_WIDTH :: 16;

PI_F64 : float64 : 3.14159265358979323846;
S16_TO_FLOAT : float32 : 1.0 / 32768.0;

Normalize_Mode :: enum
{
    NONE;
    PEAK;
    RMS;
}

Preprocess_Settings :: struct
{
    sample_rate:       u32 = PREPROCESS_SAMPLE_RATE;
    normalize:         Normalize_Mode = .PEAK;
    kernel_half_width: s32 = PREPROCESS_KERNEL_HALF_WIDTH;
}

Preprocessed_Audio :: struct
{
    loaded:      bool;
    sample_rate: u32;
    samples:     [..] float32;
    frame_count: s64;
    duration:    float64;

    peak: float32;
    rms:  float32;
    gain: float32;

    source_sample_rate: u32;
    source_channels:    u32;
    source_frames:      s64;

    settings: Preprocess_Settings;
}

samples_s16_to_float32 :: (samples: [] s16) -> [..] float32
{
    result: [..] float32;
    if samples.count == 0 return result;

    array_resize(*result, samples.count, false);
    for index: 0 .. samples.count - 1
    {
        result[index] = cast(float32) samples[index] * S16_TO_FLOAT;
    }

    return result;
}

downmix_to_mono :: (interleaved: [] float32, channel_count: u32) -> [..] float32
{
    result: [..] float32;
    if channel_count == 0 return result;
    if interleaved.count < cast(s64) channel_count return result;

    channels    := cast(s64) channel_count;
    frame_count := interleaved.count / channels;
    if frame_count == 0 return result;

    array_resize(*result, frame_count, false);

    scale := 1.0 / cast(float32) channels;
    for frame: 0 .. frame_count - 1
    {
        sum: float32 = 0;
        for channel: 0 .. channels - 1
        {
            sum += interleaved[frame * channels + channel];
        }
        result[frame] = sum * scale;
    }

    return result;
}

sinc :: (x: float64) -> float64
{
    if x > -1.0e-9 && x < 1.0e-9 return 1.0;

    t := PI_F64 * x;
    return sin(t) / t;
}

hann_window :: (u: float64) -> float64
{
    if u <= -1.0 || u >= 1.0 return 0.0;
    return 0.5 * (1.0 + cos(PI_F64 * u));
}

resample_kernel :: (d: float64, cutoff: float64, support: float64) -> float64
{
    return cutoff * sinc(cutoff * d) * hann_window(d / support);
}

RESAMPLE_PHASES :: 512;

resample_sinc :: (input: [] float32, input_rate: u32, output_rate: u32, half_width: s32 = PREPROCESS_KERNEL_HALF_WIDTH) -> [..] float32
{
    result: [..] float32;

    if input.count == 0 || input_rate == 0 || output_rate == 0 return result;
    if half_width < 1 return result;

    if input_rate == output_rate
    {
        array_resize(*result, input.count, false);
        memcpy(result.data, input.data, input.count * size_of(float32));
        return result;
    }

    ratio     := cast(float64) output_rate / cast(float64) input_rate;
    cutoff    := ifx ratio < 1.0 then ratio else 1.0;
    support_f := cast(float64) half_width / cutoff;
    support   := cast(s64) ceil(support_f);
    taps      := 2 * support + 1;
    step      := cast(float64) input_rate / cast(float64) output_rate;

    output_count := cast(s64) (cast(float64) input.count * ratio);
    if output_count <= 0 return result;

    kernel_sum: float64 = 0;
    for j: -support .. support
    {
        kernel_sum += resample_kernel(cast(float64) j, cutoff, support_f);
    }
    if kernel_sum <= 0.0 return result;

    weights: [..] float32;
    array_resize(*weights, RESAMPLE_PHASES * taps, false);
    defer free_float_array(*weights);

    for phase: 0 .. RESAMPLE_PHASES - 1
    {
        fraction := cast(float64) phase / cast(float64) RESAMPLE_PHASES;

        for j: 0 .. taps - 1
        {
            offset := cast(float64) (j - support);
            weights[phase * taps + j] = cast(float32) (resample_kernel(offset - fraction, cutoff, support_f) / kernel_sum);
        }
    }

    array_resize(*result, output_count, false);

    for out: 0 .. output_count - 1
    {
        position := cast(float64) out * step;
        base     := cast(s64) floor(position);
        fraction := position - cast(float64) base;

        phase := cast(s64) (fraction * cast(float64) RESAMPLE_PHASES + 0.5);
        if phase >= RESAMPLE_PHASES phase = RESAMPLE_PHASES - 1;

        row  := weights.data + phase * taps;
        from := base - support;

        first_tap: s64 = 0;
        if from < 0 first_tap = -from;

        last_tap: s64 = taps - 1;
        if from + taps > input.count last_tap = input.count - from - 1;

        sum: float32 = 0;
        for j: first_tap .. last_tap
        {
            sum += input.data[from + j] * row[j];
        }

        result[out] = sum;
    }

    return result;
}

signal_peak :: (samples: [] float32) -> float32
{
    peak: float32 = 0;

    for samples
    {
        magnitude := ifx it < 0 then -it else it;
        if magnitude > peak peak = magnitude;
    }

    return peak;
}

signal_rms :: (samples: [] float32) -> float32
{
    if samples.count == 0 return 0;

    sum: float64 = 0;
    for samples sum += cast(float64) it * cast(float64) it;

    return cast(float32) sqrt(sum / cast(float64) samples.count);
}

scale_samples :: (samples: [..] float32, gain: float32)
{
    if gain == 1.0 return;

    for index: 0 .. samples.count - 1
    {
        samples[index] *= gain;
    }
}

preprocess_audio :: (audio: *Audio_File, settings: Preprocess_Settings = .{}) -> (Preprocessed_Audio, string)
{
    if !audio.loaded return .{}, "preprocess_audio: there is no decoded audio to preprocess.";
    if audio.samples.count == 0 return .{}, "preprocess_audio: the decoded audio is empty.";
    if settings.sample_rate == 0 return .{}, "preprocess_audio: the target sample rate is zero.";

    interleaved := samples_s16_to_float32(audio.samples);

    mono := downmix_to_mono(interleaved, audio.channel_count);
    free_float_array(*interleaved);

    if mono.count == 0
    {
        free_float_array(*mono);
        return .{}, "preprocess_audio: downmixing produced no samples.";
    }

    resampled := resample_sinc(mono, audio.sample_rate, settings.sample_rate, settings.kernel_half_width);
    free_float_array(*mono);

    if resampled.count == 0
    {
        free_float_array(*resampled);
        return .{}, "preprocess_audio: resampling produced no samples.";
    }

    peak := signal_peak(resampled);
    rms  := signal_rms(resampled);

    gain: float32 = 1.0;
    if      settings.normalize == .PEAK && peak > 0.0 gain = 1.0 / peak;
    else if settings.normalize == .RMS  && rms  > 0.0 gain = 1.0 / rms;
    scale_samples(resampled, gain);

    result: Preprocessed_Audio;
    result.loaded      = true;
    result.sample_rate = settings.sample_rate;
    result.samples     = resampled;
    result.frame_count = resampled.count;
    result.duration    = cast(float64) resampled.count / cast(float64) settings.sample_rate;
    result.peak        = peak;
    result.rms         = rms;
    result.gain        = gain;

    result.source_sample_rate = audio.sample_rate;
    result.source_channels    = audio.channel_count;
    result.source_frames      = audio.frame_count;
    result.settings           = settings;

    return result, "";
}

free_float_array :: (samples: *[..] float32)
{
    if samples.data != null array_reset(samples);
}

free_preprocessed_audio :: (audio: *Preprocessed_Audio)
{
    free_float_array(*audio.samples);
    audio.loaded = false;
}