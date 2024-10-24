package ui

import "../rec"
import rl "vendor:raylib"
import "core:slice"
import "core:strings"
import "core:fmt"
import "core:math"
// for ease of use
Rec :: rec.Rec

Ctx :: struct {
	hovered_widget: ID,
	active_widget: ID,
	
  // panels sit under widgets and we don't have zindex sooo
  
  hovered_panel: ID,
	active_panel: ID,
  
  draw_commands: [dynamic]Draw_Command,
	
  // HACK: we can only have on popup
	
  opened_popup: string,
	current_popup: string,
	popup: Popup,
	popup_time: f32,

	// style

	font: rl.Font,
	font_size: f32,
	roundness: f32,
  panel_color: rl.Color,
  widget_color: rl.Color,
	widget_hover_color: rl.Color,
	widget_active_color: rl.Color,
	accent_color: rl.Color,
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

	ctx.font = rl.LoadFontEx("../assets/HackNerdFont-Bold.ttf", 32, nil, 0)
	rl.SetTextureFilter(ctx.font.texture, .BILINEAR)
	ctx.font_size = 20
	ctx.widget_color = { 40, 40, 40, 255 }
	ctx.widget_hover_color = { 60, 60, 60, 255 }
	ctx.widget_active_color = { 30, 30, 30, 255 }
	ctx.panel_color = { 10, 10, 10, 100 }
  ctx.accent_color = rl.PURPLE
}

deinit :: proc() {
	rl.UnloadFont(ctx.font)
	delete(ctx.draw_commands)
	delete(ctx.popup.draw_commands)
}

begin :: proc() {
	if ctx.opened_popup != "" && rl.IsMouseButtonReleased(.LEFT) && is_mouse_in_rec(ctx.popup.rec) == false {
		ctx.opened_popup = ""
	}
	if ctx.opened_popup != "" {
		ctx.popup_time += rl.GetFrameTime()
	}
}

end :: proc() {
	if rl.IsMouseButtonReleased(.LEFT) {
		ctx.active_widget = 0
	  ctx.active_panel = 0
  }
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
			text := strings.clone_to_cstring(kind.text, context.temp_allocator)
			x, y := rec.get_center_of_rec(kind.rec)
			text_size := rl.MeasureTextEx(ctx.font, text, ctx.font_size, 0)
			x -= text_size.x / 2
			y -= text_size.y / 2
			rl.DrawTextEx(ctx.font, text, {x, y}, ctx.font_size, 0, rl.WHITE)
		}
	}
}

open_popup :: proc(name: string) {
	ctx.opened_popup = name
	ctx.hovered_widget = 0
	ctx.active_widget = 0
	ctx.popup_time = 0
}

close_current_popup :: proc() {
	ctx.hovered_widget = 0
	ctx.active_widget = 0
	ctx.opened_popup = ""
	ctx.popup.rec = {}
}

// NOTE: name is also used as the id
begin_popup :: proc(name: string, rec: Rec) -> (is_open: bool) {
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
	if hovered && (ctx.active_widget == 0 || ctx.active_widget == id) {
		ctx.hovered_widget = id
		if rl.IsMouseButtonPressed(.LEFT) {
			ctx.active_widget = id
		}
	}
	else if ctx.hovered_widget == id {
		ctx.hovered_widget = 0
	}
}

update_panel :: proc(id: ID, rec: Rec) {
	if ctx.opened_popup != ctx.current_popup && ctx.opened_popup != "" {
		return
	}
	hovered := is_mouse_in_rec(rec)
	if hovered && (ctx.active_panel == 0 || ctx.active_panel == id) {
		ctx.hovered_panel = id
		if rl.IsMouseButtonPressed(.LEFT) {
			ctx.active_panel = id
		}
	}
	else if ctx.hovered_panel == id {
		ctx.hovered_panel = 0
	}
}

panel :: proc(id: ID, rec: Rec) {
  update_panel(id, rec)
  push_command(Draw_Rect {
    rec = rec,
    color = ctx.panel_color,
  })
}

button :: proc(id: ID, text: string, rec: Rec) -> (clicked: bool) {	
	clicked = false
	update_widget(id, rec)
	if ctx.hovered_widget == id && rl.IsMouseButtonReleased(.LEFT){
		clicked = true
	}
	color := ctx.widget_color
	if ctx.active_widget == id {
		color = ctx.widget_active_color
	}
	else if ctx.hovered_widget == id {
		color = ctx.widget_hover_color
	}
	push_command(Draw_Rect {
		rec = rec,
		color = color
	})
	push_command(Draw_Text {
		rec = rec,
		text = text,
	})
	return clicked
}

slider :: proc(id: ID, value: ^f32, min, max: f32, rec: Rec) {
	update_widget(id, rec)
  
	if ctx.active_widget == id && rl.IsMouseButtonDown(.LEFT) {
		value^ = min + (rl.GetMousePosition().x - rec.x) * (max - min) / rec.width
	}

	value^ = math.clamp(value^, min, max)
  
	push_command(Draw_Rect {
		rec = rec,
		color = ctx.widget_color,
	})
	push_command(Draw_Rect {
		rec = { rec.x, rec.y, (value^ - min) * (rec.width) / (max - min), rec.height },
		color = ctx.accent_color,	
	})
  text := fmt.aprintf("%.2f", value^, allocator = context.temp_allocator)
	push_command(Draw_Text {
		rec = rec,
		text = text,
	})
}

push_command :: proc(command: Draw_Command) {
	if ctx.current_popup != "" {
		append(&ctx.popup.draw_commands, command)
	}
	else {
		append(&ctx.draw_commands, command)
	}
}

is_being_interacted :: proc() -> (res: bool) {
	return ctx.hovered_widget != 0 ||
	ctx.active_widget != 0 ||
	ctx.hovered_panel != 0 ||
  ctx.active_panel != 0 ||
  (ctx.opened_popup != "")
}

is_mouse_in_rec :: proc(rec: Rec) -> (is_inside: bool) {
	mpos := rl.GetMousePosition()
	return mpos.x > rec.x && mpos.y > rec.y && mpos.x < rec.x + rec.width && mpos.y < rec.y + rec.height
}
