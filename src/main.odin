package darko

import "core:fmt"
import rl "vendor:raylib"
import sa "core:container/small_array"
import "core:mem"
import "core:math"

LOCK_FPS :: #config(LOCK_FPS, true)

App :: struct {
	width: i32, height: i32,
	project: Project,
	temp_undo_image: Maybe(rl.Image),
	undos: [dynamic]rl.Image,
	image_changed: bool,
	bg_texture: rl.Texture,
	lerped_zoom: f32,
}

Project :: struct {
	zoom: f32,
	current_color: rl.Color,
	width, height: i32,
	current_layer: int,
	layers: [dynamic]Layer,
}

Layer :: struct {
	image: rl.Image,
	texture: rl.Texture,
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
	rl.InitWindow(1200, 700, "hello")
	when LOCK_FPS {
		rl.SetTargetFPS(60)
	}

	ui_init_ctx()
	defer ui_deinit_ctx()
	
	init_app()
	defer deinit_app()

	project: Project
	init_project(&project, 8, 8)
	open_project(&project)
	
	{
		layer: Layer
		init_layer(&layer)
		add_layer(&layer, 0)
	}

	for rl.WindowShouldClose() == false {
		// ui
		gui()

		// update
		if rl.IsKeyPressed(.SPACE) {
			layer: Layer
			init_layer(&layer)
			add_layer_above_current(&layer)
		}
		if rl.IsKeyPressed(.S) {
			layer: Layer
			init_layer(&layer)
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
		rl.ClearBackground({ 24, 25, 38, 255 })

		ui_draw()
		
		rl.DrawFPS(rl.GetScreenWidth() - 80, 10)
		rl.EndDrawing()
	}
	rl.CloseWindow()
}

gui :: proc() {
	if rl.IsKeyPressed(.B) {
		ui_open_popup("Open file")
	}
	ui_begin()

	screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
	menu_bar_area := rec_cut_from_top(&screen_rec, 40)
	menu_bar(menu_bar_area)

	screen_area := screen_rec
	panel_width := screen_area.width / 3

	left_panel_area := rec_cut_from_left(&screen_area, panel_width)
	middle_panel_area := rec_cut_from_left(&screen_area, panel_width)
	right_panel_area := rec_cut_from_left(&screen_area, panel_width)

	app.lerped_zoom = rl.Lerp(app.lerped_zoom, app.project.zoom, 20 * rl.GetFrameTime())
	// work around for lerp never (taking too long) reaching it's desteniton 
	if math.abs(app.project.zoom - app.lerped_zoom) < 0.01 {
		app.lerped_zoom = app.project.zoom
	}

	canvas_rec := rec_center_in_area(
		{ 0, 0, f32(app.project.width) * 10 * app.lerped_zoom, f32(app.project.height) * 10 *  app.lerped_zoom },
		middle_panel_area)
	
	if ui_is_being_interacted() == false {
		update_zoom(&app.project.zoom)
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
		thickness = 2
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
	ui_panel(ui_gen_id_auto(), left_panel_area)
	preview_rec := Rec { left_panel_area.x + 10, left_panel_area.y + 10, 200, 200 }
	ui_push_command(UI_Draw_Preview {
		rec = preview_rec,
	})
	
	color_panel(right_panel_area)
	
	// popups
	popup_rec := rec_center_in_area({ 0, 0, 400, 160 }, screen_rec)
	if open, rec := ui_begin_popup_with_header("New file", ui_gen_id_auto(), popup_rec); open {
		area := rec_pad(rec, 10)
		ui_slider_i32(ui_gen_id_auto(), &app.width, 2, 30, rec_cut_from_top(&area, 40))
		rec_delete_from_top(&area, 10)
		ui_slider_i32(ui_gen_id_auto(), &app.height, 2, 30, rec_cut_from_top(&area, 40))
		rec_delete_from_top(&area, 10)
		if ui_button(ui_gen_id_auto(), "create", area) {
			close_project()
			project: Project
			init_project(&project, app.width, app.height)
			open_project(&project)

			layer: Layer
			init_layer(&layer)
			add_layer(&layer, 0)

			ui_close_current_popup()
			ui_show_notif("\uf62b Project is created")
		}	
	}
	ui_end_popup()
	if open, rec := ui_begin_popup_with_header("Open file", ui_gen_id_auto(), popup_rec); open {
		ui_slider_i32(ui_gen_id_auto(), &app.width, 2, 30, { rec.x + 10, rec.y + 10, rec.width - 20, 40 })
		ui_slider_i32(ui_gen_id_auto(), &app.height, 2, 30, { rec.x + 10, rec.y + 50, rec.width - 20, 40 })
		if ui_button(ui_gen_id_auto(), "yah", { rec.x + 10, rec.y + 100, rec.width - 20, 40 }) {
			ui_show_notif("project is created")
		}	
	}
	ui_end_popup()
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
			"new file",
			"",
		},
		UI_Menu_Item { 
			ui_gen_id_auto(),
			"open file",
			"",
		},
		UI_Menu_Item { 
			ui_gen_id_auto(),
			"close file",
			"",
		},
	}
	menu_items_slice := menu_items[:]
	clicked_item := ui_menu_button(ui_gen_id_auto(), "File", &menu_items_slice, 300, { area.x, area.y, 60, area.height })
	if clicked_item.text == "new file" {
		ui_open_popup("New file")
	}
	else if clicked_item.text == "close file" {
		rl.CloseWindow()
	}
}

color_panel :: proc(area: Rec) {
	ui_panel(ui_gen_id_auto(), area)
	
	area := rec_pad(area, 10)
	preview_area := rec_cut_from_top(&area, 200)
	ui_push_command(UI_Draw_Rect {
		color = app.project.current_color,
		rec = preview_area,
	})
	ui_push_command(UI_Draw_Rect_Outline {
		color = ui_ctx.border_color,
		rec = preview_area,
		thickness = 2,
	})
	rec_delete_from_top(&area, 10)

	@(static)
	hsv_color := [3]f32 { 0, 0, 0 }

	changed1 := ui_slider_f32(ui_gen_id_auto(), &hsv_color[0], 0, 360, rec_cut_from_top(&area, 40))
	rec_delete_from_top(&area, 10)

	changed2 := ui_slider_f32(ui_gen_id_auto(), &hsv_color[1], 0, 1, rec_cut_from_top(&area, 40))
	rec_delete_from_top(&area, 10)
	
	changed3 := ui_slider_f32(ui_gen_id_auto(), &hsv_color[2], 0, 1, rec_cut_from_top(&area, 40))

	if changed1 || changed2 || changed3  {
		app.project.current_color = rl.ColorFromHSV(hsv_color[0], hsv_color[1], hsv_color[2])
	}
}

init_app :: proc() {
	
}

deinit_app :: proc() {
	close_project()
}

init_project :: proc(project: ^Project, width, height: i32) {
	project.zoom = 1
	project.width = width
	project.height = height
	project.layers = make([dynamic]Layer)
	project.current_color = { 10, 10, 10, 255 }
}

deinit_project :: proc(project: ^Project) {
	for &layer in project.layers {
		deinit_layer(&layer)
	}
	delete(project.layers)
}

open_project :: proc(project: ^Project) {
	app.project = project^

	app.undos = make([dynamic]rl.Image)	
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
}

close_project :: proc() {
	deinit_project(&app.project)

	for image in app.undos {
		rl.UnloadImage(image)
	}
	delete(app.undos)
	rl.UnloadTexture(app.bg_texture)
}

init_layer :: proc(layer: ^Layer) {
	image := rl.GenImageColor(app.project.width, app.project.height, rl.BLANK)
	texture := rl.LoadTextureFromImage(image)
	layer.image = image
	layer.texture = texture
}

deinit_layer :: proc(layer: ^Layer) {
	rl.UnloadTexture(layer.texture)
	rl.UnloadImage(layer.image)
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

get_current_layer :: proc() -> (layer: ^Layer) {
	return &app.project.layers[app.project.current_layer]
}

update_zoom :: proc(current_zoom: ^f32) {
	zoom := current_zoom^ + rl.GetMouseWheelMove() * 0.3
	if zoom < 0.1 {
		zoom = 0.1
	}
	current_zoom^ = zoom
}

// TODO: add parameter to set the origin, current it's centered horizontaly and verticaly
draw_sprite_stack :: proc(layers: ^[dynamic]Layer, x, y: f32, scale: f32) {
	spacing := f32(10)
	yy := y + f32(len(layers^) - 1) * spacing / 2
	@(static)
	rotation := f32(0)
	rotation += 5 * rl.GetFrameTime()
	for layer in layers {
		layer_width := f32(layer.image.width)
		layer_height := f32(layer.image.height)
		source_rec := Rec { 0, 0, layer_width, layer_height }
		dest_rec := Rec {
			x,
			yy,
			layer_width * scale,
			layer_height * scale
		}
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
			
			append(&app.undos, rl.ImageCopy(get_current_layer().image))
			fill(&get_current_layer().image, x, y, app.project.current_color)
			app.image_changed = true
		}
	}
	// undo
	if rl.IsKeyPressed(.Z) {
		if len(app.undos) > 0 {
			image := rl.ImageCopy(app.undos[len(app.undos) - 1])
			app.project.layers[app.project.current_layer].image = image
			rl.UnloadImage(app.undos[len(app.undos) - 1])
			pop(&app.undos)
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
		append(&app.undos, image)
		rl.UnloadImage(temp_undo_image)
		app.temp_undo_image = nil
	}
}