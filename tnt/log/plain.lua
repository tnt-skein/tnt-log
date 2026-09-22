--- Вид plain: тело записи одной строкой.
---
--- Сообщение, затем пары `ключ=значение`. Пары фасада — `suppressed`,
--- `truncated` и `args` — идут сразу за сообщением, до пар вызывающего:
--- поле вызывающего по имени `truncated` иначе было бы неотличимо
--- от отметки фасада. Пары вызывающего идут по алфавиту: одинаковые записи
--- должны выглядеть одинаково, иначе их не сравнить глазами
--- и не сгруппировать. Имя инстанса не печатается: plain читают на своей
--- машине, а общий поток нескольких инстансов пишется в json.
---
--- Последними идут поля контекста: опознаватели запроса и трассы
--- (`request_id=…`, `trace_id=…`, `span_id=…`) и прочие ключи контекста
--- как `context.<ключ>=…`. `trace_flags` в plain не печатается: человеку
--- он не нужен, а сборщику достаётся json. В отпечаток записи для
--- подавления повторов (`fingerprint`) контекст не входит — наравне
--- с именем инстанса: одна и та же беда в двух запросах даёт разные
--- `request_id`, и подавление иначе не работало бы вовсе.

local json = require('json')

local Module = {}

--- Верхние поля контекста, которые печатаются в plain, по порядку.
local IDENTIFIERS = { 'request_id', 'trace_id', 'span_id' }

--- Свой кодировщик, а не общий `json`: общий настраивает приложение
--- (точность чисел, глубина), а строка plain обязана читаться одинаково
--- при любых его настройках.
local encode = json.new().encode

--- Управляющий знак так, как его пишет JSON, но без кавычек.
---@param char string
---@return string
local function escaped(char)
    return encode(char):sub(2, -2)
end

--- Значение или ключ в plain.
---
--- В кавычки берётся только то, что можно спутать с разделителем:
--- пустое, с пробелом, `=`, кавычкой, обратной чертой или управляющим знаком.
--- Всё прочее — как в JSON, чтобы большое целое не потеряло цифры.
---@param value any
---@return string
local function plain_value(value)
    local encoded = encode(value)

    -- Кавычку, обратную черту и управляющие знаки (перевод строки и
    -- табуляция в их числе) JSON экранирует сам, и строка, не выросшая
    -- в JSON сверх двух кавычек, их не содержит. Проверка длиной вместо
    -- образца с классом знаков: образец стоит полторы десятых микросекунды
    -- на значение, а значений в записи десяток.
    if type(value) == 'string' and value ~= '' and #encoded == #value + 2 then
        if value:find(' ') == nil and value:find('=') == nil then
            return value
        end
    end

    return encoded
end

--- Пары таблицы по алфавиту имён, с приставкой к имени.
---@param parts string[] Куда дописывать
---@param fields table
---@param prefix string
local function append_pairs(parts, fields, prefix)
    local names = {}

    for name in pairs(fields) do
        table.insert(names, name)
    end

    table.sort(names)

    for _, name in ipairs(names) do
        table.insert(parts, prefix .. plain_value(name) .. '=' .. plain_value(fields[name]))
    end
end

--- Куски записи без контекста: сообщение, пары фасада, пары вызывающего.
---@param record TntLogRecord
---@return string[]
local function body(record)
    local parts = { (record.message:gsub('%c', escaped)) }

    if record.suppressed ~= nil then
        table.insert(parts, 'suppressed=' .. plain_value(record.suppressed))
    end

    if record.truncated then
        table.insert(parts, 'truncated=true')
    end

    if record.args ~= nil then
        table.insert(parts, 'args=' .. plain_value(record.args))
    end

    if record.fields ~= nil then
        append_pairs(parts, record.fields, '')
    end

    return parts
end

--- Отпечаток записи: тело без контекста и без имени инстанса.
---@param record TntLogRecord
---@return string
function Module.fingerprint(record)
    return table.concat(body(record), ' ')
end

--- Тело записи целиком: отпечаток и поля контекста.
---@param record TntLogRecord
---@return string
function Module.render(record)
    local parts = body(record)

    for _, name in ipairs(IDENTIFIERS) do
        if record[name] ~= nil then
            table.insert(parts, name .. '=' .. plain_value(record[name]))
        end
    end

    if record.context ~= nil then
        append_pairs(parts, record.context, 'context.')
    end

    return table.concat(parts, ' ')
end

return Module
