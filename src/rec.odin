/* rectangle helpers library
also used for layout */
package darko
import rl "vendor:raylib"

Rec :: rl.Rectangle

// taken from https://github.com/odin-lang/Odin/blob/master/vendor/microui/microui.odin#L297C1-L305C2
rec_intersect :: proc(rec1, rec2: Rec) -> (res: Rec) {
	x1 := max(rec1.x, rec2.x)
	y1 := max(rec1.y, rec2.y)
	x2 := min(rec1.x + rec1.width, rec2.x + rec2.width)
	y2 := min(rec1.y + rec1.height, rec2.y + rec2.height)
	if x2 < x1 { x2 = x1 }
	if y2 < y1 { y2 = y1 }
	return Rec {x1, y1, x2 - x1, y2 - y1}
}

rec_pad :: proc(rec: Rec, padding: f32) -> (res: Rec) {
	rec := rec
	rec.x += padding
	rec.y += padding
	rec.width -= padding * 2
	rec.height -= padding * 2
	return rec
}

rec_pad_ex :: proc(rec: Rec, left, top, right, bottom: f32) -> (res: Rec) {
	rec := rec
	rec.x += left
	rec.y += top
	rec.width -= right * 2
	rec.height -= bottom * 2
	return rec
}

rec_get_center_point :: proc(rec: Rec) -> (x, y: f32) {
	return rec.x + rec.width / 2, rec.y + rec.height / 2
}

// NOTE: rec x and y is not used
rec_center_in_area :: proc(rec: Rec, area: Rec) -> (centered_rec: Rec) {
	x := area.x + area.width / 2 - rec.width / 2
	y := area.y + area.height / 2 - rec.height / 2
	return { x, y, rec.width, rec.height }
}

rec_extend_top :: proc(rec: ^Rec, amount: f32) -> (res: Rec) {
	res = {
		rec.x,
		rec.y - amount,
		rec.width,
		amount,
	}
	rec.y -= amount
	rec.height += amount
	return res
}

rec_take_right :: proc(rec: ^Rec, amount: f32) -> (res: Rec) {
	return {
		rec.x + rec.width - amount,
		rec.y,
		amount,
		rec.height,
	}
}

rec_delete_top :: proc(rec: ^Rec, amount: f32) {
	rec.y += amount
	rec.height -= amount
}

rec_cut_top :: proc(rec: ^Rec, amount: f32) -> (res: Rec) {
	res = {
		rec.x,
		rec.y,
		rec.width,
		amount,
	}
	rec.y += amount
	rec.height -= amount
	return res
}

rec_cut_bottom :: proc(rec: ^Rec, amount: f32) -> (res: Rec) {
	res = {
		rec.x,
		rec.y + rec.height - amount,
		rec.width,
		amount,
	}
	// rec.y += amount
	rec.height -= amount
	return res
}

rec_cut_left :: proc(rec: ^Rec, amount: f32) -> (res: Rec) {
	res = {
		rec.x,
		rec.y,
		amount,
		rec.height,
	}
	rec.x += amount
	rec.width -= amount
	return res
}

rec_cut_right :: proc(rec: ^Rec, amount: f32) -> (res: Rec) {
	res = {
		rec.x + rec.width - amount,
		rec.y,
		amount,
		rec.height,
	}
	rec.width -= amount
	return res
}