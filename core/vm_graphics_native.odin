#+build !js
package core

import "core:fmt"
import rl "vendor:raylib"

// Стадия 4 (FFI-A): графика::* — статические Odin-биндинги поверх
// vendor:raylib (не своя `foreign import`-обвязка — Odin's toolchain уже
// даёт полный готовый биндинг, подтверждено вживую: линкуется чисто
// против системного raylib, поставленного через brew). Точный прецедент
// call_builtin_io (vm_io_native.odin) — тот же #+build !js/js split,
// та же (result, ok, handled)-сигнатура, тот же способ подключения в
// call_builtin (vm.odin).
//
// Vector2/Color на panos-стороне — обычные тупы (Число×2)/(Число×4), не
// новый Type_Kind (см. raylib_vector2_type/raylib_color_type,
// stdlib.odin) — распаковываются из ^Aggregate_Value этими двумя
// хелперами.
expect_vector2_arg :: proc(name: string, value: Value) -> rl.Vector2 {
	agg, ok := value.(^Aggregate_Value)
	if !ok || len(agg.elements) != 2 {
		fmt.panicf("Runtime Error: %s ожидает точку (Число, Число)", name)
	}
	x, ok_x := agg.elements[0].(f64)
	y, ok_y := agg.elements[1].(f64)
	if !ok_x || !ok_y {
		fmt.panicf("Runtime Error: %s ожидает точку (Число, Число)", name)
	}
	return rl.Vector2{f32(x), f32(y)}
}

expect_color_arg :: proc(name: string, value: Value) -> rl.Color {
	agg, ok := value.(^Aggregate_Value)
	if !ok || len(agg.elements) != 4 {
		fmt.panicf("Runtime Error: %s ожидает цвет (Число, Число, Число, Число)", name)
	}
	r, ok_r := agg.elements[0].(f64)
	g, ok_g := agg.elements[1].(f64)
	b, ok_b := agg.elements[2].(f64)
	a, ok_a := agg.elements[3].(f64)
	if !ok_r || !ok_g || !ok_b || !ok_a {
		fmt.panicf("Runtime Error: %s ожидает цвет (Число, Число, Число, Число)", name)
	}
	return rl.Color{u8(r), u8(g), u8(b), u8(a)}
}

call_builtin_graphics :: proc(vm: ^VM, name: string, args: []Value) -> (result: Value, ok: bool, handled: bool) {
	switch name {
	case "графика::инициализировать_окно":
		expect_arg_count(name, len(args), 3)
		width := number_to_index(args[0])
		height := number_to_index(args[1])
		title := expect_string_arg(name, args[2])
		rl.InitWindow(i32(width), i32(height), fmt.ctprintf("%s", title))
		return Value(f64(0)), false, true

	case "графика::окно_должно_закрыться":
		expect_arg_count(name, len(args), 0)
		return Value(rl.WindowShouldClose()), true, true

	case "графика::закрыть_окно":
		expect_arg_count(name, len(args), 0)
		rl.CloseWindow()
		return Value(f64(0)), false, true

	case "графика::начать_рисование":
		expect_arg_count(name, len(args), 0)
		rl.BeginDrawing()
		return Value(f64(0)), false, true

	case "графика::закончить_рисование":
		expect_arg_count(name, len(args), 0)
		rl.EndDrawing()
		return Value(f64(0)), false, true

	case "графика::очистить_фон":
		expect_arg_count(name, len(args), 1)
		rl.ClearBackground(expect_color_arg(name, args[0]))
		return Value(f64(0)), false, true

	case "графика::нарисовать_прямоугольник":
		expect_arg_count(name, len(args), 3)
		position := expect_vector2_arg(name, args[0])
		size := expect_vector2_arg(name, args[1])
		color := expect_color_arg(name, args[2])
		rl.DrawRectangleV(position, size, color)
		return Value(f64(0)), false, true

	case "графика::нарисовать_круг":
		expect_arg_count(name, len(args), 3)
		center := expect_vector2_arg(name, args[0])
		radius, ok_radius := args[1].(f64)
		if !ok_radius {
			fmt.panicf("Runtime Error: %s ожидает радиус (Число)", name)
		}
		color := expect_color_arg(name, args[2])
		rl.DrawCircleV(center, f32(radius), color)
		return Value(f64(0)), false, true

	case "графика::клавиша_нажата":
		expect_arg_count(name, len(args), 1)
		code := number_to_index(args[0])
		return Value(rl.IsKeyDown(rl.KeyboardKey(code))), true, true

	case "графика::время_кадра":
		expect_arg_count(name, len(args), 0)
		return Value(f64(rl.GetFrameTime())), true, true

	case "графика::задать_fps":
		expect_arg_count(name, len(args), 1)
		fps := number_to_index(args[0])
		rl.SetTargetFPS(i32(fps))
		return Value(f64(0)), false, true

	case "графика::клавиша_вверх":
		expect_arg_count(name, len(args), 0)
		return Value(f64(rl.KeyboardKey.UP)), true, true
	case "графика::клавиша_вниз":
		expect_arg_count(name, len(args), 0)
		return Value(f64(rl.KeyboardKey.DOWN)), true, true
	case "графика::клавиша_влево":
		expect_arg_count(name, len(args), 0)
		return Value(f64(rl.KeyboardKey.LEFT)), true, true
	case "графика::клавиша_вправо":
		expect_arg_count(name, len(args), 0)
		return Value(f64(rl.KeyboardKey.RIGHT)), true, true
	case "графика::клавиша_пробел":
		expect_arg_count(name, len(args), 0)
		return Value(f64(rl.KeyboardKey.SPACE)), true, true
	case "графика::клавиша_escape":
		expect_arg_count(name, len(args), 0)
		return Value(f64(rl.KeyboardKey.ESCAPE)), true, true
	}
	return
}
