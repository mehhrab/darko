package main

import "core:fmt"
import rl "vendor:raylib"
import sa "core:container/small_array"
import "core:mem"
import "rec"
import "ui"

// for ease of use
Rec :: rec.Rec

App :: struct {
	project: Project,
	temp_undo_image: rl.Image,
	undos: [dynamic]rl.Image,
	image_changed: bool,
	bg_texture: rl.Texture,
}

Project :: struct {
	zoom: f32,
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
	rl.InitWindow(600, 500, "hello")
	rl.SetTargetFPS(30)

	init_app()
	defer deinit_app()

	project: Project
	init_project(&project, 8, 8)
	app.project = project

	ui.init()
	defer ui.deinit()
	
	{
		layer: Layer
		init_layer(&layer)
		add_layer(&layer, 0)
	}

	for rl.WindowShouldClose() == false {
		// ui
		// ui.begin()
		// if ui.button(1, "click", { 10, 200, 100, 50 }) {
		// 	layer: Layer
		// 	init_layer(&layer)
		// 	add_layer_on_top(&layer)
		// }
		// ui.end()

		// update
		update_zoom(&app.project.zoom)
		canvas_rec := center_rec(
			{ 0, 0, 100 * app.project.zoom, 100 *  app.project.zoom },
			{ 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())})

		// if rl.CheckCollisionPointRec(rl.GetMousePosition(), canvas_rec) {
			update_tools(canvas_rec)
		// }
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
		if app.image_changed == true {
			// rl.UnloadTexture(get_current_layer().texture)
			// get_current_layer().texture = rl.LoadTextureFromImage(get_current_layer().image)
			colors := rl.LoadImageColors(get_current_layer().image)
			rl.UpdateTexture(get_current_layer().texture, colors)
			rl.UnloadImageColors(colors)
			app.image_changed = false
		}

		// draw
		rl.BeginDrawing()
		rl.ClearBackground(rl.DARKGRAY)
		rl.DrawFPS(10, 10)

		draw_canvas(canvas_rec)
		draw_grid(canvas_rec)

		preview_rec := Rec { 50, 50, 200, 200 }
		rl.DrawRectangleRec(preview_rec, rl.DARKBLUE)
		x, y := rec.get_center_of_rec(preview_rec)
		draw_sprite_stack(&app.project.layers, x, y, 10)

		ui.draw()
		rl.EndDrawing()
	}
	rl.CloseWindow()
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
	
	//TODO: move some of this outta here
	app.image_changed = true
	bg_image := rl.GenImageChecked(width, height, 1, 1, rl.GRAY, rl.WHITE)
	defer rl.UnloadImage(bg_image)
	app.bg_texture = rl.LoadTextureFromImage(bg_image)
}

deinit_project :: proc(project: ^Project) {
	for image in app.undos {
		rl.UnloadImage(image)
	}
	delete(app.undos)
	rl.UnloadTexture(app.bg_texture)
	for &layer in project.layers {
		deinit_layer(&layer)
	}
	delete(project.layers)
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
	zoom := current_zoom^ + rl.GetMouseWheelMove() * 0.1
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
	if rl.IsMouseButtonDown(.LEFT) {
		if app.temp_undo_image == {} {
			fmt.println("image empty")
			app.temp_undo_image = rl.ImageCopy(get_current_layer().image)
		}
		x, y := get_mouse_pos_in_canvas(area)
		rl.ImageDrawPixel(&get_current_layer().image, x, y, rl.BLUE)
		app.image_changed = true
	}
	else if rl.IsMouseButtonDown(.RIGHT) {
		x, y := get_mouse_pos_in_canvas(area)
		rl.ImageDrawPixel(&get_current_layer().image, x, y, rl.BLANK)
		app.image_changed = true
	}
	else if rl.IsMouseButtonPressed(.MIDDLE) {
		x, y := get_mouse_pos_in_canvas(area)
		
		current_color := rl.GetImageColor(get_current_layer().image, x, y)
		color := rl.BLACK
		if current_color == color {
			return
		}
		
		append(&app.undos, rl.ImageCopy(get_current_layer().image))
		fill(&get_current_layer().image, x, y, color)
		app.image_changed = true
	}
	if rl.IsMouseButtonReleased(.LEFT) {
		image := rl.ImageCopy(app.temp_undo_image)
		append(&app.undos, image)
		rl.UnloadImage(app.temp_undo_image)
		app.temp_undo_image = {}
		fmt.printfln("len {}", len(app.undos))
		app.image_changed = true
	}
	if rl.IsKeyPressed(.Z) {
		if len(app.undos) > 0 {
			//rl.UnloadImage(app.project.layers[app.project.current_layer].image)
			image := rl.ImageCopy(app.undos[len(app.undos) - 1])
			fmt.printfln("{}", rl.GetImageColor(image, 0, 0))
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

// NOTE: rec x and y is not used
center_rec :: proc(rec: Rec, area: Rec) -> (centered_rec: Rec) {
	x := area.width / 2 - rec.width / 2
	y := area.height / 2 - rec.height / 2
	return { x, y, rec.width, rec.height }
}
