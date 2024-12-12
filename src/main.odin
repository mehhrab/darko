package darko

import "core:fmt"
import rl "vendor:raylib"
import "core:mem"
import "core:math"
import "core:encoding/json"
import "core:strings"
import "core:c"
import "core:os/os2"
import ntf "../lib/nativefiledialog-odin"

LOCK_FPS :: #config(LOCK_FPS, true)

App :: struct {
	project: Project,
	width: i32, height: i32,
	lerped_zoom: f32,
	image_changed: bool,
	bg_texture: rl.Texture,
	preview_zoom: f32,	
	preview_rotation: f32,
	preview_rotation_speed: f32,
	auto_rotate_preview: bool,
	temp_undo_image: Maybe(rl.Image),
}

Project :: struct {
	name: string,
	zoom: f32,
	current_color: rl.Color,
	width, height: i32,
	current_layer: int,
	layers: [dynamic]Layer `json:"-"`,
}

Layer :: struct {
	image: rl.Image,
	texture: rl.Texture,
	undos: [dynamic]rl.Image,
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
		// ui
		gui()

		// update
		if rl.IsKeyPressed(.SPACE) {
			layer: Layer
			init_layer(&layer, app.project.width, app.project.height)
			add_layer_above_current(&layer)
		}
		if rl.IsKeyPressed(.S) {
			layer: Layer
			init_layer(&layer, app.project.width, app.project.height)
			add_layer_on_top(&layer)
		}
		if rl.IsKeyPressed(.UP) {
			app.project.current_layer += 1
			if app.project.current_layer >= len(app.project.layers) {
				app.project.current_layer = 0
			}
		}
		if rl.IsKeyPressed(.DOWN) {
			app.project.current_layer -= 1
			if app.project.current_layer < 0 {
				app.project.current_layer = len(app.project.layers) - 1
			}
		}
		if app.image_changed {
			colors := rl.LoadImageColors(get_current_layer().image)
			defer rl.UnloadImageColors(colors)
			rl.UpdateTexture(get_current_layer().texture, colors)
			app.image_changed = false
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
	menu_bar_area := rec_cut_from_top(&screen_rec, ui_ctx.default_widget_height)
	menu_bar(menu_bar_area)

	screen_area := screen_rec
	panel_width := screen_area.width / 3

	right_panel_area := rec_cut_from_right(&screen_area, panel_width)
	middle_panel_area := screen_area
	
	layer_props_area := rec_cut_from_top(&middle_panel_area, ui_ctx.default_widget_height + 8)
	layer_props(layer_props_area)

	app.lerped_zoom = rl.Lerp(app.lerped_zoom, app.project.zoom, 20 * rl.GetFrameTime())
	// work around for lerp never (taking too long) reaching it's desteniton 
	if math.abs(app.project.zoom - app.lerped_zoom) < 0.01 {
		app.lerped_zoom = app.project.zoom
	}

	canvas_rec := rec_center_in_area(
		{ 0, 0, f32(app.project.width) * 10 * app.lerped_zoom, f32(app.project.height) * 10 *  app.lerped_zoom },
		middle_panel_area)
	
	if ui_is_being_interacted() == false {
		update_zoom(&app.project.zoom, 0.3, 0.1, 100)
		update_tools(canvas_rec)
	}
	
	ui_push_command(UI_Draw_Canvas {
		rec = canvas_rec,
		panel_rec = middle_panel_area,
	})
	ui_push_command(UI_Draw_Grid {
		rec = canvas_rec,
		panel_rec = middle_panel_area,
	})
	ui_push_command(UI_Draw_Rect_Outline {
		rec = middle_panel_area,
		color = ui_ctx.border_color,
		thickness = 1
	})
	if ui_is_mouse_in_rec(middle_panel_area) && ui_is_being_interacted() == false {
		rl.HideCursor()
		mpos := rl.GetMousePosition()
		// pen
		icon := "\uf8ea"
		if rl.IsMouseButtonDown(.RIGHT) {
			// eraser
			icon = "\uf6fd"
		}
		cursor_size := f32(40)
		ui_push_command(UI_Draw_Text {
			rec = { mpos.x + 1, mpos.y - cursor_size + 5 + 1, 100, 100 },
			color = rl.BLACK,
			text = icon,
			size = cursor_size,
		})
		ui_push_command(UI_Draw_Text {
			rec = { mpos.x, mpos.y - cursor_size + 5, 100, 100 },
			color = rl.WHITE,
			text = icon,
			size = cursor_size,
		})
	}
	else {
		rl.ShowCursor()
	}
	
	ui_panel(ui_gen_id_auto(), right_panel_area)
	right_panel_area = rec_pad(right_panel_area, 16)
	color_panel(&right_panel_area)

	rec_delete_from_top(&right_panel_area, 16)

	preview(right_panel_area)
	
	preview_settings_popup()
	new_file_popup()
	
	ui_end()
}

menu_bar :: proc(area: Rec) {
	prev_panel_color := ui_ctx.panel_color
	ui_ctx.panel_color = ui_ctx.widget_color 
	ui_panel(ui_gen_id_auto(), area)
	ui_ctx.panel_color = prev_panel_color

	menu_items := [?]UI_Menu_Item {
		UI_Menu_Item { 
			ui_gen_id_auto(),
			"new project",
			"",
		},
		UI_Menu_Item { 
			ui_gen_id_auto(),
			"open project",
			"",
		},
		UI_Menu_Item { 
			ui_gen_id_auto(),
			"save project",
			"",
		},
	}
	menu_items_slice := menu_items[:]
	clicked_item := ui_menu_button(ui_gen_id_auto(), "File", &menu_items_slice, 300, { area.x, area.y, 60, area.height })
	if clicked_item.text == "new project" {
		ui_open_popup("New file")
	}
	if clicked_item.text == "open project" {
		defer ui_close_current_popup()

		path: cstring
		defer ntf.FreePathU8(path)
		args: ntf.Open_Dialog_Args
		res := ntf.PickFolderU8(&path, "")
		if res != .Okay {
			return
		}

		project: Project
		project_path := string(path)		
		loaded := load_project(&project, project_path)
		if loaded == false {
			ui_show_notif("Failed to open project")
			return
		}
		close_project()		
		open_project(&project)
		app.image_changed = true
		ui_show_notif("Project is opened")
	}
	if clicked_item.text == "save project" {
		defer ui_close_current_popup()

		path: cstring
		defer ntf.FreePathU8(path)
		args: ntf.Open_Dialog_Args
		res := ntf.PickFolderU8(&path, "")
		if res != .Okay {
			return
		}

		project_path := string(path)
		app.project.name = project_path[strings.last_index(project_path, "\\") + 1:]
		saved := save_project(&app.project, project_path)
		if saved == false {
			ui_show_notif("Could not save project")
			return
		}
		ui_show_notif("Project is saved")
	}
}

layer_props :: proc(rec: Rec) {
	ui_panel(ui_gen_id_auto(), rec)
	props_area := rec_pad(rec, 8)
	
	current_layer := app.project.current_layer + 1
	layer_count := len(app.project.layers)
	ui_push_command(UI_Draw_Text {
		align = { .Left, .Center },
		color = ui_ctx.text_color,
		rec = props_area,
		size = ui_ctx.font_size,
		text = fmt.tprintf("layer {}/{}", current_layer, layer_count),
	})
	
	if ui_button(ui_gen_id_auto(), "Delete", rec_cut_from_right(&props_area, 100)) {
		if len(app.project.layers) <= 1 {
			ui_show_notif("At least one layer is needed")
		} 
		else {
			deinit_layer(&app.project.layers[app.project.current_layer])
			ordered_remove(&app.project.layers, app.project.current_layer)
			if app.project.current_layer > 0 {
				app.project.current_layer -= 1
			}
		}
	}
	// ui_button(ui_gen_id_auto(), "Move UP", rec_cut_from_right(&props_area, 100))
	// ui_button(ui_gen_id_auto(), "Move Down", rec_cut_from_right(&props_area, 100))
}

color_panel :: proc(area: ^Rec) {	
	preview_area := rec_cut_from_top(area, ui_ctx.default_widget_height * 2)
	ui_push_command(UI_Draw_Rect {
		color = app.project.current_color,
		rec = preview_area,
	})
	ui_push_command(UI_Draw_Rect_Outline {
		color = ui_ctx.border_color,
		rec = preview_area,
		thickness = 1,
	})
	rec_delete_from_top(area, 8)

	@(static)
	hsv_color := [3]f32 { 0, 0, 0 }

	changed1 := ui_slider_f32(ui_gen_id_auto(), "Hue", &hsv_color[0], 0, 360, rec_cut_from_top(area, ui_ctx.default_widget_height))
	rec_delete_from_top(area, 8)

	changed2 := ui_slider_f32(ui_gen_id_auto(), "Saturation", &hsv_color[1], 0, 1, rec_cut_from_top(area, ui_ctx.default_widget_height))
	rec_delete_from_top(area, 8)
	
	changed3 := ui_slider_f32(ui_gen_id_auto(), "Value", &hsv_color[2], 0, 1, rec_cut_from_top(area, ui_ctx.default_widget_height))

	if changed1 || changed2 || changed3  {
		app.project.current_color = rl.ColorFromHSV(hsv_color[0], hsv_color[1], hsv_color[2])
	}
}

preview :: proc(rec: Rec) {
	area := rec
	id := ui_gen_id_auto()
	ui_update_widget(id, area)
	if ui_ctx.hovered_widget == id {
		update_zoom(&app.preview_zoom, 2, 1, 100)
	}
	if ui_ctx.active_widget == id {
		app.preview_rotation -= rl.GetMouseDelta().x 
	}
	else if app.auto_rotate_preview {
		app.preview_rotation -= app.preview_rotation_speed * rl.GetFrameTime()
	}
	ui_push_command(UI_Draw_Preview {
		rec = area,
		rotation = app.preview_rotation,
		zoom = app.preview_zoom,
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
	if ui_button(ui_gen_id_auto(), "\uf992", settings_rec, false) {
		ui_open_popup("Preview settings")
	}
	ui_ctx.font_size = prev_font_size
	ui_ctx.widget_color = prev_widget_color
}

new_file_popup :: proc() {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }

	popup_rec := rec_center_in_area({ 0, 0, 400, 150 }, screen_rec)
	if open, rec := ui_begin_popup_with_header("New file", ui_gen_id_auto(), popup_rec); open {
		area := rec_pad(rec, 16)
		ui_slider_i32(ui_gen_id_auto(), "Width", &app.width, 2, 30, rec_cut_from_top(&area, ui_ctx.default_widget_height))
		rec_delete_from_top(&area, 8)
		ui_slider_i32(ui_gen_id_auto(), "Height", &app.height, 2, 30, rec_cut_from_top(&area, ui_ctx.default_widget_height))
		rec_delete_from_top(&area, 8)
		if ui_button(ui_gen_id_auto(), "create", area) {
			close_project()

			project: Project
			init_project(&project, app.width, app.height)
			open_project(&project)
			ui_close_current_popup()
			ui_show_notif("\uf62b Project is created")
		}	
	}
	ui_end_popup()
}

preview_settings_popup :: proc() {
	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
	popup_area := rec_center_in_area({ 0, 0, 300, 200 }, screen_rec)
	if open, rec := ui_begin_popup_with_header("Preview settings", ui_gen_id_auto(), popup_area); open {
		area := rec_pad(rec, 16)
		auto_rotate_rec := rec_cut_from_top(&area, ui_ctx.default_widget_height)
		ui_check_box(ui_gen_id_auto(),"Auto rotate", &app.auto_rotate_preview, auto_rotate_rec)
		rec_delete_from_top(&area, 8)
		ui_slider_f32(ui_gen_id_auto(), "Rotation speed", &app.preview_rotation_speed, 5, 30, rec_cut_from_top(&area, ui_ctx.default_widget_height))
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
	project.width = width
	project.height = height
	project.layers = make([dynamic]Layer)
	project.current_color = { 10, 10, 10, 255 }
	
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
			layer.undos = make([dynamic]rl.Image)
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
	app.image_changed = true
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
}

close_project :: proc() {
	deinit_project(&app.project)
	rl.UnloadTexture(app.bg_texture)
}

init_layer :: proc(layer: ^Layer, width, height: i32) {
	image := rl.GenImageColor(width, height, rl.BLANK)
	texture := rl.LoadTextureFromImage(image)
	layer.image = image
	layer.texture = texture
	layer.undos = make([dynamic]rl.Image)	
}

deinit_layer :: proc(layer: ^Layer) {
	rl.UnloadTexture(layer.texture)
	rl.UnloadImage(layer.image)
	for image in layer.undos {
		rl.UnloadImage(image)
	}
	delete(layer.undos)
}

add_layer :: proc(layer: ^Layer, index: int) {
	inject_at_elem(&app.project.layers, index, layer^)
}

add_layer_on_top :: proc(layer: ^Layer) {
	add_layer(layer, len(app.project.layers))
	app.project.current_layer = len(app.project.layers) - 1
}

add_layer_above_current :: proc(layer: ^Layer) {
	add_layer(layer, app.project.current_layer + 1)
	app.project.current_layer += 1
}

get_current_layer :: proc(loc := #caller_location) -> (layer: ^Layer) {
	// fmt.printfln("{}", loc.line)
	return &app.project.layers[app.project.current_layer]
}

update_zoom :: proc(current_zoom: ^f32, strength: f32, min: f32, max: f32) {
	zoom := current_zoom^ + rl.GetMouseWheelMove() * strength
	zoom = math.clamp(zoom, min, max)
	current_zoom^ = zoom
}

// TODO: add parameter to set the origin, current it's centered horizontaly and verticaly
draw_sprite_stack :: proc(layers: ^[dynamic]Layer, x, y: f32, scale: f32, rotation: f32) {
	spacing := f32(1) * scale
	yy := y + f32(len(layers^) - 1) * spacing / 2
	for layer in layers {
		layer_width := f32(layer.image.width)
		layer_height := f32(layer.image.height)
		source_rec := Rec { 0, 0, layer_width, layer_height }
		dest_rec := Rec { x, yy, layer_width * scale, layer_height * scale }
		origin := rl.Vector2 { layer_width * scale / 2, layer_height * scale / 2 }
		rl.DrawTexturePro(layer.texture, source_rec, dest_rec, origin, rotation, rl.WHITE)
		yy -= spacing
	}
}

update_tools :: proc(area: Rec) {
	// pencil
	if ui_is_mouse_in_rec(area) {
		if rl.IsMouseButtonDown(.LEFT) {
			begin_undo()
			x, y := get_mouse_pos_in_canvas(area)
			rl.ImageDrawPixel(&get_current_layer().image, x, y, app.project.current_color)
			app.image_changed = true
		}	
	}
	if rl.IsMouseButtonReleased(.LEFT) {
		end_undo()
	}
	// eraser
	if ui_is_mouse_in_rec(area) {
		if rl.IsMouseButtonDown(.RIGHT) {
			begin_undo()
			x, y := get_mouse_pos_in_canvas(area)
			rl.ImageDrawPixel(&get_current_layer().image, x, y, rl.BLANK)
			app.image_changed = true
		}
	}
	if rl.IsMouseButtonReleased(.RIGHT) {
		end_undo()
	}
	// fill
	if ui_is_mouse_in_rec(area) {
		if rl.IsMouseButtonPressed(.MIDDLE) {
			x, y := get_mouse_pos_in_canvas(area)
			append(&get_current_layer().undos, rl.ImageCopy(get_current_layer().image))
			fill(&get_current_layer().image, x, y, app.project.current_color)
			app.image_changed = true
		}
	}
	// undo
	if rl.IsKeyPressed(.Z) {
		undos := &get_current_layer().undos
		if len(undos) > 0 {
			image := rl.ImageCopy(undos[len(undos) - 1])
			get_current_layer().image = image
			rl.UnloadImage(undos[len(undos) - 1])
			pop(undos)
			app.image_changed = true
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

begin_undo :: proc() {
	_, temp_undo_exists := app.temp_undo_image.?
	if temp_undo_exists == false {
		app.temp_undo_image = rl.ImageCopy(get_current_layer().image)
	}
}

end_undo :: proc() {
	temp_undo_image, exists := app.temp_undo_image.?
	if exists {
		image := rl.ImageCopy(temp_undo_image)
		append(&get_current_layer().undos, image)
		rl.UnloadImage(temp_undo_image)
		app.temp_undo_image = nil
	}
}