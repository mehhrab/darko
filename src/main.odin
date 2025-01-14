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

App :: struct {
	project: Project,
	width: i32, height: i32,
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
	diry_layers: [dynamic]int,
}

Project :: struct {
	name: string,
	zoom: f32,
	spacing: f32,
	current_color: HSV,
	width, height: i32,
	current_layer: int,
	layers: [dynamic]Layer `json:"-"`,
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

action_preform :: proc(action: Action) {
	switch &kind in action {
		case Action_Image_Change: {
			image := rl.ImageCopy(kind.after_image)
			app.project.layers[kind.layer_index].image = image
			mark_dirty_layers(app.project.current_layer)
		}
		case Action_Create_Layer: {
			layer: Layer
			init_layer(&layer, app.project.width, app.project.height)
			inject_at(&app.project.layers, kind.layer_index, layer)
			app.project.current_layer = kind.layer_index
		}
		case Action_Duplicate_Layer: {
			layer: Layer
			layer.image = rl.ImageCopy(app.project.layers[kind.from_index].image)
			layer.texture = rl.LoadTextureFromImage(layer.image)
			inject_at_elem(&app.project.layers, kind.to_index, layer)
			app.project.current_layer = kind.to_index
		}
		case Action_Change_Layer_Index: {
			layer := app.project.layers[kind.from_index]
			ordered_remove(&app.project.layers, kind.from_index)
			inject_at_elem(&app.project.layers, kind.to_index, layer)
			app.project.current_layer = kind.to_index
		}
		case Action_Delete_Layer: {
			kind.image = rl.ImageCopy(get_current_layer().image)
			deinit_layer(&app.project.layers[kind.layer_index])
			ordered_remove(&app.project.layers, kind.layer_index)
			if kind.layer_index > 0 {
				app.project.current_layer -= 1
			}
		}
	}
}

action_unpreform :: proc(action: Action) {
	switch kind in action {
		case Action_Image_Change: {
			image := rl.ImageCopy(kind.before_image)
			app.project.layers[kind.layer_index].image = image
			mark_dirty_layers(app.project.current_layer)
		}
		case Action_Create_Layer: {
			deinit_layer(&app.project.layers[kind.layer_index])
			ordered_remove(&app.project.layers, kind.layer_index)
			app.project.current_layer = kind.current_layer_index
		}
		case Action_Duplicate_Layer: {
			deinit_layer(&app.project.layers[kind.to_index])
			ordered_remove(&app.project.layers, kind.to_index)
			app.project.current_layer = kind.from_index
		}
		case Action_Change_Layer_Index: {
			layer := app.project.layers[kind.to_index]
			ordered_remove(&app.project.layers, kind.to_index)
			inject_at_elem(&app.project.layers, kind.from_index, layer)
			app.project.current_layer = kind.from_index
		}
		case Action_Delete_Layer: {
			layer: Layer
			layer.image = rl.ImageCopy(kind.image)
			layer.texture = rl.LoadTextureFromImage(layer.image)
			inject_at(&app.project.layers, kind.layer_index, layer)
			app.project.current_layer = kind.layer_index
			mark_dirty_layers(app.project.current_layer)
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

action_do :: proc(action: Action) {
	action_preform(action)
	append(&app.undos, action)
	for action in app.redos {
		action_deinit(action)
	}
	fmt.printfln("cleared redos")
	clear(&app.redos)
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
	
	init_app()
	defer deinit_app()

	project: Project
	init_project(&project, 8, 8)
	open_project(&project)

	for rl.WindowShouldClose() == false {
		gui()

		// update

		if ui_ctx.open_popup.name == "" {
			// create new layer above the current
			if rl.IsKeyPressed(.SPACE) {
				action_do(Action_Create_Layer {
					current_layer_index = app.project.current_layer,
					layer_index = app.project.current_layer + 1
				})
			}

			// create new layer at the top
			if rl.IsKeyPressed(.S) {
				action_do(Action_Create_Layer {
					current_layer_index = app.project.current_layer,
					layer_index = len(app.project.layers)
				})
			}

			// move current layer up
			if rl.IsKeyPressed(.UP) {
				app.project.current_layer += 1
				if app.project.current_layer >= len(app.project.layers) {
					app.project.current_layer = 0
				}
			}

			// move current layer down
			if rl.IsKeyPressed(.DOWN) {
				app.project.current_layer -= 1
				if app.project.current_layer < 0 {
					app.project.current_layer = len(app.project.layers) - 1
				}
			}

			// undo
			if rl.IsKeyPressed(.Z) {
				if len(app.undos) > 0 {
					fmt.printfln("undo")
					action := pop(&app.undos)
					action_unpreform(action)
					append(&app.redos, action)
				}	
			}

			// redo
			if rl.IsKeyPressed(.Y) {
				if len(app.redos) > 0 {
					fmt.printfln("redo")
					action := pop(&app.redos)
					action_preform(action)
					append(&app.undos, action)
				}	
			}
		}

		// update the textures for dirty layers
		if len(app.diry_layers) > 0 {
			for layer, i in app.project.layers {
				if slice.contains(app.diry_layers[:], i) {
					colors := rl.LoadImageColors(layer.image)
					defer rl.UnloadImageColors(colors)
					rl.UpdateTexture(layer.texture, colors)
				}
			}
			clear(&app.diry_layers)
		}

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

gui :: proc() {
	ui_begin()

	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
	menu_bar_area := rec_cut_top(&screen_rec, ui_ctx.default_widget_height)
	menu_bar(menu_bar_area)

	screen_area := screen_rec

	right_panel_area := rec_cut_right(&screen_area, screen_area.width / 3)
	middle_panel_area := screen_area
	
	layer_props_area := rec_cut_top(&middle_panel_area, ui_ctx.default_widget_height + 16)
	layer_props(layer_props_area)

	canvas(middle_panel_area)
	
	ui_panel(ui_gen_id(), right_panel_area)
	right_panel_area = rec_pad(right_panel_area, 16)
	color_panel(&right_panel_area)

	rec_delete_top(&right_panel_area, 16)

	preview(right_panel_area)
	
	preview_settings_popup()
	new_file_popup()
	
	ui_end()
}

menu_bar :: proc(area: Rec) {
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
		ui_open_popup("New file")
	}
	if clicked_item.text == "open project" {
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

		project: Project
		path := string(path_cstring)		
		loaded := load_project(&project, path)
		if loaded == false {
			ui_show_notif("Failed to open project")
			return
		}
		
		close_project()		
		open_project(&project)
		mark_dirty_layers(app.project.current_layer)

		ui_show_notif("Project is opened")
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
		app.project.name = path[strings.last_index(path, "\\") + 1:]
		saved := save_project(&app.project, path)
		if saved == false {
			ui_show_notif("Could not save project")
			return
		}

		ui_show_notif("Project is saved")
	}
}

layer_props :: proc(rec: Rec) {
	ui_panel(ui_gen_id(), rec)
	props_area := rec_pad_ex(rec, 8, 8, 8, 8)
	
	// draw current layer index and layer count
	current_layer := app.project.current_layer + 1
	layer_count := len(app.project.layers)
	ui_push_command(UI_Draw_Text {
		align = { .Left, .Center },
		color = ui_ctx.text_color,
		rec = props_area,
		size = ui_ctx.font_size,
		text = fmt.tprintf("layer {}/{}", current_layer, layer_count),
	})

	// delete button
	delete_rec := rec_cut_right(&props_area, ui_ctx.default_widget_height)
	if ui_button(ui_gen_id(), ICON_TRASH, delete_rec, style = UI_BUTTON_STYLE_RED) {
		if len(app.project.layers) <= 1 {
			ui_show_notif("At least one layer is needed")
		} 
		else {
			action_do(Action_Delete_Layer {
				layer_index = app.project.current_layer,
			})

		}
	}


	// move up button
	rec_cut_right(&props_area, 8)
	move_up_rec := rec_cut_right(&props_area, ui_ctx.default_widget_height)
	if ui_button(ui_gen_id(), ICON_UP, move_up_rec, style = UI_BUTTON_STYLE_ACCENT) {
		if len(app.project.layers) > 1 && app.project.current_layer < len(app.project.layers) - 1 {
			action_do(Action_Change_Layer_Index {
				from_index = app.project.current_layer,
				to_index = app.project.current_layer + 1
			})
		}
	}

	// move down button
	rec_cut_right(&props_area, 0)
	move_down_rec := rec_cut_right(&props_area, ui_ctx.default_widget_height)
	if ui_button(ui_gen_id(), ICON_DOWN, move_down_rec, style = UI_BUTTON_STYLE_ACCENT) {
		if len(app.project.layers) > 1 && app.project.current_layer > 0 {
			action_do(Action_Change_Layer_Index {
				from_index = app.project.current_layer,
				to_index = app.project.current_layer - 1
			})
		}
	}

	// duplicate button
	rec_cut_right(&props_area, 8)
	duplicate_rec := rec_cut_right(&props_area, ui_ctx.default_widget_height)
	if ui_button(ui_gen_id(), ICON_COPY, duplicate_rec, style = UI_BUTTON_STYLE_ACCENT) {
		action_do(Action_Duplicate_Layer {
			from_index = app.project.current_layer,
			to_index = app.project.current_layer + 1,
		})
	}
}

canvas :: proc(rec: Rec) {
	area := rec

	app.lerped_zoom = rl.Lerp(app.lerped_zoom, app.project.zoom, 20 * rl.GetFrameTime())
	// work around for lerp never (taking too long) reaching it's desteniton 
	if math.abs(app.project.zoom - app.lerped_zoom) < 0.01 {
		app.lerped_zoom = app.project.zoom
	}

	canvas_w := f32(app.project.width) * 10 * app.lerped_zoom 
	canvas_h := f32(app.project.height) * 10 * app.lerped_zoom
	canvas_rec := rec_center_in_area({ 0, 0, canvas_w, canvas_h }, area)
	
	cursor_icon := ""
	if ui_is_being_interacted() == false {
		update_zoom(&app.project.zoom, 0.3, 0.1, 100)
		cursor_icon = update_tools(canvas_rec)
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
		cursor_size := ui_ctx.font_size * 2
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

color_panel :: proc(area: ^Rec) {		
	// preview color
	preview_area := rec_cut_top(area, ui_ctx.default_widget_height * 3)
	ui_push_command(UI_Draw_Rect {
		color = hsv_to_rgb(app.project.current_color),
		rec = preview_area,
	})
	ui_push_command(UI_Draw_Rect_Outline {
		color = ui_ctx.border_color,
		rec = preview_area,
		thickness = 1,
	})
	rec_delete_top(area, 8)

	hsv_color := get_pen_color_hsv()

	// not sure if it's actually called grip...
	draw_grip :: proc(value, min, max: f32, rec: Rec) {
		grip_width := f32(10)
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
	hue_rec := rec_cut_top(area, ui_ctx.default_widget_height)
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

	rec_delete_top(area, 8)

	// saturation slider
	saturation_rec := rec_cut_top(area, ui_ctx.default_widget_height)
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

	rec_delete_top(area, 8)
	
	// value slider
	value_rec := rec_cut_top(area, ui_ctx.default_widget_height)
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
		app.project.current_color = hsv_color
	}
}

preview :: proc(rec: Rec) {
	area := rec
	id := ui_gen_id()
	ui_update_widget(id, area)
	if ui_ctx.hovered_widget == id {
		update_zoom(&app.preview_zoom, 2, 1, 100)
	}
	app.lerped_preview_zoom = rl.Lerp(app.lerped_preview_zoom, app.preview_zoom, 20 * rl.GetFrameTime())
	// work around for lerp never (taking too long) reaching it's desteniton 
	if math.abs(app.preview_zoom - app.lerped_preview_zoom) < 0.01 {
		app.lerped_preview_zoom = app.preview_zoom
	}
	if ui_ctx.active_widget == id {
		app.preview_rotation -= rl.GetMouseDelta().x 
	}
	else if app.auto_rotate_preview {
		app.preview_rotation -= app.preview_rotation_speed * rl.GetFrameTime()
	}
	ui_push_command(UI_Draw_Preview {
		rec = area,
	})
	settings_rec := Rec {
		area.x + area.width - ui_ctx.default_widget_height - 8,
		area.y + 8,
		ui_ctx.default_widget_height,
		ui_ctx.default_widget_height,
	}
	prev_font_size := ui_ctx.font_size
	ui_ctx.font_size = 20
	prev_widget_color := ui_ctx.widget_color
	ui_ctx.widget_color = rl.BLANK
	if ui_button(ui_gen_id(), ICON_SETTINGS, settings_rec, false, style = UI_BUTTON_STYLE_TRANSPARENT) {
		ui_open_popup("Preview settings")
	}
	ui_ctx.font_size = prev_font_size
	ui_ctx.widget_color = prev_widget_color
}

new_file_popup :: proc() {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }

	popup_rec := rec_center_in_area({ 0, 0, 400, 150 }, screen_rec)
	if open, rec := ui_begin_popup_with_header("New file", ui_gen_id(), popup_rec); open {
		area := rec_pad(rec, 16)
		ui_slider_i32(ui_gen_id(), "Width", &app.width, 2, 30, rec_cut_top(&area, ui_ctx.default_widget_height))
		rec_delete_top(&area, 8)
		ui_slider_i32(ui_gen_id(), "Height", &app.height, 2, 30, rec_cut_top(&area, ui_ctx.default_widget_height))
		rec_delete_top(&area, 8)
		if ui_button(ui_gen_id(), "Create", area) {
			close_project()

			project: Project
			init_project(&project, app.width, app.height)
			open_project(&project)
			ui_close_current_popup()
			ui_show_notif(ICON_CHECK + " Project is created")
		}	
	}
	ui_end_popup()
}

preview_settings_popup :: proc() {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
	popup_area := rec_center_in_area({ 0, 0, 300, 200 }, screen_rec)
	if open, rec := ui_begin_popup_with_header("Preview settings", ui_gen_id(), popup_area); open {
		area := rec_pad(rec, 16)
		auto_rotate_rec := rec_cut_top(&area, ui_ctx.default_widget_height)
		ui_check_box(ui_gen_id(),"Auto rotate", &app.auto_rotate_preview, auto_rotate_rec)
		rec_delete_top(&area, 8)
		ui_slider_f32(ui_gen_id(), "Rotation speed", &app.preview_rotation_speed, 5, 30, rec_cut_top(&area, ui_ctx.default_widget_height))
		rec_delete_top(&area, 8)
		ui_slider_f32(ui_gen_id(), "Spacing", &app.project.spacing, 0.1, 2, rec_cut_top(&area, ui_ctx.default_widget_height))
	}
	ui_end_popup()
}

// backend code

init_app :: proc() {
	
}

deinit_app :: proc() {
	close_project()
}

init_project :: proc(project: ^Project, width, height: i32) {
	project.name = "untitled"
	project.zoom = 1
	project.spacing = 1
	project.width = width
	project.height = height
	project.layers = make([dynamic]Layer)
	project.current_color = { 200, 0.5, 0.1 }
	
	{
		layer: Layer
		init_layer(&layer, width, height)
		append(&project.layers, layer)
	}
}

// TODO: return an error value instead of a bool
load_project :: proc(project: ^Project, dir: string) -> (ok: bool) {
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
	unmarshal_err := json.unmarshal(transmute([]u8)text, project, allocator = context.temp_allocator)
	if unmarshal_err != nil {
		return false
	}

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
			append(&project.layers, layer)
		}
	}

	return true
}

// TODO: return an error value instead of a bool
save_project :: proc(project: ^Project, dir: string) -> (ok: bool) {
	// clear the directory
	remove_err := os2.remove_all(dir)
	if remove_err != os2.ERROR_NONE {
		return false
	}
	make_dir_err := os2.make_directory(dir)
	if make_dir_err != os2.ERROR_NONE {
		return false
	}

	// save project.json
	text, marshal_err := json.marshal(app.project, { pretty = true }, context.temp_allocator)
	if marshal_err != nil {
		return false
	}
	saved := rl.SaveFileText(fmt.ctprintf("{}\\project.json", dir), raw_data(text))
	if saved == false {
		return false
	}

	// save layers
	for layer, i in app.project.layers {
		rl.ExportImage(layer.image, fmt.ctprintf("{}\\layer{}.png", dir, i))
	}
	
	return true
}

deinit_project :: proc(project: ^Project) {
	for &layer in project.layers {
		deinit_layer(&layer)
	}
	delete(project.layers)
}

open_project :: proc(project: ^Project) {
	app.project = project^
	
	rl.SetWindowTitle(fmt.ctprintf("darko - {}", project.name))

	app.lerped_zoom = 1
	app.lerped_preview_zoom = 1
	bg_image := rl.GenImageChecked(
		project.width, 
		project.height,
		1, 
		1, 
		{ 198, 208, 245, 255 }, 
		{ 131, 139, 167, 255 })
	defer rl.UnloadImage(bg_image)
	app.bg_texture = rl.LoadTextureFromImage(bg_image)
	app.preview_rotation = 0
	app.preview_zoom = 10
	app.undos = make([dynamic]Action)
	app.redos = make([dynamic]Action)
	app.diry_layers = make([dynamic]int)

	mark_all_layers_dirty()
}

close_project :: proc() {
	for action in app.undos {
		action_deinit(action)
	}
	delete(app.undos)
	for action in app.redos {
		action_deinit(action)
	}
	delete(app.redos)
	delete(app.diry_layers)
	deinit_project(&app.project)
	rl.UnloadTexture(app.bg_texture)
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

get_current_layer :: proc() -> (layer: ^Layer) {
	return &app.project.layers[app.project.current_layer]
}

mark_dirty_layers :: proc(indexes: ..int) {
	append(&app.diry_layers, ..indexes)
}

mark_all_layers_dirty :: proc() {
	for i in 0..<len(app.project.layers) {
		append(&app.diry_layers, i)
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

update_tools :: proc(area: Rec) -> (cursor_icon: string) {
	cursor_icon = ""

	// color picker
	if rl.IsKeyDown(.LEFT_CONTROL) {
		if ui_is_mouse_in_rec(area) {
			if rl.IsMouseButtonPressed(.LEFT) {
				x, y := get_mouse_pos_in_canvas(area)
				rgb_color := rl.GetImageColor(get_current_layer().image, x, y)
				if rgb_color.a != 0 {
					set_pen_color_rgb(rgb_color)
				}
			}
		}
		cursor_icon = ICON_EYEDROPPER
	}
	else {		
		// pencil
		if rl.IsMouseButtonDown(.LEFT) {
			if ui_is_mouse_in_rec(area) {
				begin_image_change()
				x, y := get_mouse_pos_in_canvas(area)
				rl.ImageDrawPixel(&get_current_layer().image, x, y, get_pen_color_rgb())
				mark_dirty_layers(app.project.current_layer)	
			}
			cursor_icon = ICON_PEN
		}
		if rl.IsMouseButtonReleased(.LEFT) {
			end_image_change()
		}

		// eraser
		if rl.IsMouseButtonDown(.RIGHT) {
			if ui_is_mouse_in_rec(area) {
				begin_image_change()
				x, y := get_mouse_pos_in_canvas(area)
				rl.ImageDrawPixel(&get_current_layer().image, x, y, rl.BLANK)
				mark_dirty_layers(app.project.current_layer)
			}
			cursor_icon = ICON_ERASER
		}
		if rl.IsMouseButtonReleased(.RIGHT) {
			end_image_change()
		}

		// fill
		if rl.IsMouseButtonPressed(.MIDDLE) {
			if ui_is_mouse_in_rec(area) {
				begin_image_change()
				x, y := get_mouse_pos_in_canvas(area)
				fill(&get_current_layer().image, x, y, get_pen_color_rgb())
				mark_dirty_layers(app.project.current_layer)
				end_image_change()
			}
		}
	}
	return cursor_icon
}

begin_image_change :: proc() {
	_, exists := app.temp_undo.?
	if exists == false {
		app.temp_undo = Action_Image_Change {
			before_image = rl.ImageCopy(get_current_layer().image),
			layer_index = app.project.current_layer,
		} 
	}
}

end_image_change :: proc() {
	temp_undo, exists := app.temp_undo.?
	action, is_correct_type := temp_undo.(Action_Image_Change)
	if exists {
		if is_correct_type {
			action.after_image = rl.ImageCopy(get_current_layer().image)
			action_do(action)
			app.temp_undo = nil			
			fmt.printfln("correct type")
		}
		else
		{
			fmt.printfln("not correct type")
		}
	}
}

get_mouse_pos_in_canvas :: proc(canvas: Rec) -> (x, y: i32) {
	mpos := rl.GetMousePosition()
	px := i32((mpos.x - canvas.x) / (canvas.width / f32(app.project.width)))
	py := i32((mpos.y - canvas.y) / (canvas.height / f32(app.project.height)))
	return px, py
}

fill :: proc(image: ^rl.Image, x, y: i32, color: rl.Color) {
	current_color := rl.GetImageColor(get_current_layer().image, x, y)
	if current_color == color {
		return
	}
	dfs(image, x, y, current_color, color)
}

dfs :: proc(image: ^rl.Image, x, y: i32, prev_color, new_color: rl.Color) {
	current_color := rl.GetImageColor(get_current_layer().image, x, y)
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

draw_canvas :: proc(area: Rec) {
	src_rec := Rec { 0, 0, f32(app.project.width), f32(app.project.height) }
	rl.DrawTexturePro(app.bg_texture, src_rec, area, { 0, 0 }, 0, rl.WHITE)
	if len(app.project.layers) > 1 && app.project.current_layer > 0{
		previous_layer := app.project.layers[app.project.current_layer - 1].texture
		rl.DrawTexturePro(previous_layer, src_rec, area, { 0, 0 }, 0, { 255, 255, 255, 100 })
	}
	rl.DrawTexturePro(get_current_layer().texture, src_rec, area, { 0, 0 }, 0, rl.WHITE)
}

draw_grid :: proc(rec: Rec) {
	x_step := rec.width / f32(app.project.width)
	y_step := rec.height / f32(app.project.height)

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

// TODO: find a better name for pen?
get_pen_color_rgb :: proc() -> rl.Color {
	return hsv_to_rgb(app.project.current_color)
}

get_pen_color_hsv :: proc() -> HSV {
	return app.project.current_color
}

set_pen_color_rgb :: proc(rgb: rl.Color) {
	app.project.current_color = HSV(rl.ColorToHSV(rgb))
}

set_pen_color_hsv :: proc(hsv: HSV) {
	app.project.current_color = hsv
}

hsv_to_rgb :: proc(hsv: HSV) -> (rgb: rl.Color) {
	return rl.ColorFromHSV(hsv[0], hsv[1], hsv[2])
}