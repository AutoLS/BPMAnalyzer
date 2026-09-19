/*
plot.jai -- our own plotting, drawn straight into SDL's OpenGL context.

ImGui is still the UI: it owns the window, the menu, the load button and
every piece of text. What it is no longer doing is the graphs. Its PlotLines
cannot put a second series on top of a first, has no axes, no gridlines and
no labels, and it has no heatmap at all -- the tempogram was being drawn as
twenty thousand separate rectangles through its draw list, which is a lot of
ImGui vertices for something a single textured quad does better.

The graphs here are ordinary GL:

  * one shader and one vertex buffer for everything on screen, uploaded once
    and then drawn in submission order, so overlays really do land on top of
    what they are drawn over
  * the heatmap is a texture, built once when a track is analysed
  * geometry is batched during the UI pass and drawn after the clear, so
    ImGui's labels land on top of the graphs without any special arrangement

Coordinates are ImGui's: pixels, origin at the top left, y increasing
downwards, which is what ImGui's own projection uses too.
*/

#import "Basic";
#import "Math";
#import "GL";

font_size :: 13.0;

Plot_RGBA :: struct
{
    r: float32;
    g: float32;
    b: float32;
    a: float32;
}

PLOT_BACKGROUND :: Plot_RGBA.{ 0.055, 0.065, 0.085, 1.0 };
PLOT_GRID       :: Plot_RGBA.{ 0.170, 0.195, 0.235, 1.0 };
PLOT_GRID_MAJOR :: Plot_RGBA.{ 0.260, 0.295, 0.350, 1.0 };
PLOT_BORDER     :: Plot_RGBA.{ 0.380, 0.420, 0.490, 1.0 };
PLOT_ENVELOPE   :: Plot_RGBA.{ 0.250, 0.560, 0.950, 0.900 };

PLOT_CURVE      :: Plot_RGBA.{ 0.300, 0.950, 1.000, 1.000 };
PLOT_BEAT       :: Plot_RGBA.{ 1.000, 1.000, 1.000, 0.200 };
PLOT_DOWNBEAT   :: Plot_RGBA.{ 1.000, 0.360, 0.240, 0.620 };

PLOT_CURSOR     :: Plot_RGBA.{ 1.000, 1.000, 1.000, 0.450 };

PLOT_WAVE           :: Plot_RGBA.{ 0.420, 0.560, 0.720, 1.000 };
PLOT_BEAT_GRID      :: Plot_RGBA.{ 1.000, 1.000, 1.000, 0.180 };
PLOT_BAR_GRID       :: Plot_RGBA.{ 1.000, 1.000, 1.000, 0.420 };
PLOT_TIMING_POINT   :: Plot_RGBA.{ 1.000, 0.780, 0.220, 0.950 };
PLOT_TIMING_CHOSEN  :: Plot_RGBA.{ 1.000, 0.400, 0.150, 1.000 };
PLOT_PLAYHEAD       :: Plot_RGBA.{ 0.300, 1.000, 0.450, 0.950 };

Plot_Vertex :: struct
{
    x, y:          float32;
    u, v:          float32;
    r, g, b, a:    float32;
}

Plot_Draw_Call :: struct
{
    first:    s32;
    count:    s32;
    textured: bool;
}

Plot_Rect :: struct
{
    x0, y0, x1, y1: float;
}

Plot_State :: struct
{
    ready:      bool;
    program:    GLuint;
    vao:        GLuint;
    vbo:        GLuint;
    projection: GLint;
    sampler:    GLint;

    vertices: [..] Plot_Vertex;
    draws:    [..] Plot_Draw_Call;

    white_texture: GLuint;

    screen_width:  float;
    screen_height: float;

    rects: [..] Plot_Rect;
    wheel: float;
}

Plot_Texture :: struct
{
    id:     GLuint;
    width:  s32;
    height: s32;
}

plot: Plot_State;
plot_texture: Plot_Texture;
plot_texture_valid := false;

plot_init :: () -> bool
{
    if plot.ready return true;

    plot_view_init();

    vertex_source := #string VERT_END
#version 330
layout(location = 0) in vec2 Position;
layout(location = 1) in vec2 UV;
layout(location = 2) in vec4 Color;
uniform mat4 ProjMtx;
out vec2 Frag_UV;
out vec4 Frag_Color;
void main() {
    Frag_UV = UV;
    Frag_Color = Color;
    gl_Position = ProjMtx * vec4(Position, 0, 1);
}
VERT_END

    fragment_source := #string FRAG_END
#version 330
uniform sampler2D Texture;
in vec2 Frag_UV;
in vec4 Frag_Color;
out vec4 Out_Color;
void main() {
    Out_Color = Frag_Color * texture(Texture, Frag_UV);
}
FRAG_END

    vertex_shader := glCreateShader(GL_VERTEX_SHADER);
    _glShaderSource(vertex_shader, vertex_source);
    glCompileShader(vertex_shader);

    fragment_shader := glCreateShader(GL_FRAGMENT_SHADER);
    _glShaderSource(fragment_shader, fragment_source);
    glCompileShader(fragment_shader);

    plot.program = glCreateProgram();
    glAttachShader(plot.program, vertex_shader);
    glAttachShader(plot.program, fragment_shader);
    glLinkProgram(plot.program);

    glDeleteShader(vertex_shader);
    glDeleteShader(fragment_shader);

    plot.projection = glGetUniformLocation(plot.program, "ProjMtx");
    plot.sampler    = glGetUniformLocation(plot.program, "Texture");

    if plot.projection < 0
    {
        print("plot_init: the shader program did not link.\n");
        DumpProgramInfoLog(plot.program, "plot");
        return false;
    }

    pixel: [4]u8 = ---;
    pixel[0] = 255; pixel[1] = 255; pixel[2] = 255; pixel[3] = 255;

    glGenTextures(1, *plot.white_texture);
    glBindTexture(GL_TEXTURE_2D, plot.white_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data);

    glGenVertexArrays(1, *plot.vao);
    glGenBuffers(1, *plot.vbo);

    glBindVertexArray(plot.vao);
    glBindBuffer(GL_ARRAY_BUFFER, plot.vbo);

    stride := cast(u32) size_of(Plot_Vertex);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride, xx 0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, stride, xx 8);
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, stride, xx 16);

    glBindVertexArray(0);

    plot.ready = true;
    return true;
}

plot_shutdown :: ()
{
    if !plot.ready return;

    if plot_texture_valid glDeleteTextures(1, *plot_texture.id);
    plot_texture_valid = false;

    glDeleteTextures(1, *plot.white_texture);
    glDeleteBuffers(1, *plot.vbo);
    glDeleteVertexArrays(1, *plot.vao);
    glDeleteProgram(plot.program);

    release_array(*plot.vertices);
    release_array(*plot.draws);
    release_array(*plot.rects);

    plot.ready = false;
}

plot_begin_frame :: (width: float, height: float)
{
    if !plot.ready return;

    array_reset_keeping_memory(*plot.vertices);
    array_reset_keeping_memory(*plot.draws);

    plot.screen_width  = width;
    plot.screen_height = height;

    for 0 .. PLOT_VIEW_COUNT - 1 plot_views_frame[it] = plot_views[it];

    plot.wheel = 0.0;

    io := ImGui.GetIO();
    for plot.rects
    {
        if io.MousePos.x < it.x0 || io.MousePos.x > it.x1 continue;
        if io.MousePos.y < it.y0 || io.MousePos.y > it.y1 continue;

        plot.wheel = io.MouseWheel;
        io.MouseWheel = 0.0;
        break;
    }

    array_reset_keeping_memory(*plot.rects);
}

plot_push :: (vertex: Plot_Vertex, textured: bool)
{
    count := plot.draws.count;

    if count == 0 || plot.draws[count - 1].textured != textured
    {
        array_add(*plot.draws, Plot_Draw_Call.{ cast(s32) plot.vertices.count, 0, textured });
        count += 1;
    }

    array_add(*plot.vertices, vertex);
    plot.draws[count - 1].count += 1;
}

plot_vertex :: (x: float, y: float, colour: Plot_RGBA)
{
    plot_push(Plot_Vertex.{ x, y, 0.0, 0.0, colour.r, colour.g, colour.b, colour.a }, false);
}

plot_quad :: (x0: float, y0: float, x1: float, y1: float, colour: Plot_RGBA)
{
    plot_vertex(x0, y0, colour);
    plot_vertex(x1, y0, colour);
    plot_vertex(x1, y1, colour);

    plot_vertex(x0, y0, colour);
    plot_vertex(x1, y1, colour);
    plot_vertex(x0, y1, colour);
}

plot_line :: (x0: float, y0: float, x1: float, y1: float, thickness: float, colour: Plot_RGBA)
{
    if thickness <= 0.0 return;

    dx := x1 - x0;
    dy := y1 - y0;
    length := sqrt(dx * dx + dy * dy);
    if length < 1.0e-6
    {
        plot_quad(x0 - thickness * 0.5, y0 - thickness * 0.5,
                  x0 + thickness * 0.5, y0 + thickness * 0.5, colour);
        return;
    }

    half := thickness * 0.5;
    nx := -dy / length * half;
    ny :=  dx / length * half;

    plot_vertex(x0 + nx, y0 + ny, colour);
    plot_vertex(x1 + nx, y1 + ny, colour);
    plot_vertex(x1 - nx, y1 - ny, colour);

    plot_vertex(x0 + nx, y0 + ny, colour);
    plot_vertex(x1 - nx, y1 - ny, colour);
    plot_vertex(x0 - nx, y0 - ny, colour);
}

plot_series :: (x0: float, y0: float, width: float, height: float, values: [] float32, baseline: float,
                min_value: float, max_value: float, thickness: float, colour: Plot_RGBA)
                {
    count := values.count;
    if count < 2 return;

    span := max_value - min_value;
    if span <= 0.0 return;

    step := width / cast(float) (count - 1);

    previous_x: float;
    previous_y: float;
    have_previous := false;

    for index: 0 .. count - 1
    {
        value := values[index];

        if value != value
        {
            have_previous = false;
            continue;
        }

        clamped := value;
        if clamped < min_value clamped = min_value;
        if clamped > max_value clamped = max_value;

        x := x0 + step * cast(float) index;
        y := y0 + height * (1.0 - cast(float) ((cast(float64) clamped - min_value) / span));

        if have_previous plot_line(previous_x, previous_y, x, y, thickness, colour);

        previous_x = x;
        previous_y = y;
        have_previous = true;
    }

    _ = baseline;
}

plot_series_filled :: (x0: float, y0: float, width: float, height: float, values: [] float32,
                       min_value: float, max_value: float, colour: Plot_RGBA)
                       {
    count := values.count;
    if count < 2 return;

    span := max_value - min_value;
    if span <= 0.0 return;

    step := width / cast(float) (count - 1);
    baseline := y0 + height;

    have_previous := false;
    previous_x: float;
    previous_y: float;

    for index: 0 .. count - 1
    {
        value := values[index];
        if value != value
        {
            have_previous = false; continue;
        }

        clamped := value;
        if clamped < min_value clamped = min_value;
        if clamped > max_value clamped = max_value;

        x := x0 + step * cast(float) index;
        y := y0 + height * (1.0 - cast(float) ((cast(float64) clamped - min_value) / span));

        if have_previous
        {
            plot_vertex(previous_x, previous_y, colour);
            plot_vertex(x, y, colour);
            plot_vertex(x, baseline, colour);

            plot_vertex(previous_x, previous_y, colour);
            plot_vertex(x, baseline, colour);
            plot_vertex(previous_x, baseline, colour);
        }

        previous_x = x;
        previous_y = y;
        have_previous = true;
    }
}

heatmap_colour :: (value: float32) -> Plot_RGBA
{
    v := value;
    if v < 0.0 v = 0.0;
    if v > 1.0 v = 1.0;

    stops := Plot_RGBA.[
        .{ 0.00, 0.00, 0.02, 1.0 },
        .{ 0.10, 0.12, 0.45, 1.0 },
        .{ 0.55, 0.20, 0.45, 1.0 },
        .{ 0.98, 0.55, 0.15, 1.0 },
        .{ 1.00, 0.95, 0.75, 1.0 },
    ];

    scaled := v * cast(float32) (stops.count - 1);
    low := cast(s32) scaled;
    if low > stops.count - 2 low = stops.count - 2;

    fraction := scaled - cast(float32) low;

    return .{
        stops[low].r + (stops[low + 1].r - stops[low].r) * fraction,
        stops[low].g + (stops[low + 1].g - stops[low].g) * fraction,
        stops[low].b + (stops[low + 1].b - stops[low].b) * fraction,
        1.0,
    };
}

plot_build_tempogram_texture :: (tempogram: *Tempogram, max_width: s32 = 1400, max_height: s32 = 256)
{
    if !plot.ready return;

    if plot_texture_valid
    {
        glDeleteTextures(1, *plot_texture.id);
        plot_texture_valid = false;
    }

    if !tempogram.loaded || tempogram.column_count < 1 return;

    bins := cast(s64) tempogram.tempo_bins;

    width: s32 = max_width;
    if cast(s64) width > tempogram.column_count width = cast(s32) tempogram.column_count;

    height: s32 = max_height;
    if cast(s64) height > bins height = cast(s32) bins;

    if width < 1 || height < 1 return;

    pixels: [..] u8;
    array_resize(*pixels, cast(s64) width * cast(s64) height * 4, false);
    defer release_array(*pixels);

    for row: 0 .. cast(s64) height - 1
    {
        bin_start := row * bins / cast(s64) height;
        bin_end   := (row + 1) * bins / cast(s64) height;
        if bin_end <= bin_start bin_end = bin_start + 1;

        for column: 0 .. cast(s64) width - 1
        {
            column_start := column * tempogram.column_count / cast(s64) width;
            column_end   := (column + 1) * tempogram.column_count / cast(s64) width;
            if column_end <= column_start column_end = column_start + 1;

            peak: float32 = 0;
            for c: column_start .. column_end - 1
            {
                for b: bin_start .. bin_end - 1
                {
                    value := tempogram.values[c * bins + b];
                    if value > peak peak = value;
                }
            }

            colour := heatmap_colour(peak);
            offset := (row * cast(s64) width + column) * 4;

            pixels[offset + 0] = cast(u8) (colour.r * 255.0);
            pixels[offset + 1] = cast(u8) (colour.g * 255.0);
            pixels[offset + 2] = cast(u8) (colour.b * 255.0);
            pixels[offset + 3] = 255;
        }
    }

    glGenTextures(1, *plot_texture.id);
    glBindTexture(GL_TEXTURE_2D, plot_texture.id);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, cast(u32) width, cast(u32) height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data);
    glBindTexture(GL_TEXTURE_2D, 0);

    plot_texture.width  = width;
    plot_texture.height = height;
    plot_texture_valid  = true;
}

plot_textured_quad :: (x0: float, y0: float, x1: float, y1: float, u0: float, v0: float, u1: float, v1: float)
{
    white := Plot_RGBA.{ 1.0, 1.0, 1.0, 1.0 };

    plot_push(Plot_Vertex.{ x0, y0, u0, v0, white.r, white.g, white.b, white.a }, true);
    plot_push(Plot_Vertex.{ x1, y0, u1, v0, white.r, white.g, white.b, white.a }, true);
    plot_push(Plot_Vertex.{ x1, y1, u1, v1, white.r, white.g, white.b, white.a }, true);

    plot_push(Plot_Vertex.{ x0, y0, u0, v0, white.r, white.g, white.b, white.a }, true);
    plot_push(Plot_Vertex.{ x1, y1, u1, v1, white.r, white.g, white.b, white.a }, true);
    plot_push(Plot_Vertex.{ x0, y1, u0, v1, white.r, white.g, white.b, white.a }, true);
}

plot_flush :: ()
{
    if !plot.ready return;
    if plot.vertices.count == 0 || plot.draws.count == 0 return;

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_SCISSOR_TEST);

    glUseProgram(plot.program);

    projection := orthographic_projection_matrix(0, plot.screen_width, plot.screen_height, 0, -1, 1);
    projection = transpose(projection);
    glUniformMatrix4fv(plot.projection, 1, GL_FALSE, xx *projection);
    glUniform1i(plot.sampler, 0);

    glActiveTexture(GL_TEXTURE0);
    glBindVertexArray(plot.vao);
    glBindBuffer(GL_ARRAY_BUFFER, plot.vbo);

    glBufferData(GL_ARRAY_BUFFER,
                 plot.vertices.count * size_of(Plot_Vertex),
                 plot.vertices.data, GL_STREAM_DRAW);

    bound_texture: GLuint = 0;
    for draw: plot.draws
    {
        if draw.count <= 0 continue;

        texture := plot.white_texture;
        if draw.textured
        {
            if !plot_texture_valid continue;
            texture = plot_texture.id;
        }

        if texture != bound_texture
        {
            glBindTexture(GL_TEXTURE_2D, texture);
            bound_texture = texture;
        }

        glDrawArrays(GL_TRIANGLES, draw.first, cast(u32) draw.count);
    }

    glBindVertexArray(0);
    glBindTexture(GL_TEXTURE_2D, 0);
    glUseProgram(0);
}

plot_label :: (x: float, y: float, text: string)
{
    saved := ImGui.GetCursorScreenPos();

    ImGui.SetCursorScreenPos(ImGui.ImVec2.{ x, y });
    ImGui.TextUnformatted(text);

    ImGui.SetCursorScreenPos(saved);
}

PLOT_VIEW_ENVELOPE  :: 0;
PLOT_VIEW_TEMPOGRAM :: 1;
PLOT_VIEW_CURVE     :: 2;
PLOT_VIEW_WAVEFORM  :: 3;
PLOT_VIEW_COUNT     :: 4;

Plot_View :: struct
{
    start_ms: float64;
    end_ms:   float64;

    zoomed:   bool;

    reset_on_double_click: bool;
}

PLOT_MIN_SPAN_MS :: 600.0;

PLOT_ZOOM_PER_NOTCH :: 0.85;

plot_views: [PLOT_VIEW_COUNT] Plot_View;

plot_views_frame: [PLOT_VIEW_COUNT] Plot_View;

plot_view_init :: ()
{
    for 0 .. PLOT_VIEW_COUNT - 1 plot_views[it].reset_on_double_click = true;

    plot_views[PLOT_VIEW_WAVEFORM].reset_on_double_click = false;
}

plot_view_reset :: (view: s32)
{
    if view < 0 || view >= PLOT_VIEW_COUNT return;

    plot_views[view].zoomed   = false;
    plot_views[view].start_ms = 0.0;
    plot_views[view].end_ms   = 0.0;
}

plot_view_set :: (view: s32, start_ms: float64, end_ms: float64)
{
    if view < 0 || view >= PLOT_VIEW_COUNT return;
    if end_ms <= start_ms return;

    plot_views[view].zoomed   = true;
    plot_views[view].start_ms = start_ms;
    plot_views[view].end_ms   = end_ms;
}

PLOT_MARGIN_LEFT   :: 44.0;
PLOT_MARGIN_RIGHT  :: 6.0;
PLOT_MARGIN_TOP    :: 6.0;
PLOT_MARGIN_BOTTOM :: 18.0;

PLOT_REFERENCE_HEIGHT :: 720.0;

plot_height_for :: (base: float) -> float
{
    scale := cast(float) (ImGui.GetIO().DisplaySize.y / PLOT_REFERENCE_HEIGHT);

    if scale < 0.75 scale = 0.75;
    if scale > 1.80 scale = 1.80;

    return base * scale;
}

Plot_Window :: struct
{
    start_ms: float64;
    end_ms:   float64;
    hovered:  bool;
    active:   bool;

    origin_x, origin_y: float;
    width, height:      float;

    x0, y0:             float;
    plot_width:         float;
    plot_height:        float;
}

plot_window :: (id: string, view: s32,
                origin_x: float, origin_y: float, width: float, height: float,
                full_start: float64, full_end: float64,
                pan_with_drag: bool = true) -> Plot_Window
                {
    window: Plot_Window;
    window.start_ms = full_start;
    window.end_ms   = full_end;

    window.origin_x = origin_x;
    window.origin_y = origin_y;
    window.width    = width;
    window.height   = height;

    window.x0          = origin_x + PLOT_MARGIN_LEFT;
    window.y0          = origin_y + PLOT_MARGIN_TOP;
    window.plot_width  = width - PLOT_MARGIN_LEFT - PLOT_MARGIN_RIGHT;
    window.plot_height = height - PLOT_MARGIN_TOP - PLOT_MARGIN_BOTTOM;

    span := full_end - full_start;
    if span <= 0.0 || window.plot_width < 16.0 || window.plot_height < 16.0 return window;
    if view < 0 || view >= PLOT_VIEW_COUNT return window;

    live := *plot_views[view];

    button_size := ImGui.ImVec2.{ width, height };
    ImGui.SetCursorScreenPos(ImGui.ImVec2.{ origin_x, origin_y });
    ImGui.InvisibleButton(id.data, *button_size);

    array_add(*plot.rects, Plot_Rect.{ origin_x, origin_y, origin_x + width, origin_y + height });

    x0    := window.x0;
    pwidth := window.plot_width;

    hovered := ImGui.IsItemHovered();
    window.hovered = hovered;
    window.active  = ImGui.IsItemActive();

    if hovered && live.reset_on_double_click && ImGui.IsMouseDoubleClicked(.Left) plot_view_reset(view);

    if hovered
    {
        wheel := plot.wheel;
        if wheel != 0.0
        {
            plot.wheel = 0.0;

            view_start := ifx live.zoomed then live.start_ms else full_start;
            view_end   := ifx live.zoomed then live.end_ms   else full_end;

            mouse := ImGui.GetMousePos();
            fraction := cast(float64) ((mouse.x - x0) / pwidth);
            if fraction < 0.0 fraction = 0.0;
            if fraction > 1.0 fraction = 1.0;

            anchor := view_start + (view_end - view_start) * fraction;
            wanted := (view_end - view_start) * cast(float64) pow(PLOT_ZOOM_PER_NOTCH, wheel);

            if wanted >= span
            {
                plot_view_reset(view);
            }
            else
            {
                if wanted < PLOT_MIN_SPAN_MS wanted = PLOT_MIN_SPAN_MS;

                ratio := wanted / (view_end - view_start);
                moved := view_start + (anchor - view_start) * (1.0 - ratio);

                live.zoomed   = true;
                live.start_ms = moved;
                live.end_ms   = moved + wanted;
            }
        }
    }

    if pan_with_drag && ImGui.IsItemActive()
    {
        delta := ImGui.GetMouseDragDelta(.Left);
        if delta.x != 0.0
        {
            shown := ifx live.zoomed then live.end_ms - live.start_ms else span;
            base  := ifx live.zoomed then live.start_ms else full_start;

            base -= cast(float64) delta.x / cast(float64) pwidth * shown;

            live.zoomed   = true;
            live.start_ms = base;
            live.end_ms   = base + shown;

            ImGui.ResetMouseDragDelta(.Left);
        }
    }

    if live.zoomed
    {
        shown := live.end_ms - live.start_ms;

        if shown >= span
        {
            plot_view_reset(view);
        }
        else
        {
            if live.start_ms < full_start
            {
                live.start_ms = full_start;
                live.end_ms   = full_start + shown;
            }
            if live.end_ms > full_end
            {
                live.end_ms   = full_end;
                live.start_ms = full_end - shown;
            }
        }
    }

    drawn := *plot_views_frame[view];

    window.start_ms = ifx drawn.zoomed then drawn.start_ms else full_start;
    window.end_ms   = ifx drawn.zoomed then drawn.end_ms   else full_end;
    return window;
}