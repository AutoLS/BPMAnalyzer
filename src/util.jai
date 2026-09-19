/*
A number that should print with a fixed number of decimals.

Jai's % substitutes an argument and does nothing else -- there is no
printf-style "%.1f", and writing one gets you the value followed by a literal
"f". A value that needs rounding has to carry the rounding with it, which is
what FormatFloat is for:

    ImGui.Text("median % BPM", decimals(median, 1));

'places' of 0 gives a whole number.

The parameter is an Any, not a float64, and that matters: FormatFloat holds
the value *by pointer*, so a helper that took a float64 would hand back a
FormatFloat pointing at its own dead parameter, and everything would print as
zero. Taking an Any means the pointer is to the caller's own value, which is
still alive when the print happens.
*/

decimals :: (value: Any, places: s32) -> FormatFloat
{
    return FormatFloat.{ value = value, trailing_width = places, zero_removal = .NO };
}

append_with_newline :: (builder: *String_Builder, str: string, args: .. Any)
{
    text := join(str, "\n");
    append(builder, tprint(text, args));
}

append_array :: (builder: *String_Builder, tag: string, arr: [] $T)
{
    append(builder, tag);
    for arr
    {
        append(builder, tprint(" %", it));
    }
    append(builder, "\n");
}

append_checked_indices :: (builder: *String_Builder, tag: string, indices: [..] u32)
{
    append(builder, tag);
    for indices 
    {
        append(builder, " ");
        append(builder, tprint("%", it));
    }
    append(builder, "\n");
}

compare_array :: (arr_a: [] $T, arr_b: [] T) -> bool
{
    equal := true;

    t := type_of(T);
    ti := cast(*Type_Info) t;

    if ti.type == .STRUCT
    {
        for arr_a
        {
            if !compare_struct(it, arr_b[it_index])
            {
                equal = false;
                break;
            }
        }
    }
    else if ti.type == .ARRAY
    {
        for arr_a
        {
            if !compare_array(it, arr_b[it_index])
            {
                equal = false;
                break;
            }
        }
    }
    else 
    {
        for arr_a
        {
            if it != arr_b[it_index]
            {
                equal = false;
                break;
            }
        }
    }

    return equal;
}

compare_struct :: ($a : $T, b : T) -> bool
{
    build_compare_func :: ($$t : Type) -> string
    {
        ti := cast(*Type_Info) t;
        assert(ti.type == .STRUCT);

        using tis := cast(*Type_Info_Struct) ti;

        builder : String_Builder;
        builder.allocator = temp;

        print_to_builder(*builder, "return ");

        for *member : members
        {
            if member.type.type == .STRUCT
            {
                print_to_builder(*builder, "compare_struct(a.%1,b.%1) ", member.name);
            }
            else if member.type.type == .ARRAY
            {
                tia := cast(*Type_Info_Array)member.type;
                print_to_builder(*builder, "compare_array(a.%1, b.%1) ", member.name);
            }
            else
            {
                print_to_builder(*builder, "a.%1 == b.%1 ", member.name);
            }

            if it_index != members.count - 1
            {
                print_to_builder(*builder, "&& ");
            }
        }

        print_to_builder(*builder, ";");

        return builder_to_string(*builder);
    }

    #insert #run build_compare_func(T);
}