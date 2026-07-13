" Vim syntax file
" Language: Panos
" Источник ключевых слов: core/lexer.odin::lookup_ident — держать в
" синхроне при добавлении новых слов языка.

if exists('b:current_syntax')
  finish
endif

" "в" (для x в iterable) и "по" (для сч = N по M) — НЕ ключевые слова
" лексера (lookup_ident их не знает, парсер сравнивает по тексту только
" в позиции грамматики "для"): panos разрешает использовать их как обычные
" идентификаторы (test.ps использует "в" как имя переменной) — намеренно
" не подсвечиваем как Keyword.

syntax keyword panosKeyword пер функ возврат конец как
syntax keyword panosConditional если тогда иначе выбор
syntax keyword panosRepeat пока цикл для продолжить прервать
syntax keyword panosOperatorWord и или не
syntax keyword panosStructure тип структура интерфейс реализация перечисление
syntax keyword panosInclude импорт экспорт
syntax keyword panosBoolean истина ложь

" Заглавная кириллическая буква в начале идентификатора — соглашение
" panos для типов/конструкторов (Число/Строка/Массив/Соответствие,
" Опция/Результат из прелюдии, Есть/Нет/Успех/Неудача — тоже варианты
" Опции/Результата, пользовательские структуры/enum/варианты). Один
" паттерн вместо перечисления каждого builtin-типа отдельно — тот же
" список никогда не устареет при добавлении нового типа в prelude.odin.
syntax match panosType "\v<[А-ЯЁ][А-Яа-яЁё0-9_]*>"

" Имя функции сразу после "функ" — до списка параметров.
syntax match panosFunctionName "\v(функ\s+)@<=[а-яёА-ЯЁ_][А-Яа-яЁё0-9_]*"

syntax match panosNumber "\v<\d+(\.\d+)?>"

" ==/<>/<=/>= до однобуквенных <, >, = — иначе более короткие альтернативы
" перехватывают первые символы двухсимвольных операторов.
"
" ВАЖНО: этот match должен идти РАНЬШЕ panosComment/panosString в файле —
" при совпадении стартовой позиции у нескольких match/region Vim отдаёт
" приоритет ПОСЛЕДНЕМУ определению (см. :help :syn-priority), а "/" у
" panosOperator и "//" у panosComment стартуют на одном и том же
" символе — без этого порядка комментарии подсвечивались бы как
" Operator, что и обнаружилось живым тестом.
syntax match panosOperator "\v(\=\=|\<\>|\<\=|\>\=|[+\-*/<>=])"

syntax region panosString start=+"+ skip=+\\\\\|\\"+ end=+"+ contains=panosStringEscape
syntax match panosStringEscape "\\[ntr\"\\]" contained

syntax match panosComment "//.*$" contains=@Spell

highlight default link panosKeyword       Keyword
highlight default link panosConditional   Conditional
highlight default link panosRepeat        Repeat
highlight default link panosOperatorWord  Keyword
highlight default link panosStructure     StorageClass
highlight default link panosInclude       Include
highlight default link panosBoolean       Boolean
highlight default link panosType          Type
highlight default link panosFunctionName  Function
highlight default link panosComment       Comment
highlight default link panosString        String
highlight default link panosStringEscape  SpecialChar
highlight default link panosNumber        Number
highlight default link panosOperator      Operator

let b:current_syntax = 'panos'
