/*
project.jai -- the save file for the Adjust tab.

What is worth keeping is not the analysis, which can be redone in a second
from the audio, but the work done on top of it: the timing points that were
moved and retuned, where the playhead was, and how the grid was set up. Plus
the path of the audio, because a set of timing points without its track is
not much use.

A plain text file, one setting per line:

  # BPM Analyzer project
  version 1
  audio E:/music/track.mp3
  position_ms 12345.60
  volume 1.000
  beats_per_bar 4
  show_beats 1
  follow 1
  point 998.50 116
  point 13216.00 232

Text rather than a binary blob because a save that can be read, diffed and
hand-edited is worth more than one that is small, and when something is wrong
with it the person looking at it can see what.

Unknown keys are ignored and missing ones fall back to their defaults, so a
file written by a later version with more settings still opens here with
whatever this version understands, and a truncated one still opens with what
survived.

The dialog and the string helpers come from audio.jai, so that has to be
loaded first, and Timing_Point comes from timing.jai.
*/

#import "Basic";
#import "String";
#import "File";

PROJECT_VERSION   :: 1;
PROJECT_EXTENSION :: "bpmproj";

OFN_OVERWRITEPROMPT :: 0x0000_0002;

Project_State :: struct
{
    loaded: bool;

    audio_path: string;
    position_ms: float64;
    volume:      float64;

    beats_per_bar: s32;
    show_beats:    bool;
    follow:        bool;

    points: [..] Timing_Point;
}

free_project_state :: (state: *Project_State)
{
    if state.audio_path.count > 0 free(state.audio_path);
    state.audio_path = "";

    if state.points.data != null array_reset(*state.points);

    state.loaded = false;
}

project_write :: (path: string, state: Project_State) -> (bool, string)
{
    if state.audio_path.count == 0 return false, "there is no audio to point the save at.";

    builder: String_Builder;
    init_string_builder(*builder);

    append(*builder, "# BPM Analyzer project\n");
    print_to_builder(*builder, "version %\n", PROJECT_VERSION);

    print_to_builder(*builder, "audio %\n", state.audio_path);

    print_to_builder(*builder, "position_ms %\n", decimals(state.position_ms, 2));
    print_to_builder(*builder, "volume %\n",      decimals(state.volume, 3));
    print_to_builder(*builder, "beats_per_bar %\n", state.beats_per_bar);
    print_to_builder(*builder, "show_beats %\n",  ifx state.show_beats then 1 else 0);
    print_to_builder(*builder, "follow %\n",      ifx state.follow then 1 else 0);

    for state.points
    {
        print_to_builder(*builder, "point % %\n", decimals(it.time_ms, 2), decimals(it.bpm, 3));
    }

    text := builder_to_string(*builder);
    defer free(text);

    if !write_entire_file(path, text) return false, tprint("could not write '%'.", path);
    return true, "";
}

key_is :: (key: string, expected: string) -> bool
{
    if key.count != expected.count return false;

    for i: 0 .. key.count - 1 if key[i] != expected[i] return false;
    return true;
}

project_read :: (path: string) -> (Project_State, string)
{
    state: Project_State;

    state.volume        = 0.1;
    state.beats_per_bar = 4;
    state.show_beats    = true;
    state.follow        = true;

    text, read_ok := read_entire_file(path);
    if !read_ok return state, tprint("could not read '%'.", path);
    defer free(text);

    line_start: s64 = 0;

    for index: 0 .. text.count
    {
        if index < text.count && text[index] != #char "\n" continue;

        line := trim(slice(text, line_start, index - line_start));
        line_start = index + 1;

        if line.count == 0 continue;
        if line[0] == #char "#" continue;

        key_end: s64 = 0;
        while key_end < line.count && line[key_end] != #char " " key_end += 1;

        key   := slice(line, 0, key_end);
        value := trim(slice(line, key_end, line.count - key_end));

        if key_is(key, "audio")
        {
            if state.audio_path.count > 0 free(state.audio_path);
            state.audio_path = copy_string(value);
            continue;
        }

        if key_is(key, "point")
        {
            time_ms, time_ok, rest := string_to_float(value);
            if time_ok
            {
                bpm, bpm_ok, _ := string_to_float(trim(rest));
                if bpm_ok
                {
                    array_add(*state.points, Timing_Point.{ cast(float64) time_ms, cast(float64) bpm });
                }
            }
            continue;
        }

        if key_is(key, "position_ms")
        {
            number, parsed, _ := string_to_float(value);
            if parsed state.position_ms = cast(float64) number;
            continue;
        }

        if key_is(key, "volume")
        {
            number, parsed, _ := string_to_float(value);
            if parsed state.volume = cast(float64) number;
            continue;
        }

        if key_is(key, "beats_per_bar")
        {
            number, parsed, _ := string_to_float(value);
            if parsed
            {
                state.beats_per_bar = cast(s32) number;
                if state.beats_per_bar < 1 state.beats_per_bar = 4;
            }
            continue;
        }

        if key_is(key, "show_beats")
        {
            number, parsed, _ := string_to_float(value);
            if parsed state.show_beats = number != 0.0;
            continue;
        }

        if key_is(key, "follow")
        {
            number, parsed, _ := string_to_float(value);
            if parsed state.follow = number != 0.0;
            continue;
        }

    }

    if state.audio_path.count == 0 return state, "the file does not name an audio file.";
    if state.points.count == 0    return state, "the file has no timing points in it.";

    if state.volume < 0.0 state.volume = 0.0;
    if state.volume > 1.0 state.volume = 1.0;

    state.loaded = true;
    return state, "";
}

build_project_dialog_filter :: (buffer: *u16, capacity: s64)
{
    length := utf8_to_wide(buffer, capacity, "BPM Analyzer timing (*.bpmproj)") + 1;
    length += utf8_to_wide(buffer + length, capacity - length, "*.bpmproj") + 1;

    if length < capacity buffer[length] = 0;
}

open_project_file_dialog :: (owner_window: *SDL_Window = null) -> (path: string, success: bool)
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

        build_project_dialog_filter(filter_buffer.data, filter_buffer.count);
        utf8_to_wide(title_buffer.data, title_buffer.count, "Open timing points");

        options: OPENFILENAMEW;
        options.lStructSize  = xx size_of(OPENFILENAMEW);
        options.hwndOwner    = window_handle(owner_window);
        options.lpstrFilter  = filter_buffer.data;
        options.lpstrFile    = file_buffer.data;
        options.nMaxFile     = xx file_buffer.count;
        options.lpstrTitle   = title_buffer.data;
        options.nFilterIndex = 1;
        options.Flags        = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST |
                               OFN_HIDEREADONLY | OFN_NOCHANGEDIR;

        if !GetOpenFileNameW(*options) return "", false;

        return wide_to_utf8(file_buffer.data), true;
    }
}

save_project_file_dialog :: (owner_window: *SDL_Window = null,
                             suggested_name: string = "timing") -> (path: string, success: bool)
                             {
    #if OS != .WINDOWS
    {
        return "", false;
    }
    else
    {
        file_buffer:      [4096]u16;
        filter_buffer:    [256]u16;
        title_buffer:     [128]u16;
        extension_buffer: [32]u16;

        build_project_dialog_filter(filter_buffer.data, filter_buffer.count);
        utf8_to_wide(title_buffer.data, title_buffer.count, "Save timing points");
        utf8_to_wide(extension_buffer.data, extension_buffer.count, PROJECT_EXTENSION);

        utf8_to_wide(file_buffer.data, 256, suggested_name);

        options: OPENFILENAMEW;
        options.lStructSize  = xx size_of(OPENFILENAMEW);
        options.hwndOwner    = window_handle(owner_window);
        options.lpstrFilter  = filter_buffer.data;
        options.lpstrFile    = file_buffer.data;
        options.nMaxFile     = xx file_buffer.count;
        options.lpstrTitle   = title_buffer.data;
        options.lpstrDefExt  = extension_buffer.data;
        options.nFilterIndex = 1;
        options.Flags        = OFN_EXPLORER | OFN_PATHMUSTEXIST | OFN_OVERWRITEPROMPT |
                               OFN_HIDEREADONLY | OFN_NOCHANGEDIR;

        if !GetSaveFileNameW(*options) return "", false;

        return wide_to_utf8(file_buffer.data), true;
    }
}