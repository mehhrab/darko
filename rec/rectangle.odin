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
