package core

import "core:strings"
import "core:unicode/utf8"

// Срез строки [start, end) по индексам РУН (не байт) — согласовано с
// get_character_at/string_length, которые тоже считают руны, а не байты
// (кириллица и т.п. многобайтовые). Panos не имеет `[a:b]`-синтаксиса —
// строки.срез (см. call_builtin) заменяет его builtin-вызовом вместо
// добавления Slice_Expr в парсер/резолвер/тайпчекер/компилятор/vm.
string_slice_by_rune :: proc(s: string, start: int, end: int) -> (string, bool) {
	if start < 0 || end < start do return "", false

	start_byte := -1
	end_byte := len(s) // по умолчанию — "до конца строки" (end == кол-во рун)
	idx := 0
	for r, offset in s {
		if idx == start do start_byte = offset
		if idx == end do end_byte = offset
		idx += 1
	}
	if end > idx do return "", false // end дальше, чем реально есть рун
	if start_byte == -1 {
		if start == idx {
			start_byte = len(s) // срез "с самого конца" — пустой результат
		} else {
			return "", false
		}
	}
	return s[start_byte:end_byte], true
}

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

// Ищет первое вхождение pattern в text начиная с РУН-индекса from_rune
// (не байт — согласовано со string_slice_by_rune/get_character_at выше),
// возвращает РУН-индекс совпадения или -1. Используется строки::найти.
string_find_rune :: proc(text: string, pattern: string, from_rune: int) -> int {
	total := string_length(text)
	if from_rune < 0 || from_rune > total do return -1

	start_byte := len(text)
	idx := 0
	for _, offset in text {
		if idx == from_rune {
			start_byte = offset
			break
		}
		idx += 1
	}

	byte_match := strings.index(text[start_byte:], pattern)
	if byte_match == -1 do return -1

	match_byte_abs := start_byte + byte_match
	rune_idx := 0
	for _, offset in text {
		if offset == match_byte_abs do return rune_idx
		rune_idx += 1
	}
	return -1 // не должно случиться — byte_match всегда указывает на начало руны
}
