package main

import "core:fmt"
import rl "vendor:raylib"
import sa "core:container/small_array"
import "core:mem"
import "rec"
import "ui"

LOCK_FPS :: #config(LOCK_FPS, true)

// for ease of use
Rec :: rec.Rec

App :: struct {
	width: i32,
	height: i32,
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
	// undos: [dynamic]rl.Image,
	// redos: [dynamic]rl.Image,
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

	init_app()
	defer deinit_app()

	project: Project
	init_project(&project, 8, 8)
	open_project(&project)
	defer close_project()

	ui.init()
	defer ui.deinit()
	
	{
		layer: Layer
		init_layer(&layer)
		add_layer(&layer, 0)
	}

	for rl.WindowShouldClose() == false {
		// ui
		gui()

		// update
		app.lerped_zoom = rl.Lerp(app.lerped_zoom, app.project.zoom, 0.3) 
		if ui.is_being_interacted() == false {
			update_zoom(&app.project.zoom)
		}
		
		canvas_rec := center_rec(
			{ 0, 0, f32(app.project.width) * 10 * app.lerped_zoom, f32(app.project.height) * 10 *  app.lerped_zoom },
			{ 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())})

		if ui.is_being_interacted() == false {
			update_tools(canvas_rec)
		}
		
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
		rl.ClearBackground(rl.DARKGRAY)

		draw_canvas(canvas_rec)
		draw_grid(canvas_rec)

		ui.draw()
		
		preview_rec := Rec { 50, 50, 200, 200 }
		rl.DrawRectangleRec(preview_rec, rl.DARKBLUE)
		x, y := rec.get_center_of_rec(preview_rec)
		draw_sprite_stack(&app.project.layers, x, y, 10)
		
		rl.DrawFPS(10, 10)
		rl.EndDrawing()
	}
	rl.CloseWindow()
}

gui :: proc() {
	ui.begin()

	menu_bar_area := Rec { 0, 0, f32(rl.GetScreenWidth()), 50 }
	menu_bar(menu_bar_area)

	screen_area := Rec { 0, menu_bar_area.height, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}

	left_panel_area := Rec { screen_area.x, screen_area.y, 400, 1000 }
	ui.panel(ui.gen_id_auto(), left_panel_area)
	
	right_panel_area := Rec { screen_area.width - 300, screen_area.y, 300, screen_area.height }
	color_panel(right_panel_area)
	
	// popups
	popup_rec := center_rec({ 0, 0, 400, 300 }, screen_area)
	if ui.begin_popup("new", popup_rec) {
		ui.slider_i32(ui.gen_id_auto(), &app.width, 2, 30, { popup_rec.x + 10, popup_rec.y + 10, 300, 40 })
		ui.slider_i32(ui.gen_id_auto(), &app.height, 2, 30, { popup_rec.x + 10, popup_rec.y + 50, 300, 40 })
		if ui.button(ui.gen_id_auto(), "new", { popup_rec.x + 10, popup_rec.y + 100, 100, 40 }) {
			close_project()
			project: Project
			init_project(&project, app.width, app.height)
			open_project(&project)

			layer: Layer
			init_layer(&layer)
			add_layer(&layer, 0)
		}	
	}
	ui.end_popup()
	ui.end()
}

menu_bar :: proc(area: Rec) {
	ui.panel(ui.gen_id_auto(), area)
	if ui.button(ui.gen_id_auto(), "file", { area.x, area.y, 60, area.height }) {
		ui.open_popup("new")
	}
}

color_panel :: proc(area: Rec) {
	ui.panel(ui.gen_id_auto(), area)
	
	area := rec.pad(area, 10)

	@(static)
	hsv_color := [3]f32 { 0, 0, 0 }

	slider_rec := Rec { area.x, area.y, area.width, 40 }
	ui.slider_f32(ui.gen_id_auto(), &hsv_color[0], 0, 360, slider_rec)
	slider_rec.y += 50
	ui.slider_f32(ui.gen_id_auto(), &hsv_color[1], 0, 1, slider_rec)
	slider_rec.y += 50
	ui.slider_f32(ui.gen_id_auto(), &hsv_color[2], 0, 1, slider_rec)

	app.project.current_color = rl.ColorFromHSV(hsv_color[0], hsv_color[1], hsv_color[2])
}

init_app :: proc() {
	
}

deinit_app :: proc() {
	deinit_project(&app.project)
}

init_project :: proc(project: ^Project, width, height: i32) {
	app.undos = make([dynamic]rl.Image)
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
	
	app.lerped_zoom = 1
	app.image_changed = true
	bg_image := rl.GenImageChecked(project.width, project.height, 1, 1, rl.GRAY, rl.WHITE)
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
	if ui.is_mouse_in_rec(area) {
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
	if ui.is_mouse_in_rec(area) {
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
	if ui.is_mouse_in_rec(area) {
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
	fmt.printfln("{}", exists)
	if exists {
		image := rl.ImageCopy(temp_undo_image)
		append(&app.undos, image)
		rl.UnloadImage(temp_undo_image)
		app.temp_undo_image = nil
	}
}

// NOTE: rec x and y is not used
center_rec :: proc(rec: Rec, area: Rec) -> (centered_rec: Rec) {
	x := area.width / 2 - rec.width / 2
	y := area.height / 2 - rec.height / 2
	return { x, y, rec.width, rec.height }
}
