// save.jai -- the save file, and the four things the File menu does

gather_project_state :: (state: *Project_State)
{
    state.loaded        = true;
    state.audio_path    = audio_file.path;
    state.position_ms   = playback_position_ms();
    state.volume        = cast(float64) adjust.volume;
    state.beats_per_bar = adjust.grid.beats_per_bar;
    state.show_beats    = adjust.grid.show_beats;
    state.follow        = adjust.follow;
    state.points        = timing.points;
}

load_new_audio :: ()
{
    path, picked := open_audio_file_dialog(window);
    if !picked return;
    defer free(path);

    loaded, load_error := load_audio_file(path);
    if load_error.count > 0
    {
        log_error("Could not load audio file: %\n", load_error);
        return;
    }
    if !loaded.loaded return;

    playback_close();

    if audio_file.loaded free_audio_file(*audio_file);
    audio_file = loaded;

    analyse_loaded_audio();
    prepare_adjust_tab();

    if project_path.count > 0 free(project_path);
    project_path = "";
}

project_save :: (ask_for_path: bool) -> bool
{
    if !audio_file.loaded || !timing.loaded return false;

    path: string;
    picked_fresh: bool;

    if ask_for_path || project_path.count == 0
    {
        suggested := tprint("%_timing", osu_base_name(audio_file.path));
        picked, ok := save_project_file_dialog(window, suggested);
        if !ok return false;

        path         = picked;
        picked_fresh = true;
    }
    else
    {
        path         = project_path;
        picked_fresh = false;
    }

    defer if picked_fresh free(path);

    state: Project_State;
    gather_project_state(*state);

    ok, write_error := project_write(path, state);
    if !ok
    {
        log_error("Could not save: %\n", write_error);
        return false;
    }

    if picked_fresh
    {
        if project_path.count > 0 free(project_path);
        project_path = copy_string(path);
    }

    timing.edited = false;
    return true;
}

project_open :: ()
{
    path, picked := open_project_file_dialog(window);
    if !picked return;
    defer free(path);

    project_open_file(path);
}

project_open_file :: (path: string)
{
    state, read_error := project_read(path);
    if read_error.count > 0
    {
        log_error("Could not open '%': %\n", path, read_error);
        return;
    }
    defer free_project_state(*state);

    audio, load_error := load_audio_file(state.audio_path);
    if load_error.count > 0
    {
        log_error("'%' names an audio file that could not be loaded: %\n", path, load_error);
        return;
    }
    if !audio.loaded return;

    playback_close();

    if audio_file.loaded free_audio_file(*audio_file);
    audio_file = audio;

    analyse_loaded_audio();
    prepare_adjust_tab();

    free_timing_edit(*timing);
    timing.loaded = true;

    for state.points array_add(*timing.points, it);

    timing.selected = 0;
    timing.edited   = false;

    adjust.grid.beats_per_bar = state.beats_per_bar;
    adjust.grid.show_beats    = state.show_beats;
    adjust.follow             = state.follow;
    adjust.volume             = cast(float) state.volume;
    playback_set_volume(state.volume);

    playback_seek(state.position_ms);

    remembered := copy_string(path);
    if project_path.count > 0 free(project_path);
    project_path = remembered;
}

ask_about_saving :: (what: Pending_Action)
{
    pending_question = what;
    show_save_prompt = true;
    ImGui.OpenPopup("Unsaved changes".data);
}

draw_save_prompt :: ()
{
    if !show_save_prompt return;

    still_open := true;
    if ImGui.BeginPopupModal("Unsaved changes".data, *still_open, .AlwaysAutoResize)
    {
        ImGui.Text("The timing points have been changed since they were saved.");

        ImGui.Separator();

        if ImGui.Button("Save".data)
        {
            if project_save(false)
            {
                pending_action   = pending_question;
                pending_question = .NONE;
                show_save_prompt = false;
                ImGui.CloseCurrentPopup();
            }
        }

        ImGui.SameLine();
        if ImGui.Button("Don't save".data)
        {
            pending_action   = pending_question;
            pending_question = .NONE;
            show_save_prompt = false;
            ImGui.CloseCurrentPopup();
        }

        ImGui.SameLine();
        if ImGui.Button("Cancel".data)
        {
            pending_question = .NONE;
            show_save_prompt = false;
            ImGui.CloseCurrentPopup();
        }

        ImGui.EndPopup();
    }

    if !still_open
    {
        pending_question = .NONE;
        show_save_prompt = false;
    }
}

request_new :: ()
{
    if timing.loaded && timing.edited
    {
        ask_about_saving(.NEW_FILE); return;
    }
    pending_action = .NEW_FILE;
}

request_open :: ()
{
    if timing.loaded && timing.edited
    {
        ask_about_saving(.OPEN_FILE); return;
    }
    pending_action = .OPEN_FILE;
}

request_reanalysis :: ()
{
    if timing.loaded && timing.edited
    {
        ask_about_saving(.REANALYSE); return;
    }
    pending_action = .REANALYSE;
}

run_pending_action :: ()
{
    action := pending_action;
    pending_action = .NONE;

    if action == .NEW_FILE  load_new_audio();
    if action == .OPEN_FILE project_open();

    if action == .REANALYSE && audio_file.loaded
    {
        analyse_loaded_audio();
        prepare_adjust_tab();

        settings_need_reanalysis = false;
    }
}