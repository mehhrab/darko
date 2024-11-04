package darko
import rl "vendor:raylib"

// Rec :: struct {
// 	x, y: f32,
// 	width, height: f32,
// }

Rec :: rl.Rectangle

rec_get_center_point :: proc(rec: Rec) -> (x, y: f32) {
	return rec.x + rec.width / 2, rec.y + rec.height / 2
}

rec_pad :: proc(rec: Rec, padding: f32) -> (res: Rec) {
	rec := rec
	rec.x += padding
	rec.y += padding
	rec.width -= padding * 2
	rec.height -= padding * 2
	return rec
}

// NOTE: rec x and y is not used
rec_center_in_area :: proc(rec: Rec, area: Rec) -> (centered_rec: Rec) {
	x := area.x + area.width / 2 - rec.width / 2
	y := area.y + area.height / 2 - rec.height / 2
	return { x, y, rec.width, rec.height }
}