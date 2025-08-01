/* application code 
frontend, backend, etc... */
package darko

import "core:fmt"
import rl "vendor:raylib"
import "core:mem"
import vmem "core:mem/virtual"
import "core:math"
import "core:strings"
import "core:c"
import os "core:os/os2"
import "core:slice"
import sa "core:container/small_array"
import ntf "../lib/ntf"
import "core:encoding/ini"
import "core:strconv"

VERSION :: "1.0.0"
TARGET_FPS :: 60

App :: struct {
	state: Screen_State, 
	next_state: Maybe(Screen_State),
	new_project_width, new_project_height: i32,
	recent_projects: sa.Small_Array(8, string),
	fav_palletes: sa.Small_Array(24, Pallete),
	active_tools: Active_Tools,
	darken_welcome_screen: bool,
	enable_custom_cursors: bool,
	show_fps: bool,
	unlock_fps: bool,
	exit: bool,
}

Screen_State :: union {
	Welcome_State,
	Project_State,
}

Welcome_State :: struct {
	mascot: rl.Texture2D,
}

Project_State :: struct {
	dir: string,
	export_dir: string,

	zoom: f32,
	lerped_zoom: f32,
	spacing: f32,
	width: i32,
	height: i32,
	layers: [dynamic]Layer,
	
	current_tool: Tool,
	pen_size: i32,
	cursor: Cursor,
	current_color: HSV,
	current_layer: int,
	lerped_current_layer: f32,
	onion_skinning: bool,
	hide_grid: bool,
	pallete: Pallete,

	show_bg: bool,
	bg_color1, bg_color2: HSV,
	bg_texture: rl.Texture,
	
	preview_zoom: f32,
	lerped_preview_zoom: f32,
	preview_rotation: f32,
	preview_rotation_speed: f32,
	auto_rotate_preview: bool,
	preview_bg_color: HSV,

	temp_undo: Maybe(Action),
	undos: [dynamic]Action,
	redos: [dynamic]Action,
	// used for checking if the project is saved before quitting
	undos_len_on_save: int,

	dirty_layers: [dynamic]int,
	copied_image: Maybe(rl.Image),
	exit_popup_confirm: proc(state: ^Project_State),
}

Layer :: struct {
	image: rl.Image,
	texture: rl.Texture,
}

Pallete :: struct {
	name: string,
	colors: sa.Small_Array(256, HSV),
}

Cursor :: struct {
	x, y: i32,
	last_mx, last_my: i32,
	active: bool,
}

Tool :: enum {
	Pen,
	Eraser,
	Color_Picker,
	Fill,
	GoTo,
}

HSV :: distinct [3]f32

Active_Tools :: struct {
	pen_size: bool,
	onion_skinning: bool,
	add_layer_at_top: bool,
	add_layer_above: bool,
	duplicate_layer: bool,
	move_layer: bool,
	clear_layer: bool,
	delete_layer: bool,
}

// popup ids used for opening them

popup_new_project := ui_gen_id()
popup_preview_settings := ui_gen_id()
popup_fav_palletes := ui_gen_id()
popup_bg_colors := ui_gen_id()
popup_exit := ui_gen_id()
popup_settings := ui_gen_id()

// undo redo actions

Action :: union {
	Action_Image_Change,
	Action_Create_Layer,
	Action_Duplicate_Layer,
	Action_Change_Layer_Index,
	Action_Delete_Layer,
}

Action_Image_Change :: struct {
	before_image: rl.Image,
	after_image: rl.Image,
	layer_index: int,
}

Action_Create_Layer :: struct {
	current_layer_index: int,
	layer_index: int,
}

Action_Duplicate_Layer :: struct {
	from_index: int,
	to_index: int,
}

Action_Change_Layer_Index :: struct {
	from_index: int,
	to_index: int,
}

Action_Delete_Layer :: struct {
	image: rl.Image,
	layer_index: int,
}

app: App

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			fmt.eprintln("checking for leaks..")
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}
	
	rl.SetTargetFPS(TARGET_FPS)
	rl.SetConfigFlags({ rl.ConfigFlags.WINDOW_RESIZABLE, rl.ConfigFlags.MSAA_4X_HINT })
	rl.InitWindow(1200, 700, "Darko")
	defer rl.CloseWindow()
	rl.SetExitKey(nil)

	ntf.Init()
	defer ntf.Quit()

	ui_init_ctx()
	defer ui_deinit_ctx()
	
	load_app_data("data.ini")

	welcome_state := Welcome_State {}
	init_welcome_state(&welcome_state)
	app.state = welcome_state
	
	defer deinit_app()
	defer save_app_data()

	for app.exit == false {
		ui_begin()
		app_shortcuts()
		switch &state in app.state {
			case Project_State: {
				project_shortcuts(&state)				
				project_view(&state)
				process_dirty_layers(&state)
				update_title(&state)
				
				// show the confirm exit popup when user closes the window
				if rl.WindowShouldClose() {
					if is_saved(&state) == false {
						confirm_project_exit(&state, proc(state: ^Project_State) {
							app.exit = true
						})
					}
					else {
						app.exit = true
					}
				}
			}
			case Welcome_State: {
				welcome_shortcuts(&state)
				welcome_screen_view(&state)

				if rl.WindowShouldClose() {
					app.exit = true
				}
			}
		}
		new_project_popup_view(&app.state)
		settings_popup_view()
		ui_end()

		// draw
		rl.BeginDrawing()
		rl.ClearBackground(COLOR_BASE_0)		
		process_commands(ui_get_draw_commmands())
		if app.show_fps {
			rl.DrawFPS(rl.GetScreenWidth() - 80, 10)
		}
		rl.EndDrawing()

		if next_state, ok := app.next_state.?; ok {
			// cleanup previous state
			switch &state in app.state {
				case Project_State: {
					deinit_project_state(&state)
				}
				case Welcome_State: {
					deinit_welcome_state(&state)
				}
			}

			// switch to the new state
			switch &state in next_state {
				case Project_State: {
					// new projects don't have a dir
					if state.dir != "" {
						add_recent_project(state.dir)
					}
					rl.SetWindowTitle(fmt.ctprintf("Darko - {}", state.dir))
					app.state = state
				}
				case Welcome_State: {
					rl.SetWindowTitle("Darko")
					app.state = state	
				}
			}
			app.next_state = nil
			rl.ShowCursor()
		} 
		
		ui_clear_temp_state()
		free_all(context.temp_allocator)
	}	
}

// frontend code

welcome_screen_view :: proc(state: ^Welcome_State) {
	screen_rec := ui_get_screen_rec()
	screen_area := screen_rec
	
	dark_mode := app.darken_welcome_screen

	left_area := rec_cut_left(&screen_area, ui_px(500))
	right_area := screen_area
	ui_push_command(UI_Draw_Gradient_V { 
		top_color = dark_mode ? COLOR_BASE_0 : COLOR_ACCENT_0, 
		bottom_color = dark_mode ? COLOR_BASE_1 : COLOR_ACCENT_1, 
		rec = right_area
	})
	
	mascot_size := ui_px(right_area.width / 3)
	mascot_rec := rec_center_in_area({ 0, 0, mascot_size , mascot_size }, right_area)
	mascot_rec.y += f32(math.cos(rl.GetTime())) * 10
	mascot_color := dark_mode ? COLOR_ACCENT_0 : COLOR_BASE_0 
	ui_draw_texture(state.mascot, mascot_rec, mascot_color)

	left_area = rec_pad(left_area, ui_px(16))
	ui_begin_clip(left_area)

	text_rec := rec_cut_top(&left_area, ui_default_widget_height() * 2)
	ui_draw_text("Welcome to Darko", text_rec, { .Center, .Bottom }, COLOR_ACCENT_0, ui_font_size() * 2)
	
	ver_rec := rec_cut_top(&left_area, ui_default_widget_height())
	ui_draw_text("version " + VERSION, ver_rec, { .Center, .Center }, COLOR_BASE_4, ui_font_size())

	rec_cut_top(&left_area, ui_px(16))

	buttons_area := rec_cut_top(&left_area, ui_default_widget_height())
	new_button_rec := rec_cut_left(&buttons_area, buttons_area.width / 2 - ui_px(8))
	if ui_button(ui_gen_id(), "New", new_button_rec) {
		ui_open_popup(popup_new_project)
	}
	
	rec_cut_left(&buttons_area, ui_px(8))
	
	open_button_rec := rec_cut_left(&buttons_area, buttons_area.width - ui_px(8))
	if ui_button(ui_gen_id(), "Open", open_button_rec) {
		try_open_project()
	}

	if app.recent_projects.len == 0 {
		no_recent_rec := rec_cut_bottom(&left_area, ui_default_widget_height())
		ui_draw_text("No recent projects", no_recent_rec)
	}
	else {		
		for i in 0..<app.recent_projects.len {
			recent := app.recent_projects.data[i]
			recent_rec := rec_cut_bottom(&left_area, ui_default_widget_height())
			style := UI_BUTTON_STYLE_DEFAULT
			style.text_align = { .Left, .Center }
			if ui_path_button(ui_gen_id(i), recent, recent_rec, style = style) {
				project: Project_State
				ok := load_project_state(&project, recent)
				if ok {
					schedule_state_change(project)
				}
				else {
					ui_show_notif("Could not open project")
				}
			}
		}

		recent_rec := rec_cut_bottom(&left_area, ui_default_widget_height())
		ui_draw_text("Recent projects", recent_rec)
	}
	ui_end_clip()

	settings_rec := rec_take_right(&screen_rec, ui_px(100))
	settings_rec.height = ui_default_widget_height()
	style := UI_BUTTON_STYLE_TRANSPARENT
	style.text_color = app.darken_welcome_screen ? COLOR_BASE_4 : COLOR_BASE_0 
	if ui_button(ui_gen_id(), "Settings", settings_rec, style = style) {
		ui_open_popup(popup_settings)
	}
}

project_view :: proc(state: ^Project_State) {
	screen_rec := ui_get_screen_rec()
	menu_bar_area := rec_cut_top(&screen_rec, ui_default_widget_height())
	menu_bar_view(state, menu_bar_area)

	screen_area := screen_rec

	right_panel_area := rec_cut_right(&screen_area, ui_px(350))
	middle_panel_area := screen_area
	
	layer_props_area := rec_cut_top(&middle_panel_area, ui_default_widget_height() + ui_px(16))
	toolbar_view(state, layer_props_area)

	canvas_view(state, middle_panel_area)
	tool_box_view(state, middle_panel_area)

	ui_panel(ui_gen_id(), right_panel_area)
	right_panel_area = rec_pad(right_panel_area, ui_px(16))
	
	color_panel_area := rec_cut_top(&right_panel_area, calc_color_panel_h())
	color_panel_view(state, color_panel_area)

	rec_delete_top(&right_panel_area, ui_px(16))

	preview_view(state, right_panel_area)	

	preview_settings_popup_view(state)
	fav_palletes_popup_view(state)
	bg_colors_popup_view(state)
	exit_popup_view(state)
}

menu_bar_view :: proc(state: ^Project_State, rec: Rec) {
	area := rec
	ui_panel(ui_gen_id(), area, { bg_color = COLOR_BASE_2 })

	settings_rec := rec_take_right(&area, ui_px(100))
	if ui_button(ui_gen_id(), "Settings", settings_rec) {
		ui_open_popup(popup_settings)
	}

	file_rec := rec_cut_left(&area, ui_calc_button_width("File"))
	if open, content_rec := ui_begin_menu_button(ui_gen_id(), "File", ui_px(300), 5, file_rec); open {
		area := content_rec
		if ui_menu_item(ui_gen_id(), "New project", &area, "Ctrl + N") {
			ui_close_current_popup()
			ui_open_popup(popup_new_project)
		}
		if ui_menu_item(ui_gen_id(), "Open project", &area, "Ctrl + O") {
			try_open_project()
		}
		if ui_menu_item(ui_gen_id(), "Save project", &area, "Ctrl + S") {
			try_save_prject(state, true)
		}
		if ui_menu_item(ui_gen_id(), "Export project", &area, "Ctrl + E") {
			try_export_project(state)
		}
		if ui_menu_item(ui_gen_id(), "Go to welcome screen", &area, "W") {
			go_to_welcome_screen(state)
		}
	}
	ui_end_menu_button()
	
	edit_rec := rec_cut_left(&area, ui_calc_button_width("Edit"))
	if open, content_rec := ui_begin_menu_button(ui_gen_id(), "Edit", ui_px(300), 4, edit_rec); open {
		area := content_rec
		if ui_menu_item(ui_gen_id(), "Copy", &area, "Ctrl + C") {
			copy_layer(state, get_current_layer(state)) 
		}
		if ui_menu_item(ui_gen_id(), "Paste", &area, "Ctrl + V") {
			paste_layer(state, state.current_layer)
		}
		if ui_menu_item(ui_gen_id(), "Undo", &area, "Ctrl + Z") {
			undo(state)
		}
		if ui_menu_item(ui_gen_id(), "Redo", &area, "Ctrl + Y") {
			redo(state)
		}
	}
	ui_end_menu_button()

	layer_rec := rec_cut_left(&area, ui_calc_button_width("Layer"))
	if open, content_rec := ui_begin_menu_button(ui_gen_id(), "Layer", ui_px(300), 7, layer_rec); open {
		area := content_rec
		if ui_menu_item(ui_gen_id(), "Add above", &area, "Space") {
			add_empty_layer(state, state.current_layer + 1)
		}
		if ui_menu_item(ui_gen_id(), "Add top", &area, "Ctrl + Space") {
			add_empty_layer(state, len(state.layers))
		}
		if ui_menu_item(ui_gen_id(), "Duplicate", &area, "D") {
			duplicate_layer(state, state.current_layer, state.current_layer + 1)
		}
		if ui_menu_item(ui_gen_id(), "Move up", &area, "Alt + Up") {
			if len(state.layers) > 1 && state.current_layer < len(state.layers) - 1 {
				change_layer_index(state, state.current_layer, state.current_layer + 1)
			}
		}
		if ui_menu_item(ui_gen_id(), "Move down", &area, "Alt + Down") {
			if len(state.layers) > 1 && state.current_layer > 0 {
				change_layer_index(state, state.current_layer, state.current_layer - 1)
			}
		}
		if ui_menu_item(ui_gen_id(), "Clear", &area, "F") {
			clear_layer(state, state.current_layer)
		}
		if ui_menu_item(ui_gen_id(), "Delete", &area, "X") {
			if len(state.layers) > 1 {
				delete_layer(state, state.current_layer)
			}
		}
	}
	ui_end_menu_button()

	view_rec := rec_cut_left(&area, ui_calc_button_width("View"))
	if open, content_rec := ui_begin_menu_button(ui_gen_id(), "View", ui_px(300), 4, view_rec); open {
		area := content_rec
		if ui_menu_item(ui_gen_id(), "Show grid", &area, toggleble = !state.hide_grid) {
			state.hide_grid = !state.hide_grid
		}
		if ui_menu_item(ui_gen_id(), "Show bg", &area, toggleble = state.show_bg) {
			state.show_bg = !state.show_bg
		}
		if ui_menu_item(ui_gen_id(), "Change bg colors", &area) {
			ui_open_popup(popup_bg_colors)
		}
		if ui_menu_item(ui_gen_id(), "Onion skinning", &area, "Tab") {
			state.onion_skinning = !state.onion_skinning
		}
	}
	ui_end_menu_button()
}

tool_options_button :: proc(state: ^Project_State, rec: Rec) {
	style := UI_BUTTON_STYLE_TRANSPARENT
	style.text_color = COLOR_BASE_4
	if open, content_rec := ui_begin_menu_button(ui_gen_id(), ICON_SETTINGS, ui_px(300), 8, rec, style); open {
		area := content_rec
		if ui_menu_item(ui_gen_id(), ICON_PEN + "  Pen size", &area, toggleble = app.active_tools.pen_size) {
			app.active_tools.pen_size = !app.active_tools.pen_size
		} 
		if ui_menu_item(ui_gen_id(), ICON_EYE + "  Onion skinning", &area, toggleble = app.active_tools.onion_skinning) {
			app.active_tools.onion_skinning = !app.active_tools.onion_skinning
		} 
		if ui_menu_item(ui_gen_id(), "+" + "  Add Layer At Top", &area, toggleble = app.active_tools.add_layer_at_top) {
			app.active_tools.add_layer_at_top = !app.active_tools.add_layer_at_top
		} 
		if ui_menu_item(ui_gen_id(), "+" + "  Add Layer Above", &area, toggleble = app.active_tools.add_layer_above) {
			app.active_tools.add_layer_above = !app.active_tools.add_layer_above
		} 
		if ui_menu_item(ui_gen_id(), ICON_COPY + "  Duplicate Layer", &area, toggleble = app.active_tools.duplicate_layer) {
			app.active_tools.duplicate_layer = !app.active_tools.duplicate_layer
		} 
		if ui_menu_item(ui_gen_id(), ICON_SWAP_VERT + "  Move Layer Up or Down", &area, toggleble = app.active_tools.move_layer) {
			app.active_tools.move_layer = !app.active_tools.move_layer
		}
		if ui_menu_item(ui_gen_id(), ICON_X + "  Clear Layer", &area, toggleble = app.active_tools.clear_layer) {
			app.active_tools.clear_layer = !app.active_tools.clear_layer
		}
		if ui_menu_item(ui_gen_id(), ICON_TRASH + "  Delete Layer", &area, toggleble = app.active_tools.delete_layer) {
			app.active_tools.delete_layer = !app.active_tools.delete_layer
		}
	}
	ui_end_menu_button()
}

toolbar_view :: proc(state: ^Project_State, rec: Rec) {
	ui_panel(ui_gen_id(), rec)
	tools_area := rec_pad(rec, ui_px(8))

	tool_options_button(state, rec_cut_right(&tools_area, ui_default_widget_height()))
	
	// draw current layer index and layer count
	current_layer := state.current_layer + 1
	layer_count := len(state.layers)
	ui_draw_text(fmt.tprintf("Layer {}/{}", current_layer, layer_count), tools_area)

	if app.active_tools.delete_layer {
		rec := rec_cut_right(&tools_area, ui_default_widget_height())
		if ui_button(ui_gen_id(), ICON_TRASH, rec, style = UI_BUTTON_STYLE_RED) {
			if len(state.layers) > 1 {
				delete_layer(state, state.current_layer)
			}
		}
	}

	if app.active_tools.clear_layer {
		rec := rec_cut_right(&tools_area, ui_default_widget_height())
		if ui_button(ui_gen_id(), ICON_X, rec, style = UI_BUTTON_STYLE_RED) {
			clear_layer(state, state.current_layer)
		}
	}

	if app.active_tools.move_layer {
		TEXT_UP :: ICON_LAYERS + " " + ICON_UP
		rec := rec_cut_right(&tools_area, ui_calc_button_width(TEXT_UP))
		if ui_button(ui_gen_id(), TEXT_UP, rec, style = UI_BUTTON_STYLE_ACCENT) {
			if len(state.layers) > 1 && state.current_layer < len(state.layers) - 1 {
				change_layer_index(state, state.current_layer, state.current_layer + 1)
			}
		}
		TEXT_DOWN :: ICON_LAYERS + " " + ICON_DOWN
		rec = rec_cut_right(&tools_area, ui_calc_button_width(TEXT_DOWN))
		if ui_button(ui_gen_id(), TEXT_DOWN, rec, style = UI_BUTTON_STYLE_ACCENT) {
			if len(state.layers) > 1 && state.current_layer > 0 {
				change_layer_index(state, state.current_layer, state.current_layer - 1)
			}
		}
	}

	
	if app.active_tools.duplicate_layer {
		rec := rec_cut_right(&tools_area, ui_default_widget_height())
		if ui_button(ui_gen_id(), ICON_COPY, rec, style = UI_BUTTON_STYLE_ACCENT) {
			duplicate_layer(state, state.current_layer, state.current_layer + 1)
		}
	}
	
	if app.active_tools.add_layer_above {
		TEXT :: "Add above"
		rec := rec_cut_right(&tools_area, ui_calc_button_width(TEXT))
		if ui_button(ui_gen_id(), TEXT, rec, style = UI_BUTTON_STYLE_ACCENT) {
			add_empty_layer(state, state.current_layer + 1)
		}
	}
	
	if app.active_tools.add_layer_at_top {
		TEXT :: "Add top"
		rec := rec_cut_right(&tools_area, ui_calc_button_width(TEXT))
		if ui_button(ui_gen_id(), TEXT, rec, style = UI_BUTTON_STYLE_ACCENT) {
			add_empty_layer(state, len(state.layers))
		}
	}
	
	if app.active_tools.onion_skinning {
		rec := rec_cut_right(&tools_area, ui_default_widget_height())
		onion_icon := state.onion_skinning ? ICON_EYE : ICON_EYE_OFF
		if ui_button(ui_gen_id(), onion_icon, rec, style = UI_BUTTON_STYLE_ACCENT) {
			state.onion_skinning = !state.onion_skinning
		}
	}

	if app.active_tools.pen_size {
		size_slider_style := UI_SLIDER_STYLE_DEFAULT
		size_slider_style.bg_color.a = 200
		rec := rec_cut_right(&tools_area, ui_px(150))
		ui_slider_i32(ui_gen_id(), "Pen size", &state.pen_size, 1, 10, rec, style = size_slider_style)
	}
}

canvas_view :: proc(state: ^Project_State, rec: Rec) {
	area := rec

	ui_begin_clip(rec)

	state.lerped_zoom = rl.Lerp(state.lerped_zoom, state.zoom, 20 * rl.GetFrameTime())
	// work around for lerp never (taking too long) reaching it's desteniton 
	if math.abs(state.zoom - state.lerped_zoom) < 0.01 {
		state.lerped_zoom = state.zoom
	}

	canvas_w := f32(state.width) * 10 * state.lerped_zoom 
	canvas_h := f32(state.height) * 10 * state.lerped_zoom
	canvas_rec := rec_center_in_area({ 0, 0, canvas_w, canvas_h }, area)
	
	current_tool := tool_shortcuts(state)
	
	if ui_is_being_interacted() == false {
		update_zoom(&state.zoom, 0.4, 0.1, 100)
	}
	update_tools(state, canvas_rec, current_tool)

	state.lerped_current_layer = rl.Lerp(state.lerped_current_layer, f32(state.current_layer), rl.GetFrameTime() * 18)

	for i in 0..<len(state.layers) {
		layer_rec := canvas_rec
		layer_rec.y -= (canvas_h + ui_px(16) * state.zoom) * (f32(i) - state.lerped_current_layer)		
		
		if state.show_bg {
			ui_draw_texture(state.bg_texture, layer_rec)
		}
		
		if i == state.current_layer {
			// TOOD: just use a UI_Draw_Texture
			// ui_push_command(UI_Draw_Canvas {
			// 	rec = layer_rec,
			// })
			if state.onion_skinning && i > 0 {
				ui_draw_texture(state.layers[i - 1].texture, layer_rec, { 255, 255, 255, 100 })	
			}
			ui_draw_texture(state.layers[i].texture, layer_rec)	

			if state.zoom > 1.2 {
				if state.hide_grid == false {
					ui_push_command(UI_Draw_Grid {
						rec = layer_rec,
					})
				}
			}
			else {
				hand_rec := Rec { layer_rec.x - ui_px(32), layer_rec.y + layer_rec.height / 2, 0, 0 }
				ui_draw_text(ICON_HAND, hand_rec, { .Center, .Center }, size = ui_font_size() * 2)
			}
			ui_draw_rec_outline(COLOR_BASE_4, 2, layer_rec)
			
			// draw cursor preview
			tool_needs_preview := current_tool != .GoTo
			if tool_needs_preview && ui_is_being_interacted() == false {
				mx, my := get_mouse_pos_in_canvas(state, layer_rec)
				pixel_size := layer_rec.width / f32(state.width)
				pen_size := current_tool == .Color_Picker || current_tool == .Fill ? 1 : state.pen_size
				x := f32(mx - (pen_size - 1) / 2) * pixel_size + layer_rec.x
				y := f32(my - (pen_size - 1) / 2) * pixel_size + layer_rec.y
				size := f32(pen_size) * pixel_size
				ui_draw_rec_outline(rl.WHITE, 2, { x, y, size, size })
			}
		}
		else {
			// when clicked on another layer move to that layer
			can_go_to := 
				current_tool == .GoTo &&
				ui_is_mouse_in_rec(layer_rec) && 
				ui_is_any_popup_open() == false 
			
			if can_go_to && rl.IsMouseButtonPressed(.LEFT) {
				state.current_layer = i
			}

			ui_draw_texture(state.layers[i].texture, layer_rec)
			ui_draw_rec_outline(can_go_to ? COLOR_BASE_3 : COLOR_BASE_1, 2, layer_rec)
		}
	}

	// draw cursor
	if app.enable_custom_cursors && ui_is_mouse_in_rec(area) && ui_is_being_interacted() == false {
		cursor_icon := ""
		switch current_tool {
			case .Pen: cursor_icon = ICON_PEN
			case .Color_Picker: cursor_icon = ICON_EYEDROPPER
			case .Eraser: cursor_icon = ICON_ERASER
			case .Fill: cursor_icon = ICON_FILL
			case .GoTo: cursor_icon = ICON_STAR
		}
		
		rl.HideCursor()
		mpos := rl.GetMousePosition()
		cursor_size := ui_font_size() * 2

		shadow_rec := Rec { mpos.x + 1, mpos.y - cursor_size + 5 + 1, 100, 100 }
		ui_draw_text(cursor_icon, shadow_rec, { .Left, .Top }, rl.BLACK, cursor_size)

		cursor_rec := Rec { mpos.x, mpos.y - cursor_size + 5, 100, 100 }
		ui_draw_text(cursor_icon, cursor_rec, { .Left, .Top }, rl.WHITE, cursor_size)
	}
	else {
		rl.ShowCursor()
	}

	ui_end_clip()
}

tool_box_view :: proc(state: ^Project_State, rec: Rec) {
	padded_rec := rec_pad(rec, ui_px(4))
	
	tool_size := ui_px(40)

	area := rec_cut_right(&padded_rec, tool_size)
	area.height = tool_size * 6 + 2
	
	ui_panel(ui_gen_id(), area)
	ui_draw_rec_outline(COLOR_BASE_0, 1, area)
	
	area = rec_pad(area, 1)

	pen_rec := rec_cut_top(&area, tool_size)
	if togglable_button(ui_gen_id(), ICON_PEN, state.current_tool == .Pen, pen_rec, ui_font_size() * 1.3) {
		state.current_tool = .Pen
	}
	
	eraser_rec := rec_cut_top(&area, tool_size)
	if togglable_button(ui_gen_id(), ICON_ERASER, state.current_tool == .Eraser, eraser_rec, ui_font_size() * 1.3) {
		state.current_tool = .Eraser
	}

	eye_dropper_rec := rec_cut_top(&area, tool_size)
	if togglable_button(ui_gen_id(), ICON_EYEDROPPER, state.current_tool == .Color_Picker, eye_dropper_rec, ui_font_size() * 1.3) {
		state.current_tool = .Color_Picker
	}

	fill_rec := rec_cut_top(&area, tool_size)
	if togglable_button(ui_gen_id(), ICON_FILL, state.current_tool == .Fill, fill_rec, ui_font_size() * 1.4) {
		state.current_tool = .Fill
	}
	
	go_style := UI_BUTTON_STYLE_DEFAULT
	go_style.bg_color = COLOR_BASE_1

	up_rec := rec_cut_top(&area, tool_size)
	if ui_button(ui_gen_id(), ICON_UP, up_rec, style = go_style) {
		if state.current_layer < len(state.layers) - 1 {
			state.current_layer += 1
		}
	}

	down_rec := rec_cut_top(&area, tool_size)
	if ui_button(ui_gen_id(), ICON_DOWN, down_rec, style = go_style) {
		if 0 < state.current_layer {
			state.current_layer -= 1
		}
	}
}

color_panel_view :: proc(state: ^Project_State, rec: Rec) {
	area := rec

	@(static) selected: int
	options := [?]UI_Option {
		{ id = ui_gen_id(), text = "Color picker" },
		{ id = ui_gen_id(), text = "Pallete" }
	}

	options_style := UI_OPTION_STYLE_DEFAULT
	options_style.option_style.text_color = rl.Fade(COLOR_TEXT_0, 0.7)
	options_rec := rec_cut_top(&area, ui_default_widget_height())
	ui_option(ui_gen_id(), options[:], &selected, options_rec, options_style)
	
	if selected == 0 {
		ui_color_picker(ui_gen_id(), &state.current_color, area)
	}
	else {
		color_pallete_view(state, area)
	}
}

calc_color_panel_h :: proc() -> (h: f32) {
	return ui_default_widget_height() + ui_calc_color_picker_height()
}

color_pallete_view :: proc(state: ^Project_State, rec: Rec) {
	area := rec

	buttons_area := rec_cut_top(&area, ui_default_widget_height())
	
	// add to favorites button
	fav_rec := rec_cut_left(&buttons_area, ui_default_widget_height())
	if ui_button(ui_gen_id(), ICON_STAR, fav_rec) {
		fav_scope: {
			if app.fav_palletes.len >= len(app.fav_palletes.data) {
				ui_show_notif("Favorite palletes is full")
				break fav_scope
			}
			for i in 0..<app.fav_palletes.len {
				if (app.fav_palletes.data[i].name == state.pallete.name) {
					ui_show_notif("Pallete with the same name already exists", UI_NOTIF_STYLE_ERROR)
					break fav_scope
				}
			}

			sa.append(&app.fav_palletes, Pallete {
				colors = state.pallete.colors,
				name = strings.clone(state.pallete.name)
			})
			ui_show_notif("Added to favorites")
		}
	}

	rec_cut_left(&buttons_area, ui_px(8))
	
	// load pallete button
	load_rec := rec_cut_right(&buttons_area, ui_calc_button_width("load"))
	if open, content_rec :=  ui_begin_menu_button(ui_gen_id(), "Load", ui_px(160), 2, load_rec); open {
		area := content_rec
		if ui_menu_item(ui_gen_id(), "From file", &area) {
			from_file_scope: {
				ui_close_current_popup()
		
				path, res := pick_file_dilaog("", context.temp_allocator)
				if res == .Error {
					ui_show_notif("Failed to load pallete", UI_NOTIF_STYLE_ERROR)
				}
				else if res == .Cancel {
					break from_file_scope
				}
				path_cstring := strings.clone_to_cstring(path, context.temp_allocator)
		
				/* sa.clear() isn't enough to clear the palletes since 
				we do slice.contains() a couple of lines below */  
				for i in 0..<state.pallete.colors.len {
					state.pallete.colors.data[i] = {}
				}
				sa.clear(&state.pallete.colors)
		
				image := rl.LoadImage(path_cstring)
				defer rl.UnloadImage(image)
				color_count := image.width * image.height
				for i in 0..<(color_count) {			
					x := i % image.width
					y := i32(i / image.width)
					color := rgb_to_hsv(rl.GetImageColor(image, x, y))
					if slice.contains(state.pallete.colors.data[:], color) {
						continue
					}
					if state.pallete.colors.len >= len(state.pallete.colors.data) {
						ui_show_notif("Image color count over the limit", UI_NOTIF_STYLE_ERROR)
						break
					}
					sa.append(&state.pallete.colors, color)
				}
		
				delete(state.pallete.name)
				state.pallete.name = shorten_path(path)
			}
		}
		if ui_menu_item(ui_gen_id(), "From favorites", &area) {
			ui_close_current_popup()
			ui_open_popup(popup_fav_palletes)
		}
	}
	ui_end_menu_button()

	ui_draw_text(state.pallete.name, buttons_area, { .Center, .Center })

	// pallete list
	ui_draw_rec(COLOR_BASE_0, area)
	list_rec := rec_pad(area, ui_px(8))
	pallete_x := list_rec.x
	pallete_y := list_rec.y
	pallete_size := ui_default_widget_height()
	spacing := ui_px(8)

	@(static) scroll, lerped_scroll: f32
	_, items := ui_begin_list_wrapped(ui_gen_id(), &scroll, &lerped_scroll, ui_default_widget_height(), state.pallete.colors.len, list_rec)
	for item in items {
		pallete_id := ui_gen_id(item.i)
		is_selected := state.current_color == state.pallete.colors.data[item.i]
		pallete_rec := is_selected ? rec_pad(item.rec, ui_px(4)) : item.rec

		ui_update_widget(pallete_id, item.rec)
		ui_draw_rec(hsv_to_rgb(state.pallete.colors.data[item.i]), pallete_rec)
		
		if pallete_id == ui_ctx.hovered_widget && ui_clicked(.LEFT) {
			state.current_color = state.pallete.colors.data[item.i]
		}
		if is_selected {
			ui_draw_rec_outline(COLOR_TEXT_0, 2, item.rec)
		}
		else if pallete_id == ui_ctx.hovered_widget {
			ui_draw_rec_outline(rl.Fade(COLOR_TEXT_0, 0.5), 2, item.rec)
		}
	}
	ui_end_list()
	ui_draw_rec_outline(COLOR_BASE_0, 1, rec)
}

fav_palletes_popup_view :: proc(state: ^Project_State) {
	screen_rec := ui_get_screen_rec()

	rec := rec_center_in_area({ 0, 0, ui_px(400), ui_px(200) }, screen_rec)
	if open, content_rec := ui_begin_popup_title(popup_fav_palletes, "Favorite palletes", rec); open {
		content_rec := rec_pad(content_rec, ui_px(8))

		@(static) scroll, lerped_scroll: f32
		_, items := ui_begin_list(ui_gen_id(), &scroll, &lerped_scroll, ui_default_widget_height(), app.fav_palletes.len, content_rec)
		for &item, i in items {			
			item_rec := item.rec

			// show delete button on hover 
			if ui_is_mouse_in_rec(item_rec) {
				delete_style := UI_BUTTON_STYLE_DEFAULT
				delete_style.bg_color = COLOR_ERROR_0
				delete_style.bg_color_hovered = COLOR_ERROR_0
				delete_style.bg_color_active = COLOR_ERROR_0
				delete_style.text_color = COLOR_BASE_0
				delete_rec := rec_cut_right(&item_rec, ui_default_widget_height())
				if ui_button(ui_gen_id(item.i), ICON_TRASH, delete_rec, style = delete_style) {
					delete(app.fav_palletes.data[item.i].name)
					sa.ordered_remove(&app.fav_palletes, item.i)
				}
			}

			// list item
			current_pallete := &app.fav_palletes.data[item.i]
			item_style := UI_BUTTON_STYLE_DEFAULT
			item_style.text_align = { .Left, .Center }
			if item.i % 2 == 0 {
				item_style.bg_color.a = 200
			}
			if ui_button(ui_gen_id(item.i), current_pallete.name, item_rec, style = item_style) {
				delete(state.pallete.name)
				state.pallete.name = strings.clone(current_pallete.name)
				sa.clear(&state.pallete.colors)
				for i in 0..<current_pallete.colors.len {
					color := app.fav_palletes.data[item.i].colors.data[i]
					sa.append(&state.pallete.colors, color)
				}
				ui_close_current_popup()
			}

		}
		ui_end_list()
		ui_draw_rec_outline(COLOR_BASE_0, 1, content_rec)
	}
	ui_end_popup()
}

preview_view :: proc(state: ^Project_State, rec: Rec) {
	area := rec
	id := ui_gen_id()
	ui_update_widget(id, area)

	if ui_ctx.hovered_widget == id {
		update_zoom(&state.preview_zoom, 2, 1, 100)
	}
	state.lerped_preview_zoom = rl.Lerp(state.lerped_preview_zoom, state.preview_zoom, 20 * rl.GetFrameTime())
	// work around for lerp never (taking too long) reaching it's desteniton 
	if math.abs(state.preview_zoom - state.lerped_preview_zoom) < 0.01 {
		state.lerped_preview_zoom = state.preview_zoom
	}

	if ui_ctx.active_widget == id {
		state.preview_rotation -= rl.GetMouseDelta().x 
	}
	else if state.auto_rotate_preview {
		state.preview_rotation -= state.preview_rotation_speed * rl.GetFrameTime()
	}

	ui_begin_clip(area)
	ui_push_command(UI_Draw_Preview {
		rec = area,
	})

	settings_rec := Rec {
		area.x + area.width - ui_default_widget_height() - ui_px(8),
		area.y + ui_px(8),
		ui_default_widget_height(),
		ui_default_widget_height(),
	}
	if ui_button(ui_gen_id(), ICON_SETTINGS, settings_rec, false, style = UI_BUTTON_STYLE_TRANSPARENT) {
		ui_open_popup(popup_preview_settings)
	}
	ui_end_clip()
}

new_project_popup_view :: proc(state: ^Screen_State) {
	can_shortcut := ui_ctx.text_mode_slider == 0
	ui_close_popup_on_esc(popup_new_project)

	screen_rec := ui_get_screen_rec()
	
	popup_h := ui_calc_popup_height(3, ui_default_widget_height(), ui_px(8), ui_px(16))
	popup_rec := rec_center_in_area({ 0, 0, ui_px(400), popup_h }, screen_rec)
	
	if open, rec := ui_begin_popup_title(popup_new_project, "New project", popup_rec); open {
		area := rec_pad(rec, ui_px(16))
		ui_slider_i32(ui_gen_id(), "Width", &app.new_project_width, 2, 32, rec_cut_top(&area, ui_default_widget_height()))
		rec_delete_top(&area, ui_px(8))
		
		ui_slider_i32(ui_gen_id(), "Height", &app.new_project_height, 2, 32, rec_cut_top(&area, ui_default_widget_height()))
		rec_delete_top(&area, ui_px(8))
		
		if ui_button(ui_gen_id(), "Create", area) || (can_shortcut && rl.IsKeyPressed(.ENTER)) {
			create_project :: proc() {
				project: Project_State
				load_project_state(&project, "", app.new_project_width, app.new_project_height)
				schedule_state_change(project)
				ui_close_all_popups()
			}
			project, project_open := &app.state.(Project_State)
			if project_open && is_saved(project) == false {
				confirm_project_exit(project, proc(state: ^Project_State) { 
					create_project() 
				})
			}
			else {
				create_project()
			}
		}	
	}
	ui_end_popup()
}

preview_settings_popup_view :: proc(state: ^Project_State) {
	ui_close_popup_on_esc(popup_preview_settings)

	screen_rec := ui_get_screen_rec()
	
	popup_h := ui_calc_popup_height(4, ui_default_widget_height(), ui_px(8), ui_px(16))
	popup_area := rec_center_in_area({ 0, 0, ui_px(300), popup_h }, screen_rec)
	if open, rec := ui_begin_popup_title(popup_preview_settings, "Preview settings", popup_area); open {
		area := rec_pad(rec, ui_px(16))
		auto_rotate_rec := rec_cut_top(&area, ui_default_widget_height())
		ui_check_box(ui_gen_id(),"Auto rotate", &state.auto_rotate_preview, auto_rotate_rec)
		rec_delete_top(&area, ui_px(8))

		ui_slider_f32(ui_gen_id(), "Rotation speed", &state.preview_rotation_speed, 5, 30, rec_cut_top(&area, ui_default_widget_height()))
		rec_delete_top(&area, ui_px(8))
		
		ui_slider_f32(ui_gen_id(), "Spacing", &state.spacing, 0.1, 2, rec_cut_top(&area, ui_default_widget_height()))
		rec_delete_top(&area, ui_px(8))
		
		ui_color_button(ui_gen_id(), "BG color", &state.preview_bg_color, area)
	}
	ui_end_popup()
}

bg_colors_popup_view :: proc(state: ^Project_State) {
	screen_rec := ui_get_screen_rec()

	popup_h := ui_calc_popup_height(2, ui_default_widget_height(), ui_px(8), ui_px(16))
	popup_area := rec_center_in_area({ 0, 0, ui_px(300), popup_h }, screen_rec)
	if open, rec := ui_begin_popup_title(popup_bg_colors, "BG colors", popup_area); open {
		area := rec_pad(rec, ui_px(16))
		
		color1_rec := rec_cut_top(&area, ui_default_widget_height())
		ui_color_button(ui_gen_id(), "BG color 1", &state.bg_color1, color1_rec)
		
		rec_cut_top(&area, ui_px(8))
		
		color2_rec := rec_cut_top(&area, ui_default_widget_height())
		ui_color_button(ui_gen_id(), "BG color 2", &state.bg_color2, color2_rec)

		// HACK
		if rl.IsMouseButtonReleased(.LEFT) {
			create_bg_texture(state)
		}
	}
	ui_end_popup()
}

settings_popup_view :: proc() {
	screen_rec := ui_get_screen_rec()
	
	ui_close_popup_on_esc(popup_settings)
	popup_h := ui_calc_popup_height(5, ui_default_widget_height(), ui_px(8), ui_px(16))
	popup_area := rec_center_in_area({ 0, 0, ui_px(500), popup_h }, screen_rec)
	if open, rec := ui_begin_popup_title(popup_settings, "Settings", popup_area); open 
	{
		area := rec_pad(popup_area, ui_px(16))
		
		ui_slider_f32(ui_gen_id(), "UI Scale", &ui_ctx.scale, 0.5, 2, rec_cut_top(&area, ui_default_widget_height()))
		rec_cut_top(&area, ui_px(8))
		
		ui_check_box(ui_gen_id(), "Enable custom cursors", &app.enable_custom_cursors, rec_cut_top(&area, ui_default_widget_height()))
		rec_cut_top(&area, ui_px(8))
		
		ui_check_box(ui_gen_id(), "Darken right side of welcome screen", &app.darken_welcome_screen, rec_cut_top(&area, ui_default_widget_height()))
		rec_cut_top(&area, ui_px(8))
		
		/* HACK: ther's a funny bug where if act_on_press is true and you click on 
		the checkbox you toggle it to false (clicks are now registered when you release the mouse button)
		and if you release the mouse button while on the checkbox you toggle it on again */ 
		press := ui_ctx.act_on_press
		ui_ctx.act_on_press = true
		ui_check_box(ui_gen_id(), "Act on press", &press, rec_cut_top(&area, ui_default_widget_height()))
		ui_ctx.act_on_press = press

		PRESS_TEXT :: "Determines if ui clicks should be registerd\nimmediatly or when the button is released"
		ui_draw_text(PRESS_TEXT, rec_cut_top(&area, ui_default_widget_height()), color = COLOR_BASE_4)
	}
	ui_end_popup()
}

exit_popup_view :: proc(state: ^Project_State) {
	screen_rec := ui_get_screen_rec()
	
	popup_h := ui_calc_popup_height(2, ui_default_widget_height(), ui_px(8), ui_px(16))
	popup_area := rec_center_in_area({ 0, 0, ui_px(300), popup_h }, screen_rec)
	if open, rec := ui_begin_popup_title(popup_exit, "Confirm", popup_area); open {
		area := rec_pad(rec, ui_px(16))
		
		ui_draw_text("Save changes to the project?", rec_cut_top(&area, ui_default_widget_height()), align = { .Center, .Center })
		
		rec_cut_top(&area, ui_px(8))
		buttons_area := rec_cut_top(&area, ui_default_widget_height())
		button_w := buttons_area.width / 3 - ui_px(2)
		if ui_button(ui_gen_id(), "Cancel", rec_cut_right(&buttons_area, button_w)) || rl.IsKeyPressed(.ESCAPE) {
			ui_close_current_popup()
		}

		exiting := false

		rec_cut_right(&buttons_area, ui_px(4))
		if ui_button(ui_gen_id(), "No", rec_cut_right(&buttons_area, button_w)) || rl.IsKeyPressed(.N) {
			exiting = true
		}
		
		rec_cut_right(&buttons_area, ui_px(4))
		if ui_button(ui_gen_id(), "Yes", rec_cut_right(&buttons_area, button_w)) || rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.Y) {
			exiting = try_save_prject(state)
		}
		
		if exiting {
			state.exit_popup_confirm(state)
		}
	}
	ui_end_popup()
}

confirm_project_exit :: proc(state: ^Project_State, callback: proc(state: ^Project_State)) {
	state.exit_popup_confirm = callback
	ui_open_popup(popup_exit)
}

go_to_welcome_screen :: proc(state: ^Project_State) {
	if is_saved(state) {
		welcome_state := Welcome_State {}
		init_welcome_state(&welcome_state)
		schedule_state_change(welcome_state)
		ui_close_all_popups()
	}
	else {
		confirm_project_exit(state, proc(state: ^Project_State) {
			welcome_state := Welcome_State {}
			init_welcome_state(&welcome_state)
			schedule_state_change(welcome_state)
			ui_close_all_popups()
		})
	}
}

togglable_button :: proc(id: UI_ID, text: string, toggled: bool, rec: Rec, font_size: f32 = 0) -> (clicked: bool) {
	active_style := UI_BUTTON_STYLE_DEFAULT
	active_style.bg_color = COLOR_ACCENT_0
	active_style.bg_color_hovered = COLOR_ACCENT_0
	active_style.bg_color_active = COLOR_ACCENT_0
	active_style.text_color = COLOR_BASE_0
	
	style := toggled ? active_style : UI_BUTTON_STYLE_DEFAULT
	style.font_size = font_size
	return ui_button(id, text, rec, style = style)
}

// backend code

deinit_app :: proc() {
	switch &state in app.state {
		case Project_State: {
			deinit_project_state(&state)
		}
		case Welcome_State: {
			deinit_welcome_state(&state)
		}
	}

	for i in 0..<app.fav_palletes.len {
		delete(app.fav_palletes.data[i].name)
	}
	for i in 0..<app.recent_projects.len {
		delete(app.recent_projects.data[i])
	}
}

load_app_data :: proc(path: string) {
	if os.exists("data.ini") == false {
		file, create_err := os.create("data.ini")
		defer os.close(file)
	}

	loaded_map, alloc_err, loaded := ini.load_map_from_path(path, context.temp_allocator)
	assert(alloc_err == nil)
	if loaded == false {
		return
	}
	
	app.show_fps = ini_read_bool(loaded_map, "", "show_fps")
	app.unlock_fps = ini_read_bool(loaded_map, "", "unlock_fps")
	app.new_project_width = i32(ini_read_int(loaded_map, "", "new_project_width", 16))
	app.new_project_height = i32(ini_read_int(loaded_map, "", "new_project_height", 16))
	ui_set_scale(ini_read_f32(loaded_map, "", "ui_scale"))
	ui_ctx.act_on_press = ini_read_bool(loaded_map, "", "act_on_press")
	app.enable_custom_cursors = ini_read_bool(loaded_map, "", "enable_custom_cursors", true)
	app.darken_welcome_screen = ini_read_bool(loaded_map, "", "darken_welcome_screen")

	app.active_tools.pen_size = ini_read_bool(loaded_map, "tool_bar", "pen_size", true)
	app.active_tools.onion_skinning = ini_read_bool(loaded_map, "tool_bar", "onion_skinning")
	app.active_tools.add_layer_at_top = ini_read_bool(loaded_map, "tool_bar", "add_layer_at_top", true)
	app.active_tools.add_layer_above = ini_read_bool(loaded_map, "tool_bar", "add_layer_above", true)
	app.active_tools.duplicate_layer = ini_read_bool(loaded_map, "tool_bar", "duplicate_layer", true)
	app.active_tools.move_layer = ini_read_bool(loaded_map, "tool_bar", "move_layer")
	app.active_tools.clear_layer = ini_read_bool(loaded_map, "tool_bar", "clear_layer")
	app.active_tools.delete_layer = ini_read_bool(loaded_map, "tool_bar", "delete_layer", true)

	sa.clear(&app.recent_projects)
	if "recent_projects" in loaded_map {
		len := ini_read_int(loaded_map, "recent_projects", "len")
		for i in 0..<len {
			recent := ini_read_string(loaded_map, "recent_projects", fmt.tprint(i))
			if recent == "" {
				continue
			}
			sa.append(&app.recent_projects, recent)
		}
	}

	fav_palletes_len := ini_read_int(loaded_map, "", "fav_palletes_len")
	app.fav_palletes.len = fav_palletes_len
	for i in 0..<fav_palletes_len {
		section := fmt.tprint("fav_pallete", i, sep = "")
		app.fav_palletes.data[i].name = ini_read_string(loaded_map, section, "name")
		pallete_count := ini_read_int(loaded_map, section, "len")
		app.fav_palletes.data[i].colors.len = pallete_count
		for j in 0..<pallete_count {
			h := ini_read_f32(loaded_map, section, fmt.tprint("h", j, sep = ""))
			s := ini_read_f32(loaded_map, section, fmt.tprint("s", j, sep = ""))
			v := ini_read_f32(loaded_map, section, fmt.tprint("v", j, sep = ""))
			app.fav_palletes.data[i].colors.data[j][0] = h
			app.fav_palletes.data[i].colors.data[j][1] = s
			app.fav_palletes.data[i].colors.data[j][2] = v
		}
	}
}

save_app_data :: proc() {
	os.remove("data.ini")
	file, create_err := os.create("data.ini")
	defer os.close(file)
	if create_err != nil {
		return
	}

	ini.write_pair(file.stream, "new_project_width", app.new_project_width)
	ini.write_pair(file.stream, "new_project_height", app.new_project_height)
	ini.write_pair(file.stream, "show_fps", app.show_fps)
	ini.write_pair(file.stream, "unlock_fps", app.unlock_fps)
	ini.write_pair(file.stream, "fav_palletes_len", app.fav_palletes.len)
	ini.write_pair(file.stream, "ui_scale", ui_ctx.scale)
	ini.write_pair(file.stream, "act_on_press", ui_ctx.act_on_press)
	ini.write_pair(file.stream, "enable_custom_cursors", app.enable_custom_cursors)
	ini.write_pair(file.stream, "darken_welcome_screen", app.darken_welcome_screen)

	ini.write_section(file.stream, "tool_bar")
	ini.write_pair(file.stream, "pen_size", app.active_tools.pen_size)
	ini.write_pair(file.stream, "onion_skinning", app.active_tools.onion_skinning)
	ini.write_pair(file.stream, "add_layer_at_top", app.active_tools.add_layer_at_top)
	ini.write_pair(file.stream, "add_layer_above", app.active_tools.add_layer_above)
	ini.write_pair(file.stream, "duplicate_layer", app.active_tools.duplicate_layer)
	ini.write_pair(file.stream, "move_layer", app.active_tools.move_layer)
	ini.write_pair(file.stream, "clear_layer", app.active_tools.clear_layer)
	ini.write_pair(file.stream, "delete_layer", app.active_tools.delete_layer)

	ini.write_section(file.stream, "recent_projects")
	ini.write_pair(file.stream, "len", app.recent_projects.len)
	for i in 0..<app.recent_projects.len {
		recent := app.recent_projects.data[i]
		ini.write_pair(file.stream, fmt.tprint(i), recent)
	}

	for i in 0..<app.fav_palletes.len {
		pallete := &app.fav_palletes.data[i]
		ini.write_section(file.stream, fmt.tprint("fav_pallete", i, sep = ""))
		ini.write_pair(file.stream, "name", pallete.name)
		ini.write_pair(file.stream, "len", pallete.colors.len)
		for i in 0..<pallete.colors.len {
			color := pallete.colors.data[i]
			ini.write_pair(file.stream, fmt.tprint("h", i, sep = ""), color[0])
			ini.write_pair(file.stream, fmt.tprint("s", i, sep = ""), color[1])
			ini.write_pair(file.stream, fmt.tprint("v", i, sep = ""), color[2])	
		}
	}
}

init_welcome_state :: proc(state: ^Welcome_State) {
	mascot_data := #load("../res/darko2.png")
	mascot_image := rl.LoadImageFromMemory(".png", raw_data(mascot_data), i32(len(mascot_data)))
	defer rl.UnloadImage(mascot_image)
	state.mascot = rl.LoadTextureFromImage(mascot_image)
} 

deinit_welcome_state :: proc(state: ^Welcome_State) {
	rl.UnloadTexture(state.mascot)
} 

/* loads project state
use an empty string for dir to make a blank project
TODO: return an error value instead of a bool */
load_project_state :: proc(state: ^Project_State, dir: string, default_w := i32(16), default_h := i32(16)) -> (ok: bool) {
	data_path := fmt.tprint(dir, "\\project.ini", sep = "")
	cstring_data_path := fmt.ctprint(data_path)

	sprites_path := fmt.tprint(dir, "\\sprites.png", sep = "")
	cstring_sprites_path := fmt.ctprint(sprites_path)

	loaded_map, alloc_err, loaded := ini.load_map_from_path(data_path, context.temp_allocator)
	assert(alloc_err == nil)
	if dir != "" && loaded == false {
		return false
	}

	loaded_state: Project_State
	
	loaded_state.export_dir = ini_read_string(loaded_map, "", "export_dir")
	loaded_state.zoom = ini_read_f32(loaded_map, "", "zoom", 1)
	loaded_state.spacing = ini_read_f32(loaded_map, "", "spacing", 1)
	loaded_state.current_layer = ini_read_int(loaded_map, "", "current_layer", 0)
	loaded_state.preview_zoom = ini_read_f32(loaded_map, "", "preview_zoom", 10)
	loaded_state.preview_rotation = ini_read_f32(loaded_map, "", "preview_rotation")
	loaded_state.preview_rotation_speed = ini_read_f32(loaded_map, "", "preview_rotation_speed", 5)
	loaded_state.auto_rotate_preview = ini_read_bool(loaded_map, "", "auto_rotate_preview", true)
	loaded_state.width = i32(ini_read_int(loaded_map, "", "width", int(default_w)))
	loaded_state.height = i32(ini_read_int(loaded_map, "", "height", int(default_h)))
	loaded_state.hide_grid = ini_read_bool(loaded_map, "", "hide_grid")
	loaded_state.onion_skinning = ini_read_bool(loaded_map, "", "onion_skinning")
	loaded_state.show_bg = ini_read_bool(loaded_map, "", "show_bg")
	loaded_state.pen_size = i32(ini_read_int(loaded_map, "", "pen_size", 1))

	loaded_state.current_color[0] = ini_read_f32(loaded_map, "current_color", "h")
	loaded_state.current_color[1] = ini_read_f32(loaded_map, "current_color", "s")
	loaded_state.current_color[2] = ini_read_f32(loaded_map, "current_color", "v")
	
	loaded_state.preview_bg_color[0] = ini_read_f32(loaded_map, "preview_bg_color", "h", 250)
	loaded_state.preview_bg_color[1] = ini_read_f32(loaded_map, "preview_bg_color", "s", 0.35)
	loaded_state.preview_bg_color[2] = ini_read_f32(loaded_map, "preview_bg_color", "v", 0.7)

	loaded_state.bg_color1[0] = ini_read_f32(loaded_map, "bg_color1", "h", 240)
	loaded_state.bg_color1[1] = ini_read_f32(loaded_map, "bg_color1", "s", 0.3)
	loaded_state.bg_color1[2] = ini_read_f32(loaded_map, "bg_color1", "v", 0.7)
	loaded_state.bg_color2[0] = ini_read_f32(loaded_map, "bg_color2", "h", 240)
	loaded_state.bg_color2[1] = ini_read_f32(loaded_map, "bg_color2", "s", 0.3)
	loaded_state.bg_color2[2] = ini_read_f32(loaded_map, "bg_color2", "v", 1)
	create_bg_texture(&loaded_state)

	loaded_state.pallete.name = ini_read_string(loaded_map, "pallete", "name")
	pallete_count := ini_read_int(loaded_map, "pallete", "len")
	loaded_state.pallete.colors.len = pallete_count
	for i in 0..<pallete_count {
		h := ini_read_f32(loaded_map, "pallete", fmt.tprint("h", i, sep = ""))
		s := ini_read_f32(loaded_map, "pallete", fmt.tprint("s", i, sep = ""))
		v := ini_read_f32(loaded_map, "pallete", fmt.tprint("v", i, sep = ""))
		loaded_state.pallete.colors.data[i][0] = h
		loaded_state.pallete.colors.data[i][1] = s
		loaded_state.pallete.colors.data[i][2] = v
	}

	loaded_state.dir = strings.clone(dir)
	loaded_state.lerped_current_layer = f32(loaded_state.current_layer)
	loaded_state.lerped_zoom = 0
	loaded_state.lerped_preview_zoom = 0

	loaded_state.layers = make([dynamic]Layer)
	loaded_state.undos = make([dynamic]Action)
	loaded_state.redos = make([dynamic]Action)
	loaded_state.dirty_layers = make([dynamic]int)

	// load layers
	sprites := rl.Image {}
	defer rl.UnloadImage(sprites)
	
	if os.exists(sprites_path) {
		sprites = rl.LoadImage(cstring_sprites_path)
	}
	else {
		sprites = rl.GenImageColor(default_w, default_h, rl.BLANK)
	}

	layer_w := f32(loaded_state.width)
	layer_h := f32(loaded_state.height)
	layer_count := sprites.width / i32(layer_w)
	for i in 0..<layer_count {
		image := rl.ImageFromImage(sprites, { f32(i) * layer_w, 0, layer_w, layer_h })
		append(&loaded_state.layers, Layer {
			image = image,
			texture = rl.LoadTextureFromImage(image)
		})
	}

	state^ = loaded_state
	return true
}

// TODO: return an error value instead of a bool
save_project_state :: proc(state: ^Project_State, dir: string) -> (ok: bool) {
	state.undos_len_on_save = len(state.undos)
	if state.dir != dir {
		delete(state.dir)
		state.dir = strings.clone(dir)
	}

	// clear the directory
	remove_err := os.remove_all(dir)
	if remove_err != os.ERROR_NONE {
		fmt.printfln("{}", remove_err)
		return false
	}
	make_dir_err := os.make_directory(dir)
	if make_dir_err != os.ERROR_NONE {
		fmt.printfln("{}", make_dir_err)
		return false
	}

	file, create_err := os.create(fmt.tprintf("{}\\project.ini", dir))
	defer os.close(file)
	if create_err != nil {
		return
	}

	ini.write_pair(file.stream, "export_dir", state.export_dir)
	ini.write_pair(file.stream, "zoom", state.zoom)
	ini.write_pair(file.stream, "spacing", state.spacing)
	ini.write_pair(file.stream, "current_layer", state.current_layer)
	ini.write_pair(file.stream, "preview_zoom", state.preview_zoom)
	ini.write_pair(file.stream, "preview_rotation", state.preview_rotation)
	ini.write_pair(file.stream, "preview_rotation_speed", state.preview_rotation_speed)
	ini.write_pair(file.stream, "auto_rotate_preview", state.auto_rotate_preview)
	ini.write_pair(file.stream, "width", state.width)
	ini.write_pair(file.stream, "height", state.height)
	ini.write_pair(file.stream, "hide_grid", state.hide_grid)
	ini.write_pair(file.stream, "onion_skinning", state.onion_skinning)
	ini.write_pair(file.stream, "show_bg", state.show_bg)
	ini.write_pair(file.stream, "pen_size", state.pen_size)

	ini.write_section(file.stream, "current_color")
	ini.write_pair(file.stream, "h", state.current_color[0])
	ini.write_pair(file.stream, "s", state.current_color[1])
	ini.write_pair(file.stream, "v", state.current_color[2])

	ini.write_section(file.stream, "preview_bg_color")
	ini.write_pair(file.stream, "h", state.preview_bg_color[0])
	ini.write_pair(file.stream, "s", state.preview_bg_color[1])
	ini.write_pair(file.stream, "v", state.preview_bg_color[2])

	ini.write_section(file.stream, "bg_color1")
	ini.write_pair(file.stream, "h", state.bg_color1[0])
	ini.write_pair(file.stream, "s", state.bg_color1[1])
	ini.write_pair(file.stream, "v", state.bg_color1[2])

	ini.write_section(file.stream, "bg_color2")
	ini.write_pair(file.stream, "h", state.bg_color2[0])
	ini.write_pair(file.stream, "s", state.bg_color2[1])
	ini.write_pair(file.stream, "v", state.bg_color2[2])

	ini.write_section(file.stream, "pallete")
	ini.write_pair(file.stream, "name", state.pallete.name)
	ini.write_pair(file.stream, "len", state.pallete.colors.len)
	for i in 0..<state.pallete.colors.len {
		color := state.pallete.colors.data[i]
		ini.write_pair(file.stream, fmt.tprint("h", i, sep = ""), fmt.tprint(color[0]))
		ini.write_pair(file.stream, fmt.tprint("s", i, sep = ""), fmt.tprint(color[1]))
		ini.write_pair(file.stream, fmt.tprint("v", i, sep = ""), fmt.tprint(color[2]))	
	}

	// save layers into one image
	sprites := rl.GenImageColor(state.width * i32(len(state.layers)), state.height, rl.BLANK)
	layer_w := f32(state.width)
	layer_h := f32(state.height)
	for layer, i in state.layers {
		src_rec := Rec { 0, 0, layer_w, layer_h }
		dest_rec := Rec { layer_w * f32(i), 0, layer_w, layer_h }
		rl.ImageDraw(&sprites, layer.image, src_rec, dest_rec, rl.WHITE)
	}
	rl.ExportImage(sprites, fmt.ctprintf("{}\\sprites.png", dir))

	return true
}

// TODO: return an error value instead of a bool
export_project_state :: proc(state: ^Project_State, dir: string) -> (ok: bool) {
	if state.export_dir != dir {
		delete(state.export_dir)
		state.export_dir = strings.clone(dir)
	}

	// clear the directory
	remove_err := os.remove_all(dir)
	if remove_err != os.ERROR_NONE {
		fmt.printfln("{}", remove_err)
		return false
	}
	make_dir_err := os.make_directory(dir)
	if make_dir_err != os.ERROR_NONE {
		fmt.printfln("{}", make_dir_err)
		return false
	}

	file, create_err := os.create(fmt.tprintf("{}\\data.ini", dir))
	defer os.close(file)
	if create_err != nil {
		return
	}

	ini.write_pair(file.stream, "spacing", state.spacing)
	ini.write_pair(file.stream, "width", state.width)
	ini.write_pair(file.stream, "height", state.height)

	// save layers into one image
	sprites := rl.GenImageColor(state.width * i32(len(state.layers)), state.height, rl.BLANK)
	layer_w := f32(state.width)
	layer_h := f32(state.height)
	for layer, i in state.layers {
		src_rec := Rec { 0, 0, layer_w, layer_h }
		dest_rec := Rec { layer_w * f32(i), 0, layer_w, layer_h }
		rl.ImageDraw(&sprites, layer.image, src_rec, dest_rec, rl.WHITE)
	}
	rl.ExportImage(sprites, fmt.ctprintf("{}\\sprites.png", dir))

	return true
}

deinit_project_state :: proc(state: ^Project_State) {
	delete(state.dir)
	delete(state.export_dir)
	for &layer in state.layers {
		deinit_layer(&layer)
	}
	delete(state.layers)
	for action in state.undos {
		action_deinit(action)
	}
	delete(state.undos)
	for action in state.redos {
		action_deinit(action)
	}
	delete(state.redos)
	delete(state.dirty_layers)
	if copied_image, exists := state.copied_image.?; exists {
		rl.UnloadImage(copied_image)
	}
	rl.UnloadTexture(state.bg_texture)
	delete(state.pallete.name)
}

try_open_project :: proc() {
	_open :: proc(default_dir := "") {
		ui_close_all_popups()
		
		path, res := pick_folder_dialog(default_dir, context.temp_allocator)
		if res == .Error {
			ui_show_notif("Failed to open project", UI_NOTIF_STYLE_ERROR)
		}
		else if res == .Cancel {
			return
		}
	
		loaded_project: Project_State
		loaded := load_project_state(&loaded_project, path)
		if loaded == false {
			ui_show_notif("Failed to open project", UI_NOTIF_STYLE_ERROR)
			return
		}
			
		schedule_state_change(loaded_project)
	}
	switch &state in app.state {
		case Welcome_State: {
			_open()
		}
		case Project_State: {
			if is_saved(&state) {
				_open(state.dir)
			}
			else {
				confirm_project_exit(&state, proc(state: ^Project_State) { _open(state.dir) })
			}
		}
	}
}

try_save_prject :: proc(state: ^Project_State, force_open_dialog := false) -> (saved: bool) {
	saved = false
	
	path := state.dir
	if force_open_dialog || path == "" {
		res := ntf.Result {}
		path, res = pick_folder_dialog(state.dir, context.temp_allocator)
		if res == .Error {
			ui_show_notif("Failed to save project", UI_NOTIF_STYLE_ERROR)
		}
		else if res == .Cancel {
			return saved
		}
	}

	saved = save_project_state(state, path)
	if saved == false {
		ui_show_notif("Failed to save project", UI_NOTIF_STYLE_ERROR)
		return saved
	}

	add_recent_project(state.dir)
	ui_show_notif("Project is saved")
	return saved
}

try_export_project :: proc(state: ^Project_State) -> (exported: bool) {
	exported = false

	path, res := pick_folder_dialog(state.export_dir, context.temp_allocator)
	if res == .Error {
		ui_show_notif("Failed to export project", UI_NOTIF_STYLE_ERROR)
	}
	else if res == .Cancel {
		return false
	}

	exported = export_project_state(state, path)
	if exported == false {
		ui_show_notif("Failed to export project", UI_NOTIF_STYLE_ERROR)
		return false
	}

	ui_show_notif("Project is exported")
	return true
}

add_recent_project :: proc(path: string) {
	// remove first recent when recent_projects is full
	if app.recent_projects.len >= len(app.recent_projects.data) {
		delete(app.recent_projects.data[0])
		sa.ordered_remove(&app.recent_projects, 0)
	}

	// remove duplicate recents
	if index, found := slice.linear_search(app.recent_projects.data[:], path); found {
		if found {
			delete(app.recent_projects.data[index])
			sa.ordered_remove(&app.recent_projects, index)
		}
	}

	sa.append(&app.recent_projects, strings.clone(path))
}

// NOTE: deinit calls for the previous state are handled automatically 
schedule_state_change :: proc(state: Screen_State) {
	app.next_state = state
}

init_layer :: proc(layer: ^Layer, width, height: i32) {
	image := rl.GenImageColor(width, height, rl.BLANK)
	texture := rl.LoadTextureFromImage(image)
	layer.image = image
	layer.texture = texture
}

deinit_layer :: proc(layer: ^Layer) {
	rl.UnloadTexture(layer.texture)
	rl.UnloadImage(layer.image)
}

get_current_layer :: #force_inline proc(state: ^Project_State) -> (layer: ^Layer) {
	return &state.layers[state.current_layer]
}

mark_dirty_layers :: proc(state: ^Project_State, indexes: ..int) {
	append(&state.dirty_layers, ..indexes)
}

mark_all_layers_dirty :: proc(state: ^Project_State) {
	for i in 0..<len(state.layers) {
		append(&state.dirty_layers, i)
	}
}

update_tools :: proc(state: ^Project_State, area: Rec, tool: Tool) {
	can_have_input := ui_is_being_interacted() == false
	
	// color picker
	if tool == .Color_Picker && can_have_input && rl.IsMouseButtonPressed(.LEFT) {
		x, y := get_mouse_pos_in_canvas(state, area)
		rgb_color := rl.GetImageColor(get_current_layer(state).image, x, y)
		if rgb_color.a != 0 {
			state.current_color = rgb_to_hsv(rgb_color)
		}
	}

	// pen
	if tool == .Pen  {
		if can_have_input && rl.IsMouseButtonDown(.LEFT) {
			begin_image_change(state)
			
			color := hsv_to_rgb(state.current_color)			
			positions := cursor_get_positions(state, area, context.temp_allocator)
			for pos in positions {
				for i in 0..<state.pen_size {
					for j in 0..<state.pen_size {
						x := pos.x + i - (state.pen_size - 1) / 2
						y := pos.y + j - (state.pen_size - 1) / 2
						rl.ImageDrawPixel(&get_current_layer(state).image, x, y, color)
					}
				}
			}
			
			mark_dirty_layers(state, state.current_layer)	
		}

		if rl.IsMouseButtonReleased(.LEFT) {
			end_image_change(state)
			cursor_mouse_up(state)
		}
	}

	// eraser
	if tool == .Eraser {
		if can_have_input && rl.IsMouseButtonDown(.LEFT) {
			begin_image_change(state)
			
			color := hsv_to_rgb(state.current_color)			
			positions := cursor_get_positions(state, area, context.temp_allocator)
			for pos in positions {
				for i in 0..<state.pen_size {
					for j in 0..<state.pen_size {
						x := pos.x + i - (state.pen_size - 1) / 2
						y := pos.y + j - (state.pen_size - 1) / 2
						rl.ImageDrawPixel(&get_current_layer(state).image, x, y, rl.BLANK)
					}
				}
			}
			
			mark_dirty_layers(state, state.current_layer)	
		}

		if rl.IsMouseButtonReleased(.LEFT) {
			end_image_change(state)
			cursor_mouse_up(state)
		}
	}

	// fill
	if tool == .Fill && can_have_input && rl.IsMouseButtonPressed(.LEFT) {
		begin_image_change(state)
		x, y := get_mouse_pos_in_canvas(state, area)
		color := hsv_to_rgb(state.current_color)
		fill(&get_current_layer(state).image, x, y, color)
		mark_dirty_layers(state, state.current_layer)
		end_image_change(state)
	}
}

cursor_get_positions :: proc(state: ^Project_State, canvas_rec: Rec, allocator := context.allocator) -> (positions: [][2]i32) {
	pos_list := make([dynamic][2]i32, allocator)

	x, y := get_mouse_pos_in_canvas(state, canvas_rec)
	state.cursor.x = x
	state.cursor.y = y
	
	if state.cursor.active {
		append(&pos_list, ..get_line_positions(state.cursor.last_mx, state.cursor.last_my, x, y, allocator))
	}
	append(&pos_list, [2]i32 { x, y })
	
	state.cursor.last_mx = x
	state.cursor.last_my = y
	state.cursor.active = true
	
	return pos_list[:]
}

cursor_mouse_up :: proc(state: ^Project_State) {
	state.cursor.active = false
}

begin_image_change :: proc(state: ^Project_State) {
	_, exists := state.temp_undo.?
	if exists == false {
		state.temp_undo = Action_Image_Change {
			before_image = rl.ImageCopy(get_current_layer(state).image),
			layer_index = state.current_layer,
		} 
	}
}

end_image_change :: proc(state: ^Project_State) {
	temp_undo, exists := state.temp_undo.?
	action, is_correct_type := temp_undo.(Action_Image_Change)
	if exists {
		if is_correct_type {
			action.after_image = rl.ImageCopy(get_current_layer(state).image)
			action_do(state, action)
			state.temp_undo = nil			
		}
	}
}

get_mouse_pos_in_canvas :: proc(state: ^Project_State, canvas: Rec) -> (x, y: i32) {
	mpos := rl.GetMousePosition()
	px := i32(math.floor((mpos.x - canvas.x) / (canvas.width / f32(state.width))))
	py := i32(math.floor((mpos.y - canvas.y) / (canvas.height / f32(state.height))))
	return px, py
}

fill :: proc(image: ^rl.Image, x, y: i32, color: rl.Color) {
	if x < 0 || y < 0 || image.width <= x || image.height <= y {
		return
	}
	current_color := rl.GetImageColor(image^, x, y)
	if current_color == color {
		return
	}
	dfs(image, x, y, current_color, color)
}

dfs :: proc(image: ^rl.Image, x, y: i32, prev_color, new_color: rl.Color) {
	current_color := rl.GetImageColor(image^, x, y)
	if current_color != prev_color {
		return
	}

	rl.ImageDrawPixel(image, x, y, new_color)

	if x - 1 >= 0 {
		dfs(image, x - 1, y, prev_color, new_color)
	}
	if x + 1 < image^.width {
		dfs(image, x + 1, y, prev_color, new_color)
	}
	if y - 1 >= 0 {
		dfs(image, x, y - 1, prev_color, new_color)
	}
	if y + 1 < image^.height {
		dfs(image, x, y + 1, prev_color, new_color)
	}
}

// taken from https://github.com/raysan5/raylib/blob/abf255fbe73f8b15d52285746f127b376660fa40/src/rtextures.c#L3490
get_line_positions :: proc(x1, y1, x2, y2: i32, allocator := context.allocator) -> (positions: [][2]i32) {
	pos_list := make([dynamic][2]i32, allocator)

	short_len := y2 - y1
	long_len := x2 - x1
	y_longer := false
	
	if math.abs(short_len) > abs(long_len) {
		temp := short_len
		short_len = long_len
		long_len = temp
		y_longer = true
	}

	end_val := long_len
	sgn_inc := i32(1)

	if long_len < 0 {
		long_len = -long_len
		sgn_inc = -1
	}

	dec_inc := long_len == 0 ? 0 : (short_len << 16) / long_len
	if y_longer {
		i := i32(0)
		j := i32(0)
		for i != end_val {
			append(&pos_list, [2]i32 { x1 + (j >> 16), y1 + i })
			i += sgn_inc
			j += dec_inc
		} 
	}
	else {
		i := i32(0)
		j := i32(0)
		for i != end_val {
			append(&pos_list, [2]i32 { x1 + i, y1 + (j >> 16) })
			i += sgn_inc
			j += dec_inc
		} 
	}

	return pos_list[:]
}

translate_layer :: proc(state: ^Project_State, layer_index, x, y: int) {
	before_image := rl.ImageCopy(state.layers[layer_index].image)
	after_image := rl.ImageCopy(before_image)
	translate_image(state, &after_image, x, y)
	action_do(state, Action_Image_Change { 
		before_image = before_image, 
		after_image = after_image, 
		layer_index = layer_index 
	})
}

translate_image :: proc(state: ^Project_State, image: ^rl.Image, x, y: int) {
	image_rec := Rec { 0, 0, f32(state.width), f32(state.height) }
	dest_rec := Rec { f32(x), f32(y), f32(state.width), f32(state.height) }
	prev_image := rl.ImageCopy(image^)
	defer rl.UnloadImage(prev_image)
	rl.ImageClearBackground(image, rl.BLANK)
	rl.ImageDraw(image, prev_image, image_rec, dest_rec, rl.WHITE)
}

copy_layer :: proc(state: ^Project_State, layer: ^Layer) {
	if copied_image, exists := state.copied_image.?; exists {
		rl.UnloadImage(copied_image)
	}
	image := rl.ImageCopy(layer.image)
	state.copied_image = image
}

paste_layer :: proc(state: ^Project_State, layer_index: int) {
	if copied_image, exists := state.copied_image.?; exists {
		action_do(state, Action_Image_Change { 
			before_image = rl.ImageCopy(get_current_layer(state).image),
			after_image = rl.ImageCopy(copied_image),
			layer_index = layer_index,
		})
		image_rec := Rec { 0, 0, f32(state.width), f32(state.height) }
		rl.ImageClearBackground(&state.layers[layer_index].image, rl.BLANK)
		rl.ImageDraw(&state.layers[layer_index].image, copied_image, image_rec, image_rec, rl.WHITE) 
		mark_dirty_layers(state, layer_index)
	}
}

add_empty_layer :: proc(state: ^Project_State, layer_index: int) {
	action_do(state, Action_Create_Layer { current_layer_index = state.current_layer, layer_index = layer_index })
}

duplicate_layer :: proc(state: ^Project_State, from_index, to_index: int) {
	action_do(state, Action_Duplicate_Layer { from_index = from_index, to_index = to_index })
}

change_layer_index :: proc(state: ^Project_State, from_index, to_index: int) {
	action_do(state, Action_Change_Layer_Index { from_index = from_index, to_index = to_index })
}

clear_layer :: proc(state: ^Project_State, layer_index: int) {
	action_do(state, Action_Image_Change {
		before_image = rl.ImageCopy(get_current_layer(state).image),
		after_image = rl.GenImageColor(state.width, state.height, rl.BLANK),
		layer_index = state.current_layer,
	})	
}

delete_layer :: proc(state: ^Project_State, layer_index: int) {
	action_do(state, Action_Delete_Layer { layer_index = layer_index })
}

draw_sprite_stack :: proc(layers: ^[dynamic]Layer, x, y: f32, scale: f32, rotation: f32, spacing: f32) {
	spacing := spacing * scale
	y := y + f32(len(layers^) - 1) * spacing / 2
	for layer in layers {
		layer_width := f32(layer.image.width)
		layer_height := f32(layer.image.height)
		source_rec := Rec { 0, 0, layer_width, layer_height }
		dest_rec := Rec { x, y, layer_width * scale, layer_height * scale }
		origin := rl.Vector2 { layer_width * scale / 2, layer_height * scale / 2 }
		rl.DrawTexturePro(layer.texture, source_rec, dest_rec, origin, rotation, rl.WHITE)
		y -= spacing
	}
}

draw_canvas :: proc(state: ^Project_State, area: Rec) {
	src_rec := Rec { 0, 0, f32(state.width), f32(state.height) }
	if state.onion_skinning && len(state.layers) > 1 && state.current_layer > 0 {
		previous_layer := state.layers[state.current_layer - 1].texture
		rl.DrawTexturePro(previous_layer, src_rec, area, { 0, 0 }, 0, { 255, 255, 255, 100 })
	}
	rl.DrawTexturePro(get_current_layer(state).texture, src_rec, area, { 0, 0 }, 0, rl.WHITE)
}

draw_grid :: proc(slice_w, slice_h: i32, rec: Rec) {
	x_step := rec.width / f32(slice_w)
	y_step := rec.height / f32(slice_h)

	// HACK: (+ 0.1)
	x := rec.x
	for x < rec.x + rec.width + 0.1 {
		rl.DrawLineV({ x, rec.y }, { x, rec.y + rec.height }, COLOR_BASE_1)
		x += x_step
	}
	y := rec.y
	for y < rec.y + rec.height + 0.1 {
		rl.DrawLineV({ rec.x, y }, { rec.x + rec.width, y }, COLOR_BASE_1)
		y += y_step
	}
}

app_shortcuts :: proc() {
	if rl.IsKeyDown(.LEFT_CONTROL) {
		// toggle unlock_fps
		if rl.IsKeyPressed(.F1) {
			app.unlock_fps = !app.unlock_fps
			if app.unlock_fps {
				rl.SetTargetFPS(-1)
			}
			else {
				rl.SetTargetFPS(TARGET_FPS)
			}
		}
	
		// toggle show_fps
		if rl.IsKeyPressed(.F2) {
			app.show_fps = !app.show_fps
		}
	
		// zoom in ui
		if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.EQUAL) {
			ui_set_scale(ui_ctx.scale + 0.1)
		}
		// zoom out ui
		if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.MINUS) {
			ui_set_scale(ui_ctx.scale - 0.1)
		}
	
		// update these shortcuts when no textbox is active
		if ui_ctx.text_mode_slider == 0 {
			// new project
			if rl.IsKeyPressed(.N) {
				ui_open_popup(popup_new_project)
			}

			// open project
			if rl.IsKeyPressed(.O) {
				try_open_project()
			}
		}
	}
}

welcome_shortcuts :: proc(state: ^Welcome_State) {
	// open a recent project by pressing a number
	index := -1
	if rl.IsKeyPressed(.KP_1) || rl.IsKeyPressed(.ONE) {
		index = 0
	}
	if rl.IsKeyPressed(.KP_2) || rl.IsKeyPressed(.TWO) {
		index = 1
	}
	if rl.IsKeyPressed(.KP_3) || rl.IsKeyPressed(.THREE) {
		index = 2
	}
	if rl.IsKeyPressed(.KP_4) || rl.IsKeyPressed(.FOUR) {
		index = 3
	}
	if rl.IsKeyPressed(.KP_5) || rl.IsKeyPressed(.FIVE) {
		index = 4
	}
	if rl.IsKeyPressed(.KP_6) || rl.IsKeyPressed(.SIX) {
		index = 5
	}
	if rl.IsKeyPressed(.KP_7) || rl.IsKeyPressed(.SEVEN) {
		index = 6
	}
	if rl.IsKeyPressed(.KP_8) || rl.IsKeyPressed(.EIGHT) {
		index = 7
	}

	// recents are showed in reverse order in welcome screen
	index = app.recent_projects.len - index - 1

	if 0 <= index && index < app.recent_projects.len {
		project: Project_State
		ok := load_project_state(&project, app.recent_projects.data[index])
		if ok {
			schedule_state_change(project)
		}
		else {
			ui_show_notif("Could not open project")
		}
	}
}

project_shortcuts :: proc(state: ^Project_State) {
	if ui_is_any_popup_open() == false {
		if rl.IsKeyDown(.LEFT_CONTROL) {
			// save project
			if rl.IsKeyPressed(.S) {
				try_save_prject(state)
			}

			// export project
			if rl.IsKeyPressed(.E) {
				try_export_project(state)
			}

			// undo
			if rl.IsKeyPressed(.Z) {
				undo(state)
			}

			// redo
			if rl.IsKeyPressed(.Y) {
				redo(state)
			}

			// copy
			if rl.IsKeyPressed(.C) {
				copy_layer(state, get_current_layer(state))
			}

			// paste
			if rl.IsKeyPressed(.V) {
				paste_layer(state, state.current_layer)
			}

			// translate layer
			if rl.IsKeyPressed(.LEFT) {
				translate_layer(state, state.current_layer, -1, 0)
			}
			else if rl.IsKeyPressed(.RIGHT) {
				translate_layer(state, state.current_layer, 1, 0)
			}
			else if rl.IsKeyPressed(.UP) {
				translate_layer(state, state.current_layer, 0, -1)
			}
			else if rl.IsKeyPressed(.DOWN) {
				translate_layer(state, state.current_layer, 0, 1)
			}

			// create new layer at the top
			if rl.IsKeyPressed(.SPACE) {
				add_empty_layer(state, len(state.layers))
			}		
		}
		else if rl.IsKeyDown(.LEFT_ALT) {
			// move layer up
			if rl.IsKeyPressed(.UP) {
				if len(state.layers) > 1 && state.current_layer < len(state.layers) - 1 {
					change_layer_index(state, state.current_layer, state.current_layer + 1)
				}
			}

			// move layer down
			if rl.IsKeyPressed(.DOWN) {
				if len(state.layers) > 1 && state.current_layer > 0 {
					change_layer_index(state, state.current_layer, state.current_layer - 1)
				}
			}
		}
		else {			
			// create new layer above the current
			if rl.IsKeyPressed(.SPACE) {
				add_empty_layer(state, state.current_layer + 1)
			}

			// duplicate layer
			if rl.IsKeyPressed(.D) {
				duplicate_layer(state, state.current_layer, state.current_layer + 1)
			}

			// toggle onion skinning
			if rl.IsKeyPressed(.TAB) {
				state.onion_skinning = !state.onion_skinning
			}

			// move current layer up
			if rl.IsKeyPressed(.UP) {
				state.current_layer += 1
				if state.current_layer >= len(state.layers) {
					state.current_layer = 0
				}
			}

			// move current layer down
			if rl.IsKeyPressed(.DOWN) {
				state.current_layer -= 1
				if state.current_layer < 0 {
					state.current_layer = len(state.layers) - 1
				}
			}

			// clear current layer
			if rl.IsKeyPressed(.F) {
				clear_layer(state, state.current_layer)
			}

			// delete current layer
			if rl.IsKeyPressed(.X) {
				if len(state.layers) > 1 {
					delete_layer(state, state.current_layer)
				}
			}

			// go to welcome screen
			if rl.IsKeyPressed(.W) {
				go_to_welcome_screen(state)
			}
		}
	}
}

tool_shortcuts :: proc(state: ^Project_State) -> (current_tool: Tool) {
	if ui_is_any_popup_open() do return
	
	/* sometimes we may want to temporarily override current selected tool
	eg when user holds control key to color pick, in which case
	we just return that tool enum */

	// temp select color picker
	if rl.IsKeyDown(.LEFT_CONTROL) {
		return .Color_Picker
	}
	
	// temp select go to
	if rl.IsKeyDown(.LEFT_SHIFT) {
		return .GoTo
	}
	
	// select pen
	if rl.IsKeyPressed(.P) {
		state.current_tool = .Pen
	}

	if rl.IsKeyPressed(.E) {
		state.current_tool = .Eraser
	}

	// select color picker
	if rl.IsKeyPressed(.I) {
		state.current_tool = .Color_Picker
	}

	// select bucket fill 
	if rl.IsKeyPressed(.B) {
		state.current_tool = .Fill
	}

	return state.current_tool
}

action_preform :: proc(state: ^Project_State, action: Action) {
	switch &kind in action {
		case Action_Image_Change: {
			image := rl.ImageCopy(kind.after_image)
			state.layers[kind.layer_index].image = image
			mark_dirty_layers(state, state.current_layer)
		}
		case Action_Create_Layer: {
			layer: Layer
			init_layer(&layer, state.width, state.height)
			inject_at(&state.layers, kind.layer_index, layer)
			state.current_layer = kind.layer_index
		}
		case Action_Duplicate_Layer: {
			layer: Layer
			layer.image = rl.ImageCopy(state.layers[kind.from_index].image)
			layer.texture = rl.LoadTextureFromImage(layer.image)
			inject_at_elem(&state.layers, kind.to_index, layer)
			state.current_layer = kind.to_index
		}
		case Action_Change_Layer_Index: {
			layer := state.layers[kind.from_index]
			ordered_remove(&state.layers, kind.from_index)
			inject_at_elem(&state.layers, kind.to_index, layer)
			state.current_layer = kind.to_index
		}
		case Action_Delete_Layer: {
			kind.image = rl.ImageCopy(get_current_layer(state).image)
			deinit_layer(&state.layers[kind.layer_index])
			ordered_remove(&state.layers, kind.layer_index)
			if kind.layer_index > 0 {
				state.current_layer -= 1
			}
		}
	}
}

action_unpreform :: proc(state: ^Project_State, action: Action) {
	switch kind in action {
		case Action_Image_Change: {
			image := rl.ImageCopy(kind.before_image)
			state.layers[kind.layer_index].image = image
			mark_dirty_layers(state, kind.layer_index)
			state.current_layer = kind.layer_index
		}
		case Action_Create_Layer: {
			deinit_layer(&state.layers[kind.layer_index])
			ordered_remove(&state.layers, kind.layer_index)
			state.current_layer = kind.current_layer_index
		}
		case Action_Duplicate_Layer: {
			deinit_layer(&state.layers[kind.to_index])
			ordered_remove(&state.layers, kind.to_index)
			state.current_layer = kind.from_index
		}
		case Action_Change_Layer_Index: {
			layer := state.layers[kind.to_index]
			ordered_remove(&state.layers, kind.to_index)
			inject_at_elem(&state.layers, kind.from_index, layer)
			state.current_layer = kind.from_index
		}
		case Action_Delete_Layer: {
			layer: Layer
			layer.image = rl.ImageCopy(kind.image)
			layer.texture = rl.LoadTextureFromImage(layer.image)
			inject_at(&state.layers, kind.layer_index, layer)
			state.current_layer = kind.layer_index
			mark_dirty_layers(state, state.current_layer)
		}
	}
}

action_deinit :: proc(action: Action) {
	switch kind in action {
		case Action_Image_Change: {
			rl.UnloadImage(kind.before_image)
			rl.UnloadImage(kind.after_image)
		}
		case Action_Create_Layer: {
			
		}
		case Action_Duplicate_Layer: {
			
		}
		case Action_Change_Layer_Index: {
			
		}
		case Action_Delete_Layer: {
			rl.UnloadImage(kind.image)
		}
	}
}

// maybe this logic could move to action_preform? 
action_do :: proc(state: ^Project_State, action: Action) {
	action_preform(state, action)
	append(&state.undos, action)
	for action in state.redos {
		action_deinit(action)
	}
	clear(&state.redos)
}

undo :: proc(state: ^Project_State) {
	if len(state.undos) > 0 {
		action := pop(&state.undos)
		action_unpreform(state, action)
		append(&state.redos, action)
	}	
}

redo :: proc(state: ^Project_State) {
	if len(state.redos) > 0 {
		action := pop(&state.redos)
		action_preform(state, action)
		append(&state.undos, action)
	}	
}

process_dirty_layers :: proc(state: ^Project_State) {
	// update the textures for dirty layers
	if len(state.dirty_layers) > 0 {
		for layer, i in state.layers {
			if slice.contains(state.dirty_layers[:], i) {
				colors := rl.LoadImageColors(layer.image)
				defer rl.UnloadImageColors(colors)
				rl.UpdateTexture(layer.texture, colors)
			}
		}
		clear(&state.dirty_layers)
	}
}

// puts a star in the window title when an unsaved change exists
update_title :: proc(state: ^Project_State) {
	@(static) saved_last_frame := true
	saved := is_saved(state)
	if saved != saved_last_frame {
		star := saved == false ? "*" : ""
		rl.SetWindowTitle(fmt.ctprint("Darko - ", state.dir, star))
	}
	saved_last_frame = is_saved(state)
}

process_commands :: proc(draw_commands: [][]UI_Draw_Command) {
	for commands in draw_commands {
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
	
					rl.DrawTextEx(ui_ctx.font, text, { x, y }, kind.size, 0, kind.color)
				}
				case UI_Draw_Texture: {
					src_rec := Rec { 0, 0, f32(kind.texture.width), f32(kind.texture.height) }
					rl.DrawTexturePro(kind.texture, src_rec, kind.rec, { 0, 0 }, 0, kind.tint)
				}
				case UI_Draw_Gradient_H: {
					x := i32(math.ceil_f32(kind.rec.x))
					y := i32(math.ceil_f32(kind.rec.y))
					w := i32(math.ceil_f32(kind.rec.width))
					h := i32(math.ceil_f32(kind.rec.height))
					rl.DrawRectangleGradientH(x, y, w, h, kind.left_color, kind.right_color)
				}
				case UI_Draw_Gradient_V: {
					x := i32(math.ceil_f32(kind.rec.x))
					y := i32(math.ceil_f32(kind.rec.y))
					w := i32(math.ceil_f32(kind.rec.width))
					h := i32(math.ceil_f32(kind.rec.height))
					rl.DrawRectangleGradientV(x, y, w, h, kind.top_color, kind.bottom_color)
				}
				case UI_Clip: {
					if kind.rec != {} {
						x := i32(math.round(kind.rec.x))
						y := i32(math.round(kind.rec.y))
						w := i32(math.round(kind.rec.width))
						h := i32(math.round(kind.rec.height))
						rl.BeginScissorMode(x, y, w, h)
					}
					else {
						rl.EndScissorMode()
					}
				}
				case UI_Draw_Canvas: {
					// TODO: just draw these to a render texture
					project, project_exists := app.state.(Project_State)
					assert(project_exists)
					draw_canvas(&project, kind.rec)
				}
				case UI_Draw_Grid: {
					// TODO: just draw these to a render texture
					project, project_exists := app.state.(Project_State)
					assert(project_exists)
					draw_grid(project.width, project.height, kind.rec)
				}
				case UI_Draw_Preview: {
					// TODO: just draw these to a render texture
					project, project_exists := app.state.(Project_State)
					assert(project_exists)
					
					x := i32(math.round(kind.rec.x))
					y := i32(math.round(kind.rec.y))
					w := i32(math.round(kind.rec.width))
					h := i32(math.round(kind.rec.height))
					
					bottom_color := hsv_to_rgb(project.preview_bg_color)
					top_color := hsv_to_rgb({
						f32(int(project.preview_bg_color[0] - 20) % 360),
						project.preview_bg_color[1],
						project.preview_bg_color[2] / 2,
					})
					rl.DrawRectangleGradientV(x, y, w, h, top_color, bottom_color)
	
					px, py := rec_get_center_point(kind.rec)
					draw_sprite_stack(&project.layers, px, py, project.lerped_preview_zoom, project.preview_rotation, project.spacing)
					
					rl.DrawTextEx(ui_ctx.font, "Preview", { kind.rec.x + 10, kind.rec.y + 10 }, ui_font_size(), 0, { 255, 255, 255, 100 })
					
					rl.DrawRectangleLinesEx(kind.rec, 1, COLOR_BASE_0)
				}
			}
		}
	}
}

update_zoom :: proc(current_zoom: ^f32, strength: f32, min: f32, max: f32) {
	zoom := current_zoom^ + rl.GetMouseWheelMove() * strength
	zoom = math.clamp(zoom, min, max)
	current_zoom^ = zoom
}

create_bg_texture :: proc(state: ^Project_State) {
	color1 := hsv_to_rgb(state.bg_color1)
	color2 := hsv_to_rgb(state.bg_color2)
	bg_image := rl.GenImageChecked(state.width, state.height, 1, 1, color1, color2)
	defer rl.UnloadImage(bg_image)
	state.bg_texture = rl.LoadTextureFromImage(bg_image)
}

is_saved :: proc(state: ^Project_State) -> (saved: bool) {
	return state.undos_len_on_save == len(state.undos)
}

rgb_to_hsv :: #force_inline proc(rgb: rl.Color) -> (hsv: HSV) {
	return HSV(rl.ColorToHSV(rgb))
}

hsv_to_rgb :: #force_inline proc(hsv: HSV) -> (rgb: rl.Color) {
	return rl.ColorFromHSV(hsv[0], hsv[1], hsv[2])
}

ini_read_bool :: proc(mapp: ini.Map, section, name: string, default: bool = false) -> (res: bool) {
	if name in mapp[section] {
		value, ok := strconv.parse_bool(mapp[section][name])
		if ok {
			return value
		}
	}
	return default
}

ini_read_int :: proc(mapp: ini.Map, section, name: string, default: int = 0) -> (res: int) {
	if name in mapp[section] {
		value, ok := strconv.parse_int(mapp[section][name])
		if ok {
			return value
		}
	}
	return default
}

ini_read_f32 :: proc(mapp: ini.Map, section, name: string, default: f32 = 0) -> (res: f32) {
	if name in mapp[section] {
		value, ok := strconv.parse_f32(mapp[section][name])
		if ok {
			return value
		}
	}
	return default
} 

ini_read_string :: proc(mapp: ini.Map, section, name: string, default := "", allocator := context.allocator) -> (res: string) {
	if name in mapp[section] {
		value, ok := mapp[section][name]
		if ok {
			return strings.clone(value, allocator)
		}
	}
	return strings.clone(default, allocator)
}

pick_file_dilaog :: proc(default_path := "", allocator := context.allocator) -> (path: string, res: ntf.Result) {
	path_cstring: cstring
	defer ntf.FreePathU8(path_cstring)
	default_path_cstring := strings.clone_to_cstring(default_path, context.temp_allocator)
	
	window_type := ntf.Window_Handle_Type.Unset
	if ODIN_OS == .Windows { window_type = .Windows }
	else if ODIN_OS == .Linux { window_type = .X11 }
	
	args := ntf.Open_Dialog_Args {
		default_path = default_path_cstring,
		parent_window = {
			handle = rl.GetWindowHandle(),
			type = window_type,
		}
	}
	
	res = ntf.OpenDialogU8_With(&path_cstring, &args)
	path = strings.clone_from_cstring(path_cstring, allocator)
	return path, res
}

pick_folder_dialog :: proc(default_path := "", allocator := context.allocator) -> (path: string, res: ntf.Result) {
	default_path_cstring := strings.clone_to_cstring(default_path)
	defer delete(default_path_cstring)
	path_cstring: cstring
	defer ntf.FreePathU8(path_cstring)

	window_type := ntf.Window_Handle_Type.Unset
	if ODIN_OS == .Windows { window_type = .Windows }
	else if ODIN_OS == .Linux { window_type = .X11 }
	
	args := ntf.Pick_Folder_Args {
		default_path = default_path_cstring,
		parent_window = {
			handle = rl.GetWindowHandle(),
			type = window_type,
		}
	}
	pick_res := ntf.PickFolderU8_With(&path_cstring, &args)
	path_res := strings.clone_from_cstring(path_cstring, allocator)
	
	return path_res, pick_res
}

shorten_path :: proc(path: string, allocator := context.allocator) -> (res: string) {
	if strings.contains_any(path, "/") {
		splitted_path := strings.split(path, "/")
		defer delete(splitted_path)
		return strings.clone(splitted_path[len(splitted_path) - 1])
	}
	else if strings.contains_any(path, "\\") {
		splitted_path := strings.split(path, "\\")
		defer delete(splitted_path)
		return strings.clone(splitted_path[len(splitted_path) - 1])
	}
	else {
		return strings.clone(path, allocator)
	}
}