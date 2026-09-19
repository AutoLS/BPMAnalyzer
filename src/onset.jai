/*
onset.jai -- stage 2: the onset strength envelope.

Turns the preprocessed signal (mono, 22050 Hz, peak-normalized) into a
one-dimensional signal oe[t], sampled at the frame rate -- one value every
~23 ms -- that spikes when something percussive happens.

  1. STFT            2048-sample Hann window, 512-sample hop
  2. magnitude       throw the phase away; only energy matters
  3. compression     log (or cube root), so a quiet hi-hat is not invisible
                     next to a loud kick
  4. spectral flux   sum of the positive frame-to-frame differences: energy
                     that appeared, which is what an onset is
  5. running mean    subtract a moving average, so the envelope sits near 0
  6. rectify         clip whatever is still negative
  7. normalize       scale to [0, 1]

The envelope is deliberately *not* smoothed: smoothing blurs exactly the fine
timing that variable-tempo analysis needs.  If noise is a problem, a short
median filter (3-5 frames) is available and, unlike a moving average, does
not smear a peak into its neighbours.

Timing: a frame is centred on its timestamp, so frame_time(t) is the middle of
the audio that frame was computed from.  Onsets come out about one frame
(~23 ms) early in practice -- the window starts filling as soon as a transient
reaches its leading edge, and the compression makes that first small rise
stand out.  The lead is the same for every onset, so it does not affect tempo
or drift measurements; correct for it only when an absolute time matters.

This file uses PI_F64 from preprocess.jai, so preprocess.jai has to be loaded
first.
*/

#import "Basic";
#import "Math";

FFT_Plan :: struct
{
    size:     s32;
    reversed: [..] s64;
    cosines:  [..] float32;
    sines:    [..] float32;
}

fft_plan_create :: (size: s32) -> FFT_Plan
{
    plan: FFT_Plan;
    if size < 2 return plan;
    if !is_power_of_two(size) return plan;

    n := cast(s64) size;
    plan.size = size;

    bits: s32 = 0;
    while (1 << bits) < size bits += 1;

    array_resize(*plan.reversed, n, false);
    for i: 0 .. n - 1
    {
        reversed: s64 = 0;
        for bit: 0 .. cast(s64) bits - 1
        {
            if (i & (1 << bit)) != 0 reversed |= 1 << (cast(s64) bits - 1 - bit);
        }
        plan.reversed[i] = reversed;
    }

    array_resize(*plan.cosines, n / 2, false);
    array_resize(*plan.sines,   n / 2, false);
    for k: 0 .. n / 2 - 1
    {
        angle := 2.0 * PI_F64 * cast(float64) k / cast(float64) n;
        plan.cosines[k] = cast(float32) cos(angle);
        plan.sines[k]   = cast(float32) sin(angle);
    }

    return plan;
}

fft_plan_destroy :: (plan: *FFT_Plan)
{
    if plan.reversed.data != null array_reset(*plan.reversed);
    if plan.cosines.data  != null array_reset(*plan.cosines);
    if plan.sines.data    != null array_reset(*plan.sines);
    plan.size = 0;
}

is_power_of_two :: (value: s32) -> bool
{
    if value < 1 return false;
    return (value & (value - 1)) == 0;
}

fft_forward :: (plan: *FFT_Plan, real: [] float32, imaginary: [] float32)
{
    n := cast(s64) plan.size;
    if n < 2 return;

    real_data      := real.data;
    imaginary_data := imaginary.data;
    reversed       := plan.reversed.data;
    cosines        := plan.cosines.data;
    sines          := plan.sines.data;

    for i: 0 .. n - 1
    {
        j := reversed[i];
        if i < j
        {
            temporary := real_data[i];
            real_data[i] = real_data[j];
            real_data[j] = temporary;

            temporary = imaginary_data[i];
            imaginary_data[i] = imaginary_data[j];
            imaginary_data[j] = temporary;
        }
    }

    size: s64 = 2;
    while size <= n
    {
        half := size / 2;
        step := n / size;

        block: s64 = 0;
        while block < n
        {
            for j: 0 .. half - 1
            {
                k := j * step;

                wr :=  cosines[k];
                wi := -sines[k];

                a := block + j;
                b := a + half;

                tr := real_data[b] * wr - imaginary_data[b] * wi;
                ti := real_data[b] * wi + imaginary_data[b] * wr;

                real_data[b]      = real_data[a] - tr;
                imaginary_data[b] = imaginary_data[a] - ti;
                real_data[a]      = real_data[a] + tr;
                imaginary_data[a] = imaginary_data[a] + ti;
            }
            block += size;
        }

        size *= 2;
    }
}

Spectrogram :: struct
{
    first_frame: s64;
    frame_count: s64;
    bin_count:   s32;
    sample_rate: u32;
    hop_size:    s32;
    window_size: s32;
    frame_rate:  float64;
    magnitudes:  [..] float32;
}

free_spectrogram :: (spectrogram: *Spectrogram)
{
    if spectrogram.magnitudes.data != null array_reset(*spectrogram.magnitudes);
    spectrogram.frame_count = 0;
}

make_analysis_window :: (size: s32) -> [..] float32
{
    result: [..] float32;
    if size < 1 return result;

    array_resize(*result, size, false);

    if size == 1
    {
        result[0] = 1.0;
        return result;
    }

    total: float64 = 0;
    for i: 0 .. cast(s64) size - 1
    {
        value := 0.5 - 0.5 * cos(2.0 * PI_F64 * cast(float64) i / cast(float64) size);
        result[i] = cast(float32) value;
        total += value;
    }

    scale := cast(float32) (1.0 / total);
    for i: 0 .. cast(s64) size - 1 result[i] *= scale;

    return result;
}

stft_frame_magnitudes :: (plan: *FFT_Plan, window: [] float32, samples: [] float32, start: s64,
                          real: [] float32, imaginary: [] float32,
                          magnitudes: [] float32, magnitude_offset: s64)
                          {
    size := cast(s64) plan.size;

    for i: 0 .. size - 1
    {
        index := start + i;
        value: float32 = 0;
        if index >= 0 && index < samples.count value = samples[index];

        real[i] = value * window[i];
        imaginary[i] = 0;
    }

    fft_forward(plan, real, imaginary);

    bin_count := size / 2 + 1;
    for bin: 0 .. bin_count - 1
    {
        r := real[bin];
        i := imaginary[bin];
        magnitudes[magnitude_offset + bin] = cast(float32) sqrt(cast(float64) r * cast(float64) r + cast(float64) i * cast(float64) i);
    }
}

compute_spectrogram :: (samples: [] float32, sample_rate: u32, window_size: s32, hop_size: s32) -> (Spectrogram, string)
{
    if window_size < 2 || !is_power_of_two(window_size) return .{}, "compute_spectrogram: the window size must be a power of two.";
    if hop_size < 1 return .{}, "compute_spectrogram: the hop size must be positive.";
    if samples.count == 0 return .{}, "compute_spectrogram: there are no samples.";

    plan := fft_plan_create(window_size);
    defer fft_plan_destroy(*plan);

    window := make_analysis_window(window_size);
    defer free_float_array(*window);

    bin_count := window_size / 2 + 1;
    first_frame, frame_count := stft_frame_plan(samples.count, hop_size, window_size);
    if frame_count <= 0 return .{}, "compute_spectrogram: the signal is too short for one frame.";

    result: Spectrogram;
    result.first_frame = first_frame;
    result.frame_count = frame_count;
    result.bin_count   = bin_count;
    result.sample_rate = sample_rate;
    result.hop_size    = hop_size;
    result.window_size = window_size;
    result.frame_rate  = cast(float64) sample_rate / cast(float64) hop_size;

    array_resize(*result.magnitudes, frame_count * cast(s64) bin_count, false);

    real: [..] float32;
    imaginary: [..] float32;
    array_resize(*real, window_size, false);
    array_resize(*imaginary, window_size, false);
    defer free_float_array(*real);
    defer free_float_array(*imaginary);

    for index: 0 .. frame_count - 1
    {
        row := index * cast(s64) bin_count;
        stft_frame_magnitudes(*plan, window, samples,
                              stft_frame_start(first_frame + index, hop_size, window_size),
                              real, imaginary, result.magnitudes, row);
    }

    return result, "";
}

stft_frame_plan :: (sample_count: s64, hop_size: s32, window_size: s32) -> (s64, s64)
{
    if sample_count <= 0 || hop_size < 1 || window_size < 2 return 0, 0;

    half := cast(s64) (window_size / 2);
    if sample_count < cast(s64) window_size return 0, 1;

    first := (half + cast(s64) hop_size - 1) / cast(s64) hop_size;
    last := (sample_count - half) / cast(s64) hop_size;
    if last < first return 0, 0;

    return first, last - first + 1;
}

stft_frame_start :: (frame: s64, hop_size: s32, window_size: s32) -> s64
{
    return frame * cast(s64) hop_size - cast(s64) (window_size / 2);
}

Compression :: enum
{
    NONE;
    LOG;
    CUBE_ROOT;
}

Envelope_Normalize :: enum
{
    NONE;
    FILE;
    WINDOW;
}

Onset_Settings :: struct
{
    window_size: s32 = 2048;
    hop_size:    s32 = 512;

    compression:       Compression = .LOG;
    compression_gamma: float32 = 1000.0;

    max_frequency: float32 = 0.0;

    running_mean_seconds: float64 = 1.5;

    normalize:                Envelope_Normalize = .FILE;
    normalize_window_seconds: float64 = 4.0;

    median_filter_frames: s32 = 0;

    superflux_bins: s32 = 0;
}

Onset_Envelope :: struct
{
    loaded:      bool;
    values:      [..] float32;
    first_frame: s64;
    frame_count: s64;
    frame_rate:  float64;
    duration:    float64;

    sample_rate: u32;
    window_size: s32;
    hop_size:    s32;
    bin_count:   s32;

    settings: Onset_Settings;
}

free_onset_envelope :: (envelope: *Onset_Envelope)
{
    if envelope.values.data != null array_reset(*envelope.values);
    envelope.frame_count = 0;
    envelope.loaded = false;
}

frame_time :: (envelope: *Onset_Envelope, index: s64) -> float64
{
    hop := envelope.first_frame + index;
    return cast(float64) (hop * cast(s64) envelope.hop_size) / cast(float64) envelope.sample_rate;
}

frame_time_ms :: (envelope: *Onset_Envelope, index: s64) -> float64
{
    return frame_time(envelope, index) * 1000.0;
}

compress_magnitude :: (magnitude: float32, compression: Compression, gamma: float32) -> float32
{
    if compression == .NONE return magnitude;
    if magnitude <= 0.0 return 0.0;

    if compression == .CUBE_ROOT
    {
        return cast(float32) pow(cast(float64) magnitude, 1.0 / 3.0);
    }

    return cast(float32) log(1.0 + cast(float64) gamma * cast(float64) magnitude);
}

running_mean :: (values: [] float32, half_window: s64) -> [..] float32
{
    result: [..] float32;
    if values.count == 0 return result;

    array_resize(*result, values.count, false);

    prefix: [..] float64;
    array_resize(*prefix, values.count + 1, false);
    defer array_reset(*prefix);

    prefix[0] = 0;
    for i: 0 .. values.count - 1 prefix[i + 1] = prefix[i] + cast(float64) values[i];

    for i: 0 .. values.count - 1
    {
        from := i - half_window;
        if from < 0 from = 0;

        to := i + half_window + 1;
        if to > values.count to = values.count;

        result[i] = cast(float32) ((prefix[to] - prefix[from]) / cast(float64) (to - from));
    }

    return result;
}

median_filter :: (values: [] float32, radius: s64) -> [..] float32
{
    result: [..] float32;
    if values.count == 0 return result;

    array_resize(*result, values.count, false);

    if radius <= 0
    {
        memcpy(result.data, values.data, values.count * size_of(float32));
        return result;
    }

    window: [..] float32;
    array_resize(*window, radius * 2 + 1, false);
    defer free_float_array(*window);

    for i: 0 .. values.count - 1
    {
        count: s64 = 0;
        for j: i - radius .. i + radius
        {
            if j < 0 continue;
            if j >= values.count break;

            window[count] = values[j];
            count += 1;
        }

        for a: 1 .. count - 1
        {
            key := window[a];
            b := a - 1;
            while b >= 0 && window[b] > key
            {
                window[b + 1] = window[b];
                b -= 1;
            }
            window[b + 1] = key;
        }

        result[i] = window[count / 2];
    }

    return result;
}

normalize_windowed :: (values: [..] float32, half_window: s64)
{
    if values.count == 0 return;

    for i: 0 .. values.count - 1
    {
        from := i - half_window;
        if from < 0 from = 0;

        to := i + half_window + 1;
        if to > values.count to = values.count;

        peak: float32 = 0;
        for j: from .. to - 1
        {
            if values[j] > peak peak = values[j];
        }

        if peak > 0.0 values[i] /= peak;
    }
}

onset_envelope_from_samples :: (samples: [] float32, sample_rate: u32, settings: Onset_Settings) -> (Onset_Envelope, string)
{
    if sample_rate == 0 return .{}, "onset_envelope_from_samples: the sample rate is zero.";
    if samples.count == 0 return .{}, "onset_envelope_from_samples: there are no samples.";
    if settings.window_size < 2 || !is_power_of_two(settings.window_size)
    {
        return .{}, "onset_envelope_from_samples: the window size must be a power of two.";
    }
    if settings.hop_size < 1 return .{}, "onset_envelope_from_samples: the hop size must be positive.";

    plan := fft_plan_create(settings.window_size);
    defer fft_plan_destroy(*plan);

    window := make_analysis_window(settings.window_size);
    defer free_float_array(*window);

    bin_count := settings.window_size / 2 + 1;
    bin_limit := bin_count;
    if settings.max_frequency > 0.0
    {
        bin_limit = cast(s32) (cast(float64) settings.max_frequency * cast(float64) settings.window_size / cast(float64) sample_rate) + 1;
        if bin_limit < 1 bin_limit = 1;
        if bin_limit > bin_count bin_limit = bin_count;
    }

    first_frame, frame_count := stft_frame_plan(samples.count, settings.hop_size, settings.window_size);
    if frame_count <= 0 return .{}, "onset_envelope_from_samples: the signal is too short for one frame.";

    real: [..] float32;
    imaginary: [..] float32;
    array_resize(*real, settings.window_size, false);
    array_resize(*imaginary, settings.window_size, false);
    defer free_float_array(*real);
    defer free_float_array(*imaginary);

    current: [..] float32;
    previous: [..] float32;
    array_resize(*current, bin_count, false);
    array_resize(*previous, bin_count, false);
    defer free_float_array(*current);
    defer free_float_array(*previous);

    flux: [..] float32;
    array_resize(*flux, frame_count, false);

    for frame: 0 .. frame_count - 1
    {
        stft_frame_magnitudes(*plan, window, samples,
                              stft_frame_start(first_frame + frame, settings.hop_size, settings.window_size),
                              real, imaginary, current, 0);

        for bin: 0 .. cast(s64) bin_count - 1
        {
            current[bin] = compress_magnitude(current[bin], settings.compression, settings.compression_gamma);
        }

        if frame == 0
        {
            flux[frame] = 0;
        }
        else
        {
            width    := cast(s64) settings.superflux_bins;
            last_bin := cast(s64) bin_count - 1;

            sum: float32 = 0;
            for bin: 0 .. cast(s64) bin_limit - 1
            {
                reference := previous[bin];

                if width > 0
                {
                    low := bin - width;
                    if low < 0 low = 0;

                    high := bin + width;
                    if high > last_bin high = last_bin;

                    for other: low .. high
                    {
                        if previous[other] > reference reference = previous[other];
                    }
                }

                rise := current[bin] - reference;
                if rise > 0 sum += rise;
            }
            flux[frame] = sum;
        }

        memcpy(previous.data, current.data, cast(s64) bin_count * size_of(float32));
    }

    half_window := cast(s64) (settings.running_mean_seconds * cast(float64) sample_rate / cast(float64) settings.hop_size / 2.0);
    if half_window < 1 half_window = 1;

    mean := running_mean(flux, half_window);
    defer free_float_array(*mean);

    for frame: 0 .. frame_count - 1
    {
        value := flux[frame] - mean[frame];
        if value < 0 value = 0;
        flux[frame] = value;
    }

    if settings.median_filter_frames >= 3
    {
        filtered := median_filter(flux, cast(s64) settings.median_filter_frames / 2);
        free_float_array(*flux);
        flux = filtered;
    }

    if settings.normalize == .FILE
    {
        peak := signal_peak(flux);
        if peak > 0.0 scale_samples(flux, 1.0 / peak);
    }
    else if settings.normalize == .WINDOW
    {
        normalize_half := cast(s64) (settings.normalize_window_seconds * cast(float64) sample_rate / cast(float64) settings.hop_size / 2.0);
        if normalize_half < 1 normalize_half = 1;
        normalize_windowed(flux, normalize_half);
    }

    result: Onset_Envelope;
    result.loaded      = true;
    result.values      = flux;
    result.first_frame = first_frame;
    result.frame_count = frame_count;
    result.frame_rate  = cast(float64) sample_rate / cast(float64) settings.hop_size;

    covered_samples := cast(float64) ((frame_count - 1) * cast(s64) settings.hop_size + cast(s64) settings.window_size);
    result.duration = covered_samples / cast(float64) sample_rate;
    result.sample_rate = sample_rate;
    result.window_size = settings.window_size;
    result.hop_size    = settings.hop_size;
    result.bin_count   = bin_count;
    result.settings    = settings;

    return result, "";
}

compute_onset_envelope :: (audio: *Preprocessed_Audio, settings: Onset_Settings = .{}) -> (Onset_Envelope, string)
{
    if !audio.loaded return .{}, "compute_onset_envelope: there is no preprocessed audio to analyse.";

    envelope, error := onset_envelope_from_samples(audio.samples, audio.sample_rate, settings);
    return envelope, error;
}