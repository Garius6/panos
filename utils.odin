package main

import "core:unicode/utf8"

get_character_at :: proc(s: string, target_index: int) -> (string, bool) {
	current_index := 0

	// r - сама руна, byte_offset - ее стартовый байт в строке
	for r, byte_offset in s {
		if current_index == target_index {
			// Узнаем, сколько байт занимает эта руна (от 1 до 4)
			r_size := utf8.rune_size(r)

			// Возвращаем срез оригинальной строки
			return s[byte_offset:byte_offset + r_size], true
		}
		current_index += 1
	}
	return "", false // Если индекс вышел за пределы
}
