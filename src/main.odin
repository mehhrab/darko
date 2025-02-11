/* application code 
frontend gui, backend code, ect */
package darko

import "core:fmt"
import rl "vendor:raylib"
import "core:mem"
import vmem "core:mem/virtual"
import "core:math"
import "core:strings"
import "core:c"
import "core:os/os2"
import "core:slice"
import sa "core:container/small_array"
import ntf "../lib/ntf"
import "core:encoding/ini"
import "core:strconv"

TARGET_FPS :: 60
HSV :: distinct [3]f32
/* to open a popup you have to know it's name
they act as ids. actual ids should probably be used... */
POPUP_NEW_PROJECT :: "New project"
POPUP_PREVIEW_SETTINGS :: "Preview settings"

App :: struct {
	state: Screen_State, 
	next_state: Maybe(Screen_State),
	new_project_width, new_project_height: i32,
	recent_projects: sa.Small_Array(8, string),
	show_fps: bool,
	unlock_fps: bool,
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
	zoom: f32,
	spacing: f32,
	current_color: HSV,
	width: i32,
	height: i32,
	current_layer: int,
	layers: [dynamic]Layer,
	lerped_zoom: f32,
	image_changed: bool,
	bg_texture: rl.Texture,
	preview_zoom: f32,
	lerped_preview_zoom: f32,
	preview_rotation: f32,
	preview_rotation_speed: f32,
	auto_rotate_preview: bool,
	temp_undo: Maybe(Action),
	undos: [dynamic]Action,
	redos: [dynamic]Action,
	dirty_layers: [dynamic]int,
}

Layer :: struct {
	image: rl.Image,
	texture: rl.Texture,
}

// actions: (for undo and redo)

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
	
	rl.SetConfigFlags({rl.ConfigFlags.WINDOW_RESIZABLE})
	rl.InitWindow(1200, 700, "Darko")
	rl.SetExitKey(nil)
	rl.SetTargetFPS(TARGET_FPS)

	ntf.Init()
	defer ntf.Quit()

	ui_init_ctx()
	defer ui_deinit_ctx()
	
	if os2.exists("data.ini") {
		load_app_data("data.ini")
		welcome_state := Welcome_State {}
		init_welcome_state(&welcome_state)
		app.state = welcome_state
	}
	else {
		init_app()
		welcome_state := Welcome_State {}
		init_welcome_state(&welcome_state)
		app.state = welcome_state
	}

	defer save_app_data()
	defer deinit_app()

	for rl.WindowShouldClose() == false {
		ui_begin()

		if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.EQUAL) {
			ui_set_scale(ui_ctx.scale + 0.1)
		}
		if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.MINUS) {
			ui_set_scale(ui_ctx.scale - 0.1)
		}

		switch &state in app.state {
			case Project_State: {
				project_screen(&state)

				if ui_is_any_popup_open() == false {
					// create new layer above the current
					if rl.IsKeyPressed(.SPACE) {
						action_do(&state, Action_Create_Layer {
							current_layer_index = state.current_layer,
							layer_index = state.current_layer + 1
						})
					}

					// create new layer at the top
					if rl.IsKeyPressed(.S) {
						action_do(&state, Action_Create_Layer {
							current_layer_index = state.current_layer,
							layer_index = len(state.layers)
						})
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

					// undo
					if rl.IsKeyPressed(.Z) {
						if len(state.undos) > 0 {
							fmt.printfln("undo")
							action := pop(&state.undos)
							action_unpreform(&state, action)
							append(&state.redos, action)
						}	
					}

					// redo
					if rl.IsKeyPressed(.Y) {
						if len(state.redos) > 0 {
							fmt.printfln("redo")
							action := pop(&state.redos)
							action_preform(&state, action)
							append(&state.undos, action)
						}	
					}
				}

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
			case Welcome_State: {
				welcome_screen(&state)
			}
			case: {
				panic("what")
			}
		}
		new_file_popup(&app.state)

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

		ui_end()

		// draw
		rl.BeginDrawing()
		rl.ClearBackground(COLOR_BASE_0)		
		process_commands(ui_get_draw_commmands())
		if app.show_fps {
			rl.DrawFPS(rl.GetScreenWidth() - 80, 10)
		}
		rl.EndDrawing()
		ui_clear_temp_state()

		if next_state, ok := app.next_state.?; ok {
			// cleanup previuos state
			switch &state in app.state {
				case Project_State: {
					close_project(&state)
				}
				case Welcome_State: {
					deinit_welcome_state(&state)
				}
			}
			// switch to the new state
			switch &state in next_state {
				case Project_State: {
					open_project(&state)
				}
				case Welcome_State: {
					rl.SetWindowTitle("Darko")
					app.state = state	
				}
				case: {
					panic("x")
				}
			}
			app.next_state = nil
		} 
	}
	rl.CloseWindow()
}

// ui code:

welcome_screen :: proc(state: ^Welcome_State) {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
	screen_area := screen_rec
	
	right_area := rec_cut_right(&screen_area, screen_area.width / 2)
	left_area := screen_area
	ui_push_command(UI_Draw_Rect {
		color = COLOR_ACCENT_0,
		rec = right_area
	})
	
	mascot_size := ui_px(right_area.width / 2)
	mascot_rec := rec_center_in_area({ 0, 0, mascot_size , mascot_size }, right_area)
	mascot_rec.y += f32(math.cos(rl.GetTime())) * 10
	ui_push_command(UI_Draw_Texture {
		rec = mascot_rec,
		texture = state.mascot, 
	})

	left_area = rec_pad(left_area, ui_px(16))
	ui_push_command(UI_Draw_Text {
		text = "Welcome to Darko!",
		align = { .Center, .Center },
		size = ui_font_size() * 2,
		color = COLOR_ACCENT_0,
		rec = rec_cut_top(&left_area, ui_default_widget_height() * 2)
	})

	buttons_area := rec_cut_top(&left_area, ui_default_widget_height())
	new_button_rec := rec_cut_left(&buttons_area, buttons_area.width / 2 - ui_px(8))
	if ui_button(ui_gen_id(), "New", new_button_rec) {
		ui_open_popup(POPUP_NEW_PROJECT)
	}
	
	rec_cut_left(&buttons_area, ui_px(8))
	
	open_button_rec := rec_cut_left(&buttons_area, buttons_area.width - ui_px(8))
	if ui_button(ui_gen_id(), "Open", open_button_rec) {
		path_cstring: cstring
		defer ntf.FreePathU8(path_cstring)
		args: ntf.Open_Dialog_Args
		res := ntf.PickFolderU8(&path_cstring, "")
		if res == .Error {
			ui_show_notif("Failed to open project", UI_NOTIF_STYLE_ERROR)
		}
		else if res == .Cancel {
			return
		}

		loaded_project: Project_State
		path := string(path_cstring)		
		loaded := load_project_state(&loaded_project, path)
		if loaded == false {
			ui_show_notif("Failed to open project", UI_NOTIF_STYLE_ERROR)
			return
		}
		
		mark_all_layers_dirty(&loaded_project)
		add_recent_project(path)
		schedule_state_change(loaded_project)
	}
	if app.recent_projects.len == 0 {
		ui_push_command(UI_Draw_Text {
			align = { .Left, .Center },
			color = COLOR_TEXT_0,
			rec = rec_cut_bottom(&left_area, ui_default_widget_height()),
			size = ui_font_size(),
			text = "No recent projects"
		})
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
					add_recent_project(recent)
					schedule_state_change(project)
				}
				else {
					ui_show_notif("Could not open project")
				}
			}
		}
		ui_push_command(UI_Draw_Text {
			align = { .Left, .Center },
			color = COLOR_TEXT_0,
			rec = rec_cut_bottom(&left_area, ui_default_widget_height()),
			size = ui_font_size(),
			text = "Recent projects:"
		})
	}
}

project_screen :: proc(state: ^Project_State) {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
	menu_bar_area := rec_cut_top(&screen_rec, ui_default_widget_height())
	menu_bar(state, menu_bar_area)

	screen_area := screen_rec

	right_panel_area := rec_cut_right(&screen_area, ui_px(screen_area.width / 3))
	middle_panel_area := screen_area
	
	layer_props_area := rec_cut_top(&middle_panel_area, ui_default_widget_height() + ui_px(16))
	layer_props(state, layer_props_area)

	canvas(state, middle_panel_area)
	
	ui_panel(ui_gen_id(), right_panel_area)
	right_panel_area = rec_pad(right_panel_area, ui_px(16))
	color_panel(state, &right_panel_area)

	rec_delete_top(&right_panel_area, ui_px(16))

	preview(state, right_panel_area)	
	preview_settings_popup(state)
}

menu_bar :: proc(state: ^Project_State, area: Rec) {
	ui_panel(ui_gen_id(), area, { bg_color = COLOR_BASE_2 })
	NEW_PROJECT :: "new project" 
	OPEN_PROJECT :: "open project" 
	SAVE_PROJECT :: "save project" 
	OPEN_WELCOME_SCREEN :: "open welcome screen" 
	menu_items := [?]UI_Menu_Item {
		UI_Menu_Item { 
			ui_gen_id(),
			NEW_PROJECT,
			"",
		},
		UI_Menu_Item { 
			ui_gen_id(),
			OPEN_PROJECT,
			"",
		},
		UI_Menu_Item { 
			ui_gen_id(),
			SAVE_PROJECT,
			"",
		},
		UI_Menu_Item { 
			ui_gen_id(),
			OPEN_WELCOME_SCREEN,
			"",
		},
	}
	menu_items_slice := menu_items[:]
	clicked_item := ui_menu_button(ui_gen_id(), "File", &menu_items_slice, 300, { area.x, area.y, 60, area.height })
	
	if clicked_item.text == NEW_PROJECT {
		ui_open_popup(POPUP_NEW_PROJECT)
	}
	
	if clicked_item.text == OPEN_PROJECT {
		defer ui_close_current_popup()

		path_cstring: cstring
		defer ntf.FreePathU8(path_cstring)
		current_dir := strings.clone_to_cstring(state.dir, context.temp_allocator)
		args := ntf.Pick_Folder_Args {
			default_path = current_dir,
			parent_window = {
				handle = rl.GetWindowHandle(),
				type = .Windows,
			}
		}
		res := ntf.PickFolderU8_With(&path_cstring, &args)
		if res == .Error {
			ui_show_notif("Failed to open project", UI_NOTIF_STYLE_ERROR)
		}
		else if res == .Cancel {
			return
		}

		loaded_project: Project_State
		path := string(path_cstring)		
		loaded := load_project_state(&loaded_project, path)
		if loaded == false {
			ui_show_notif("Failed to open project", UI_NOTIF_STYLE_ERROR)
			return
		}
			
		mark_all_layers_dirty(&loaded_project)
		add_recent_project(path)
		schedule_state_change(loaded_project)
	}

	if clicked_item.text == SAVE_PROJECT {
		defer ui_close_current_popup()

		path_cstring: cstring
		defer ntf.FreePathU8(path_cstring)
		current_dir := strings.clone_to_cstring(state.dir, context.temp_allocator)
		args := ntf.Pick_Folder_Args {
			default_path = current_dir,
			parent_window = {
				handle = rl.GetWindowHandle(),
				type = .Windows,
			}
		}
		res := ntf.PickFolderU8_With(&path_cstring, &args)
		if res == .Error {
			ui_show_notif("Failed to save project", UI_NOTIF_STYLE_ERROR)
		}
		else if res == .Cancel {
			return
		}

		path := string(path_cstring)
		saved := save_project_state(state, path)
		if saved == false {
			ui_show_notif("Failed to save project", UI_NOTIF_STYLE_ERROR)
			return
		}

		add_recent_project(path)
		ui_show_notif("Project is saved")
	}

	if clicked_item.text == OPEN_WELCOME_SCREEN {
		defer ui_close_current_popup()

		welcome_state := Welcome_State {}
		init_welcome_state(&welcome_state)
		schedule_state_change(welcome_state)
	}
}

layer_props :: proc(state: ^Project_State, rec: Rec) {
	ui_panel(ui_gen_id(), rec)
	props_area := rec_pad(rec, ui_px(8))
	
	// draw current layer index and layer count
	current_layer := state.current_layer + 1
	layer_count := len(state.layers)
	ui_push_command(UI_Draw_Text {
		align = { .Left, .Center },
		color = COLOR_TEXT_0,
		rec = props_area,
		size = ui_font_size(),
		text = fmt.tprintf("layer {}/{}", current_layer, layer_count),
	})

	// delete button
	delete_rec := rec_cut_right(&props_area, ui_default_widget_height())
	if ui_button(ui_gen_id(), ICON_TRASH, delete_rec, style = UI_BUTTON_STYLE_RED) {
		if len(state.layers) <= 1 {
			ui_show_notif("At least one layer is needed", UI_NOTIF_STYLE_ERROR)
		} 
		else {
			action_do(state, Action_Delete_Layer {
				layer_index = state.current_layer,
			})

		}
	}


	// move up button
	rec_cut_right(&props_area, ui_px(8))
	move_up_rec := rec_cut_right(&props_area, ui_default_widget_height())
	if ui_button(ui_gen_id(), ICON_UP, move_up_rec, style = UI_BUTTON_STYLE_ACCENT) {
		if len(state.layers) > 1 && state.current_layer < len(state.layers) - 1 {
			action_do(state, Action_Change_Layer_Index {
				from_index = state.current_layer,
				to_index = state.current_layer + 1
			})
		}
	}

	// move down button
	move_down_rec := rec_cut_right(&props_area, ui_default_widget_height())
	if ui_button(ui_gen_id(), ICON_DOWN, move_down_rec, style = UI_BUTTON_STYLE_ACCENT) {
		if len(state.layers) > 1 && state.current_layer > 0 {
			action_do(state, Action_Change_Layer_Index {
				from_index = state.current_layer,
				to_index = state.current_layer - 1
			})
		}
	}

	// duplicate button
	rec_cut_right(&props_area, ui_px(8))
	duplicate_rec := rec_cut_right(&props_area, ui_default_widget_height())
	if ui_button(ui_gen_id(), ICON_COPY, duplicate_rec, style = UI_BUTTON_STYLE_ACCENT) {
		action_do(state, Action_Duplicate_Layer {
			from_index = state.current_layer,
			to_index = state.current_layer + 1,
		})
	}
}

canvas :: proc(state: ^Project_State, rec: Rec) {
	area := rec

	state.lerped_zoom = rl.Lerp(state.lerped_zoom, state.zoom, 20 * rl.GetFrameTime())
	// work around for lerp never (taking too long) reaching it's desteniton 
	if math.abs(state.zoom - state.lerped_zoom) < 0.01 {
		state.lerped_zoom = state.zoom
	}

	canvas_w := f32(state.width) * 10 * state.lerped_zoom 
	canvas_h := f32(state.height) * 10 * state.lerped_zoom
	canvas_rec := rec_center_in_area({ 0, 0, canvas_w, canvas_h }, area)
	
	cursor_icon := ""
	if ui_is_being_interacted() == false {
		update_zoom(&state.zoom, 0.3, 0.1, 100)
		cursor_icon = update_tools(state, canvas_rec)
	}
	
	ui_push_command(UI_Draw_Canvas {
		rec = canvas_rec,
		panel_rec = area,
	})
	ui_push_command(UI_Draw_Grid {
		rec = canvas_rec,
		panel_rec = area,
	})
	ui_push_command(UI_Draw_Rect_Outline {
		rec = area,
		color = COLOR_BASE_0,
		thickness = 1
	})
	if ui_is_mouse_in_rec(area) && ui_is_being_interacted() == false {
		if cursor_icon == "" {
			cursor_icon = ICON_PEN
		}
		rl.HideCursor()
		mpos := rl.GetMousePosition()
		cursor_size := ui_font_size() * 2
		ui_push_command(UI_Draw_Text {
			rec = { mpos.x + 1, mpos.y - cursor_size + 5 + 1, 100, 100 },
			color = rl.BLACK,
			text = cursor_icon,
			size = cursor_size,
		})
		ui_push_command(UI_Draw_Text {
			rec = { mpos.x, mpos.y - cursor_size + 5, 100, 100 },
			color = rl.WHITE,
			text = cursor_icon,
			size = cursor_size,
		})
	}
	else {
		rl.ShowCursor()
	}
}

color_panel :: proc(state: ^Project_State, area: ^Rec) {		
	// preview color
	preview_area := rec_cut_top(area, ui_default_widget_height() * 3)
	ui_push_command(UI_Draw_Rect {
		color = hsv_to_rgb(state.current_color),
		rec = preview_area,
	})
	ui_push_command(UI_Draw_Rect_Outline {
		color = COLOR_BASE_0,
		rec = preview_area,
		thickness = 1,
	})
	rec_delete_top(area, ui_px(8))

	hsv_color := state.current_color

	// not sure if it's actually called grip...
	draw_grip :: proc(value, min, max: f32, rec: Rec) {
		grip_width := ui_px(10)
		grip_x := (value - min) * (rec.width) / (max - min) - grip_width / 2
		g_rec := Rec { rec.x + grip_x, rec.y, grip_width, rec.height }
		ui_push_command(UI_Draw_Rect_Outline {
			color = rl.BLACK,
			thickness = 3,
			rec = rec_pad(g_rec, -1),
		})
		ui_push_command(UI_Draw_Rect_Outline {
			color = rl.WHITE,
			thickness = 1,
			rec = g_rec,
		})
	}

	// hue slider
	hue_rec := rec_cut_top(area, ui_default_widget_height())
	hue_changed := ui_slider_behaviour_f32(ui_gen_id(), &hsv_color[0], 0, 360, hue_rec)
	ui_push_command(UI_Draw_Rect {
		color = COLOR_BASE_0,
		rec = hue_rec,
	})
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

	rec_delete_top(area, ui_px(8))

	// saturation slider
	saturation_rec := rec_cut_top(area, ui_default_widget_height())
	saturation_changed := ui_slider_behaviour_f32(ui_gen_id(), &hsv_color[1], 0, 1, saturation_rec)
	ui_push_command(UI_Draw_Rect {
		color = COLOR_BASE_0,
		rec = saturation_rec,
	})
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

	rec_delete_top(area, ui_px(8))
	
	// value slider
	value_rec := rec_cut_top(area, ui_default_widget_height())
	value_changed := ui_slider_behaviour_f32(ui_gen_id(), &hsv_color[2], 0, 1, value_rec)
	ui_push_command(UI_Draw_Rect {
		color = COLOR_BASE_0,
		rec = value_rec,
	})
	value_rec = rec_pad(value_rec, 1)
	ui_push_command(UI_Draw_Gradient_H {
		left_color = rl.BLACK,
		right_color = rl.WHITE,
		rec = value_rec,
	})
	draw_grip(hsv_color[2], 0, 1, value_rec)

	if hue_changed || saturation_changed || value_changed  {
		state.current_color = hsv_color
	}
}

preview :: proc(state: ^Project_State, rec: Rec) {
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
		ui_open_popup(POPUP_PREVIEW_SETTINGS)
	}
}

new_file_popup :: proc(state: ^Screen_State) {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
	
	popup_h := ui_calc_popup_height(3, ui_default_widget_height(), ui_px(8), ui_px(16))
	popup_rec := rec_center_in_area({ 0, 0, ui_px(400), popup_h }, screen_rec)
	if open, rec := ui_begin_popup_title(ui_gen_id(), POPUP_NEW_PROJECT, popup_rec); open {
		area := rec_pad(rec, ui_px(16))
		ui_slider_i32(ui_gen_id(), "Width", &app.new_project_width, 2, 30, rec_cut_top(&area, ui_default_widget_height()))
		rec_delete_top(&area, ui_px(8))
		
		ui_slider_i32(ui_gen_id(), "Height", &app.new_project_height, 2, 30, rec_cut_top(&area, ui_default_widget_height()))
		rec_delete_top(&area, ui_px(8))
		
		if ui_button(ui_gen_id(), "Create", area) {
			project: Project_State
			init_project_state(&project, app.new_project_width, app.new_project_height)
			schedule_state_change(project)
			ui_close_current_popup()
		
			ui_show_notif(ICON_CHECK + " Project is created")
		}	
	}
	ui_end_popup()
}

preview_settings_popup :: proc(state: ^Project_State) {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
	
	popup_h := ui_calc_popup_height(3, ui_default_widget_height(), ui_px(8), ui_px(16))
	popup_area := rec_center_in_area({ 0, 0, ui_px(300), popup_h }, screen_rec)
	if open, rec := ui_begin_popup_title(ui_gen_id(), POPUP_PREVIEW_SETTINGS, popup_area); open {
		area := rec_pad(rec, ui_px(16))
		auto_rotate_rec := rec_cut_top(&area, ui_default_widget_height())
		ui_check_box(ui_gen_id(),"Auto rotate", &state.auto_rotate_preview, auto_rotate_rec)
		rec_delete_top(&area, ui_px(8))

		ui_slider_f32(ui_gen_id(), "Rotation speed", &state.preview_rotation_speed, 5, 30, rec_cut_top(&area, ui_default_widget_height()))
		rec_delete_top(&area, ui_px(8))
		
		ui_slider_f32(ui_gen_id(), "Spacing", &state.spacing, 0.1, 2, rec_cut_top(&area, ui_default_widget_height()))
	}
	ui_end_popup()
}

// backend code:

process_commands :: proc(commands: []UI_Draw_Command) {
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
			case UI_Draw_Texture: {
				src_rec := Rec { 0, 0, f32(kind.texture.width), f32(kind.texture.height) }
				rl.DrawTexturePro(kind.texture, src_rec, kind.rec, { 0, 0 }, 0, rl.WHITE)
			}
			case UI_Draw_Gradient_H: {
				x := i32(math.ceil_f32(kind.rec.x))
				y := i32(math.ceil_f32(kind.rec.y))
				w := i32(math.ceil_f32(kind.rec.width))
				h := i32(math.ceil_f32(kind.rec.height))
				rl.DrawRectangleGradientH(x, y, w, h, kind.left_color, kind.right_color)
			}
			case UI_Draw_Canvas: {
				// TODO: just draw these to a render texture
				project, project_exists := app.state.(Project_State)
				assert(project_exists)

				rl.BeginScissorMode(
					i32(kind.panel_rec.x), 
					i32(kind.panel_rec.y), 
					i32(kind.panel_rec.width), 
					i32(kind.panel_rec.height))
				draw_canvas(&project, kind.rec)
				rl.EndScissorMode()
			}
			case UI_Draw_Grid: {
				// TODO: just draw these to a render texture
				project, project_exists := app.state.(Project_State)
				assert(project_exists)

				rl.BeginScissorMode(
					i32(kind.panel_rec.x), 
					i32(kind.panel_rec.y), 
					i32(kind.panel_rec.width), 
					i32(kind.panel_rec.height))
				draw_grid(project.width, project.height, kind.rec)
				rl.EndScissorMode()
			}
			case UI_Draw_Preview: {
				// TODO: just draw these to a render texture
				project, project_exists := app.state.(Project_State)
				assert(project_exists)
				
				x := i32(math.round(kind.rec.x))
				y := i32(math.round(kind.rec.y))
				w := i32(math.round(kind.rec.width))
				h := i32(math.round(kind.rec.height))
				
				rl.BeginScissorMode(x, y, w, h)
				rl.DrawRectangleGradientV(x, y, w, h, COLOR_BASE_1, COLOR_BASE_4)
				px, py := rec_get_center_point(kind.rec)
				draw_sprite_stack(&project.layers, px, py, project.lerped_preview_zoom, project.preview_rotation, project.spacing)
				rl.DrawTextEx(ui_ctx.font, "Preview", { kind.rec.x + 10, kind.rec.y + 10 }, ui_font_size(), 0, { 255, 255, 255, 100 })
				rl.EndScissorMode()
				rl.DrawRectangleLinesEx(kind.rec, 1, COLOR_BASE_0)
			}
		}
	}
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
			mark_dirty_layers(state, state.current_layer)
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

action_do :: proc(state: ^Project_State, action: Action) {
	action_preform(state, action)
	append(&state.undos, action)
	for action in state.redos {
		action_deinit(action)
	}
	clear(&state.redos)
}

init_app :: proc() {
	app.new_project_width = 16
	app.new_project_height = 16
}

deinit_app :: proc() {
	switch &state in app.state {
		case Project_State: {
			close_project(&state)
		}
		case Welcome_State: {

		}
	}

	for recent in app.recent_projects.data {
		delete(recent)
	}
}

load_app_data :: proc(path: string) {
	file_exists := os2.exists(path)
	if file_exists == false {
		return
	}

	loaded_map, alloc_err, loaded := ini.load_map_from_path(path, context.temp_allocator)
	assert(alloc_err == nil)
	if loaded == false {
		return
	}

	fmt.printfln("loaded app map: {}", loaded_map) 
	
	app.show_fps = ini_read_bool(loaded_map, "", "show_fps")
	app.unlock_fps = ini_read_bool(loaded_map, "", "unlock_fps")
	app.new_project_width = i32(ini_read_int(loaded_map, "", "new_project_width"))
	app.new_project_height = i32(ini_read_int(loaded_map, "", "new_project_height"))
	
	sa.clear(&app.recent_projects)
	if "recent_projects" in loaded_map {
		len := ini_read_int(loaded_map, "recent_projects", "len")
		for i in 0..<len {
			recent := ini_read_string(loaded_map, "recent_projects", fmt.tprint(i))
			if recent == "" {
				continue
			}
			sa.append(&app.recent_projects, strings.clone(recent))
		}
	}
}

save_app_data :: proc() {
	file, create_err := os2.create("data.ini")
	defer os2.close(file)
	if create_err != nil {
		return
	}

	ini.write_pair(file.stream, "new_project_width", fmt.tprint(app.new_project_width))
	ini.write_pair(file.stream, "new_project_height", fmt.tprint(app.new_project_height))
	ini.write_pair(file.stream, "show_fps", fmt.tprint(app.show_fps))
	ini.write_pair(file.stream, "unlock_fps", fmt.tprint(app.unlock_fps))

	ini.write_section(file.stream, "recent_projects")
	ini.write_pair(file.stream, "len", app.recent_projects.len)
	for i in 0..<app.recent_projects.len {
		recent := app.recent_projects.data[i]
		ini.write_pair(file.stream, fmt.tprint(i), recent)
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

init_project_state :: proc(state: ^Project_State, width, height: i32) {
	state.zoom = 1
	state.spacing = 1
	state.width = width
	state.height = height
	state.layers = make([dynamic]Layer)
	state.current_color = { 200, 0.5, 0.1 }		
	state.lerped_zoom = 0
	state.lerped_preview_zoom = 1
	bg_image := rl.GenImageChecked(state.width, state.height, 1, 1, { 198, 208, 245, 255 }, { 131, 139, 167, 255 })
	defer rl.UnloadImage(bg_image)
	state.bg_texture = rl.LoadTextureFromImage(bg_image)
	state.preview_rotation = 0
	state.preview_zoom = 10
	state.layers = make([dynamic]Layer)
	state.undos = make([dynamic]Action)
	state.redos = make([dynamic]Action)
	state.dirty_layers = make([dynamic]int)
	
	layer: Layer
	init_layer(&layer, width, height)
	append(&state.layers, layer)
	mark_all_layers_dirty(state)
}

/* some duplicate code from init_project_state() not sure what's the alternative
TODO: return an error value instead of a bool */
load_project_state :: proc(state: ^Project_State, dir: string) -> (ok: bool) {
	data_exists := os2.exists(fmt.tprintf("{}{}", dir, "\\project.ini"))
	sprites_exists := os2.exists(fmt.tprintf("{}{}", dir, "\\sprites.png"))
	if (data_exists || sprites_exists) == false {
		return false
	}

	loaded_map, alloc_err, loaded:= ini.load_map_from_path(fmt.tprintf("{}{}", dir, "\\project.ini"), context.temp_allocator)
	assert(alloc_err == nil)
	if loaded == false {
		return
	}
	
	fmt.printfln("loaded project map: {}", loaded_map) 
	
	loaded_state: Project_State
	
	loaded_state.zoom = ini_read_f32(loaded_map, "", "zoom", 1)
	loaded_state.spacing = ini_read_f32(loaded_map, "", "spacing")
	loaded_state.current_layer = ini_read_int(loaded_map, "", "current_layer", 0)
	loaded_state.preview_zoom = ini_read_f32(loaded_map, "", "preview_zoom", 1)
	loaded_state.preview_rotation = ini_read_f32(loaded_map, "", "preview_rotation")
	loaded_state.preview_rotation_speed = ini_read_f32(loaded_map, "", "preview_rotation_speed")
	loaded_state.auto_rotate_preview = ini_read_bool(loaded_map, "", "auto_rotate_preview")
	loaded_state.width = i32(ini_read_int(loaded_map, "", "width"))
	loaded_state.height = i32(ini_read_int(loaded_map, "", "height"))
	loaded_state.current_color[0] = ini_read_f32(loaded_map, "current_color", "h")
	loaded_state.current_color[1] = ini_read_f32(loaded_map, "current_color", "s")
	loaded_state.current_color[2] = ini_read_f32(loaded_map, "current_color", "v")
	
	if loaded_state.dir != dir {
		delete(loaded_state.dir)
		loaded_state.dir = strings.clone(dir)
	}
	loaded_state.lerped_zoom = 0
	loaded_state.lerped_preview_zoom = 0
	
	bg_image := rl.GenImageChecked(loaded_state.width,  loaded_state.height, 1, 1, { 198, 208, 245, 255 }, { 131, 139, 167, 255 })
	defer rl.UnloadImage(bg_image)
	loaded_state.bg_texture = rl.LoadTextureFromImage(bg_image)

	loaded_state.layers = make([dynamic]Layer)
	loaded_state.undos = make([dynamic]Action)
	loaded_state.redos = make([dynamic]Action)
	loaded_state.dirty_layers = make([dynamic]int)

	// load layers
	sprites := rl.LoadImage(fmt.ctprintf("{}{}", dir, "\\sprites.png"))
	defer rl.UnloadImage(sprites)

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
	if state.dir != dir {
		delete(state.dir)
		state.dir = strings.clone(dir)
	}

	// clear the directory
	remove_err := os2.remove_all(dir)
	if remove_err != os2.ERROR_NONE {
		fmt.printfln("{}", remove_err)
		return false
	}
	make_dir_err := os2.make_directory(dir)
	if make_dir_err != os2.ERROR_NONE {
		fmt.printfln("{}", make_dir_err)
		return false
	}

	file, create_err := os2.create(fmt.tprintf("{}\\project.ini", dir))
	defer os2.close(file)
	if create_err != nil {
		return
	}

	ini.write_pair(file.stream, "zoom", fmt.tprint(state.zoom))
	ini.write_pair(file.stream, "spacing", fmt.tprint(state.spacing))
	ini.write_pair(file.stream, "current_layer", fmt.tprint(state.current_layer))
	ini.write_pair(file.stream, "preview_zoom", fmt.tprint(state.preview_zoom))
	ini.write_pair(file.stream, "preview_rotation", fmt.tprint(state.preview_rotation))
	ini.write_pair(file.stream, "preview_rotation_speed", fmt.tprint(state.preview_rotation_speed))
	ini.write_pair(file.stream, "auto_rotate_preview", fmt.tprint(state.auto_rotate_preview))
	ini.write_pair(file.stream, "width", fmt.tprint(state.width))
	ini.write_pair(file.stream, "height", fmt.tprint(state.height))
	
	ini.write_section(file.stream, "current_color")
	ini.write_pair(file.stream, "h", fmt.tprint(state.current_color[0]))
	ini.write_pair(file.stream, "s", fmt.tprint(state.current_color[1]))
	ini.write_pair(file.stream, "v", fmt.tprint(state.current_color[2]))
	
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
	rl.UnloadTexture(state.bg_texture)
}

open_project :: proc(state: ^Project_State) {
	rl.SetWindowTitle(fmt.ctprintf("Darko   {}", state.dir))
	app.state = state^
	ui_show_notif(ICON_CHECK + " Project is opened")
}

close_project :: proc(state: ^Project_State) {
	deinit_project_state(state)
}

// NOTE: deinit calls for the previous state will be handled automatically 
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

add_recent_project :: proc(path: string) {
	// remove first recent when `recent_projects` is full
	if app.recent_projects.len >= len(app.recent_projects.data) {
		delete(app.recent_projects.data[0])
		sa.ordered_remove(&app.recent_projects, 0)
	}
	// remove duplicate recents
	if slice.contains(app.recent_projects.data[:], path) {
		recent_index, found := slice.linear_search(app.recent_projects.data[:], path)
		if found {
			delete(app.recent_projects.data[recent_index])
			sa.ordered_remove(&app.recent_projects, recent_index)
		}
	}

	sa.append(&app.recent_projects, strings.clone(path))
}

update_zoom :: proc(current_zoom: ^f32, strength: f32, min: f32, max: f32) {
	zoom := current_zoom^ + rl.GetMouseWheelMove() * strength
	zoom = math.clamp(zoom, min, max)
	current_zoom^ = zoom
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

update_tools :: proc(state: ^Project_State, area: Rec) -> (cursor_icon: string) {
	cursor_icon = ""

	// color picker
	if rl.IsKeyDown(.LEFT_CONTROL) {
		if ui_is_mouse_in_rec(area) {
			if rl.IsMouseButtonPressed(.LEFT) {
				x, y := get_mouse_pos_in_canvas(state, area)
				rgb_color := rl.GetImageColor(get_current_layer(state).image, x, y)
				if rgb_color.a != 0 {
					state.current_color = rgb_to_hsv(rgb_color)
				}
			}
		}
		cursor_icon = ICON_EYEDROPPER
	}
	else {		
		// pencil
		if rl.IsMouseButtonDown(.LEFT) {
			if ui_is_mouse_in_rec(area) {
				begin_image_change(state)
				x, y := get_mouse_pos_in_canvas(state, area)
				color := hsv_to_rgb(state.current_color)
				rl.ImageDrawPixel(&get_current_layer(state).image, x, y, color)
				mark_dirty_layers(state, state.current_layer)	
			}
			cursor_icon = ICON_PEN
		}
		if rl.IsMouseButtonReleased(.LEFT) {
			end_image_change(state)
		}

		// eraser
		if rl.IsMouseButtonDown(.RIGHT) {
			if ui_is_mouse_in_rec(area) {
				begin_image_change(state)
				x, y := get_mouse_pos_in_canvas(state, area)
				rl.ImageDrawPixel(&get_current_layer(state).image, x, y, rl.BLANK)
				mark_dirty_layers(state, state.current_layer)
			}
			cursor_icon = ICON_ERASER
		}
		if rl.IsMouseButtonReleased(.RIGHT) {
			end_image_change(state)
		}

		// fill
		if rl.IsMouseButtonPressed(.MIDDLE) {
			if ui_is_mouse_in_rec(area) {
				begin_image_change(state)
				x, y := get_mouse_pos_in_canvas(state, area)
				color := hsv_to_rgb(state.current_color)
				fill(&get_current_layer(state).image, x, y, color)
				mark_dirty_layers(state, state.current_layer)
				end_image_change(state)
			}
		}
	}
	return cursor_icon
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
			fmt.printfln("correct type")
		}
		else
		{
			fmt.printfln("not correct type")
		}
	}
}

get_mouse_pos_in_canvas :: proc(state: ^Project_State, canvas: Rec) -> (x, y: i32) {
	mpos := rl.GetMousePosition()
	px := i32((mpos.x - canvas.x) / (canvas.width / f32(state.width)))
	py := i32((mpos.y - canvas.y) / (canvas.height / f32(state.height)))
	return px, py
}

fill :: proc(image: ^rl.Image, x, y: i32, color: rl.Color) {
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

draw_canvas :: proc(state: ^Project_State, area: Rec) {
	src_rec := Rec { 0, 0, f32(state.width), f32(state.height) }
	rl.DrawTexturePro(state.bg_texture, src_rec, area, { 0, 0 }, 0, rl.WHITE)
	if len(state.layers) > 1 && state.current_layer > 0{
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
		rl.DrawLineV({ x, rec.y }, { x, rec.y + rec.height }, rl.BLACK)
		x += x_step
	}
	y := rec.y
	for y < rec.y + rec.height + 0.1 {
		rl.DrawLineV({ rec.x, y }, { rec.x + rec.width, y }, rl.BLACK)
		y += y_step
	}
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

ini_read_string :: proc(mapp: ini.Map, section, name: string, default: string = "") -> (res: string) {
	if name in mapp[section] {
		value, ok := mapp[section][name]
		if ok {
			return value
		}
	}
	return default
}