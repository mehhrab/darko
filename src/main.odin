package darko

import "core:fmt"
import rl "vendor:raylib"
import "core:mem"
import "core:math"
import "core:encoding/json"
import "core:strings"
import "core:c"
import "core:os/os2"
import "core:slice"
import ntf "../lib/nativefiledialog-odin"

LOCK_FPS :: #config(LOCK_FPS, true)
HSV :: distinct [3]f32
POPUP_NEW_PROJECT :: "New project"
POPUP_PREVIEW_SETTINGS :: "Preview settings"

App :: struct {
	state: Screen_State,
	new_project_width, new_project_height: i32,
}

Screen_State :: union {
	Welcome_State,
	Project_State,
}

Welcome_State :: struct {
}

Project_State :: struct {
	name: string,
	zoom: f32,
	spacing: f32,
	current_color: HSV,
	width: i32,
	height: i32,
	current_layer: int,
	layers: [dynamic]Layer `json:"-"`,
	lerped_zoom: f32 `json:"-"`,
	image_changed: bool `json:"-"`,
	bg_texture: rl.Texture `json:"-"`,
	preview_zoom: f32,
	lerped_preview_zoom: f32 `json:"-"`,
	preview_rotation: f32,
	preview_rotation_speed: f32,
	auto_rotate_preview: bool,
	temp_undo: Maybe(Action) `json:"-"`,
	undos: [dynamic]Action `json:"-"`,
	redos: [dynamic]Action `json:"-"`,
	diry_layers: [dynamic]int `json:"-"`,
}

Layer :: struct {
	image: rl.Image,
	texture: rl.Texture,
}

Undo :: struct {
	image: rl.Image,
}

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
	when LOCK_FPS {
		rl.SetTargetFPS(60)
	}

	ntf.Init()
	defer ntf.Quit()

	ui_init_ctx()
	defer ui_deinit_ctx()
	
	welcome_state := Welcome_State {}
	init_app(welcome_state)
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

				if ui_ctx.open_popup.name == "" {
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
				if len(state.diry_layers) > 0 {
					for layer, i in state.layers {
						if slice.contains(state.diry_layers[:], i) {
							colors := rl.LoadImageColors(layer.image)
							defer rl.UnloadImageColors(colors)
							rl.UpdateTexture(layer.texture, colors)
						}
					}
					clear(&state.diry_layers)
				}
			}
			case Welcome_State: {
				welcome_screen()
			}
			case: {
				panic("what")
			}
		}
		
		new_file_popup(&app.state)
		ui_end()

		// draw
		rl.BeginDrawing()
		rl.ClearBackground(ui_ctx.border_color)

		ui_draw()
		
		// rl.DrawFPS(rl.GetScreenWidth() - 80, 10)
		rl.EndDrawing()
	}
	rl.CloseWindow()
}

// gui code

welcome_screen :: proc() {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
	screen_area := screen_rec
	ui_push_command(UI_Draw_Rect {
		color = ui_ctx.accent_color,
		rec = rec_cut_right(&screen_area, screen_area.width / 2)
	})
	screen_area = rec_pad(screen_area, ui_px(16))
	ui_push_command(UI_Draw_Text {
		text = "Welcome to Darko!",
		align = { .Center, .Center },
		size = ui_font_size() * 2,
		color = ui_ctx.accent_color,
		rec = rec_cut_top(&screen_area, ui_default_widget_height() * 2)
	})
	buttons_area := rec_cut_top(&screen_area, ui_default_widget_height())
	if ui_button(ui_gen_id(), "New", rec_cut_left(&buttons_area, buttons_area.width / 2 - ui_px(8))) {
		ui_open_popup(POPUP_NEW_PROJECT)
	}
	rec_cut_left(&buttons_area, ui_px(8))
	if ui_button(ui_gen_id(), "Open", rec_cut_left(&buttons_area, buttons_area.width - ui_px(8))) {
		path_cstring: cstring
		defer ntf.FreePathU8(path_cstring)
		args: ntf.Open_Dialog_Args
		res := ntf.PickFolderU8(&path_cstring, "")
		if res == .Error {
			ui_show_notif("Could not open project")
		}
		else if res == .Cancel {
			return
		}

		loaded_project: Project_State
		path := string(path_cstring)		
		loaded := load_project_state(&loaded_project, path)
		if loaded == false {
			ui_show_notif("Failed to open project")
			return
		}
		
		mark_all_layers_dirty(&loaded_project)
		open_project(&loaded_project)
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
	prev_panel_color := ui_ctx.panel_color
	ui_ctx.panel_color = ui_ctx.widget_color 
	ui_panel(ui_gen_id(), area)
	ui_ctx.panel_color = prev_panel_color

	menu_items := [?]UI_Menu_Item {
		UI_Menu_Item { 
			ui_gen_id(),
			"new project",
			"",
		},
		UI_Menu_Item { 
			ui_gen_id(),
			"open project",
			"",
		},
		UI_Menu_Item { 
			ui_gen_id(),
			"save project",
			"",
		},
	}
	menu_items_slice := menu_items[:]
	clicked_item := ui_menu_button(ui_gen_id(), "File", &menu_items_slice, 300, { area.x, area.y, 60, area.height })
	if clicked_item.text == "new project" {
		ui_open_popup(POPUP_NEW_PROJECT)
	}
	if clicked_item.text == "open project" {
		defer ui_close_current_popup()

		path_cstring: cstring
		defer ntf.FreePathU8(path_cstring)
		args: ntf.Open_Dialog_Args
		res := ntf.PickFolderU8(&path_cstring, "")
		if res == .Error {
			ui_show_notif("Could not open project")
		}
		else if res == .Cancel {
			return
		}

		loaded_project: Project_State
		path := string(path_cstring)		
		loaded := load_project_state(&loaded_project, path)
		if loaded == false {
			ui_show_notif("Failed to open project")
			return
		}
		
		close_project(state)		
		open_project(&loaded_project)
		mark_all_layers_dirty(&loaded_project)
	}
	if clicked_item.text == "save project" {
		defer ui_close_current_popup()

		path_cstring: cstring
		defer ntf.FreePathU8(path_cstring)
		args: ntf.Open_Dialog_Args
		res := ntf.PickFolderU8(&path_cstring, "")
		if res == .Error {
			ui_show_notif("Could not save project")
		}
		else if res == .Cancel {
			return
		}

		path := string(path_cstring)
		state.name = path[strings.last_index(path, "\\") + 1:]
		saved := save_project_state(state, path)
		if saved == false {
			ui_show_notif("Could not save project")
			return
		}

		ui_show_notif("Project is saved")
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
		color = ui_ctx.text_color,
		rec = props_area,
		size = ui_font_size(),
		text = fmt.tprintf("layer {}/{}", current_layer, layer_count),
	})

	// delete button
	delete_rec := rec_cut_right(&props_area, ui_default_widget_height())
	if ui_button(ui_gen_id(), ICON_TRASH, delete_rec, style = UI_BUTTON_STYLE_RED) {
		if len(state.layers) <= 1 {
			ui_show_notif("At least one layer is needed")
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
		color = ui_ctx.border_color,
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
		color = ui_ctx.border_color,
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
		color = ui_ctx.border_color,
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
		color = ui_ctx.border_color,
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
		color = ui_ctx.border_color,
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
	prev_font_size := ui_ctx.font_size
	ui_ctx.font_size = 20
	prev_widget_color := ui_ctx.widget_color
	ui_ctx.widget_color = rl.BLANK
	if ui_button(ui_gen_id(), ICON_SETTINGS, settings_rec, false, style = UI_BUTTON_STYLE_TRANSPARENT) {
		ui_open_popup(POPUP_PREVIEW_SETTINGS)
	}
	ui_ctx.font_size = prev_font_size
	ui_ctx.widget_color = prev_widget_color
}

new_file_popup :: proc(state: ^Screen_State) {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
	
	popup_h := ui_calc_popup_height(3, ui_default_widget_height(), ui_px(8), ui_px(16))
	popup_rec := rec_center_in_area({ 0, 0, ui_px(400), popup_h }, screen_rec)
	if open, rec := ui_begin_popup_with_header(POPUP_NEW_PROJECT, ui_gen_id(), popup_rec); open {
		area := rec_pad(rec, ui_px(16))
		ui_slider_i32(ui_gen_id(), "Width", &app.new_project_width, 2, 30, rec_cut_top(&area, ui_default_widget_height()))
		rec_delete_top(&area, ui_px(8))
		
		ui_slider_i32(ui_gen_id(), "Height", &app.new_project_height, 2, 30, rec_cut_top(&area, ui_default_widget_height()))
		rec_delete_top(&area, ui_px(8))
		
		if ui_button(ui_gen_id(), "Create", area) {
			switch &current_state in state {
				case Project_State: {
					close_project(&current_state)
				}
				case Welcome_State: {

				}
			}

			project: Project_State
			init_project_state(&project, app.new_project_width, app.new_project_height)
			open_project(&project)
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
	if open, rec := ui_begin_popup_with_header(POPUP_PREVIEW_SETTINGS, ui_gen_id(), popup_area); open {
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

// backend code

init_app :: proc(state: Screen_State) {
	app.state = state
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
}

init_project_state :: proc(state: ^Project_State, width, height: i32) {
	state.name = "untitled"
	state.zoom = 1
	state.spacing = 1
	state.width = width
	state.height = height
	state.layers = make([dynamic]Layer)
	state.current_color = { 200, 0.5, 0.1 }	
	state.lerped_zoom = 1
	state.lerped_preview_zoom = 1
	bg_image := rl.GenImageChecked(state.width,  state.height, 1, 1, { 198, 208, 245, 255 }, { 131, 139, 167, 255 })
	defer rl.UnloadImage(bg_image)
	state.bg_texture = rl.LoadTextureFromImage(bg_image)
	state.preview_rotation = 0
	state.preview_zoom = 10
	state.undos = make([dynamic]Action)
	state.redos = make([dynamic]Action)
	state.diry_layers = make([dynamic]int)
	
	layer: Layer
	init_layer(&layer, width, height)
	append(&state.layers, layer)
	mark_all_layers_dirty(state)
}

// TODO: return an error value instead of a bool
load_project_state :: proc(state: ^Project_State, dir: string) -> (ok: bool) {
	// check if project.json and at least one layer exists
	json_exists := os2.exists(fmt.tprintf("{}{}", dir, "\\project.json"))
	layer0_exists := os2.exists(fmt.tprintf("{}{}", dir, "\\layer0.png"))
	if (json_exists || layer0_exists) == false {
		return false
	}

	// load project.json
	size: i32
	data := rl.LoadFileData(fmt.ctprintf("{}{}", dir, "\\project.json"), &size)
	defer rl.UnloadFileData(data)
	text := strings.string_from_null_terminated_ptr(data, int(size))
	loaded_state: Project_State
	unmarshal_err := json.unmarshal(transmute([]u8)text, &loaded_state, allocator = context.temp_allocator)
	if unmarshal_err != nil {
		return false
	}
	state^ = loaded_state

	// load layers
	files, read_dir_err := os2.read_all_directory_by_path(dir, context.allocator)
	defer os2.file_info_slice_delete(files, context.allocator)
	if read_dir_err != os2.ERROR_NONE {
		return false
	}
	for file in files {
		if strings.has_suffix(file.fullpath, ".png") {
			layer: Layer
			layer.image = rl.LoadImage(fmt.ctprint(file.fullpath))
			layer.texture = rl.LoadTextureFromImage(layer.image)
			append(&state.layers, layer)
		}
	}

	return true
}

// TODO: return an error value instead of a bool
save_project_state :: proc(state: ^Project_State, dir: string) -> (ok: bool) {
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

	// save project.json
	text, marshal_err := json.marshal(state^, { pretty = true }, context.temp_allocator)
	if marshal_err != nil {
		fmt.printfln("{}", marshal_err)
		return false
	}
	saved := rl.SaveFileText(fmt.ctprintf("{}\\project.json", dir), raw_data(text))
	if saved == false {
		fmt.printfln("svae file text")
		return false
	}

	// save layers
	for layer, i in state.layers {
		rl.ExportImage(layer.image, fmt.ctprintf("{}\\layer{}.png", dir, i))
	}
	
	return true
}

deinit_project_state :: proc(state: ^Project_State) {
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
	delete(state.diry_layers)
	rl.UnloadTexture(state.bg_texture)
}

open_project :: proc(state: ^Project_State) {
	app.state = state^
	rl.SetWindowTitle(fmt.ctprintf("darko - {}", state.name))
	ui_show_notif(ICON_CHECK + " Project is opened")
}

close_project :: proc(state: ^Project_State) {
	deinit_project_state(state)
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

get_current_layer :: proc(state: ^Project_State) -> (layer: ^Layer) {
	return &state.layers[state.current_layer]
}

mark_dirty_layers :: proc(state: ^Project_State, indexes: ..int) {
	append(&state.diry_layers, ..indexes)
}

mark_all_layers_dirty :: proc(state: ^Project_State) {
	for i in 0..<len(state.layers) {
		append(&state.diry_layers, i)
	}
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

rgb_to_hsv :: proc(rgb: rl.Color) -> (hsv: HSV) {
	return HSV(rl.ColorToHSV(rgb))
}

hsv_to_rgb :: proc(hsv: HSV) -> (rgb: rl.Color) {
	return rl.ColorFromHSV(hsv[0], hsv[1], hsv[2])
}