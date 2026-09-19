/*
audio.jai -- audio file loading for the BPM Analyzer.

Supported formats: WAV (PCM), OGG Vorbis and MP3.

Decoding is delegated to SDL2_mixer, which bundles dr_wav, stb_vorbis and
dr_mp3, so a single loader covers all three formats.  SDL2_mixer refuses to
decode anything until an audio device has been opened, so the mixer is opened
once (on the first load) at a fixed 44100 Hz / stereo / 16-bit format; every
file is converted to that format while loading, which means the samples of
every Audio_File have the same layout no matter what the file contained.

SDL2_mixer.dll and its import library SDL2_mixer.lib have to sit in the
project root, next to BPMAnalyzer.exe.  They ship with the Jai modules
(modules/SDL_Mixer) but the .lib has to be generated from the .dll once:

    dumpbin /exports SDL2_mixer.dll > exports.txt   (then turn it into a .def)
    lib /def:SDL2_mixer.def /out:SDL2_mixer.lib /machine:x64

SDL2.dll has to be the build that ships with the Jai modules as well
(modules/SDL/windows, currently 2.30.2): SDL2_mixer 2.5.2 needs symbols that
the old SDL 2.0.7 does not export, and the executable is linked against the
module's SDL2.lib anyway.
*/

#import "Basic";
#import "File";
#import "Windows";
#import "SDL";

SDL_Mixer :: #library "../SDL2_mixer";

AUDIO_MIXER_FREQUENCY  :: 44100;
AUDIO_MIXER_CHANNELS   :: 2;
AUDIO_MIXER_CHUNK_SIZE :: 4096;

MIX_INIT_FLAC :: 0x0000_0001;
MIX_INIT_MOD  :: 0x0000_0002;
MIX_INIT_MP3  :: 0x0000_0008;
MIX_INIT_OGG  :: 0x0000_0010;

Mix_Chunk :: struct
{
    allocated: s32;
    abuf:      *u8;
    alen:      u32;
    volume:    u8;
}

Mix_Init              :: (flags: s32) -> s32 #foreign SDL_Mixer;
Mix_Quit              :: () #foreign SDL_Mixer;
Mix_OpenAudio         :: (frequency: s32, format: u16, channels: s32, chunksize: s32) -> s32 #foreign SDL_Mixer;
Mix_CloseAudio        :: () #foreign SDL_Mixer;
Mix_QuerySpec         :: (frequency: *s32, format: *u16, channels: *s32) -> s32 #foreign SDL_Mixer;
Mix_LoadWAV_RW        :: (src: *SDL_RWops, freesrc: s32) -> *Mix_Chunk #foreign SDL_Mixer;
Mix_FreeChunk         :: (chunk: *Mix_Chunk) #foreign SDL_Mixer;

audio_mixer_open := false;

Audio_Format :: enum
{
    UNKNOWN;
    WAV;
    OGG;
    MP3;
}

WAV_File :: struct
{
    valid:           bool;
    audio_format:    u16;
    channel_count:   u16;
    sample_rate:     u32;
    byte_rate:       u32;
    block_align:     u16;
    bits_per_sample: u16;
    data_offset:     s64;
    data_size:       u32;
}

OGG_File :: struct
{
    valid:           bool;
    vorbis_version:  u32;
    channel_count:   u8;
    sample_rate:     u32;
    bitrate_maximum: s32;
    bitrate_nominal: s32;
    bitrate_minimum: s32;
    serial_number:   u32;
}

MP3_File :: struct
{
    valid:              bool;
    id3v2_size:         u32;
    has_id3v1:          bool;
    is_vbr:             bool;
    first_frame_offset: s64;
    mpeg_version:       u8;
    layer:              u8;
    bitrate_kbps:       u32;
    sample_rate:        u32;
    channel_mode:       u8;
    channel_count:      u8;
    frame_count:        u32;
}

Audio_File :: struct
{
    loaded:        bool;
    path:          string;
    format:        Audio_Format;
    sample_rate:   u32;
    channel_count: u32;
    frame_count:   s64;
    duration:      float64;
    file_size:     s64;
    samples:       [..] s16;

    wav: WAV_File;
    ogg: OGG_File;
    mp3: MP3_File;
}

read_u16_le :: (data: string, offset: s64) -> u16
{
    if offset + 2 > data.count return 0;

    low  := cast(u32) data[offset];
    high := cast(u32) data[offset + 1];

    return cast,no_check(u16) (low | (high << 8));
}

read_u32_le :: (data: string, offset: s64) -> u32
{
    if offset + 4 > data.count return 0;

    b0 := cast(u32) data[offset];
    b1 := cast(u32) data[offset + 1];
    b2 := cast(u32) data[offset + 2];
    b3 := cast(u32) data[offset + 3];

    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
}

read_s32_le :: (data: string, offset: s64) -> s32
{
    return cast,no_check(s32) read_u32_le(data, offset);
}

string_at_is :: (data: string, offset: s64, tag: string) -> bool
{
    if offset < 0 || offset + tag.count > data.count return false;

    for tag
    {
        if data[offset + it_index] != it return false;
    }

    return true;
}

detect_audio_format :: (data: string) -> Audio_Format
{
    if string_at_is(data, 0, "RIFF") && string_at_is(data, 8, "WAVE") return .WAV;
    if string_at_is(data, 0, "OggS")                         return .OGG;
    if string_at_is(data, 0, "ID3")                          return .MP3;

    if data.count >= 2 && data[0] == 0xFF && (data[1] & 0xE0) == 0xE0 return .MP3;

    return .UNKNOWN;
}

audio_format_name :: (format: Audio_Format) -> string
{
    if format == .WAV return "WAV";
    if format == .OGG return "OGG Vorbis";
    if format == .MP3 return "MP3";
    return "Unknown";
}

parse_wav_file :: (data: string) -> WAV_File
{
    result: WAV_File;

    if !string_at_is(data, 0, "RIFF") return result;
    if !string_at_is(data, 8, "WAVE") return result;

    offset: s64 = 12;
    while offset + 8 <= data.count
    {
        chunk_size := cast(s64) read_u32_le(data, offset + 4);
        body       := offset + 8;

        if string_at_is(data, offset, "fmt ")
        {
            result.audio_format    = read_u16_le(data, body +  0);
            result.channel_count   = read_u16_le(data, body +  2);
            result.sample_rate     = read_u32_le(data, body +  4);
            result.byte_rate       = read_u32_le(data, body +  8);
            result.block_align     = read_u16_le(data, body + 12);
            result.bits_per_sample = read_u16_le(data, body + 14);
        }
        else if string_at_is(data, offset, "data")
        {
            result.data_offset = body;
            result.data_size   = cast(u32) chunk_size;

            result.valid = result.channel_count != 0 && result.sample_rate != 0;
            break;
        }

        offset = body + chunk_size + (chunk_size & 1);
    }

    return result;
}

parse_ogg_file :: (data: string) -> OGG_File
{
    result: OGG_File;

    if !string_at_is(data, 0, "OggS") return result;
    if data.count < 28 return result;

    segment_count := cast(s64) data[26];
    packet        := 27 + segment_count;

    if packet + 30 > data.count        return result;
    if data[packet] != 1               return result;
    if !string_at_is(data, packet + 1, "vorbis") return result;

    result.vorbis_version  = read_u32_le(data, packet +  7);
    result.channel_count   = data[packet + 11];
    result.sample_rate     = read_u32_le(data, packet + 12);
    result.bitrate_maximum = read_s32_le(data, packet + 16);
    result.bitrate_nominal = read_s32_le(data, packet + 20);
    result.bitrate_minimum = read_s32_le(data, packet + 24);
    result.serial_number   = read_u32_le(data, 14);
    result.valid           = true;

    return result;
}

MP3_Frame_Header :: struct
{
    valid:         bool;
    mpeg_version:  u8;
    layer:         u8;
    bitrate_kbps:  u32;
    sample_rate:   u32;
    channel_mode:  u8;
    channel_count: u8;
    has_crc:       bool;
    frame_size:    s64;
}

MP3_BITRATES_MPEG1_LAYER3 :: u32.[ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 ];
MP3_BITRATES_MPEG2_LAYER3 :: u32.[ 0,  8, 16, 24, 32, 40, 48, 56,  64,  80,  96, 112, 128, 144, 160, 0 ];
MP3_SAMPLE_RATES_MPEG1    :: u32.[ 44100, 48000, 32000 ];
MP3_SAMPLE_RATES_MPEG2    :: u32.[ 22050, 24000, 16000 ];
MP3_SAMPLE_RATES_MPEG25   :: u32.[ 11025, 12000,  8000 ];

parse_mp3_frame_header :: (data: string, offset: s64) -> MP3_Frame_Header
{
    result: MP3_Frame_Header;

    if offset + 4 > data.count                 return result;
    if data[offset] != 0xFF                    return result;
    if (data[offset + 1] & 0xE0) != 0xE0       return result;

    version_bits  := (data[offset + 1] >> 3) & 0x03;
    layer_bits    := (data[offset + 1] >> 1) & 0x03;
    bitrate_index := (data[offset + 2] >> 4) & 0x0F;
    rate_index    := (data[offset + 2] >> 2) & 0x03;
    padding       := (data[offset + 2] & 0x02) != 0;
    channel_mode  := (data[offset + 3] >> 6) & 0x03;

    if version_bits == 1                          return result;
    if layer_bits == 0                            return result;
    if bitrate_index == 0 || bitrate_index == 15  return result;
    if rate_index == 3                            return result;
    if layer_bits != 1                            return result;

    mpeg_version := cast(u8) (ifx version_bits == 0 then 25 else ifx version_bits == 2 then 2 else 1);

    bitrates := ifx mpeg_version == 1 then MP3_BITRATES_MPEG1_LAYER3 else MP3_BITRATES_MPEG2_LAYER3;
    rates    := ifx mpeg_version == 1 then MP3_SAMPLE_RATES_MPEG1
                else ifx mpeg_version == 2 then MP3_SAMPLE_RATES_MPEG2
                else MP3_SAMPLE_RATES_MPEG25;

    result.mpeg_version  = mpeg_version;
    result.layer         = 3;
    result.bitrate_kbps  = bitrates[xx bitrate_index];
    result.sample_rate   = rates[xx rate_index];
    result.channel_mode  = channel_mode;
    result.channel_count = cast(u8) (ifx channel_mode == 3 then 1 else 2);
    result.has_crc       = (data[offset + 1] & 0x01) == 0;

    coefficient: s64  = ifx mpeg_version == 1 then 144 else 72;
    bitrate_bps: s64  = cast(s64) result.bitrate_kbps * 1000;
    sample_rate: s64  = cast(s64) result.sample_rate;
    padding_size: s64 = ifx padding then 1 else 0;

    result.frame_size = coefficient * bitrate_bps / sample_rate + padding_size;
    result.valid      = result.frame_size > 4;

    return result;
}

mp3_has_xing_header :: (data: string, frame_offset: s64, header: MP3_Frame_Header) -> bool
{
    side_info: s64;
    if header.mpeg_version == 1
    {
        side_info = ifx header.channel_count == 1 then 17 else 32;
    }
    else
    {
        side_info = ifx header.channel_count == 1 then  9 else 17;
    }

    crc_size := ifx header.has_crc then 2 else 0;
    xing := frame_offset + 4 + crc_size + side_info;

    return string_at_is(data, xing, "Xing") || string_at_is(data, xing, "Info");
}

parse_mp3_file :: (data: string) -> MP3_File
{
    result: MP3_File;

    offset: s64 = 0;

    if string_at_is(data, 0, "ID3") && data.count >= 10
    {
        tag_size := (cast(u32)(data[6] & 0x7F) << 21)
                  | (cast(u32)(data[7] & 0x7F) << 14)
                  | (cast(u32)(data[8] & 0x7F) <<  7)
                  |  cast(u32)(data[9] & 0x7F);

        offset = 10 + cast(s64) tag_size;
        if (data[5] & 0x10) != 0 offset += 10;
        result.id3v2_size = cast(u32) offset;
    }

    result.has_id3v1 = data.count >= 128 && string_at_is(data, data.count - 128, "TAG");

    first_frame: s64 = -1;
    header: MP3_Frame_Header;

    scan := offset;
    while scan + 4 <= data.count
    {
        header = parse_mp3_frame_header(data, scan);
        if header.valid
        {
            first_frame = scan; break;
        }
        scan += 1;
    }

    if first_frame < 0 return result;

    result.first_frame_offset = first_frame;
    result.mpeg_version       = header.mpeg_version;
    result.layer              = header.layer;
    result.bitrate_kbps       = header.bitrate_kbps;
    result.sample_rate        = header.sample_rate;
    result.channel_mode       = header.channel_mode;
    result.channel_count      = header.channel_count;
    result.is_vbr             = mp3_has_xing_header(data, first_frame, header);

    position := first_frame;
    while position + 4 <= data.count
    {
        frame := parse_mp3_frame_header(data, position);
        if !frame.valid break;

        result.frame_count += 1;
        position += frame.frame_size;
    }

    result.valid = true;

    return result;
}

audio_mixer_start :: () -> (success: bool, error: string)
{
    if audio_mixer_open return true, "";

    flags := Mix_Init(MIX_INIT_MP3 | MIX_INIT_OGG | MIX_INIT_FLAC);
    if (flags & MIX_INIT_MP3) == 0 && (flags & MIX_INIT_OGG) == 0
    {
        return false, tprint("SDL2_mixer was built without MP3 or OGG support (got 0x%).", formatInt(xx flags, 16));
    }

    if Mix_OpenAudio(AUDIO_MIXER_FREQUENCY, AUDIO_S16SYS, AUDIO_MIXER_CHANNELS, AUDIO_MIXER_CHUNK_SIZE) != 0
    {
        return false, tprint("Could not open the audio device: %", to_string(SDL_GetError()));
    }

    audio_mixer_open = true;
    return true, "";
}

audio_mixer_stop :: ()
{
    if !audio_mixer_open return;

    Mix_CloseAudio();
    Mix_Quit();
    audio_mixer_open = false;
}

load_audio_file :: (path: string) -> (Audio_File, string)
{
    mixer_ok, mixer_error := audio_mixer_start();
    if !mixer_ok return .{}, mixer_error;

    rw := SDL_RWFromFile(temp_c_string(path), "rb");
    if rw == null return .{}, tprint("Could not open '%': %", path, to_string(SDL_GetError()));

    chunk := Mix_LoadWAV_RW(rw, 1);
    if chunk == null
    {
        return .{}, tprint("Could not decode '%': % (supported formats: WAV, OGG, MP3)", path, to_string(SDL_GetError()));
    }

    sample_rate:   s32;
    sample_format: u16;
    channels:      s32;
    Mix_QuerySpec(*sample_rate, *sample_format, *channels);
    if channels <= 0 channels = AUDIO_MIXER_CHANNELS;

    bytes_per_frame := size_of(s16) * channels;
    frame_count     := cast(s64) chunk.alen / bytes_per_frame;

    audio: Audio_File;
    audio.loaded        = true;
    audio.path          = copy_string(path);
    audio.sample_rate   = cast(u32) sample_rate;
    audio.channel_count = cast(u32) channels;
    audio.frame_count   = frame_count;
    audio.duration      = cast(float64) frame_count / cast(float64) sample_rate;

    array_resize(*audio.samples, frame_count * channels, false);
    memcpy(audio.samples.data, chunk.abuf, chunk.alen);
    Mix_FreeChunk(chunk);

    file_data, read_ok := read_entire_file(path, false, false);
    if read_ok
    {
        audio.file_size = file_data.count;
        audio.format    = detect_audio_format(file_data);

        if      audio.format == .WAV audio.wav = parse_wav_file(file_data);
        else if audio.format == .OGG audio.ogg = parse_ogg_file(file_data);
        else if audio.format == .MP3 audio.mp3 = parse_mp3_file(file_data);

        free(file_data);
    }

    return audio, "";
}

free_audio_file :: (audio: *Audio_File)
{
    if audio.samples.data != null array_reset(*audio.samples);

    if audio.path.count > 0 free(audio.path);
    audio.path = "";

    audio.loaded = false;
}

audio_duration_string :: (seconds: float64) -> string
{
    total := cast(s64) seconds;
    minutes := total / 60;
    seconds_part := total % 60;
    hundredths := cast(s64) ((seconds - cast(float64) total) * 100.0);

    return tprint("%:%.%",
                  minutes,
                  ifx seconds_part < 10 then tprint("0%", seconds_part) else tprint("%", seconds_part),
                  ifx hundredths < 10 then tprint("0%", hundredths) else tprint("%", hundredths));
}

OFN_HIDEREADONLY  :: 0x0000_0004;
OFN_PATHMUSTEXIST :: 0x0000_0800;
OFN_FILEMUSTEXIST :: 0x0000_1000;
OFN_EXPLORER      :: 0x0008_0000;

AUDIO_FILE_FILTER_DESCRIPTION :: "Audio files (*.wav; *.mp3; *.ogg)";
AUDIO_FILE_FILTER_PATTERN     :: "*.wav;*.mp3;*.ogg";

utf8_to_wide :: (destination: *u16, capacity: s64, text: string) -> s64
{
    if capacity < 1 return 0;

    if text.count == 0 || capacity == 1
    {
        destination[0] = 0;
        return 0;
    }

    written := MultiByteToWideChar(CP_UTF8, 0, text.data, xx text.count, destination, xx (capacity - 1));
    if written < 0 written = 0;

    destination[written] = 0;
    return cast(s64) written;
}

wide_to_utf8 :: (wide: *u16) -> string
{
    length := WideCharToMultiByte(CP_UTF8, 0, wide, -1, null, 0, null, null);
    if length <= 0 return "";

    buffer := cast(*u8) alloc(length);
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, buffer, length, null, null);

    result: string;
    result.data  = buffer;
    result.count = length - 1;
    return result;
}

window_handle :: (window: *SDL_Window) -> HWND
{
    if window == null return null;

    #if OS == .WINDOWS
    {
        info: SDL_SysWMinfo;
        SDL_VERSION(*info.version);
        if !SDL_GetWindowWMInfo(window, *info) return null;
        return info.info.win.window;
    }
    else
    {
        return null;
    }
}

shell32 :: #system_library "shell32";

ShellExecuteW :: (hwnd: HWND, operation: *u16, file: *u16, parameters: *u16,
                  directory: *u16, show: s32) -> HINSTANCE #foreign shell32;

reveal_in_explorer :: (path: string, owner: *SDL_Window = null) -> bool
{
    #if OS != .WINDOWS
    {
        _ = path;
        _ = owner;
        return false;
    }
    else
    {
        source: [4096]u16;
        if utf8_to_wide(source.data, cast(s64) source.count, path) <= 0 return false;

        absolute: [4096]u16;
        written := GetFullPathNameW(source.data, cast(DWORD) absolute.count, absolute.data, null);
        if written == 0 || written >= cast(DWORD) absolute.count return false;

        target := wide_to_utf8(absolute.data);
        defer free(target);

        for 0 .. target.count - 1
        {
            if target[it] == #char "/" target[it] = #char "\\";
        }

        argument_text := tprint("/select,\"%\"", target);

        arguments: [4200]u16;
        operation: [16]u16;
        program:   [32]u16;

        if utf8_to_wide(arguments.data, cast(s64) arguments.count, argument_text) <= 0 return false;
        utf8_to_wide(operation.data, cast(s64) operation.count, "open");
        utf8_to_wide(program.data,   cast(s64) program.count,   "explorer.exe");

        result := ShellExecuteW(window_handle(owner), operation.data, program.data,
                                arguments.data, null, SW_SHOWNORMAL);

        return xx result > 32;
    }
}

build_open_dialog_filter :: (buffer: *u16, capacity: s64)
{
    length := utf8_to_wide(buffer, capacity, AUDIO_FILE_FILTER_DESCRIPTION) + 1;    length += utf8_to_wide(buffer + length, capacity - length, AUDIO_FILE_FILTER_PATTERN) + 1;

    if length < capacity buffer[length] = 0;
}

open_audio_file_dialog :: (owner_window: *SDL_Window = null) -> (path: string, success: bool)
{
    #if OS != .WINDOWS
    {
        return "", false;
    }
    else
    {
        file_buffer:   [4096]u16;
        filter_buffer: [256]u16;
        title_buffer:  [128]u16;

        build_open_dialog_filter(filter_buffer.data, filter_buffer.count);
        utf8_to_wide(title_buffer.data, title_buffer.count, "Load audio file");

        options: OPENFILENAMEW;
        options.lStructSize  = xx size_of(OPENFILENAMEW);
        options.hwndOwner    = window_handle(owner_window);
        options.lpstrFilter  = filter_buffer.data;
        options.lpstrFile    = file_buffer.data;
        options.nMaxFile     = xx file_buffer.count;
        options.lpstrTitle   = title_buffer.data;
        options.nFilterIndex = 1;
        options.Flags        = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_NOCHANGEDIR;

        if !GetOpenFileNameW(*options) return "", false;

        return wide_to_utf8(file_buffer.data), true;
    }
}

load_audio_file_dialog :: (owner_window: *SDL_Window = null) -> (result: Audio_File, error: string)
{
    path, picked := open_audio_file_dialog(owner_window);
    if !picked return .{}, "";

    loaded, load_error := load_audio_file(path);
    free(path);

    return loaded, load_error;
}