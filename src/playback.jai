/*
playback.jai -- playing the track back, so timing can be checked by ear.

The mixing is done here rather than by SDL_mixer's Mix_Music. That is not the
simpler arrangement, and it is not for want of trying: there is no rate
control anywhere in SDL_mixer -- no Mix_SetMusicTempo, no speed, no pitch --
and slowing the music down is the whole point of the feature this exists for.
Checked against the exported functions of the DLL rather than assumed.

What makes it cheap is that the samples are already in the output format.
load_audio_file in audio.jai decodes through Mix_LoadWAV_RW, which hands back
PCM converted to the mixer's own spec -- 44100 Hz, two channels, signed
16-bit -- so playback reads straight out of audio_file.samples with nothing
to convert. The file is decoded for the analysis anyway; this borrows it.

Borrows, though, and that is the one thing to be careful of: the slice points
into audio_file, so playback has to be closed before that audio is freed.

Playing slower is done by advancing the read through the samples by less than
one frame per output frame. Left at that it drops the pitch as it goes, which
is a record player running slow; 'keep_pitch' asks for the alternative, where
the notes stay where they are and only the time between them changes.

The alternative is WSOLA -- waveform-similarity overlap-add. The track is cut
into overlapping windows and they are laid back down closer together (or
further apart) than they were taken, so the sound is unchanged in pitch and
stretched in time. Taken naively that sounds like a ring modulator, because
two windows that overlap while out of step cancel where they meet; WSOLA
avoids it by sliding each window a little either way to the offset that
continues the last one most smoothly, which is the search below.

Not a phase vocoder, which is the other standard answer and the wrong one
here. A phase vocoder smears transients -- it is built on the assumption that
the signal is steady over the window -- and a transient is precisely what
this program is for looking at. WSOLA keeps a drum hit a drum hit.
*/

#import "Basic";
#import "Math";

Mix_MusicMixCallback :: #type (udata: *void, stream: *u8, len: s32) #c_call;

Mix_HookMusic  :: (func: Mix_MusicMixCallback, arg: *void) #foreign SDL_Mixer;
Mix_VolumeMusic :: (volume: s32) -> s32 #foreign SDL_Mixer;

PLAYBACK_RATES :: float64.[ 1.0, 0.75, 0.5, 0.25 ];
PLAYBACK_RATE_NAMES :: string.[ "1x", "0.75x", "0.5x", "0.25x" ];

STRETCH_FRAME  :: 1024;
STRETCH_HOP    :: 512;
STRETCH_SEARCH :: 128;

STRETCH_CHANNELS :: 2;

Playback :: struct
{
    loaded: bool;
    path:   string;

    samples:     [] s16;
    frame_count: s64;
    channels:    s32;
    sample_rate: s32;

    playing: bool;
    paused:  bool;

    cursor: float64;

    rate:   float64;
    volume: float64;

    keep_pitch: bool;

    stretch_window:  [STRETCH_FRAME] float64;
    stretch_acc:     [STRETCH_FRAME * STRETCH_CHANNELS] float64;
    stretch_prev:    s64;
    stretch_pending: s64;
    stretch_ready:   bool;
    window_ready:    bool;
}

playback: Playback;

playback_position_ms :: () -> float64
{
    if !playback.loaded || playback.sample_rate <= 0 return 0.0;

    return playback.cursor / cast(float64) playback.sample_rate * 1000.0;
}

playback_duration_ms :: () -> float64
{
    if !playback.loaded || playback.sample_rate <= 0 return 0.0;

    return cast(float64) playback.frame_count / cast(float64) playback.sample_rate * 1000.0;
}

playback_is_playing :: () -> bool
{
    return playback.loaded && playback.playing && !playback.paused;
}

playback_is_paused :: () -> bool
{
    return playback.loaded && playback.playing && playback.paused;
}

playback_rate :: () -> float64
{
    if playback.rate <= 0.0 return 1.0;
    return playback.rate;
}

playback_set_rate_index :: (index: s32)
{
    if index < 0 || index >= PLAYBACK_RATES.count return;
    if PLAYBACK_RATES[index] == playback.rate return;

    playback.rate = PLAYBACK_RATES[index];
    stretch_reset();
}

playback_set_keep_pitch :: (keep: bool)
{
    if keep == playback.keep_pitch return;

    playback.keep_pitch = keep;
    stretch_reset();
}

playback_rate_index :: () -> s32
{
    for index: 0 .. PLAYBACK_RATES.count - 1
    {
        if abs(PLAYBACK_RATES[index] - playback.rate) < 0.0001 return cast(s32) index;
    }
    return 0;
}

playback_scale :: (value: float64) -> s16 #c_call
{
    if playback.volume < 1.0 value *= playback.volume;

    if value >  32767.0 value =  32767.0;
    if value < -32768.0 value = -32768.0;

    return cast(s16) value;
}

playback_finish :: (out: *s16, from: s64, out_frames: s64, channels: s64) #c_call
{
    memset(out + from * channels, 0,
           (out_frames - from) * cast(s64) size_of(s16) * channels);

    playback.cursor  = cast(float64) playback.frame_count;
    playback.playing = false;
    playback.paused  = false;
}

resample_fill :: (out: *s16, out_frames: s64, channels: s64) #c_call
{
    last := playback.frame_count - 1;

    for frame: 0 .. out_frames - 1
    {
        at := cast(s64) playback.cursor;

        if at >= last
        {
            playback_finish(out, frame, out_frames, channels);
            return;
        }

        fraction := playback.cursor - cast(float64) at;
        from := at * channels;
        to   := (at + 1) * channels;

        for channel: 0 .. channels - 1
        {
            a := cast(float64) playback.samples[from + channel];
            b := cast(float64) playback.samples[to + channel];

            out[frame * channels + channel] = playback_scale(a + (b - a) * fraction);
        }

        playback.cursor += playback.rate;
    }
}

playback_build_window :: ()
{
    if playback.window_ready return;

    for i: 0 .. STRETCH_FRAME - 1
    {
        angle := 2.0 * PI_F64 * cast(float64) i / cast(float64) STRETCH_FRAME;
        playback.stretch_window[i] = 0.5 * (1.0 - cos(angle));
    }

    playback.window_ready = true;
}

stretch_next_frame :: () #c_call
{
    last := playback.frame_count - 1;

    nominal := cast(s64) (playback.cursor + 0.5);

    if nominal >= last
    {
        playback.playing = false;
        playback.paused  = false;
        playback.cursor  = cast(float64) playback.frame_count;
        return;
    }

    start := nominal;

    if playback.stretch_ready
    {
        target  := playback.stretch_prev + STRETCH_HOP;
        overlap := STRETCH_FRAME - STRETCH_HOP;

        if target + overlap < last
        {
            best: float64 = -1.0e30;

            for offset: -STRETCH_SEARCH .. STRETCH_SEARCH
            {
                candidate := nominal + offset;
                if candidate < 0 || candidate + overlap >= last continue;

                score: float64 = 0.0;
                for i: 0 .. overlap - 1
                {
                    s := cast(float64) playback.samples[(candidate + i) * STRETCH_CHANNELS];
                    t := cast(float64) playback.samples[(target + i) * STRETCH_CHANNELS];
                    score += 2.0 * s * t - s * s;
                }

                if score > best
                {
                    best  = score;
                    start = candidate;
                }
            }
        }
    }

    if start < 0 start = 0;
    if start > last start = last;

    for i: 0 .. STRETCH_FRAME - 1
    {
        at := start + i;
        if at > last at = last;

        weight := playback.stretch_window[i];
        from   := at * STRETCH_CHANNELS;

        for channel: 0 .. STRETCH_CHANNELS - 1
        {
            playback.stretch_acc[i * STRETCH_CHANNELS + channel] +=
                cast(float64) playback.samples[from + channel] * weight;
        }
    }

    playback.stretch_prev  = start;
    playback.stretch_ready = true;

    playback.cursor += cast(float64) STRETCH_HOP * playback.rate;
}

stretch_fill :: (out: *s16, out_frames: s64) #c_call
{
    channels := cast(s64) STRETCH_CHANNELS;
    written: s64 = 0;

    while written < out_frames
    {
        if playback.stretch_pending == 0
        {
            stretch_next_frame();

            if !playback.playing
            {
                playback_finish(out, written, out_frames, channels);
                return;
            }

            playback.stretch_pending = STRETCH_HOP;
        }

        take := playback.stretch_pending;
        if take > out_frames - written take = out_frames - written;

        for i: 0 .. take - 1
        {
            for channel: 0 .. channels - 1
            {
                out[(written + i) * channels + channel] =
                    playback_scale(playback.stretch_acc[i * channels + channel]);
            }
        }

        moved := take * channels;
        for i: 0 .. (STRETCH_FRAME * channels - moved) - 1
        {
            playback.stretch_acc[i] = playback.stretch_acc[i + moved];
        }
        for i: 0 .. moved - 1
        {
            playback.stretch_acc[STRETCH_FRAME * channels - moved + i] = 0.0;
        }

        playback.stretch_pending -= take;
        written += take;
    }
}

stretch_reset :: () #c_call
{
    for 0 .. STRETCH_FRAME * STRETCH_CHANNELS - 1 playback.stretch_acc[it] = 0.0;

    playback.stretch_pending = 0;
    playback.stretch_ready   = false;
}

playback_mix :: (udata: *void, stream: *u8, len: s32) #c_call
{
    channels := playback.channels;
    if channels < 1 channels = 1;

    out := cast(*s16) stream;
    out_frames := cast(s64) len / (cast(s64) size_of(s16) * cast(s64) channels);

    if !playback.playing || playback.paused || !playback.loaded || playback.samples.data == null
    {
        memset(stream, 0, cast(s64) len);
        return;
    }

    if playback.keep_pitch && playback.rate != 1.0 && channels == STRETCH_CHANNELS
    {
        stretch_fill(out, out_frames);
        return;
    }

    resample_fill(out, out_frames, channels);
}

free_playback_path :: ()
{
    if playback.path.count > 0 free(playback.path);
    playback.path = "";
}

playback_open :: (audio: *Audio_File) -> (bool, string)
{
    mixer_ok, mixer_error := audio_mixer_start();
    if !mixer_ok return false, mixer_error;

    playback_close();

    if !audio.loaded return false, "there is no audio to play.";
    if audio.samples.count == 0 return false, "the audio decoded to nothing.";
    if audio.channel_count < 1 return false, "the audio has no channels.";

    playback.samples     = audio.samples;
    playback.frame_count = audio.frame_count;
    playback.channels    = cast(s32) audio.channel_count;
    playback.sample_rate = cast(s32) audio.sample_rate;

    playback.path    = copy_string(audio.path);
    playback.loaded  = true;
    playback.playing = false;
    playback.paused  = false;
    playback.cursor  = 0.0;
    playback.rate    = 1.0;
    playback.volume  = 1.0;
    playback.keep_pitch = true;

    playback_build_window();
    stretch_reset();

    Mix_HookMusic(playback_mix, null);

    return true, "";
}

playback_close :: ()
{
    playback.playing  = false;
    playback.paused   = false;
    playback.loaded   = false;
    playback.cursor   = 0.0;
    playback.samples  = .[];
    playback.frame_count = 0;

    if playback.path.count > 0 free(playback.path);
    playback.path = "";

    Mix_HookMusic(null, null);
}

playback_pause :: ()
{
    if !playback.loaded || !playback.playing return;
    playback.paused = true;
}

playback_resume :: ()
{
    if !playback.loaded return;

    if !playback.playing playback.playing = true;

    playback.paused = false;
}

playback_play_from :: (milliseconds: float64)
{
    if !playback.loaded return;

    playback_seek(milliseconds);
    stretch_reset();

    playback.playing = true;
    playback.paused  = false;
}

playback_stop :: ()
{
    if !playback.loaded return;

    playback.playing = false;
    playback.paused  = false;
    playback.cursor  = 0.0;
}

playback_seek :: (milliseconds: float64)
{
    if !playback.loaded || playback.sample_rate <= 0 return;

    stretch_reset();

    frame := milliseconds / 1000.0 * cast(float64) playback.sample_rate;

    if frame < 0.0 frame = 0.0;
    if frame > cast(float64) playback.frame_count frame = cast(float64) playback.frame_count;

    playback.cursor = frame;
}

playback_toggle :: ()
{
    if !playback.loaded return;

    if !playback.playing
    {
        if playback.cursor >= cast(float64) playback.frame_count
        {
            playback_play_from(0.0);
            return;
        }

        playback.playing = true;
        playback.paused  = false;
        return;
    }

    playback.paused = !playback.paused;
}

playback_set_volume :: (fraction: float64)
{
    playback.volume = fraction;
    if playback.volume < 0.0 playback.volume = 0.0;
    if playback.volume > 1.0 playback.volume = 1.0;
}