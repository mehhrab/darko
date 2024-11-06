package darko

import rl "vendor:raylib"
import "core:slice"
import "core:strings"
import "core:fmt"
import "core:math"

UI_Ctx :: struct {
	hovered_widget: UI_ID,
	active_widget: UI_ID,
	hovered_panel: UI_ID,
	active_panel: UI_ID,
	draw_commands: [dynamic]UI_Draw_Command,
	notif_text: string,
	notif_time: f32,	
	
	// HACK: we can only have on popup
	
	opened_popup: string,
	current_popup: string,
	popup: UI_Popup,
	popup_time: f32,

	// style:

	font: rl.Font,
	font_size: f32,
	roundness: f32,
	header_height: f32,

	text_color: rl.Color,
	panel_color: rl.Color,
	widget_color: rl.Color,
	accent_color: rl.Color,
	border_color: rl.Color,
	widget_hover_color: rl.Color,
	widget_active_color: rl.Color,
}

UI_ID :: u32

UI_Popup :: struct {
	name: string,
	rec: Rec,
	draw_commands: [dynamic]UI_Draw_Command,
	show_header: bool,
}

UI_Draw_Command :: union {
	UI_Draw_Rect,
	UI_Draw_Rect_Outline,
	UI_Draw_Text,
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
	rec: Rec,
	color: rl.Color,
}

// darko specific commands:

UI_Draw_Canvas :: struct {
	rec: Rec,
}

// TODO: add more options
UI_Draw_Grid :: struct {
	rec: Rec,
}

UI_Draw_Preview :: struct {
	rec: Rec,
}

ui_ctx: UI_Ctx

ui_init_ctx :: proc() {
	ui_ctx.draw_commands = make([dynamic]UI_Draw_Command)

	ui_ctx.font = rl.LoadFontEx("../assets/HackNerdFont-Bold.ttf", 32, nil, 0)
	rl.SetTextureFilter(ui_ctx.font.texture, .BILINEAR)
	ui_ctx.font_size = 20
	ui_ctx.header_height = 30

	ui_ctx.text_color = { 198, 208, 245, 255 }
	ui_ctx.panel_color = { 41, 44, 60, 255 }
	ui_ctx.widget_color = { 65, 69, 89, 255 }
	ui_ctx.accent_color = { 202, 158, 230, 255 }
	ui_ctx.border_color = { 10, 15, 10, 255 }
	ui_ctx.widget_hover_color = { 115, 121, 148, 255 }
	ui_ctx.widget_active_color = { 131, 139, 167, 255 }
}

ui_deinit_ctx :: proc() {
	rl.UnloadFont(ui_ctx.font)
	delete(ui_ctx.draw_commands)
	delete(ui_ctx.popup.draw_commands)
}

ui_begin :: proc() {
	if ui_ctx.opened_popup != "" &&
		rl.IsMouseButtonReleased(.LEFT) &&
		ui_is_mouse_in_rec(ui_ctx.popup.rec) == false &&
		ui_ctx.active_widget == 0 &&
		ui_ctx.active_panel == 0 {
		ui_ctx.opened_popup = ""
	}
	if ui_ctx.opened_popup != "" {
		ui_ctx.popup_time += rl.GetFrameTime()
	}
	if ui_ctx.notif_text != "" {
		ui_ctx.notif_time += rl.GetFrameTime()
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
	ui_process_commands(&ui_ctx.draw_commands)

	if ui_ctx.opened_popup != "" {
		screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
		opacity := ui_ctx.popup_time * 150 * 5
		if opacity >= 150 {
			opacity = 150
		}
		rl.DrawRectangleRec(screen_rec, { 0, 0, 0, u8((opacity / 255) * 255) })
		ui_process_commands(&ui_ctx.popup.draw_commands)
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

	clear(&ui_ctx.draw_commands)
	clear(&ui_ctx.popup.draw_commands)
	free_all(context.temp_allocator)
}

// TODO: should be handled in app
ui_process_commands :: proc(commands: ^[dynamic]UI_Draw_Command) {
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
				text := strings.clone_to_cstring(kind.text, context.temp_allocator)
				x, y := rec_get_center_point(kind.rec)
				text_size := rl.MeasureTextEx(ui_ctx.font, text, ui_ctx.font_size, 0)
				x -= text_size.x / 2
				y -= text_size.y / 2
				rl.DrawTextEx(ui_ctx.font, text, {x, y}, ui_ctx.font_size, 0, kind.color)
			}
			case UI_Draw_Canvas: {
				draw_canvas(kind.rec)
			}
			case UI_Draw_Grid: {
				draw_grid(kind.rec)
			}
			case UI_Draw_Preview: {
				rl.DrawRectangleRec(kind.rec, ui_ctx.text_color)
				x, y := rec_get_center_point(kind.rec)
				draw_sprite_stack(&app.project.layers, x, y, 10)
			}
		}
	}
}

ui_open_popup :: proc(name: string) {
	ui_ctx.opened_popup = name
	ui_ctx.hovered_widget = 0
	ui_ctx.active_widget = 0
	ui_ctx.popup_time = 0
}

ui_close_current_popup :: proc() {
	ui_ctx.hovered_widget = 0
	ui_ctx.active_widget = 0
	ui_ctx.opened_popup = ""
	ui_ctx.popup.rec = {}
	ui_ctx.popup.show_header = false
}

// NOTE: name is also used as the id
ui_begin_popup :: proc(name: string, rec: Rec) -> (open: bool) {
	ui_ctx.current_popup = name
	ui_ctx.popup.rec = rec
	 
	return name == ui_ctx.opened_popup
}

ui_begin_popup_with_header :: proc(name: string, rec: Rec) -> (open: bool, client_rec: Rec) {
	ui_ctx.current_popup = name
	ui_ctx.popup.rec =  { rec.x, rec.y - ui_ctx.header_height, rec.width, rec.height + ui_ctx.header_height }
	ui_ctx.popup.show_header = true
	return name == ui_ctx.opened_popup, { rec.x, rec.y, rec.width, rec.height + ui_ctx.header_height }
}

ui_end_popup :: proc() {
	inject_at(&ui_ctx.popup.draw_commands, 0, UI_Draw_Rect {
		color = ui_ctx.panel_color,
		rec = ui_ctx.popup.rec,
	})
	if ui_ctx.popup.show_header {
		inject_at(&ui_ctx.popup.draw_commands, 1, UI_Draw_Rect {
			color = ui_ctx.accent_color,
			rec = { ui_ctx.popup.rec.x, ui_ctx.popup.rec.y, ui_ctx.popup.rec.width, ui_ctx.header_height },
		})
		inject_at(&ui_ctx.popup.draw_commands, 2, UI_Draw_Text {
			color = ui_ctx.border_color,
			rec = { ui_ctx.popup.rec.x, ui_ctx.popup.rec.y, ui_ctx.popup.rec.width, ui_ctx.header_height },
			text = ui_ctx.opened_popup
		})
	}
	ui_ctx.current_popup = ""
}

ui_show_notif :: proc(text: string) {
	ui_ctx.notif_text = text
	ui_ctx.notif_time = 0
}

ui_update_widget :: proc(id: UI_ID, rec: Rec) {
	if ui_ctx.opened_popup != ui_ctx.current_popup && ui_ctx.opened_popup != "" {
		return
	}
	hovered := ui_is_mouse_in_rec(rec)
	if hovered && (ui_ctx.active_widget == 0 || ui_ctx.active_widget == id) {
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
	if ui_ctx.opened_popup != ui_ctx.current_popup && ui_ctx.opened_popup != "" {
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

ui_button :: proc(id: UI_ID, text: string, rec: Rec) -> (clicked: bool) {	
	clicked = false
	ui_update_widget(id, rec)
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
		rec = rec,
		text = text,
		color = ui_ctx.text_color,
	})
	return clicked
}

ui_slider_f32 :: proc(id: UI_ID, value: ^f32, min, max: f32, rec: Rec, format: string = "%.2f", step: f32 = 0) {
	last_value := value^
	ui_update_widget(id, rec)

	progress_rec := rec_pad(rec, 2)
	if ui_ctx.active_widget == id && rl.IsMouseButtonDown(.LEFT) {
		last_value = min + (rl.GetMousePosition().x - progress_rec.x) * (max - min) / progress_rec.width
		if step != 0 {
			last_value = (math.round(last_value / step)) * step
		}
	}
	
	last_value = math.clamp(last_value, min, max)
	value^ = last_value

	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color =  { 24, 25, 38, 255 },
	})
	// ui_push_command(UI_Draw_Rect_Outline {
	// 	rec = rec,
	// 	color =  ui_ctx.border_color,
	// 	thickness = 1,
	// })
	progress_width := (last_value - min) * (progress_rec.width) / (max - min)
	progress_rec.width = progress_width
	ui_push_command(UI_Draw_Rect {
		rec = progress_rec,
		color = ui_ctx.widget_color,	
	})
	
	text := fmt.aprintf(format, last_value, allocator = context.temp_allocator)
	ui_push_command(UI_Draw_Text {
		rec = rec,
		text = text,
		color = ui_ctx.text_color,
	})
}

ui_slider_i32 :: proc(id: UI_ID, value: ^i32, min, max: i32, rec: Rec, step: i32 = 1) {
	value_f32 := math.round(f32(value^))
	ui_slider_f32(id, &value_f32, f32(min), f32(max), rec, "%.0f", f32(step))
	value^ = i32(value_f32)
}

ui_push_command :: proc(command: UI_Draw_Command) {
	if ui_ctx.current_popup != "" {
		append(&ui_ctx.popup.draw_commands, command)
	}
	else {
		append(&ui_ctx.draw_commands, command)
	}
}

ui_is_being_interacted :: proc() -> (res: bool) {
	return ui_ctx.hovered_widget != 0 ||
	ui_ctx.active_widget != 0 ||
	ui_ctx.hovered_panel != 0 ||
	ui_ctx.active_panel != 0 ||
	(ui_ctx.opened_popup != "")
}

ui_is_mouse_in_rec :: proc(rec: Rec) -> (is_inside: bool) {
	mpos := rl.GetMousePosition()
	return mpos.x > rec.x && mpos.y > rec.y && mpos.x < rec.x + rec.width && mpos.y < rec.y + rec.height
}
