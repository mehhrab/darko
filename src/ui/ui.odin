package ui

import "../rec"
import rl "vendor:raylib"
import "core:slice"
import "core:strings"
import "core:fmt"

// for ease of use
Rec :: rec.Rec

Ctx :: struct {
	hovered_id: ID,
	active_id: ID,
	draw_commands: [dynamic]Draw_Command,
	// HACK: we can only have on popup
	opened_popup: string,
	current_popup: string,
	popup: Popup,
	popup_time: f32,
	any_hovered: bool,
}

ID :: u32

Popup :: struct {
	name: string,
	rec: Rec,
	draw_commands: [dynamic]Draw_Command,
}

Draw_Command :: union {
	Draw_Rect,
	Draw_Text,
}

Draw_Rect :: struct {
	rec: Rec,
	color: rl.Color,
}

Draw_Text :: struct {
	text: string,
	rec: Rec,
}

ctx: Ctx

init :: proc() {
	ctx.draw_commands = make([dynamic]Draw_Command)
}

deinit :: proc() {
	delete(ctx.draw_commands)
	delete(ctx.popup.draw_commands)
}

begin :: proc() {
	if ctx.opened_popup != "" && rl.IsMouseButtonReleased(.LEFT) && is_mouse_in_rec(ctx.popup.rec) == false {
		ctx.opened_popup = ""
		fmt.println("closing")
	}
	if ctx.opened_popup != "" {
		ctx.popup_time += rl.GetFrameTime()
	}
}

end :: proc() {
	if rl.IsMouseButtonReleased(.LEFT) {
		ctx.active_id = 0
	}
	ctx.any_hovered = false
}

gen_id_auto :: proc(loc := #caller_location) -> ID {
	return ID(loc.line)
}

draw :: proc() {
	for &command in ctx.draw_commands {
		draw_command(&command)
	}

	if ctx.opened_popup != "" {
		screen_rec := Rec { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
		opacity := ctx.popup_time * 100 * 5
		if opacity >= 100 {
			opacity = 100
		}
		rl.DrawRectangleRec(screen_rec, { 0, 0, 0, u8((opacity / 255) * 255) })
		for &command in ctx.popup.draw_commands {
			draw_command(&command)
		}
	}
	
	clear(&ctx.draw_commands)
	clear(&ctx.popup.draw_commands)
	free_all(context.temp_allocator)
}

draw_command :: proc(command: ^Draw_Command) {
	switch kind in command^ {
		case Draw_Rect: {
			rl.DrawRectangleRec(kind.rec, kind.color)
		}
		case Draw_Text: {
			font_size := i32(24)
			text := strings.clone_to_cstring(kind.text, context.temp_allocator)
			_x, _y := rec.get_center_of_rec(kind.rec)
			x := i32(_x)
			y := i32(_y)
			x -= rl.MeasureText(text, font_size) / 2
			y -= font_size / 2
			rl.DrawText(text, x, y, font_size, rl.WHITE)
		}
	}
}

open_popup :: proc(name: string) {
	ctx.hovered_id = 0
	ctx.active_id = 0
	ctx.opened_popup = name
	ctx.popup_time = 0
}

close_current_popup :: proc() {
	ctx.opened_popup = ""
	ctx.popup.rec = {}
}

// NOTE: name is also used as the id
begin_popup :: proc(name: string, rec: Rec) -> (is_open: bool) {
	if is_mouse_in_rec(rec) {
		ctx.any_hovered = true
	}
	ctx.current_popup = name
	ctx.popup.rec = rec
	 
	// if ctx.opened_popup == name
	return name == ctx.opened_popup
}

end_popup :: proc() {
	inject_at(&ctx.popup.draw_commands, 0, Draw_Rect {
		color = rl.BLACK,
		rec = ctx.popup.rec,
	})
	ctx.current_popup = ""
}

update_widget :: proc(id: ID, rec: Rec) {
	if ctx.opened_popup != ctx.current_popup && ctx.opened_popup != "" {
		return
	}
	hovered := is_mouse_in_rec(rec)
	if hovered {
		ctx.any_hovered = true
	}
	if hovered && (ctx.active_id == 0 || ctx.active_id == id) {
		ctx.hovered_id = id
		if rl.IsMouseButtonPressed(.LEFT) {
			ctx.active_id = id
		}
	}
	else if ctx.hovered_id == id {
		ctx.hovered_id = 0
	}
}


button :: proc(id: ID, text: string, rec: Rec) -> (clicked: bool) {	
	update_widget(id, rec)
	if ctx.hovered_id == id && rl.IsMouseButtonReleased(.LEFT){
		clicked = true
	}
	color := rl.GREEN
	if ctx.active_id == id {
		color = rl.BLUE
	}
	else if ctx.hovered_id == id {
		color = rl.BLACK
	}
	push_command(Draw_Rect {
			rec = rec,
			color = color
	})
	push_command(Draw_Text {
			rec = rec,
			text = text,
	})
	return
}

push_command :: proc(command: Draw_Command) {
	// if ctx.current_popup != "" && ctx.opened_popup == "" {
	// 	return
	// }
	// if ctx.opened_popup != "" {}
	if ctx.current_popup != "" {
		append(&ctx.popup.draw_commands, command)
	}
	else {
		append(&ctx.draw_commands, command)
	}
}

is_mouse_in_rec :: proc(rec: Rec) -> (is_inside: bool) {
	mpos := rl.GetMousePosition()
	return mpos.x > rec.x && mpos.y > rec.y && mpos.x < rec.x + rec.width && mpos.y < rec.y + rec.height
}
