#load "imgui_sdl_gl.jai";
IMGUI_WINDOW_FLAGS :: ImGui.WindowFlags;
IMGUI_INPUT_TEXT_FLAGS :: ImGui.InputTextFlags;
TAB_BAR_FLAGS :: ImGui.TabBarFlags;
TAB_ITEM_FLAGS :: ImGui.TabItemFlags;
TABLE_FLAGS :: ImGui.TableFlags;
TABLE_COLUMN_FLAGS :: ImGui.TableColumnFlags;
TABLE_ROW_FLAGS :: ImGui.TableRowFlags;

label :: (text: string)
{
    ImGui.Text(text);
    ImGui.SameLine();
}

reset_checklist :: (data: *bool, count: int)
{
    for index: 0 .. count-1
    {
        data[index] = false;
    }
}

checkall_checklist :: (data: *bool, count: int)
{
    for index: 0 .. count-1
    {
        data[index] = true;
    }
}

check_list :: (name: string, items: [] string, data: *bool) -> bool
{
    changed := false;
    ImGui.Text(name);
    if ImGui.Button("Check all")
    {
        changed = true;
        checkall_checklist(data, items.count);
    }
    ImGui.SameLine();
    if ImGui.Button("Reset")
    {
        changed = true;
        reset_checklist(data, items.count);
    }
    for items
    {
        if ImGui.Checkbox(temp_c_string(it), *data[it_index])
        {
            changed = true;
        }
    }

    return changed;
}