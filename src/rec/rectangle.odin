package rec
import rl "vendor:raylib"

// Rec :: struct {
// 	x, y: f32,
// 	width, height: f32,
// }

Rec :: rl.Rectangle

get_center_of_rec :: proc(rec: Rec) -> (x, y: f32) {
	return rec.x + rec.width / 2, rec.y + rec.height / 2
}

pad :: proc(rec: Rec, padding: f32) -> (res: Rec) {
	rec := rec
	rec.x += padding
	rec.y += padding
	rec.width -= padding * 2
	rec.height -= padding * 2
	return rec
}
