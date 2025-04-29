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
	text_mode_slider: UI_ID,
	slider_text_buffer: [32]byte,
	slider_text: strings.Builder,
	slider_caret_x: i32,
	draw_commands: Draw_Commands,
	clip_stack: sa.Small_Array(16, Rec),

	popup_scope: UI_ID,
	open_popups: sa.Small_Array(8, UI_Popup),
	// HACK: we can only have one active notif
	current_notif: UI_Notif,

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
	id: UI_ID,
	name: string,
	show_header: bool,
	darker_window: bool,
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
	separator: bool,
	toggled: Maybe(bool),
}

UI_Option :: struct {
	id: UI_ID,
	text: string,
}

UI_List_Item :: struct {
	i: int,
	rec: Rec,
}

UI_Draw_Command :: union {
	UI_Draw_Rect,
	UI_Draw_Rect_Outline,
	UI_Draw_Text,
	UI_Draw_Gradient_H,
	UI_Draw_Gradient_V,
	UI_Clip,
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

UI_Draw_Gradient_V :: struct {
	top_color: rl.Color,
	bottom_color: rl.Color,
	rec: Rec,
}

UI_Clip :: struct {
	rec: Rec,
}

// darko specific commands:

UI_Draw_Canvas :: struct {
	rec: Rec,
}

UI_Draw_Grid :: struct {
	rec: Rec,
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

UI_Toggle_Style :: struct {
	bg_color: rl.Color,
	toggled_bg_color: rl.Color,
	bg_color_hovered: rl.Color,
	toggled_bg_color_hovered: rl.Color,
	text_color: rl.Color,
	toggled_text_color: rl.Color,
	text_align: UI_Align,
	// when zero will default to ui_font_size()
	font_size: f32,
}

UI_TOGGLE_STYLE_DEFAULT :: UI_Toggle_Style {
	bg_color = COLOR_BASE_2,
	toggled_bg_color = COLOR_ACCENT_0,
	bg_color_hovered = COLOR_BASE_3,
	toggled_bg_color_hovered = COLOR_ACCENT_1,
	text_color = COLOR_TEXT_0,
	toggled_text_color = COLOR_BASE_0,
	text_align = { .Center, .Center },
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
ICON_STAR :: "\uf9cd"
ICON_HAND :: "\uf7c6"
ICON_EYE :: "\ufbce"
ICON_EYE_OFF :: "\ufbcf"


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
	ICON_CHECK +
	ICON_STAR +
	ICON_HAND +
	ICON_EYE +
	ICON_EYE_OFF
	
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
	top_popup := ui_get_top_popup()
	mouse_in_top_popup := top_popup != nil && ui_is_mouse_in_rec(top_popup.rec)
	if ui_is_any_popup_open() &&
		rl.IsMouseButtonReleased(.LEFT) &&
		mouse_in_top_popup == false &&
		ui_ctx.active_widget == 0 &&
		ui_ctx.active_panel == 0 {
		ui_close_current_popup()
	}

	if ui_ctx.current_notif.text != "" {
		ui_ctx.current_notif.time += 0.01
	}

	if ui_ctx.text_mode_slider != ui_ctx.hovered_widget && rl.IsMouseButtonReleased(.LEFT) || rl.IsMouseButtonReleased(.RIGHT) {
		ui_ctx.text_mode_slider = 0
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

// this is ugly but gets the job done.
ui_get_draw_commmands :: proc() -> (commands: []UI_Draw_Command) {
	len := ui_ctx.draw_commands.len + ui_ctx.current_notif.draw_commands.len 
	popup_with_darker_window := -1
	for i in 0..<ui_ctx.open_popups.len {
		if ui_ctx.open_popups.data[i].darker_window {
			popup_with_darker_window = i
		}
	}
	if popup_with_darker_window != -1 {
		len += 1
	}
	for i in 0..<ui_ctx.open_popups.len {
		len += ui_ctx.open_popups.data[i].draw_commands.len
	}
	
	commands = make_slice([]UI_Draw_Command, len, context.temp_allocator)
	
	append_draw_commands :: proc(host: ^[]UI_Draw_Command, commands: ^Draw_Commands, index: ^int) {
		for i in 0..<commands.len {
			host[index^ + i] = commands.data[i] 
		}
		index^ += commands.len
	}

	index := 0
	append_draw_commands(&commands, &ui_ctx.draw_commands, &index)
	for i in 0..<ui_ctx.open_popups.len {
		if popup_with_darker_window == i {
			commands[index] = UI_Draw_Rect {
				color = { 0, 0, 0, 100 },
				rec = { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) },
			}
			index += 1
		}
		append_draw_commands(&commands, &ui_ctx.open_popups.data[i].draw_commands, &index)
	}
	append_draw_commands(&commands, &ui_ctx.current_notif.draw_commands, &index)
	
	return commands
}

ui_clear_temp_state :: proc() {
	sa.clear(&ui_ctx.draw_commands)
	for i in 0..<ui_ctx.open_popups.len {
		sa.clear(&ui_ctx.open_popups.data[i].draw_commands)
	}
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

ui_open_popup :: proc(id: UI_ID, darker_window := true) {
	// if the popup already exists, remove it
	for i in 0..<ui_ctx.open_popups.len {
		if ui_ctx.open_popups.data[i].id == id {
			sa.ordered_remove(&ui_ctx.open_popups, i)
			break
		}
	}

	popup := UI_Popup {
		id = id,
		darker_window = darker_window,
	}
	sa.append(&ui_ctx.open_popups, popup)
	ui_ctx.hovered_widget = 0
	ui_ctx.active_widget = 0
}

ui_close_current_popup :: proc() {
	ui_ctx.hovered_widget = 0
	ui_ctx.active_widget = 0
	ui_ctx.hovered_panel = 0
	ui_ctx.active_panel = 0
	last_index := ui_ctx.open_popups.len - 1
	if last_index >= 0 {
		sa.ordered_remove(&ui_ctx.open_popups, last_index)
	}
}

ui_close_all_popups :: proc() {
	popups_len := ui_ctx.open_popups.len
	for i in 0..<popups_len {
		ui_close_current_popup()
	}
}

// TODO: return opened popup
ui_begin_popup :: proc(id: UI_ID, rec: Rec) -> (open: bool) {
	ui_ctx.popup_scope = id
	popup := ui_find_popup(id)
	if popup != nil && id == popup.id {
		ui_push_popup_draw(popup)
		popup.rec = rec
	}
	 
	return popup != nil && id == popup.id
}

// TODO: return opened popup
// TODO: popups with titles aren't correctly centered on the y axis
ui_begin_popup_title :: proc(id: UI_ID, name: string, rec: Rec) -> (open: bool, content_rec: Rec) {
	ui_ctx.popup_scope = id
	popup := ui_find_popup(id)
	if popup != nil && id == popup.id {
		popup.show_header = true
		popup.name = name
		area := rec
		header_area := rec_extend_top(&area, ui_default_widget_height() + ui_px(8)) 
		popup.rec = area
		close_rec := rec_pad(rec_take_right(&header_area, header_area.height), ui_px(8))
		style := UI_BUTTON_STYLE_TRANSPARENT
		style.text_color = COLOR_BASE_0
		if ui_button(id, ICON_X, close_rec, style = style) {
			ui_close_current_popup()
		}
		ui_push_popup_draw(popup)
	}
	return popup != nil && id == popup.id, { rec.x, rec.y, rec.width, rec.height }
}

ui_push_popup_draw :: proc(popup: ^UI_Popup) {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }

	// outline
	sa.inject_at(&popup.draw_commands, UI_Draw_Rect {
		color = COLOR_BASE_0,
		rec = rec_pad(popup.rec, -1),
	}, 0)
	
	// background
	sa.inject_at(&popup.draw_commands, UI_Draw_Rect {
		color = COLOR_BASE_1,
		rec = popup.rec,
	}, 1)

	// header
	if popup.show_header {
		header_height := ui_default_widget_height() + ui_px(8)
		sa.inject_at(&popup.draw_commands, UI_Draw_Gradient_H {
			right_color = COLOR_ACCENT_0,
			left_color = COLOR_ACCENT_1,
			rec = { popup.rec.x, popup.rec.y, popup.rec.width, header_height },
		}, 2)
		sa.inject_at(&popup.draw_commands, UI_Draw_Text {
			color = COLOR_BASE_0,
			rec = { popup.rec.x, popup.rec.y, popup.rec.width, header_height },
			text = popup.name,
			align = { .Center, .Center },
			size = ui_font_size(),
		}, 3)
	}
}

ui_end_popup :: proc() {
	ui_ctx.popup_scope = 0
}

ui_find_popup :: proc(id: UI_ID) -> (res: ^UI_Popup) {
	res = nil

	if ui_ctx.open_popups.len > 0 {
		for i in 0..<ui_ctx.open_popups.len {
			if id == ui_ctx.open_popups.data[i].id {
				res = &ui_ctx.open_popups.data[i]
				break
			}
		}
	}
	
	return res
}

ui_get_top_popup :: proc() -> (res: ^UI_Popup) {
	if ui_ctx.open_popups.len > 0 {
		return &ui_ctx.open_popups.data[ui_ctx.open_popups.len - 1]
	}
	else {
		return nil
	}
}

ui_show_notif :: proc(text: string, style := UI_NOTIF_STYLE_ACCENT) {
	ui_ctx.current_notif = {
		text = text,
		time = 0,
		style = style,
	}
}

ui_update_widget :: proc(id: UI_ID, rec: Rec, blocking := true) {
	top_popup := ui_get_top_popup()
	if top_popup != nil && top_popup.id != ui_ctx.popup_scope {
		return
	}
	
	rec := rec
	if ui_ctx.clip_stack.len > 0 {
		clip := ui_ctx.clip_stack.data[ui_ctx.clip_stack.len - 1]
		rec = rec_intersect(rec, clip)
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
	top_popup := ui_get_top_popup()
	if top_popup != nil && top_popup.id != ui_ctx.popup_scope {
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

ui_begin_list :: proc(
	id: UI_ID, 
	scroll: ^f32, 
	lerped_scroll: ^f32,
	items_h: f32, 
	items_count: int, 
	rec: Rec, 
	allocator := context.temp_allocator
) -> (
	content_rec: Rec, visible_items: []UI_List_Item
) {
	rec := rec
	items_list := make([dynamic]UI_List_Item, allocator = allocator)
	
	ui_update_panel(id, rec)
	
	ui_push_command(UI_Draw_Rect {
		color = COLOR_BASE_0,
		rec = rec,
	})
	
	has_scroll_bar := rec.height < items_h * f32(items_count) 
	max_scroll_y := (items_h * f32(items_count) - rec.height) * -1
	if has_scroll_bar {
		if ui_ctx.hovered_panel == id {
			scroll^ += rl.GetMouseWheelMove() * 10
		}
		
		scroll_bar_rec := rec_cut_right(&rec, ui_px(14))
		ui_update_widget(id, scroll_bar_rec)
		
		if ui_ctx.active_widget == id && rl.IsMouseButtonDown(.LEFT) {
			scroll^ = 0 + (rl.GetMousePosition().y - rec.y) * (max_scroll_y - 0) / rec.height
		}
		if scroll^ > 0 {
			scroll^ = 0
		}
		if scroll^ < max_scroll_y {
			scroll^ = max_scroll_y
		}
		
		thumb_h := rec.height * (rec.height / ((items_h * f32(items_count))))
		thumb_y := scroll_bar_rec.y + (lerped_scroll^ / max_scroll_y) * (scroll_bar_rec.height) - thumb_h / 2
		thumb_rec := Rec {
			x = scroll_bar_rec.x,
			y = thumb_y,
			width = scroll_bar_rec.width,
			height = thumb_h
		}
		// this probably can be removed
		thumb_rec.y = clamp(thumb_rec.y, scroll_bar_rec.y, scroll_bar_rec.y + scroll_bar_rec.height - thumb_h)
		
		ui_push_command(UI_Draw_Rect {
			color = COLOR_BASE_0,
			rec = scroll_bar_rec,
		})
		ui_push_command(UI_Draw_Rect {
			color = COLOR_BASE_2,
			rec = rec_pad_ex(thumb_rec, 2, 2, 2, 2),
		})
	}
	else {
		scroll^ = 0
	}
	
	lerped_scroll^ = rl.Lerp(lerped_scroll^, scroll^, rl.GetFrameTime() * 12)
	
	// TODO: we could just start the loop from first visible element
	for i in 0..<items_count {
		item_rec := Rec { 
			rec.x, 
			rec.y + f32(i) * items_h + lerped_scroll^, 
			rec.width, 
			items_h 
		}
		if rl.CheckCollisionRecs(item_rec, rec) {
			append(&items_list, UI_List_Item { i = i, rec = item_rec })
		}
	}	

	ui_begin_clip(rec)
	
	return rec, items_list[:]
}

ui_end_list :: proc() {
	ui_end_clip()
}

ui_begin_list_wrapped :: proc(
	id: UI_ID, 
	scroll: ^f32, 
	lerped_scroll: ^f32,
	item_size: f32, 
	items_count: int, 
	rec: Rec, 
	allocator := context.temp_allocator
) -> (
	content_rec: Rec, visible_items: []UI_List_Item
) {
	rec := rec
	items_list := make([dynamic]UI_List_Item, allocator = allocator)

	ui_update_panel(id, rec)
	ui_push_command(UI_Draw_Rect {
		color = COLOR_BASE_0,
		rec = rec,
	})
	
	// max_scroll_y := (items_h * f32(items_count) - rec.height) * -1
	row_count := math.ceil((item_size + ui_px(8)) * f32(items_count) / (rec.width - ui_px(14)))
	has_scroll_bar := rec.height < ((item_size + ui_px(8))) * row_count  
	max_scroll_y := rec.height - ((item_size + ui_px(8)) * row_count)
	if max_scroll_y > 0 {
		max_scroll_y = 0
	}
	if has_scroll_bar {
		if ui_ctx.hovered_panel == id {
			scroll^ += rl.GetMouseWheelMove() * 10
		}
		
		scroll_bar_rec := rec_cut_right(&rec, ui_px(14))
		ui_update_widget(id, scroll_bar_rec)
			
		if ui_ctx.active_widget == id && rl.IsMouseButtonDown(.LEFT) {
			scroll^ = 0 + (rl.GetMousePosition().y - rec.y) * (max_scroll_y - 0) / rec.height
		}
		if scroll^ > 0 {
			scroll^ = 0
		}
		if scroll^ < max_scroll_y {
			scroll^ = max_scroll_y
		}
		
		thumb_h := rec.height * (rec.height / (((item_size + ui_px(8)) * row_count)))
		thumb_h = clamp(thumb_h, ui_px(8), rec.height)
		thumb_y := scroll_bar_rec.y + (lerped_scroll^ / max_scroll_y) * (scroll_bar_rec.height) - thumb_h / 2
		thumb_rec := Rec {
			x = scroll_bar_rec.x,
			y = thumb_y,
			width = scroll_bar_rec.width,
			height = thumb_h
		}
		// this probably can be removed
		thumb_rec.y = clamp(thumb_rec.y, scroll_bar_rec.y, scroll_bar_rec.y + scroll_bar_rec.height - thumb_h)

		ui_push_command(UI_Draw_Rect {
			color = COLOR_BASE_0,
			rec = scroll_bar_rec,
		})
		ui_push_command(UI_Draw_Rect {
			color = COLOR_BASE_2,
			rec = rec_pad_ex(thumb_rec, 2, 2, 2, 2),
		})
	}
	else {
		scroll^ = 0
	}
	
	// TODO: we could just start the loop from first visible element
	x, y := f32(0), f32(0)
	for i in 0..<items_count {
		item_rec := Rec { 
			rec.x + x, 
			rec.y + y + lerped_scroll^, 
			item_size, 
			item_size 
		}
		if rl.CheckCollisionRecs(item_rec, rec) {
			append(&items_list, UI_List_Item { i = i, rec = item_rec })
		}
		x += item_size + ui_px(8)
		if x + item_size > rec.width {
			x = 0
			y += item_size + ui_px(8)
		}
	}
	
	ui_begin_clip(rec)
	
	lerped_scroll^ = rl.Lerp(lerped_scroll^, scroll^, rl.GetFrameTime() * 12)

	return rec, items_list[:]
}

ui_tooltip :: proc(id: UI_ID, widget_rec: Rec, text: string) {
	if ui_ctx.hovered_widget == id {
		w := ui_calc_button_width(text)
		x := clamp(widget_rec.x + widget_rec.width / 2 - w / 2, 0, f32(rl.GetScreenWidth()))
		rec := Rec { x, widget_rec.y + widget_rec.height + ui_px(2), w, ui_default_widget_height() }
		ui_push_command(UI_Draw_Rect {
			color = COLOR_BASE_0,
			rec = rec,
		})
		ui_push_command(UI_Draw_Rect_Outline {
			color = COLOR_BASE_2,
			thickness = 1,
			rec = rec,
		})
		ui_push_command(UI_Draw_Text {
			align = { .Center, .Center },
			color = COLOR_TEXT_0,
			rec = rec,
			size = ui_font_size(),
			text = text
		})
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

	ui_begin_clip(rec)
	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = color
	})
	ui_push_command(UI_Draw_Text {
		rec = rec_pad(rec, 10),
		text = text,
		size = font_size,
		color = style.text_color,
		align = style.text_align,
	})
	ui_end_clip()

	return clicked
}

ui_menu_button :: proc(id: UI_ID, text: string, items: []UI_Menu_Item, item_width: f32, rec: Rec) -> (clicked_item: UI_Menu_Item) {	
	clicked_item = {}

	ui_update_widget(id, rec)
	if ui_ctx.hovered_widget == id && ui_ctx.active_widget == id && rl.IsMouseButtonReleased(.LEFT) {
		ui_open_popup(id, false)	
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

	if ui_begin_popup(id, popup_rec) {
		menu_item_y := popup_rec.y
		style := UI_BUTTON_STYLE_DEFAULT
		style.font_size = ui_font_size()
		style.text_align = { .Left, .Center }
		for item, i in items {
			item_rec := Rec { popup_rec.x, menu_item_y, item_width, item_height }
			if ui_button(item.id, item.text, item_rec, style = style) {
				clicked_item = item
			}
			
			toggled, is_toggleble := item.toggled.?
			if is_toggleble {
				text_w := ui_calc_button_width(item.text)
				toggle_rec := Rec { item_rec.x + text_w, item_rec.y, item_rec.width, item_rec.height }
				ui_draw_text(toggled ? ICON_CHECK: ICON_X, toggle_rec)
			}

			if item.shortcut != "" {
				item_rec.width -= padding
				ui_draw_text(item.shortcut, item_rec, { .Right, .Center }, rl.ColorAlpha(COLOR_TEXT_0, 0.6))
			}
			if item.separator {
				sep_rec := item_rec
				sep_rec.y += item_height - 1
				sep_rec.height = 1
				ui_draw_rec(COLOR_BASE_0, sep_rec)
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

ui_menu_item :: proc(id: UI_ID, text: string, shortcut := "", separator := false, toggled: Maybe(bool) = nil) -> UI_Menu_Item {
	return UI_Menu_Item { id, text, shortcut, separator, toggled }
}

ui_path_button :: proc(id: UI_ID, text: string, rec: Rec, blocking := true, style := UI_BUTTON_STYLE_DEFAULT) -> (clicked: bool) {	
	clicked = false
	
	ui_update_widget(id, rec, blocking)
	font_size := style.font_size == 0 ? ui_font_size() : style.font_size

	clicked = ui_ctx.hovered_widget == id && ui_ctx.active_widget == id && rl.IsMouseButtonReleased(.LEFT)
	bg_color := style.bg_color
	if ui_ctx.active_widget == id {
		bg_color = style.bg_color_active
	}
	else if ui_ctx.hovered_widget == id {
		bg_color = style.bg_color_hovered
	}
	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = bg_color
	})
	bslash_index := strings.last_index(text, "\\")
	text_cstring := strings.clone_to_cstring(text[:bslash_index + 1], context.temp_allocator)
	path_width := rl.MeasureTextEx(ui_ctx.font, text_cstring, font_size, 0)[0]
	path_color := style.text_color
	path_color.a = 100

	ui_begin_clip(rec)
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
	ui_end_clip()

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

ui_toggle :: proc(id: UI_ID, text: string, checked: ^bool, rec: Rec, style := UI_TOGGLE_STYLE_DEFAULT) -> (clicked: bool) {
	clicked = false

	button_style: UI_Button_Style
	button_style.font_size = style.font_size
	button_style.text_align = style.text_align
	if checked^ {
		button_style.text_color = style.toggled_text_color
		button_style.bg_color = style.toggled_bg_color
		button_style.bg_color_hovered = style.toggled_bg_color_hovered
		button_style.bg_color_active = style.toggled_bg_color_hovered
	}
	else {
		button_style.text_color = style.text_color
		button_style.bg_color = style.bg_color
		button_style.bg_color_hovered = style.bg_color_hovered
		button_style.bg_color_active = style.bg_color_hovered
	}
	if ui_button(id, text, rec, style = button_style) {
		checked^ = !checked^
		clicked = true
	}
	
	return clicked
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
	
	font_size := style.font_size == 0 ? ui_font_size() : style.font_size
	
	ui_push_command(UI_Draw_Rect {
		rec = rec,
		color = style.bg_color,
	})
	
	if ui_ctx.text_mode_slider != id {
		// when right clicked write the value to slider_text_buffer and goto text mode
		if ui_ctx.hovered_widget == id && rl.IsMouseButtonReleased(.RIGHT) {
			ui_ctx.text_mode_slider = id
			strings.builder_reset(&ui_ctx.slider_text)
			strings.write_string(&ui_ctx.slider_text, fmt.tprintf(format, value^))
			ui_ctx.slider_caret_x = i32(len(ui_ctx.slider_text.buf))
		}
		else {
			value_changed = ui_slider_behaviour_f32(id, value, min, max, rec, step)
		}
		
		// draw slider
		progress_rec := rec_pad(rec, 1)
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
			rec = rec_pad(rec, 10),
			text = text,
			size = font_size,
			color = style.text_color,
			align = { .Right, .Center },	
		})
	}
	// TODO: get this logic outta here
	if ui_ctx.text_mode_slider == id {
		if rl.IsKeyPressed(.ESCAPE) {
			strings.builder_reset(&ui_ctx.slider_text)
			ui_ctx.text_mode_slider = 0
		}

		if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT) {
			ui_ctx.slider_caret_x -= 1
		}
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) {
			ui_ctx.slider_caret_x += 1
		}

		if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.C) {
			text_cstring, err := strings.to_cstring(&ui_ctx.slider_text)
			assert(err == nil)
			rl.SetClipboardText(text_cstring)
		}

		if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.V) {
			text := strings.clone_from_cstring(rl.GetClipboardText(), context.temp_allocator)
			if number, ok := strconv.parse_f32(text); ok {
				value^ = number
			}
			strings.builder_reset(&ui_ctx.slider_text)
			strings.write_string(&ui_ctx.slider_text, text)
			ui_ctx.slider_caret_x = i32(len(ui_ctx.slider_text.buf))
		}

		char := rl.GetCharPressed()
		switch char {
			case '0'..='9', '.': {
				inject_at(&ui_ctx.slider_text.buf, ui_ctx.slider_caret_x, byte(char))
				ui_ctx.slider_caret_x += 1
			}
		}
		if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {
			if strings.builder_len(ui_ctx.slider_text) > 0 {
				if ui_ctx.slider_caret_x != 0 {
					ordered_remove(&ui_ctx.slider_text.buf, ui_ctx.slider_caret_x - 1)
					ui_ctx.slider_caret_x -= 1
				}
			}
		}
		if rl.IsKeyPressed(.ENTER) {
			text := strings.to_string(ui_ctx.slider_text)
			if number, ok := strconv.parse_f32(text); ok {
				value^ = number
			}
			strings.builder_reset(&ui_ctx.slider_text)
			ui_ctx.text_mode_slider = 0
		}
		
		// draw textbox
		ui_ctx.slider_caret_x = clamp(ui_ctx.slider_caret_x, 0, i32(strings.builder_len(ui_ctx.slider_text)))
		text_before_caret := strings.to_string(ui_ctx.slider_text)[0:ui_ctx.slider_caret_x]
		text_before_caret_cstring := strings.clone_to_cstring(text_before_caret, context.temp_allocator)
		text_before_caret_w := rl.MeasureTextEx(ui_ctx.font, text_before_caret_cstring, ui_font_size(), 0)[0]
		caret_h := rec.height * 0.7

		ui_push_command(UI_Draw_Text {
			align = { .Left, .Center },
			color = style.text_color,
			rec = rec_pad(rec, ui_px(8)),
			size = font_size,
			text = strings.to_string(ui_ctx.slider_text),
		})

		ui_push_command(UI_Draw_Rect {
			color = COLOR_ACCENT_0,
			rec = { 
				rec.x + ui_px(8) + text_before_caret_w, 
				rec.y + rec.height / 2 - caret_h / 2, 
				ui_px(2), 
				caret_h 
			}
		})

		ui_push_command(UI_Draw_Rect_Outline {
			color = style.progress_color,
			rec = rec,
			thickness = 1,
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

// HACK: this guy uses some stuff from main.odin but i can't be bothered 
ui_color_picker :: proc(id: UI_ID, color: ^HSV, rec: Rec) -> (changed: bool) {
	area := rec

	// preview color
	preview_area := rec_cut_top(&area, ui_default_widget_height() * 3)
	ui_draw_rec(hsv_to_rgb(color^), preview_area)
	ui_draw_rec_outline(COLOR_BASE_0, ui_px(1), preview_area)
	rec_delete_top(&area, ui_px(8))

	hsv_color := color^

	// not sure if it's actually called grip...
	draw_grip :: proc(value, min, max: f32, rec: Rec) {
		grip_width := ui_px(10)
		grip_x := (value - min) * (rec.width) / (max - min) - grip_width / 2
		g_rec := Rec { rec.x + grip_x, rec.y, grip_width, rec.height }
		ui_draw_rec_outline(rl.BLACK, 3, rec_pad(g_rec, -1))
		ui_draw_rec_outline(rl.WHITE, 1, g_rec)
	}

	// hue slider
	hue_rec := rec_cut_top(&area, ui_default_widget_height())
	hue_changed := ui_slider_behaviour_f32(ui_gen_id(int(id)), &hsv_color[0], 0, 360, hue_rec)
	ui_draw_rec(COLOR_BASE_0, hue_rec)

	hue_rec = rec_pad(hue_rec, 1)
	hue_area := hue_rec
	segment_width := hue_rec.width / 6
	ui_push_command(UI_Draw_Gradient_H {
		left_color = { 255, 0, 255, 255 },
		right_color = { 255, 0, 0, 255 },
		rec = rec_cut_right(&hue_area, segment_width)
	})
	ui_push_command(UI_Draw_Gradient_H {
		left_color = { 0, 0, 255, 255 },
		right_color = { 255, 0, 255, 255 },
		rec = rec_cut_right(&hue_area, segment_width)
	})
	ui_push_command(UI_Draw_Gradient_H {
		left_color = { 0, 255, 255, 255 },
		right_color = { 0, 0, 255, 255 },
		rec = rec_cut_right(&hue_area, segment_width)
	})
	ui_push_command(UI_Draw_Gradient_H {
		left_color = { 0, 255, 0, 255 },
		right_color = { 0, 255, 255, 255 },
		rec = rec_cut_right(&hue_area, segment_width)
	})
	ui_push_command(UI_Draw_Gradient_H {
		left_color = { 255, 255, 0, 255 },
		right_color = { 0, 255, 0, 255 },
		rec = rec_cut_right(&hue_area, segment_width)
	})
	ui_push_command(UI_Draw_Gradient_H {
		left_color = { 255, 0, 0, 255 },
		right_color = { 255, 255, 0, 255 },
		rec = rec_cut_right(&hue_area, segment_width)
	})

	draw_grip(hsv_color[0], 0, 360, hue_rec)
	rec_delete_top(&area, ui_px(8))

	// saturation slider
	saturation_rec := rec_cut_top(&area, ui_default_widget_height())
	saturation_changed := ui_slider_behaviour_f32(ui_gen_id(int(id)), &hsv_color[1], 0, 1, saturation_rec)
	ui_draw_rec(COLOR_BASE_0, saturation_rec)

	saturation_rec = rec_pad(saturation_rec, 1)
	sat_color := hsv_color
	sat_color[1] = 1
	left_color := rl.ColorLerp(rl.WHITE, rl.BLACK, 1 - hsv_color[2])
	right_color := hsv_to_rgb(sat_color)
	right_color = rl.ColorLerp(right_color, rl.BLACK, 1 - hsv_color[2])
	ui_push_command(UI_Draw_Gradient_H {
		left_color = left_color,
		right_color = right_color,
		rec = saturation_rec,
	})

	draw_grip(hsv_color[1], 0, 1, saturation_rec)
	rec_delete_top(&area, ui_px(8))
	
	// value slider
	value_rec := rec_cut_top(&area, ui_default_widget_height())
	value_changed := ui_slider_behaviour_f32(ui_gen_id(int(id)), &hsv_color[2], 0, 1, value_rec)
	ui_draw_rec(COLOR_BASE_0, value_rec)

	value_rec = rec_pad(value_rec, 1)
	ui_push_command(UI_Draw_Gradient_H {
		left_color = rl.BLACK,
		right_color = rl.WHITE,
		rec = value_rec,
	})

	draw_grip(hsv_color[2], 0, 1, value_rec)

	changed = hue_changed || saturation_changed || value_changed
	if changed {
		color^ = hsv_color
	}
	return changed
}

ui_calc_color_picker_height :: proc() -> (h: f32) {
	return ui_default_widget_height() * 6 + ui_px(8) * 3 
}

ui_color_button :: proc(id: UI_ID, label: string, color: ^HSV, rec: Rec) {
	area := rec

	ui_draw_text(label, area)

	color_rec := rec_take_right(&area, ui_default_widget_height())
	ui_update_widget(id, color_rec)
	if ui_ctx.active_widget == id && rl.IsMouseButtonReleased(.LEFT) {
		ui_open_popup(id, false)
	}
	
	ui_draw_rec(COLOR_BASE_0, color_rec)
	ui_draw_rec(hsv_to_rgb(color^), rec_pad(color_rec, 2))

	popup_rec := Rec { 
		rec.x + rec.width + ui_px(10), 
		rec.y + rec.height + ui_px(10), 
		ui_px(300), 
		ui_calc_color_picker_height()
	}
	if ui_begin_popup(id, popup_rec) {
		ui_color_picker(ui_gen_id(int(id)), color, popup_rec)
	}
	ui_end_popup()
}

ui_draw_text :: proc(text: string, rec: Rec, align := UI_Align { .Left, .Center }, color := COLOR_TEXT_0, size := f32(0)) {
	size := size == 0 ? ui_font_size() : size
	ui_push_command(UI_Draw_Text { text = text, rec = rec, align = align, color = color, size = size })
}

ui_draw_rec :: proc(color: rl.Color, rec: Rec) {
	ui_push_command(UI_Draw_Rect { color = color, rec = rec })
}

ui_draw_rec_outline :: proc(color: rl.Color, thickness: f32, rec: Rec) {
	ui_push_command(UI_Draw_Rect_Outline { color = color, rec = rec, thickness = thickness })
}

ui_push_command :: proc(command: UI_Draw_Command) {
	if ui_ctx.popup_scope != 0 {
		popup := ui_find_popup(ui_ctx.popup_scope)
		if popup != nil {
			sa.append(&popup.draw_commands, command)
		}
	}
	else {
		sa.append(&ui_ctx.draw_commands, command)
	}
}

ui_begin_clip :: proc(rec: Rec) {
	rec := rec
	if ui_ctx.clip_stack.len > 0 {
		last_rec := ui_ctx.clip_stack.data[ui_ctx.clip_stack.len - 1]
		rec = rec_intersect(last_rec, rec)
	}
	sa.append(&ui_ctx.clip_stack, rec )
	ui_push_command(UI_Clip { rec = rec })
}

ui_end_clip :: proc() {
	ui_push_command(UI_Clip { })
	if ui_ctx.clip_stack.len > 0 {
		sa.pop_back(&ui_ctx.clip_stack)
	}
}

ui_is_being_interacted :: #force_inline proc() -> (res: bool) {
	return ui_ctx.hovered_widget != 0 ||
	ui_ctx.active_widget != 0 ||
	ui_ctx.hovered_panel != 0 ||
	ui_ctx.active_panel != 0 ||
	(ui_is_any_popup_open())
}

ui_close_popup_on_esc :: proc(id: UI_ID) {
	popup := ui_get_top_popup()
	if popup == nil do return
	if popup.id != id do return

	can_shortcut := ui_ctx.text_mode_slider == 0
	if can_shortcut && rl.IsKeyPressed(.ESCAPE) {
		ui_close_current_popup()
	}
}

ui_is_mouse_in_rec :: proc(rec: Rec) -> (is_inside: bool) {
	mpos := rl.GetMousePosition()
	return mpos.x > rec.x && mpos.y > rec.y && mpos.x < rec.x + rec.width && mpos.y < rec.y + rec.height
}

ui_calc_popup_height :: proc(item_count: i32, item_h, separator_h, padding: f32) -> (height: f32) {
	return item_h * f32(item_count) + separator_h * (f32(item_count) - 1) + padding * 2 
}

ui_is_any_popup_open :: #force_inline proc() -> (res: bool) {
	return ui_ctx.open_popups.len > 0
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

ui_get_screen_rec :: proc() -> (rec: Rec) {
	return { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
}