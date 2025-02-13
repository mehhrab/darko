/* immediate mode ui library
currently depends on app (main.odin) for some draw commands */
package darko

import rl "vendor:raylib"
import "core:slice"
import "core:strings"
import "core:fmt"
import "core:math"
import "core:c"
import sa "core:container/small_array"
import "core:strconv"
import "core:hash"
import "core:mem"

UI_Ctx :: struct {
	hovered_widget: UI_ID,
	active_widget: UI_ID,
	hovered_panel: UI_ID,
	active_panel: UI_ID,
	active_textbox: UI_ID,
	slider_text_buffer: [32]byte,
	slider_text: strings.Builder,
	draw_commands: Draw_Commands,
	
	// HACK: we can only have one active notif
	current_notif: UI_Notif,
	// current popup scope
	popup_scope: string,
	// HACK: we can only have one active popup
	open_popup: UI_Popup,

	// style:

	scale: f32,
	font: rl.Font,
	font_size: f32,
	roundness: f32,
	text_align: UI_Align,
	default_widget_height: f32,
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

UI_Notif :: struct {
	time: f32,
	text: string,
	style: UI_NOTIF_STYLE,
	draw_commands: Draw_Commands,
}

UI_Menu_Item :: struct {
	id: UI_ID,
	text: string,
	shortcut: string,
}

UI_Option :: struct {
	id: UI_ID,
	text: string,
}

UI_Draw_Command :: union {
	UI_Draw_Rect,
	UI_Draw_Rect_Outline,
	UI_Draw_Text,
	UI_Draw_Gradient_H,
	UI_Draw_Texture,
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
	clip: Rec,
	color: rl.Color,
	align: UI_Align,
}

UI_Draw_Texture :: struct {
	texture: rl.Texture,
	rec: Rec,
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

// styles:

COLOR_BASE_0 :: rl.Color { 20, 23, 37, 255 }
COLOR_BASE_1 :: rl.Color { 48, 52, 70, 255 }
COLOR_BASE_2 :: rl.Color { 65, 69, 89, 255 }
COLOR_BASE_3 :: rl.Color { 81, 87, 109, 255 }
COLOR_BASE_4 :: rl.Color { 115, 121, 148, 255 }
COLOR_ACCENT_0 :: rl.Color{ 176, 131, 240, 255 }
COLOR_ACCENT_1 :: rl.Color { 242, 131, 240, 255 }
COLOR_ERROR_0 :: rl.Color { 255, 101, 125, 255 }
COLOR_TEXT_0 :: rl.Color { 200, 209, 218, 255 }
// transparent colors:
COLOR_ACCENT_0_T0 :: rl.Color { COLOR_ACCENT_0[0], COLOR_ACCENT_0[1], COLOR_ACCENT_0[3], 35 }
COLOR_ACCENT_0_T1 :: rl.Color { COLOR_ACCENT_0[0], COLOR_ACCENT_0[1], COLOR_ACCENT_0[3], 70 }
COLOR_ERROR_0_T1 :: rl.Color { COLOR_ERROR_0[0], COLOR_ERROR_0[1], COLOR_ERROR_0[3], 30 }
COLOR_ERROR_0_T2 :: rl.Color { COLOR_ERROR_0[0], COLOR_ERROR_0[1], COLOR_ERROR_0[3], 70 }

UI_Button_Style :: struct {
	bg_color: rl.Color,
	bg_color_hovered: rl.Color,
	bg_color_active: rl.Color,
	text_color: rl.Color,
	text_align: UI_Align,
	// when zero will default to ui_font_size()
	font_size: f32,
}

UI_BUTTON_STYLE_DEFAULT :: UI_Button_Style {
	bg_color = COLOR_BASE_2,
	bg_color_hovered = COLOR_BASE_3,
	bg_color_active = COLOR_BASE_4,
	text_color = COLOR_TEXT_0,
	text_align = { .Center, .Center },
	font_size = 0,
}

UI_BUTTON_STYLE_TRANSPARENT :: UI_Button_Style {
	bg_color = rl.BLANK,
	bg_color_hovered = COLOR_BASE_3,
	bg_color_active = COLOR_BASE_4,
	text_color = COLOR_TEXT_0,
	text_align = { .Center, .Center },
	font_size = 0,
}

UI_BUTTON_STYLE_ACCENT :: UI_Button_Style {
	bg_color = rl.BLANK,
	bg_color_hovered = COLOR_ACCENT_0_T0,
	bg_color_active = COLOR_ACCENT_0_T1,
	text_color = COLOR_ACCENT_0,
	text_align = { .Center, .Center },
	font_size = 0,
}

UI_BUTTON_STYLE_RED :: UI_Button_Style {
	bg_color = rl.BLANK,
	bg_color_hovered = COLOR_ERROR_0_T1,
	bg_color_active = COLOR_ERROR_0_T2,
	text_color = COLOR_ERROR_0,
	text_align = { .Center, .Center },
	font_size = 0,
}

UI_SLIDER_STYLE :: struct {
	bg_color: rl.Color,
	progress_color: rl.Color,
	text_color: rl.Color,
	// when zero will default to ui_font_size()
	font_size: f32,
}

UI_SLIDER_STYLE_DEFAULT :: UI_SLIDER_STYLE {
	bg_color = COLOR_BASE_0,
	progress_color = COLOR_BASE_2,
	text_color = COLOR_TEXT_0,
	font_size = 0,
}

UI_CHECKBOX_STYLE :: struct {
	bg_color: rl.Color,
	check_color: rl.Color,
	text_color: rl.Color,
	// when zero will default to ui_font_size()
	font_size: f32,
}

UI_CHECKBOX_STYLE_DEFAULT :: UI_CHECKBOX_STYLE {
	bg_color = COLOR_BASE_0,
	check_color = COLOR_ACCENT_0,
	text_color = COLOR_TEXT_0,
	font_size = 0,
}

UI_Option_Style :: struct {
	option_style: UI_Button_Style,
	selected_option_style: UI_Button_Style,
}

UI_OPTION_STYLE_DEFAULT :: UI_Option_Style {
	option_style = UI_BUTTON_STYLE_TRANSPARENT,
	selected_option_style = UI_BUTTON_STYLE_ACCENT,
}

UI_NOTIF_STYLE :: struct {
	bg_color: rl.Color,
	text_color: rl.Color,
	// when zero will default to ui_font_size()
	font_size: f32,	
}

UI_NOTIF_STYLE_ACCENT :: UI_NOTIF_STYLE {
	bg_color = COLOR_ACCENT_0,
	text_color = COLOR_BASE_0,
	font_size = 0,
}

UI_NOTIF_STYLE_ERROR :: UI_NOTIF_STYLE {
	bg_color = COLOR_ERROR_0,
	text_color = COLOR_BASE_0,
	font_size = 0,
}

UI_PANEL_STYLE :: struct {
	bg_color: rl.Color,
}

UI_PANEL_STYLE_DEFAULT :: UI_PANEL_STYLE {
	bg_color = COLOR_BASE_1,
}

// icons:

ICON_PEN :: "\uf8ea"
ICON_ERASER :: "\uf6fd"
ICON_EYEDROPPER :: "\uf709"
ICON_TRASH :: "\uf6bf"
ICON_UP :: "\ufc35"
ICON_DOWN :: "\ufc2c"
ICON_COPY :: "\uf68e"
ICON_SETTINGS :: "\uf992"
ICON_X :: "\uf655" 
ICON_CHECK :: "\uf62b"

ui_ctx: UI_Ctx

ui_init_ctx :: proc() {	
	ui_ctx.slider_text = strings.builder_from_bytes(ui_ctx.slider_text_buffer[:])
	ui_ctx.scale = 1
	ui_ctx.font_size = 18 

	ui_load_font(i32(ui_font_size() * 2))
	
	ui_ctx.text_align = { .Center, .Center }
	ui_ctx.default_widget_height = 32
}

ui_deinit_ctx :: proc() {
	rl.UnloadFont(ui_ctx.font)
}

ui_load_font :: proc(size: i32) {
	CHARS :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789… ~!@#$%^&*()-|\"':;_+={}[]\\/`,.<>?"
	ICONS :: ICON_PEN + 
	ICON_ERASER +
	ICON_EYEDROPPER + 
	ICON_TRASH + 
	ICON_UP + 
	ICON_DOWN + 
	ICON_COPY +
	ICON_SETTINGS +
	ICON_X +
	ICON_CHECK
	
	code_point_count: i32
	code_points := rl.LoadCodepoints(CHARS + ICONS, &code_point_count)

	font_data := #load("../res/Hack Bold Nerd Font Complete.ttf")
	ui_ctx.font = rl.LoadFontFromMemory(
		".ttf", 
		raw_data(font_data), 
		i32(len(font_data)), 
		i32(size), 
		code_points,
		code_point_count)
	rl.SetTextureFilter(ui_ctx.font.texture, .BILINEAR)
}

ui_begin :: proc() {
	if ui_is_any_popup_open() &&
		rl.IsMouseButtonReleased(.LEFT) &&
		ui_is_mouse_in_rec(ui_ctx.open_popup.rec) == false &&
		ui_ctx.active_widget == 0 &&
		ui_ctx.active_panel == 0 {
		ui_close_current_popup()
	}
	if ui_is_any_popup_open() {
		ui_ctx.open_popup.open_time += 0.01
	}
	if ui_ctx.current_notif.text != "" {
		ui_ctx.current_notif.time += 0.01
	}

	if rl.IsMouseButtonReleased(.LEFT) || rl.IsMouseButtonReleased(.RIGHT) {
		ui_ctx.active_textbox = 0
	}
	
	ui_ctx.hovered_widget = 0
}

ui_end :: proc() {
	if rl.IsMouseButtonReleased(.LEFT) || rl.IsMouseButtonReleased(.RIGHT) {
		ui_ctx.active_widget = 0
		ui_ctx.active_panel = 0
	}

	ui_draw_notif()
}

ui_gen_id :: proc(i := 0, loc := #caller_location) -> UI_ID {
    text := fmt.aprintfln("{}{}{}", i, loc.procedure, loc.line, allocator = context.temp_allocator)
    id := hash.fnv32(mem.byte_slice(raw_data(text), len(text)))
    return id
}

ui_get_draw_commmands :: proc() -> (commands: []UI_Draw_Command) {
	dc := ui_ctx.draw_commands
	pdc := ui_ctx.open_popup.draw_commands
	ndc := ui_ctx.current_notif.draw_commands
	res, err := make_slice([]UI_Draw_Command, dc.len + pdc.len + ndc.len, context.temp_allocator)
	for i in 0..<dc.len {
		res[i] = dc.data[:][i]
	}
	for i in 0..<pdc.len {
		res[dc.len + i] = pdc.data[:][i]
	}
	for i in 0..<ndc.len {
		res[dc.len + pdc.len + i] = ndc.data[:][i]
	}
	return res 
}

ui_clear_temp_state :: proc() {
	sa.clear(&ui_ctx.draw_commands)
	sa.clear(&ui_ctx.open_popup.draw_commands)
	sa.clear(&ui_ctx.current_notif.draw_commands)
}

ui_draw_notif :: proc() {
	if ui_ctx.current_notif.text != "" {
		ww := f32(rl.GetScreenWidth())
		wh := f32(rl.GetScreenHeight())

		style := ui_ctx.current_notif.style
		text := strings.clone_to_cstring(ui_ctx.current_notif.text, context.temp_allocator)
		font_size := style.font_size == 0 ? ui_font_size() : style.font_size
		offset := ui_px(80)
		padding := ui_px(10)
		text_size := rl.MeasureTextEx(ui_ctx.font, text, font_size, 0)
		notif_w := text_size.x + padding * 2
		notif_h := text_size.y + padding * 2
		notif_x := ww / 2 - text_size.x / 2 + padding
		notif_y := f32(0)
		
		if ui_ctx.current_notif.time < 0.2 {
			notif_y = wh - offset * (ui_ctx.current_notif.time / 0.2)
		}
		else if ui_ctx.current_notif.time >= 0.2 && ui_ctx.current_notif.time < 1 {
			notif_y = wh - offset
		} 
		else if ui_ctx.current_notif.time >= 1 && ui_ctx.current_notif.time <= 1.2 {
			notif_y = wh - offset + offset * (ui_ctx.current_notif.time - 1) / 0.2
		}
		else {
			ui_ctx.current_notif.text = ""
		}
		if ui_ctx.current_notif.text != "" {
			notif_y += padding
			sa.append(&ui_ctx.current_notif.draw_commands, UI_Draw_Rect {
				color = style.bg_color,
				rec = { notif_x, notif_y, notif_w, notif_h },
			})
			sa.append(&ui_ctx.current_notif.draw_commands, UI_Draw_Text {
				align = { .Center, .Center },
				color = style.text_color,
				rec = { notif_x, notif_y, notif_w, notif_h },
				size = font_size,
				text = ui_ctx.current_notif.text,
			})
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
	sa.clear(&ui_ctx.open_popup.draw_commands)
}

// NOTE: name is also used as the id
ui_begin_popup :: proc(name: string, rec: Rec) -> (open: bool) {
	ui_ctx.popup_scope = name

	if name == ui_ctx.open_popup.name {
		ui_push_popup_draw()
		ui_ctx.open_popup.rec = rec
	}
	 
	return name == ui_ctx.open_popup.name
}

ui_begin_popup_title :: proc(id: UI_ID, name: string, rec: Rec) -> (open: bool, content_rec: Rec) {
	ui_ctx.popup_scope = name

	if name == ui_ctx.open_popup.name {
		ui_push_popup_draw()
		ui_ctx.open_popup.show_header = true
		area := rec
		header_area := rec_extend_top(&area, ui_default_widget_height() + ui_px(8)) 
		ui_ctx.open_popup.rec = area
		x_rec := rec_pad(rec_take_right(&header_area, header_area.height), ui_px(8))
		style := UI_BUTTON_STYLE_TRANSPARENT
		style.text_color = COLOR_BASE_0
		if ui_button(id, ICON_X, x_rec, style = style) {
			ui_close_current_popup()
		}
	}
	return name == ui_ctx.open_popup.name, { rec.x, rec.y, rec.width, rec.height }
}

ui_push_popup_draw :: proc() {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
	opacity := ui_ctx.open_popup.open_time * 40 * 8
	if opacity >= 40 {
		opacity = 40
	}
	sa.inject_at(&ui_ctx.open_popup.draw_commands, UI_Draw_Rect {
		color =  { 0, 0, 0, u8((opacity / 255) * 255) },
		rec = screen_rec,
	}, 0)
	sa.inject_at(&ui_ctx.open_popup.draw_commands, UI_Draw_Rect {
		color = COLOR_BASE_0,
		rec = rec_pad(ui_ctx.open_popup.rec, -1),
	}, 1)
	sa.inject_at(&ui_ctx.open_popup.draw_commands, UI_Draw_Rect {
		color = COLOR_BASE_0,
		rec = rec_pad(ui_ctx.open_popup.rec, -1),
	}, 2)
	sa.inject_at(&ui_ctx.open_popup.draw_commands, UI_Draw_Rect {
		color = COLOR_BASE_1,
		rec = ui_ctx.open_popup.rec,
	}, 3)
	if ui_ctx.open_popup.show_header {
		header_height := ui_default_widget_height() + ui_px(8)
		sa.inject_at(&ui_ctx.open_popup.draw_commands, UI_Draw_Gradient_H {
			right_color = COLOR_ACCENT_0,
			left_color = COLOR_ACCENT_1,
			rec = { ui_ctx.open_popup.rec.x, ui_ctx.open_popup.rec.y, ui_ctx.open_popup.rec.width, header_height },
		}, 4)
		sa.inject_at(&ui_ctx.open_popup.draw_commands, UI_Draw_Text {
			color = COLOR_BASE_0,
			rec = { ui_ctx.open_popup.rec.x, ui_ctx.open_popup.rec.y, ui_ctx.open_popup.rec.width, header_height },
			text = ui_ctx.open_popup.name,
			align = { .Center, .Center },
			size = ui_font_size(),
		}, 5)
	}
}

ui_end_popup :: proc() {
	ui_ctx.popup_scope = ""
}

ui_show_notif :: proc(text: string, style := UI_NOTIF_STYLE_ACCENT) {
	ui_ctx.current_notif = {
		text = text,
		time = 0,
		style = style,
	}
}

ui_update_widget :: proc(id: UI_ID, rec: Rec, blocking := true) {
	if ui_ctx.open_popup.name != ui_ctx.popup_scope && ui_is_any_popup_open() {
		return
	}
	hovered := ui_is_mouse_in_rec(rec)
	if hovered && (blocking == false || (ui_ctx.active_widget == 0 || ui_ctx.active_widget == id)) {
		ui_ctx.hovered_widget = id
		if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) {
			ui_ctx.active_widget = id
		}
	}
	else if ui_ctx.hovered_widget == id {
		ui_ctx.hovered_widget = 0
	}
}

ui_update_panel :: proc(id: UI_ID, rec: Rec) {
	if ui_ctx.open_popup.name != ui_ctx.popup_scope && ui_is_any_popup_open() {
		return
	}
	hovered := ui_is_mouse_in_rec(rec)
	if hovered && (ui_ctx.active_panel == 0 || ui_ctx.active_panel == id) {
		ui_ctx.hovered_panel = id
		if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) {
			ui_ctx.active_panel = id
		}
	}
	else if ui_ctx.hovered_panel == id {
		ui_ctx.hovered_panel = 0
	}
}

ui_panel :: proc(id: UI_ID, rec: Rec, style := UI_PANEL_STYLE_DEFAULT) {
	ui_update_panel(id, rec)
	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = style.bg_color,
	})
}

ui_calc_button_width :: proc(text: string) -> (w: f32) {
	padding := ui_px(10) * 2
	text_cstring := strings.clone_to_cstring(text, context.temp_allocator)
	return rl.MeasureTextEx(ui_ctx.font, text_cstring, ui_font_size(), 0)[0] + padding
}

ui_button :: proc(id: UI_ID, text: string, rec: Rec, blocking := true, style := UI_BUTTON_STYLE_DEFAULT) -> (clicked: bool) {	
	clicked = false
	ui_update_widget(id, rec, blocking)
	if ui_ctx.hovered_widget == id && ui_ctx.active_widget == id && rl.IsMouseButtonReleased(.LEFT){
		clicked = true
	}
	font_size := style.font_size == 0 ? ui_font_size() : style.font_size
	color := style.bg_color
	if ui_ctx.active_widget == id {
		color = style.bg_color_active
	}
	else if ui_ctx.hovered_widget == id {
		color = style.bg_color_hovered
	}
	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = color
	})
	ui_push_command(UI_Draw_Text {
		rec = rec_pad(rec, 10),
		clip = rec,
		text = text,
		size = font_size,
		color = style.text_color,
		align = style.text_align,
	})
	return clicked
}

ui_menu_button :: proc(id: UI_ID, text: string, items: []UI_Menu_Item, item_width: f32, rec: Rec) -> (clicked_item: UI_Menu_Item) {	
	clicked_item = {}

	item_width := item_width * ui_ctx.scale

	ui_update_widget(id, rec)
	if ui_ctx.hovered_widget == id && ui_ctx.active_widget == id && rl.IsMouseButtonReleased(.LEFT) {
		ui_open_popup(text)	
	}

	padding := ui_px(10)
	item_height := ui_default_widget_height()
	popup_rec: Rec
	// try to keep popup rec inside the screen
	if rec.x - padding - item_width < 0 {
		popup_rec = { 
			rec.x + padding, 
			rec.y + rec.height + padding, 
			item_width, 
			item_height * f32(len(items)) 
		}
	}
	else if rec.x + padding + item_width > f32(rl.GetScreenWidth()) {
		popup_rec = { 
			rec.x + rec.width - item_width - padding, 
			rec.y + rec.height + padding, 
			item_width, 
			item_height * f32(len(items))
		}
	}

	if ui_begin_popup(text, popup_rec) {
		// HACK, TODO: add an option for disabling popup backaground
		ui_ctx.open_popup.open_time = 0

		menu_item_y := popup_rec.y
		style := UI_BUTTON_STYLE_DEFAULT
		style.font_size = ui_font_size()
		style.text_align = { .Left, .Center }
		for item, i in items {
			if ui_button(item.id, item.text, { popup_rec.x, menu_item_y, item_width, item_height }, style = style) {
				clicked_item = item
			}
			menu_item_y += item_height
		}
	}
	ui_end_popup()

	color := COLOR_BASE_2
	if ui_ctx.active_widget == id {
		color = COLOR_BASE_4
	}
	else if ui_ctx.hovered_widget == id {
		color = COLOR_BASE_3
	}
	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = color
	})
	ui_push_command(UI_Draw_Text {
		rec = rec,
		text = text,
		size = ui_font_size(),
		color = COLOR_TEXT_0,
		align = ui_ctx.text_align,	
	})
	return clicked_item
}

ui_path_button :: proc(id: UI_ID, text: string, rec: Rec, blocking := true, style := UI_BUTTON_STYLE_DEFAULT) -> (clicked: bool) {	
	clicked = false
	ui_update_widget(id, rec, blocking)
	if ui_ctx.hovered_widget == id && ui_ctx.active_widget == id && rl.IsMouseButtonReleased(.LEFT){
		clicked = true
	}
	font_size := style.font_size == 0 ? ui_font_size() : style.font_size
	color := style.bg_color
	if ui_ctx.active_widget == id {
		color = style.bg_color_active
	}
	else if ui_ctx.hovered_widget == id {
		color = style.bg_color_hovered
	}
	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = color
	})
	bslash_index := strings.last_index(text, "\\")
	text_cstring := strings.clone_to_cstring(text[:bslash_index + 1], context.temp_allocator)
	path_width := rl.MeasureTextEx(ui_ctx.font, text_cstring, font_size, 0)[0]
	path_color := style.text_color
	path_color.a = 100
	ui_push_command(UI_Draw_Text {
		rec = rec_pad(rec, 10),
		text = text[:bslash_index + 1],
		size = font_size,
		color = path_color,
		align = style.text_align,
	})
	ui_push_command(UI_Draw_Text {
		rec = rec_pad_ex(rec, 10 + f32(path_width), 10, 10, 10),
		text = text[bslash_index + 1:],
		size = font_size,
		color = style.text_color,
		align = style.text_align,
	})
	return clicked
}


ui_check_box :: proc(id: UI_ID, label: string, checked: ^bool, rec: Rec, style := UI_CHECKBOX_STYLE_DEFAULT) {
	font_size := style.font_size == 0 ? ui_font_size() : style.font_size
	check_box_rec := Rec {
		rec.x + rec.width - ui_default_widget_height(),
		rec.y,
		ui_default_widget_height(),
		rec.height,
	}
	ui_update_widget(id, check_box_rec)
	if ui_ctx.hovered_widget == id && ui_ctx.active_widget == id && rl.IsMouseButtonReleased(.LEFT) {
		checked^ = !checked^ 
	}
	ui_push_command(UI_Draw_Rect {
		rec = check_box_rec,
		color = style.bg_color,
	})
	if checked^ {		
		ui_push_command(UI_Draw_Rect {
			rec = rec_pad(check_box_rec, ui_px(8)),
			color = style.check_color,
		})
	}
	ui_push_command(UI_Draw_Text {
		rec = rec,
		align = { .Left, .Center },
		color = style.text_color,
		size = font_size,
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
	style := UI_SLIDER_STYLE_DEFAULT,
) -> (
	value_changed: bool,
) {
	ui_update_widget(id, rec)

	if ui_ctx.active_textbox != id {
		// when right clicked write the value to slider_text_buffer and goto textmode
		if ui_ctx.hovered_widget == id && ui_ctx.active_widget == id && rl.IsMouseButtonReleased(.RIGHT) {
			ui_ctx.active_textbox = id
			strings.builder_reset(&ui_ctx.slider_text)
			strings.write_string(&ui_ctx.slider_text, fmt.tprintf(format, value^))
		}
		else {
			value_changed = ui_slider_behaviour_f32(id, value, min, max, rec, step)
		}
	}
	else {
		// clear textbox if right or left clicked
		if ui_ctx.hovered_widget == id && ui_ctx.active_widget == id && (rl.IsMouseButtonReleased(.RIGHT)) {
			strings.builder_reset(&ui_ctx.slider_text)
			ui_ctx.active_textbox = 0
		}

		// exit text mode when escape key is pressed
		if rl.IsKeyPressed(.ESCAPE) {
			strings.builder_reset(&ui_ctx.slider_text)
			ui_ctx.active_textbox = 0
		}

		// when left clicked and in apply buffer to value pointer
		if ui_ctx.hovered_widget == id && rl.IsMouseButtonReleased(.LEFT) {
			number, ok := strconv.parse_f32(strings.to_string(ui_ctx.slider_text))
			if ok {
				value^ = number
			}
		}

		char := rl.GetCharPressed()
		switch char {
			case '0'..='9', '.': {
				strings.write_byte(&ui_ctx.slider_text, byte(char))
			}
		}
		if rl.IsKeyPressed(.BACKSPACE) {
			if strings.builder_len(ui_ctx.slider_text) > 0 {
				index := strings.builder_len(ui_ctx.slider_text) - 1
				ordered_remove(&ui_ctx.slider_text.buf, index)
			}
		}
		if rl.IsKeyPressedRepeat(.BACKSPACE) {
			if strings.builder_len(ui_ctx.slider_text) > 0 {
				index := strings.builder_len(ui_ctx.slider_text) - 1
				ordered_remove(&ui_ctx.slider_text.buf, index)
			}
		}
		if rl.IsKeyPressed(.ENTER) {
			number, ok := strconv.parse_f32(strings.to_string(ui_ctx.slider_text))
			if ok {
				value^ = number
			}
			strings.builder_reset(&ui_ctx.slider_text)
			ui_ctx.active_textbox = 0
		}
	}

	progress_rec := rec_pad(rec, 1)
	font_size := style.font_size == 0 ? ui_font_size() : style.font_size

	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = style.bg_color,
	})

	if ui_ctx.active_textbox == id {
		// draw textbox
		ui_push_command(UI_Draw_Text {
			align = { .Left, .Center },
			color = style.text_color,
			rec = rec_pad(rec, ui_px(8)),
			size = font_size,
			text = strings.to_string(ui_ctx.slider_text),
		})
		
		ui_push_command(UI_Draw_Rect_Outline {
			color = style.progress_color,
			rec = rec,
			thickness = 1,
		})
	}
	else {
		// draw slider
		progress_width := (value^ - min) * (progress_rec.width) / (max - min)
		progress_rec.width = progress_width
		ui_push_command(UI_Draw_Rect {
			rec = progress_rec,
			color = style.progress_color,	
		})
		
		ui_push_command(UI_Draw_Text {
			rec = rec_pad(rec, 10),
			text = label,
			size = font_size,
			color = style.text_color,
			align = { .Left, .Center },	
		})
		text := fmt.aprintf(format, value^, allocator = context.temp_allocator)
		ui_push_command(UI_Draw_Text {
			rec = rec_pad({ rec.x + 2, rec.y + 2, rec.width, rec.height }, 10),
			text = text,
			size = font_size,
			color = style.bg_color,
			align = { .Right, .Center },
		})
		ui_push_command(UI_Draw_Text {
			rec = rec_pad(rec, 10),
			text = text,
			size = font_size,
			color = style.text_color,
			align = { .Right, .Center },	
		})
	}
	return value_changed
}

ui_slider_i32 :: proc
(
	id: UI_ID,
	label: string,
	value: ^i32,
	min, max: i32,
	rec: Rec,
	step: i32 = 1,
	style := UI_SLIDER_STYLE_DEFAULT,
) -> (
	value_changed: bool,
) {
	value_f32 := math.round(f32(value^))
	value_changed = ui_slider_f32(id, label, &value_f32, f32(min), f32(max), rec, "%.0f", f32(step), style)
	value^ = i32(value_f32)
	return value_changed
}

ui_option :: proc(id: UI_ID, items: []UI_Option, selceted: ^int, rec: Rec, style := UI_OPTION_STYLE_DEFAULT) {
	item_w := rec.width / f32(len(items))
	for item, i in items {
		item_rec := Rec { rec.x + f32(i) * item_w, rec.y, item_w, rec.height }
		button_style := i == selceted^ ? style.selected_option_style : style.option_style
		if ui_button(item.id, item.text, item_rec, style = button_style) {
			selceted^ = i
		}
	}
}

ui_push_command :: proc(command: UI_Draw_Command) {
	if ui_ctx.popup_scope != "" {
		sa.append(&ui_ctx.open_popup.draw_commands, command)
	}
	else {
		sa.append(&ui_ctx.draw_commands, command)
	}
}

ui_is_being_interacted :: #force_inline proc() -> (res: bool) {
	return ui_ctx.hovered_widget != 0 ||
	ui_ctx.active_widget != 0 ||
	ui_ctx.hovered_panel != 0 ||
	ui_ctx.active_panel != 0 ||
	(ui_is_any_popup_open())
}

ui_is_mouse_in_rec :: proc(rec: Rec) -> (is_inside: bool) {
	mpos := rl.GetMousePosition()
	return mpos.x > rec.x && mpos.y > rec.y && mpos.x < rec.x + rec.width && mpos.y < rec.y + rec.height
}

ui_calc_popup_height :: proc(item_count: i32, item_h, seprator_h, padding: f32) -> (height: f32) {
	return item_h * f32(item_count) + seprator_h * (f32(item_count) - 1) + padding * 2 
}

ui_is_any_popup_open :: #force_inline proc() -> (res: bool) {
	return ui_ctx.open_popup.name != ""
}

// not sure if px is the right name...
// returns v multiplied by ui scale 
ui_px :: #force_inline proc(v: f32) -> (px: f32) {
	return v * ui_ctx.scale
}

// returns default widget height multiplied by ui scale 
ui_default_widget_height :: #force_inline proc() -> (height: f32) {
	return ui_px(ui_ctx.default_widget_height)
}

// returns font size multiplied by ui scale 
ui_font_size :: #force_inline proc() -> (size: f32) {
	return ui_px(ui_ctx.font_size)
}

ui_set_scale :: proc(scale: f32) {
	if scale <= 0 {
		return
	}
	ui_ctx.scale = scale
	ui_load_font(i32(ui_font_size() * 2))
}