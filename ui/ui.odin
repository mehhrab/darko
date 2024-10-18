package ui

import "../rec"
import rl "vendor:raylib"
import "core:slice"

// for ease of use
Rec :: rec.Rec

Ctx :: struct {
	hovered_id: ID,
    	active_id: ID,
    	current_container: Container,
    	containers: [dynamic]Container,
}

ID :: u32

Container :: struct {
	id: ID,
	rec: Rec,
	zindex: int,
	draw_commands: [dynamic]Draw_Command,
}

Draw_Command :: struct {
	kind: Draw_Command_Kind, 
}

Draw_Command_Kind :: union {
	Draw_Rect,
	Draw_Text,
	Jump_Command,
}

Jump_Command :: struct {
	index: int,
}

Draw_Rect :: struct {
	rec: Rec,
	color: rl.Color,
}

Draw_Text :: struct {
	
}

ctx: Ctx

init :: proc() {
	
}

deinit :: proc() {
	for container in ctx.containers {
		delete(container.draw_commands)
	}
	delete(ctx.containers)
}

begin :: proc() {
	begin_container(1000, { 0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) })
}

end :: proc() {
	end_container()
	
	if rl.IsMouseButtonReleased(.LEFT) {
		ctx.active_id = 0
	}
}

draw :: proc() {
	sorted := ctx.containers[:]
	slice.sort_by(sorted, proc(c1, c2: Container) -> bool { return c1.zindex < 0 }) 
	for container in sorted {
		for command in container.draw_commands {
			switch kind in command.kind {
				case Draw_Rect: {
					rl.DrawRectangleRec(kind.rec, kind.color)
				}
				case Draw_Text: {
				
				}
				case Jump_Command: {
				
				}
			}
		}
		
	}
	for &container in ctx.containers {
		clear(&container.draw_commands)
	}
	clear(&ctx.containers)
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

begin_container :: proc(id: ID, rec: Rec) {
	container := Container {}
	container.draw_commands = make([dynamic]Draw_Command)
	append(&ctx.containers, container)
}

end_container :: proc() {
	container := ctx.containers[len(ctx.containers) - 1]
	ctx.containers[len(ctx.containers) - 1] = container
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
	append(&ctx.containers[len(ctx.containers) - 1].draw_commands, command)
}

is_mouse_in_rec :: proc(rec: Rec) -> (is_inside: bool) {
	mpos := rl.GetMousePosition()
	return mpos.x > rec.x && mpos.y > rec.y && mpos.x < rec.x + rec.width && mpos.y < rec.y + rec.height
}
