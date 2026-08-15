# Встраивание Panos в Zig

`panos_embed` — нативный Zig-модуль для приложения, которому нужен Panos
как сценарный слой. Он владеет загрузкой модулей, компиляцией и VM; приложение
остаётся владельцем окна, рендера, физики, карт и игрового цикла.

## Подключение

В `build.zig` движка добавьте зависимость Panos и импортируйте только
`panos_embed`. Его нативные зависимости (vendored SQLite и libffi) следуют за
модулем автоматически.

```zig
const panos_dep = b.dependency("panos", .{
    .target = target,
    .optimize = optimize,
});
game.root_module.addImport("panos_embed", panos_dep.module("panos_embed"));
game.rdynamic = true;
```

`rdynamic` обязателен, если Panos-сценарии вызывают функции движка через
`внешний "хост"`: он публикует `pub export fn` исполняемого файла в таблице
динамических символов. Это нативный POSIX-путь; браузерный интерпретатор не
поддерживает `внешний`.

## Жизненный цикл сценария

Создайте один `Runtime` на один набор сценариев. Граф загружается и
компилируется один раз во время старта уровня; `call` выполняется на границах
игровых событий. Результат `Value` и `output()` принадлежат Runtime и остаются
действительны до следующего вызова.

```zig
const panos = @import("panos_embed");

var runtime = panos.Runtime.init(allocator, .{
    .global_search_roots = &.{"scripts/std"},
    .program_args = &.{"уровень_01"},
});
defer runtime.deinit();

try runtime.load(&reader, "scripts/уровень.pns");
if (runtime.hasGraphErrors()) return error.ScriptLoadFailed;

try runtime.compile();
if (runtime.hasCompilationErrors()) return error.ScriptCompileFailed;

const outcome = try runtime.call("обновить", &.{.{ .number = delta_seconds }});
```

`reader` — любой указатель на тип с методом
`read(allocator, path) ![]u8`. Поэтому движок может читать сценарии из обычной
файловой системы, архива ресурсов или памяти, не меняя Panos.

## Нативная поверхность движка

Не добавляйте `игра.*` в VM. Экспортируйте маленькие C-ABI-функции из движка и
объявляйте только нужные сигнатуры рядом со сценарием.

```zig
pub export fn game_damage_multiplier(base: f64) f64 {
    return base * 1.5;
}
```

```text
внешний "хост" функ game_damage_multiplier(base: Число(64)) -> Число(64)

экспорт функ урон_волны(base: Число) -> Число
    game_damage_multiplier(base)
конец
```

Так слой сценариев видит только сознательно опубликованный ABI. События,
карты, компоненты ECS и указатели движка не пересекают границу неявно; для
сложных данных используйте числовые идентификаторы и узкие функции чтения/
записи.
