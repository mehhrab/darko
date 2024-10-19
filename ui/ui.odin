package ui

import "../rec"
import rl "vendor:raylib"
import "core:slice"

// for ease of use
Rec :: rec.Rec

Ctx :: struct {
	hovered_id: ID,
  active_id: ID,
	draw_commands: [dynamic]Draw_Command,
  //HACK: we can only have on popup
  popup: Popup,
}

ID :: u32

Popup :: struct {
	id: ID,
	rec: Rec,
	draw_commands: [dynamic]Draw_Command,
}

Draw_Command :: struct {
	kind: Draw_Command_Kind, 
}

Draw_Command_Kind :: union {
	Draw_Rect,
	Draw_Text,
}

Draw_Rect :: struct {
	rec: Rec,
	color: rl.Color,
}

Draw_Text :: struct {
	
}

ctx: Ctx

init :: proc() {
	ctx.draw_commands = make([dynamic]Draw_Command)
}

deinit :: proc() {
	delete(ctx.draw_commands)
}

begin :: proc() {
}

end :: proc() {
	if rl.IsMouseButtonReleased(.LEFT) {
		ctx.active_id = 0
	}
}

draw :: proc() {
	for command in ctx.draw_commands {
		switch kind in command.kind {
			case Draw_Rect: {
				rl.DrawRectangleRec(kind.rec, kind.color)
			}
			case Draw_Text: {
			
			}
		}
	}
	for command in ctx.popup.draw_commands {
		switch kind in command.kind {
			case Draw_Rect: {
				rl.DrawRectangleRec(kind.rec, kind.color)
			}
			case Draw_Text: {
			
			}
		}
	}
	clear(&ctx.draw_commands)
}

update_widget :: proc(id: ID, rec: Rec) {
	if is_mouse_in_rec(rec) == true && (ctx.active_id == 0 || ctx.active_id == id) {
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
	color := rl.WHITE
	if ctx.active_id == id {
		color = rl.BLUE
	}
	else if ctx.hovered_id == id {
		color = rl.BLACK
	}
	push_draw_command(Draw_Rect {
		rec = rec,
		color = color,
	})
	return
}

push_draw_command :: proc(kind: Draw_Command_Kind) {
	command := Draw_Command {
		kind = kind
	}
	append(&ctx.draw_commands, command)
}

is_mouse_in_rec :: proc(rec: Rec) -> (is_inside: bool) {
	mpos := rl.GetMousePosition()
	return mpos.x > rec.x && mpos.y > rec.y && mpos.x < rec.x + rec.width && mpos.y < rec.y + rec.height
}
