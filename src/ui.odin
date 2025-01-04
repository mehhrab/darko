package darko

import rl "vendor:raylib"
import "core:slice"
import "core:strings"
import "core:fmt"
import "core:math"
import "core:c"
import sa "core:container/small_array"

UI_Ctx :: struct {
	hovered_widget: UI_ID,
	active_widget: UI_ID,
	hovered_panel: UI_ID,
	active_panel: UI_ID,
	draw_commands: Draw_Commands,
	notif_text: string,
	notif_time: f32,	
	
	// current popup scope
	current_popup: string,
	// HACK: we can only have one active popup
	open_popup: UI_Popup,

	// style:

	font: rl.Font,
	font_size: f32,
	roundness: f32,
	header_height: f32,
	text_align: UI_Align,
	default_widget_height: f32,

	text_color: rl.Color,
	panel_color: rl.Color,
	accent_color: rl.Color,
	border_color: rl.Color,
	widget_color: rl.Color,
	widget_hover_color: rl.Color,
	widget_active_color: rl.Color,
}

UI_ID :: u32

Draw_Commands :: sa.Small_Array(1024, UI_Draw_Command)

UI_Align :: struct {
	horizontal: UI_Align_Horizontal,
	vertical: UI_Align_Vertical,
}

UI_Align_Horizontal :: enum {
	Left,
	Center,
	Right,
}

UI_Align_Vertical :: enum {
	Top,
	Center,
	Bottom,
}

UI_Popup :: struct {
	name: string,
	show_header: bool,
	open_time: f32,
	rec: Rec,
	draw_commands: Draw_Commands,
}

UI_Menu_Item :: struct {
	id: UI_ID,
	text: string,
	shortcut: string,
}

UI_Draw_Command :: union {
	UI_Draw_Rect,
	UI_Draw_Rect_Outline,
	UI_Draw_Text,
	UI_Draw_Gradient_H,
	UI_Draw_Canvas,
	UI_Draw_Grid,
	UI_Draw_Preview,
}

UI_Draw_Rect :: struct {
	rec: Rec,
	color: rl.Color,
}

UI_Draw_Rect_Outline :: struct {
	rec: Rec,
	color: rl.Color,
	thickness: f32,
}

UI_Draw_Text :: struct {
	text: string,
	size: f32,
	rec: Rec,
	color: rl.Color,
	align: UI_Align,
}

UI_Draw_Gradient_H :: struct {
	left_color: rl.Color,
	right_color: rl.Color,
	rec: Rec,
}

// darko specific commands:

UI_Draw_Canvas :: struct {
	rec: Rec,
	panel_rec: Rec,
}

UI_Draw_Grid :: struct {
	rec: Rec,
	panel_rec: Rec,
}

UI_Draw_Preview :: struct {
	rec: Rec,
}

UI_Axis :: enum {
	Horizontal,
	Vertical,
}

UI_Box_Layout :: struct {
	direction: UI_Axis,
	taken: f32,
	spacing: f32,
	rec: Rec,
} 

UI_Grid_Layout :: struct {

}

ICON_PEN :: "\uf8ea"
ICON_ERASER :: "\uf6fd"
ICON_TRASH :: "\uf6bf"
ICON_UP :: "\ufc35"
ICON_DOWN :: "\ufc2c"
ICON_COPY :: "\uf68e"
ICON_SETTINGS :: "\uf992"
ICON_X :: "\uf655" 
ICON_CHECK :: "\uf62b"

ui_ctx: UI_Ctx

ui_init_ctx :: proc() {	
	ui_ctx.font_size = 18

	CHARS :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789… ~!@#$%^&*()-|\"':;_+={}[]\\/`,.<>?"
	ICONS :: ICON_PEN + 
	ICON_ERASER + 
	ICON_TRASH + 
	ICON_UP + 
	ICON_DOWN + 
	ICON_COPY +
	ICON_SETTINGS +
	ICON_X +
	ICON_CHECK
	
	code_point_count: i32
	code_points := rl.LoadCodepoints(CHARS + ICONS, &code_point_count)

	font_data := #load("../assets/Hack Bold Nerd Font Complete.ttf")
	ui_ctx.font = rl.LoadFontFromMemory(
		".ttf", 
		raw_data(font_data), 
		i32(len(font_data)), 
		i32(ui_ctx.font_size * 2.5), 
		code_points,
		code_point_count)
	rl.SetTextureFilter(ui_ctx.font.texture, .BILINEAR)
	
	ui_ctx.text_align = { .Center, .Center }
	ui_ctx.default_widget_height = 32
	ui_ctx.header_height = ui_ctx.default_widget_height * 1.2

	ui_ctx.text_color = { 200, 209, 218, 255 }
	ui_ctx.panel_color = { 33, 40, 48, 255 }
	ui_ctx.accent_color = { 176, 131, 240, 255 }
	ui_ctx.border_color = { 20, 23, 28, 255 }
	ui_ctx.widget_color = { 61, 68, 77, 255 }
	ui_ctx.widget_hover_color = { 101, 108, 118, 255 }
	ui_ctx.widget_active_color = { 101, 108, 118, 255 }
}

ui_deinit_ctx :: proc() {
	rl.UnloadFont(ui_ctx.font)
}

ui_begin :: proc() {
	if ui_ctx.open_popup.name != "" &&
		rl.IsMouseButtonReleased(.LEFT) &&
		ui_is_mouse_in_rec(ui_ctx.open_popup.rec) == false &&
		ui_ctx.active_widget == 0 &&
		ui_ctx.active_panel == 0 {
		ui_close_current_popup()
	}
	if ui_ctx.open_popup.name != "" {
		ui_ctx.open_popup.open_time += 0.01
	}
	if ui_ctx.notif_text != "" {
		ui_ctx.notif_time += 0.01
	}
}

ui_end :: proc() {
	if rl.IsMouseButtonReleased(.LEFT) {
		ui_ctx.active_widget = 0
		ui_ctx.active_panel = 0
	}
}

ui_gen_id_auto :: proc(loc := #caller_location) -> UI_ID {
	return UI_ID(loc.line)
}

ui_draw :: proc() {
	ui_process_commands(sa.slice(&ui_ctx.draw_commands))

	if ui_ctx.open_popup.name != "" {
		screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
		opacity := ui_ctx.open_popup.open_time * 40 * 5
		if opacity >= 40 {
			opacity = 40
		}
		rl.DrawRectangleRec(screen_rec, { 255, 255, 255, u8((opacity / 255) * 255) })
		ui_process_commands(sa.slice(&ui_ctx.open_popup.draw_commands))
	}
	
	// TODO: clean this up
	if ui_ctx.notif_text != "" {
		ww := f32(rl.GetScreenWidth())
		wh := f32(rl.GetScreenHeight())

		text := strings.clone_to_cstring(ui_ctx.notif_text, context.temp_allocator)
		offset := f32(80)
		padding := f32(10)
		text_size := rl.MeasureTextEx(ui_ctx.font, text, ui_ctx.font_size, 0)
		notif_w := text_size.x + padding * 2
		notif_h := text_size.y + padding * 2
		notif_x := ww / 2 - text_size.x / 2 + padding
		notif_y := f32(0)
		
		if ui_ctx.notif_time < 0.2 {
			notif_y = wh - offset * (ui_ctx.notif_time / 0.2)
		}
		else if ui_ctx.notif_time >= 0.2 && ui_ctx.notif_time < 1 {
			notif_y = wh - offset
		} 
		else if ui_ctx.notif_time >= 1 && ui_ctx.notif_time <= 1.2 {
			notif_y = wh - offset + offset * (ui_ctx.notif_time - 1) / 0.2
		}
		else {
			ui_ctx.notif_text = ""
		}
		if ui_ctx.notif_text != "" {
			notif_y += padding
			rl.DrawRectangleRec({ notif_x, notif_y, notif_w, notif_h }, ui_ctx.accent_color)
			rl.DrawTextEx(ui_ctx.font, text, { notif_x + padding, notif_y + padding }, ui_ctx.font_size, 0, { 35, 38, 52, 255 })
		}
	}	

	sa.clear(&ui_ctx.draw_commands)
	sa.clear(&ui_ctx.open_popup.draw_commands)
	free_all(context.temp_allocator)
}

// TODO: should be handled in app
ui_process_commands :: proc(commands: []UI_Draw_Command) {
	for command in commands
	{
		switch kind in command {
			case UI_Draw_Rect: {
				rl.DrawRectangleRec(kind.rec, kind.color)
			}
			case UI_Draw_Rect_Outline: {
				rl.DrawRectangleLinesEx(kind.rec, kind.thickness, kind.color)
			}
			case UI_Draw_Text: {
				x := f32(0)
				y := f32(0)

				text := strings.clone_to_cstring(kind.text, context.temp_allocator)
				text_size := rl.MeasureTextEx(ui_ctx.font, text, kind.size, 0)
				
				if kind.align.horizontal == .Left {
					x = kind.rec.x
				}
				else if kind.align.horizontal == .Center {
					x = kind.rec.x + kind.rec.width / 2 - text_size.x / 2
				}
				else if kind.align.horizontal == .Right {
					x = kind.rec.x + kind.rec.width - text_size.x
				}

				if kind.align.vertical == .Top {
					y = kind.rec.y
				}
				else if kind.align.vertical == .Center {
					y = kind.rec.y + kind.rec.height / 2 - text_size.y / 2
				}
				else if kind.align.vertical == .Bottom {
					y = kind.rec.y + kind.rec.height - text_size.y
				}

				rl.DrawTextEx(ui_ctx.font, text, {x, y}, kind.size, 0, kind.color)
			}
			case UI_Draw_Gradient_H: {
				x := i32(math.ceil_f32(kind.rec.x))
				y := i32(math.ceil_f32(kind.rec.y))
				w := i32(math.ceil_f32(kind.rec.width))
				h := i32(math.ceil_f32(kind.rec.height))
				rl.DrawRectangleGradientH(x, y, w, h, kind.left_color, kind.right_color)
			}
			case UI_Draw_Canvas: {
				rl.BeginScissorMode(
					i32(kind.panel_rec.x), 
					i32(kind.panel_rec.y), 
					i32(kind.panel_rec.width), 
					i32(kind.panel_rec.height))
				draw_canvas(kind.rec)
				rl.EndScissorMode()
			}
			case UI_Draw_Grid: {
				rl.BeginScissorMode(
					i32(kind.panel_rec.x), 
					i32(kind.panel_rec.y), 
					i32(kind.panel_rec.width), 
					i32(kind.panel_rec.height))
				draw_grid(kind.rec)
				rl.EndScissorMode()
			}
			case UI_Draw_Preview: {
				x := i32(math.round(kind.rec.x))
				y := i32(math.round(kind.rec.y))
				w := i32(math.round(kind.rec.width))
				h := i32(math.round(kind.rec.height))
				
				rl.BeginScissorMode(x, y, w, h)
				rl.DrawRectangleGradientV(x, y, w, h, ui_ctx.panel_color, ui_ctx.widget_hover_color)
				px, py := rec_get_center_point(kind.rec)
				draw_sprite_stack(&app.project.layers, px, py, app.lerped_preview_zoom, app.preview_rotation, app.project.spacing)
				rl.DrawTextEx(ui_ctx.font, "PREVIEW", { kind.rec.x + 10, kind.rec.y + 10 }, ui_ctx.font_size * 1.4, 0, { 255, 255, 255, 100 })
				rl.EndScissorMode()
				rl.DrawRectangleLinesEx(kind.rec, 1, ui_ctx.border_color)
			}
		}
	}
}

ui_open_popup :: proc(name: string) {
	ui_ctx.open_popup.name = name
	ui_ctx.open_popup.open_time = 0
	ui_ctx.hovered_widget = 0
	ui_ctx.active_widget = 0
}

ui_close_current_popup :: proc() {
	ui_ctx.hovered_widget = 0
	ui_ctx.active_widget = 0
	ui_ctx.open_popup.name = ""
	ui_ctx.open_popup.rec = {}
	ui_ctx.open_popup.show_header = false
}

// NOTE: name is also used as the id
ui_begin_popup :: proc(name: string, rec: Rec) -> (open: bool) {
	ui_ctx.current_popup = name

	if name == ui_ctx.open_popup.name {
		ui_ctx.open_popup.rec = rec
	}
	 
	return name == ui_ctx.open_popup.name
}

ui_begin_popup_with_header :: proc(name: string, id: UI_ID, rec: Rec) -> (open: bool, client_rec: Rec) {
	ui_ctx.current_popup = name

	if name == ui_ctx.open_popup.name {
		ui_ctx.open_popup.show_header = true
		area := rec
		header_area := rec_extend_from_top(&area, ui_ctx.header_height) 
		ui_ctx.open_popup.rec = area
		if ui_button(id, ICON_X, rec_pad(rec_take_from_right(&header_area, header_area.height), 8)) {
			ui_close_current_popup()
		}
	}
	return name == ui_ctx.open_popup.name, { rec.x, rec.y, rec.width, rec.height }
}

// TODO: i don't remember why draw commands are pushed here
ui_end_popup :: proc() {
	sa.inject_at(&ui_ctx.open_popup.draw_commands, UI_Draw_Rect {
		color = ui_ctx.border_color,
		rec = rec_pad(ui_ctx.open_popup.rec, -1),
	}, 0)
	sa.inject_at(&ui_ctx.open_popup.draw_commands, UI_Draw_Rect {
		color = ui_ctx.panel_color,
		rec = ui_ctx.open_popup.rec,
	}, 1)
	if ui_ctx.open_popup.show_header {
		sa.inject_at(&ui_ctx.open_popup.draw_commands, UI_Draw_Rect {
			color = ui_ctx.border_color,
			rec = { ui_ctx.open_popup.rec.x, ui_ctx.open_popup.rec.y, ui_ctx.open_popup.rec.width, ui_ctx.header_height },
		}, 2)
		sa.inject_at(&ui_ctx.open_popup.draw_commands, UI_Draw_Text {
			color = rl.Fade(ui_ctx.text_color, 0.7),
			rec = { ui_ctx.open_popup.rec.x, ui_ctx.open_popup.rec.y, ui_ctx.open_popup.rec.width, ui_ctx.header_height },
			text = ui_ctx.open_popup.name,
			align = { .Center, .Center },
			size = ui_ctx.font_size * 1.2,
		}, 3)
	}
	ui_ctx.current_popup = ""
}

ui_show_notif :: proc(text: string) {
	ui_ctx.notif_text = text
	ui_ctx.notif_time = 0
}

ui_update_widget :: proc(id: UI_ID, rec: Rec, blocking := true) {
	if ui_ctx.open_popup.name != ui_ctx.current_popup && ui_ctx.open_popup.name != "" {
		return
	}
	hovered := ui_is_mouse_in_rec(rec)
	if hovered && (blocking == false || (ui_ctx.active_widget == 0 || ui_ctx.active_widget == id)) {
		ui_ctx.hovered_widget = id
		if rl.IsMouseButtonPressed(.LEFT) {
			ui_ctx.active_widget = id
		}
	}
	else if ui_ctx.hovered_widget == id {
		ui_ctx.hovered_widget = 0
	}
}

ui_update_panel :: proc(id: UI_ID, rec: Rec) {
	if ui_ctx.open_popup.name != ui_ctx.current_popup && ui_ctx.open_popup.name != "" {
		return
	}
	hovered := ui_is_mouse_in_rec(rec)
	if hovered && (ui_ctx.active_panel == 0 || ui_ctx.active_panel == id) {
		ui_ctx.hovered_panel = id
		if rl.IsMouseButtonPressed(.LEFT) {
			ui_ctx.active_panel = id
		}
	}
	else if ui_ctx.hovered_panel == id {
		ui_ctx.hovered_panel = 0
	}
}

ui_panel :: proc(id: UI_ID, rec: Rec) {
	ui_update_panel(id, rec)
	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = ui_ctx.panel_color,
	})
}

ui_button :: proc(id: UI_ID, text: string, rec: Rec, blocking := true) -> (clicked: bool) {	
	clicked = false
	ui_update_widget(id, rec, blocking)
	if ui_ctx.hovered_widget == id && rl.IsMouseButtonReleased(.LEFT){
		clicked = true
	}
	color := ui_ctx.widget_color
	if ui_ctx.active_widget == id {
		color = ui_ctx.widget_active_color
	}
	else if ui_ctx.hovered_widget == id {
		color = ui_ctx.widget_hover_color
	}
	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = color
	})
	ui_push_command(UI_Draw_Text {
		rec = rec_pad(rec, 10),
		text = text,
		size = ui_ctx.font_size,
		color = ui_ctx.text_color,
		align = ui_ctx.text_align,
	})
	return clicked
}

ui_menu_button :: proc(id: UI_ID, text: string, items: ^[]UI_Menu_Item, item_width: f32, rec: Rec) -> (clicked_item: UI_Menu_Item) {	
	clicked_item = {}
	ui_update_widget(id, rec)
	if ui_ctx.hovered_widget == id && rl.IsMouseButtonReleased(.LEFT){
		ui_open_popup(text)	
	}

	padding := f32(10)
	item_height := f32(ui_ctx.default_widget_height)
	if ui_begin_popup(text, { rec.x + 10, rec.y + rec.height + padding, item_width, item_height * f32(len(items^)) }) {
		// HACK: add an option for disabling popup backaground
		ui_ctx.open_popup.open_time = 0

		menu_item_y := rec.y + rec.height + padding
		prev_text_align := ui_ctx.text_align
		ui_ctx.text_align = { .Left, .Center }
		for item, i in items^ {
			if ui_button(item.id, item.text, { rec.x + padding, menu_item_y, item_width, item_height }) {
				clicked_item = item
			}
			menu_item_y += item_height
		}
		ui_ctx.text_align = prev_text_align
	}
	ui_end_popup()

	color := ui_ctx.widget_color
	if ui_ctx.active_widget == id {
		color = ui_ctx.widget_active_color
	}
	else if ui_ctx.hovered_widget == id {
		color = ui_ctx.widget_hover_color
	}
	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = color
	})
	ui_push_command(UI_Draw_Text {
		rec = rec,
		text = text,
		size = ui_ctx.font_size,
		color = ui_ctx.text_color,
		align = ui_ctx.text_align,	
	})
	return clicked_item
}

ui_check_box :: proc(id: UI_ID, label: string, checked: ^bool, rec: Rec) {
	check_box_rec := Rec {
		rec.x + rec.width - ui_ctx.default_widget_height,
		rec.y,
		ui_ctx.default_widget_height,
		rec.height,
	}
	ui_update_widget(id, check_box_rec)
	if ui_ctx.active_widget == id && rl.IsMouseButtonReleased(.LEFT) {
		checked^ = !checked^ 
	}
	ui_push_command(UI_Draw_Rect {
		rec = check_box_rec,
		color = ui_ctx.border_color,
	})
	if checked^ {		
		ui_push_command(UI_Draw_Rect {
			rec = rec_pad(check_box_rec, 8),
			color = ui_ctx.accent_color,
		})
	}
	ui_push_command(UI_Draw_Text {
		rec = rec,
		align = { .Left, .Center },
		color = ui_ctx.text_color,
		size = ui_ctx.font_size,
		text = label,
	})
}

ui_slider_behaviour_f32 :: proc(
	id: UI_ID,
	value: ^f32,
	min, max: f32,
	rec: Rec,
	step: f32 = 0,
) -> (
	value_changed: bool,
) {
	value_changed = false
	last_value := value^
	ui_update_widget(id, rec)

	if ui_ctx.active_widget == id && rl.IsMouseButtonDown(.LEFT) {
		last_value = min + (rl.GetMousePosition().x - rec.x) * (max - min) / rec.width
		if step != 0 {
			last_value = (math.round(last_value / step)) * step
		}
		value_changed = true
	}
	
	last_value = math.clamp(last_value, min, max)
	value^ = last_value

	return value_changed
}

ui_slider_f32 :: proc(
	id: UI_ID,
	label: string,
	value: ^f32,
	min, max: f32,
	rec: Rec,
	format: string = "%.2f",
	step: f32 = 0,
) -> (
	value_changed: bool,
) {
	value_changed = ui_slider_behaviour_f32(id, value, min, max, rec, step)
	progress_rec := rec_pad(rec, 1)

	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = ui_ctx.border_color,
	})

	progress_width := (value^ - min) * (progress_rec.width) / (max - min)
	progress_rec.width = progress_width
	ui_push_command(UI_Draw_Rect {
		rec = progress_rec,
		color = ui_ctx.widget_color,	
	})
	
	ui_push_command(UI_Draw_Text {
		rec = rec_pad(rec, 10),
		text = label,
		size = ui_ctx.font_size,
		color = ui_ctx.text_color,
		align = { .Left, .Center },	
	})
	text := fmt.aprintf(format, value^, allocator = context.temp_allocator)
	ui_push_command(UI_Draw_Text {
		rec = rec_pad({ rec.x + 2, rec.y + 2, rec.width, rec.height }, 10),
		text = text,
		size = ui_ctx.font_size,
		color = ui_ctx.border_color,
		align = { .Right, .Center },
	})
	ui_push_command(UI_Draw_Text {
		rec = rec_pad(rec, 10),
		text = text,
		size = ui_ctx.font_size,
		color = ui_ctx.text_color,
		align = { .Right, .Center },	
	})
	return value_changed
}

ui_slider_i32 :: proc
(
	id: UI_ID,
	label: string,
	value: ^i32,
	min, max: i32,
	rec: Rec,
	step: i32 = 1
) -> (
	value_changed: bool,
) {
	value_f32 := math.round(f32(value^))
	value_changed = ui_slider_f32(id, label, &value_f32, f32(min), f32(max), rec, "%.0f", f32(step))
	value^ = i32(value_f32)
	return value_changed
}

ui_push_command :: proc(command: UI_Draw_Command) {
	if ui_ctx.current_popup != "" {
		sa.append(&ui_ctx.open_popup.draw_commands, command)
	}
	else {
		sa.append(&ui_ctx.draw_commands, command)
	}
}

ui_is_being_interacted :: proc() -> (res: bool) {
	return ui_ctx.hovered_widget != 0 ||
	ui_ctx.active_widget != 0 ||
	ui_ctx.hovered_panel != 0 ||
	ui_ctx.active_panel != 0 ||
	(ui_ctx.open_popup.name != "")
}

ui_is_mouse_in_rec :: proc(rec: Rec) -> (is_inside: bool) {
	mpos := rl.GetMousePosition()
	return mpos.x > rec.x && mpos.y > rec.y && mpos.x < rec.x + rec.width && mpos.y < rec.y + rec.height
}
