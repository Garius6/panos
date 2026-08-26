# Quickstart: регистрация host-функций без `pub export fn`/`rdynamic`

1. В Zig-коде встраивающего приложения (например, игрового движка)
   напишите обычные функции — без `pub export fn`, без экспорта:

   ```zig
   fn entityApplyDamage(id: i64, amount: f64) void {
       ecs.applyDamage(@intCast(id), amount);
   }
   ```

2. Соберите их в `hostFunctions(...)` и передайте в `Runtime.Config` при
   старте уровня:

   ```zig
   var runtime = panos.Runtime.init(allocator, .{
       .host_functions = panos.hostFunctions(.{
           .entity_apply_damage = entityApplyDamage,
       }),
       .global_search_roots = &.{"scripts/std"},
   });
   ```

3. В `.pns`-скрипте уровня объявите ту же функцию как обычно — синтаксис
   не меняется:

   ```panos-cli
   внешний "хост" функ entity_apply_damage(id: Целое(64), урон: Число(64)) -> Пусто

   функ на_попадание(цель: Целое, урон: Число) -> Пусто
       entity_apply_damage(цель, урон)
   конец
   ```

4. Уберите `rdynamic = true` из `build.zig` встраивающего приложения, если
   больше нет ни одной host-функции на старом `pub export fn`-пути.

5. Если сигнатура в `.pns` не совпадёт с зарегистрированной Zig-функцией —
   `runtime.compile()` вернёт `void` (не ошибку — та же семантика, что и
   любая другая ошибка компиляции скрипта), но
   `runtime.hasCompilationErrors()` после него станет `true`; конкретное
   несовпадение — в `runtime.compilationDiagnostics()`/
   `runtime.formatDiagnostics(...)` (см. `contracts/embed-api.md`) — до
   какого-либо реального вызова.

Полный рабочий пример — `contracts/embed-api.md`.
