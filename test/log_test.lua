--- Тесты фасада журнала в процессе проверок.
---
--- Журнал ядра подменяется двойником через внешнюю зависимость: двойник получает ровно
--- тот аргумент, который ушёл бы в ядро, и проверяется именно он. Настоящий
--- журнал ядра проверяется в дочернем процессе (`builtin_test.lua`): в этом
--- процессе его уже настроил luatest, и перенастроить нельзя.

local t = require('luatest')
local ffi = require('ffi')
local json = require('json')
local uuid = require('uuid')
local decimal = require('decimal')

local helper = dofile('test/helper.lua')

--- Номера уровней ядра, записанные здесь независимо от фасада: сверять
--- фасад с его же таблицей значило бы не проверять ничего.
local LEVEL_NUMBERS = { fatal = 0, syserror = 1, error = 2, crit = 3, warn = 4, info = 5, verbose = 6, debug = 7 }
local METHOD_NUMBERS = { debug = 7, info = 5, warn = 4, error = 2 }
local METHODS = { 'debug', 'info', 'warn', 'error' }

local HIDDEN = '[скрыто]'

ffi.cdef('struct tnt_log_test_unprintable { int value; };')

--- cdata, у которого печать бросает.
local Unprintable = ffi.metatype('struct tnt_log_test_unprintable', {
    __tostring = function()
        error('не печатается')
    end,
})

--- Таблица, чья собственная печать бросает: её отдают чужие `__tostring`.
local POISON = setmetatable({}, {
    __tostring = function()
        error('отравленная печать')
    end,
})

ffi.cdef('struct tnt_log_test_poisoned { int value; };')

--- cdata, чей `__tostring` отдаёт не строку, а таблицу с бросающей печатью.
local Poisoned = ffi.metatype('struct tnt_log_test_poisoned', {
    __tostring = function()
        return POISON
    end,
})

local g = t.group('tnt.log')

--- Двойник фабрики журналов ядра: складывает каждый аргумент.
---@param written table[]
---@return fun(name: string): table
local function recorder(written)
    return function(name)
        local methods = {}

        for _, method in ipairs(METHODS) do
            methods[method] = function(argument)
                table.insert(written, { module = name, level = method, argument = argument })
            end
        end

        return methods
    end
end

g.before_each(function()
    g.log = helper.load()
    g.context = helper.context()
    g.written = {}
    g.settings = { level = 'debug', format = 'json' }
    g.instance = nil

    g.log._set_source({
        logger = recorder(g.written),
        settings = function()
            return g.settings
        end,
        instance_name = function()
            return g.instance
        end,
    })
end)

-- Выгрузка возвращает загруженное до проверки: установленные копии
-- соседей держат ссылку на прежний журнал.
g.after_each(function()
    helper.unload()
end)

--- Что получило ядро последней записью.
---@return any
local function last()
    return (assert(g.written[#g.written], 'записей не было')).argument
end

--- Что получило ядро записью под номером.
---@param index integer
---@return any
local function argument_at(index)
    return (assert(g.written[index], ('записи №%d не было'):format(index))).argument
end

--- Пишет значение полем и отдаёт, каким оно дошло до ядра.
---@param value any
---@return any shown
---@return table record
local function shown(value)
    g.log.new('tnt.pool').info('m', { v = value })

    local record = last()

    return record.fields.v, record
end

--- Сколько раз за время действия звались перевод в нижний регистр, замена
--- и перебор совпадений.
---
--- Так видна цена, а не ответ. Память имён и предпроверки перед образцами
--- на ответ не влияют — только на то, сколько работы сделано, и по-другому
--- их не наблюдать.
---@param act fun()
---@return { lower: integer, gsub: integer, gmatch: integer }
local function spied(act)
    local calls = { lower = 0, gsub = 0, gmatch = 0 }
    local real = {}

    for name in pairs(calls) do
        local original = string[name]

        real[name] = original
        string[name] = function(...)
            calls[name] = calls[name] + 1

            return original(...)
        end
    end

    local ok, err = pcall(act)

    for name, original in pairs(real) do
        string[name] = original
    end

    if not ok then
        error(err, 0)
    end

    return calls
end

--- Сколько раз за время действия имя переводилось в нижний регистр.
---
--- Так видно, помнит ли фасад проверенное имя: из памяти имя берётся без
--- перевода.
---@param act fun()
---@return integer
local function lowered(act)
    return spied(act).lower
end

--- Есть ли подстрока в строке, ключе или значении на любой глубине.
---@param value any
---@param needle string
---@return boolean
local function leaks(value, needle)
    if type(value) == 'string' then
        return value:find(needle, 1, true) ~= nil
    end

    if type(value) ~= 'table' then
        return false
    end

    for key, inner in pairs(value) do
        if leaks(key, needle) or leaks(inner, needle) then
            return true
        end
    end

    return false
end

--- Цепочка вложенных таблиц: `levels` таблиц, считая корень.
---@param levels integer
---@return table
local function chain(levels)
    local root = {}
    local at = root

    for _ = 2, levels do
        at.x = {}
        at = at.x
    end

    return root
end

--- Поля, в которых значение лежит на заданной глубине: корень — первая.
---@param depth integer
---@param value any
---@return table
local function placed(depth, value)
    local root = chain(depth - 1)
    local at = root

    for _ = 3, depth do
        at = at.x
    end

    at.x = value

    return root
end

--- Что лежит в полях на заданной глубине.
---@param fields table
---@param depth integer
---@return any
local function reached(fields, depth)
    local at = fields

    for _ = 3, depth do
        at = at.x
    end

    return at.x
end

--- Таблица, считающая, сколько раз её обошли.
---@param counter { calls: integer }
---@return table
local function counted(counter)
    return setmetatable({}, {
        __serialize = function()
            counter.calls = counter.calls + 1

            return 1
        end,
    })
end

--- Подменяет `box.cfg` на время действия.
---@param value any
---@param act fun()
local function with_box_cfg(value, act)
    local real = box.cfg

    box.cfg = value

    local ok, err = pcall(act)

    box.cfg = real

    if not ok then
        error(err, 0)
    end
end

-- ── Форма записи ─────────────────────────────────────────────────────

g.test_a_record_without_fields_carries_only_the_message = function()
    g.log.new('tnt.pool').info('пул готов')

    t.assert_equals(
        g.written,
        { { module = 'tnt.pool', level = 'info', argument = { message = 'пул готов' } } }
    )
end

g.test_caller_fields_go_inside_fields = function()
    g.log
        .new('tnt.pool')
        .warn('соединение не открылось', { attempt = 1, reason = 'нет связи' })

    t.assert_equals(last(), {
        message = 'соединение не открылось',
        fields = { attempt = 1, reason = 'нет связи' },
    })
end

g.test_every_method_writes_at_its_own_level = function()
    local pool = g.log.new('tnt.pool')

    for _, method in ipairs(METHODS) do
        pool[method](method)
    end

    for index, method in ipairs(METHODS) do
        t.assert_equals(g.written[index].level, method)
        t.assert_equals(g.written[index].argument, { message = method })
    end
end

g.test_a_message_that_is_not_a_string_is_shown_by_its_value = function()
    local pool = g.log.new('tnt.pool')

    pool.info(42)
    pool.info(0 / 0)
    pool.info(print)
    pool.info(nil)

    t.assert_equals(argument_at(1).message, '42')
    t.assert_equals(argument_at(2).message, 'nan')
    t.assert_equals(argument_at(3).message, '[function]')
    t.assert_equals(argument_at(4).message, '[nil]')
end

g.test_a_table_message_becomes_the_json_of_its_clean_copy = function()
    g.log.new('tnt.pool').info({ password = 'hunter2', text = 'сообщение' })

    t.assert_equals(json.decode(last().message), { password = HIDDEN, text = 'сообщение' })
    t.assert_equals(last().fields, nil)
end

g.test_fields_that_are_not_a_table_go_under_value = function()
    local pool = g.log.new('tnt.pool')

    pool.info('m', 'просто строка')
    pool.info('m', 7)

    t.assert_equals(argument_at(1).fields, { value = 'просто строка' })
    t.assert_equals(argument_at(2).fields, { value = 7 })
end

g.test_empty_fields_are_left_out = function()
    g.log.new('tnt.pool').info('m', {})

    t.assert_equals(last(), { message = 'm' })
end

g.test_the_caller_table_is_not_changed = function()
    local fields = { password = 'hunter2', nested = { token = 'x', list = { 1, 2 } }, [true] = 'b' }
    local copy = table.deepcopy(fields)

    g.log.new('tnt.pool').info('m', fields)

    t.assert_equals(fields, copy)
end

g.test_plain_settings_hand_the_core_a_rendered_string = function()
    g.settings = { level = 'debug', format = 'plain' }

    g.log
        .new('tnt.pool')
        .warn('соединение не открылось', { reason = 'нет связи', attempt = 1 })

    t.assert_equals(last(), 'соединение не открылось attempt=1 reason="нет связи"')
end

g.test_top_level_fields_always_get_string_keys = function()
    local pool = g.log.new('tnt.pool')

    pool.info('m', { 'a', 'b' })
    pool.info(
        'm',
        setmetatable({}, {
            __serialize = function()
                return { 'c' }
            end,
        })
    )

    t.assert_equals(argument_at(1).fields, { ['1'] = 'a', ['2'] = 'b' })
    t.assert_equals(argument_at(2).fields, { ['1'] = 'c' })
end

g.test_nested_arrays_stay_arrays = function()
    t.assert_equals(shown({ 'storage-001-a', 'storage-001-b' }), { 'storage-001-a', 'storage-001-b' })
    t.assert_equals(shown({ [2] = 'b' }), { [2] = 'b' })
end

-- ── Заполнители ──────────────────────────────────────────────────────

--- Сообщение с заполнителями при данных полях: как оно дошло до ядра.
---@param message string
---@param fields any
---@return string
local function message_of(message, fields)
    g.log.new('tnt.pool').info(message, fields)

    return last().message
end

g.test_a_placeholder_is_filled_from_the_fields_by_name = function()
    g.log.new('tnt.pool').warn(
        'соединение {endpoint} не открылось, попытка {attempt}',
        { endpoint = 'db:3301', attempt = 3 }
    )

    -- Поле остаётся в `fields`: по нему ищут в сборщике.
    t.assert_equals(last(), {
        message = 'соединение db:3301 не открылось, попытка 3',
        fields = { endpoint = 'db:3301', attempt = 3 },
    })
end

g.test_a_value_is_filled_in_the_way_json_writes_it = function()
    local fields = {
        s = 'строка',
        n = 1.5,
        i = 7,
        yes = true,
        no = false,
        null = box.NULL,
        list = { 'a', 'b' },
        map = { k = 'v' },
    }

    t.assert_equals(
        message_of('{s} {n} {i} {yes} {no} {null} {list} {map}', fields),
        'строка 1.5 7 true false null ["a","b"] {"k":"v"}'
    )
end

g.test_a_dotted_name_walks_into_nested_fields = function()
    local fields = { db = { host = 'db', port = 3301, opts = { tls = true } }, peers = { 'a', 'b' } }

    t.assert_equals(message_of('{db.host}:{db.port} {db.opts.tls} {peers.1}', fields), 'db:3301 true a')
    -- Ключи верхнего уровня всегда строки, и первый элемент массива полей
    -- лежит под строкой `1`.
    t.assert_equals(message_of('{1}', { 'x' }), 'x')
end

g.test_a_name_may_carry_uppercase_letters_and_digits = function()
    t.assert_equals(message_of('{Db} {aB} {k9} {a}', { Db = 'x', aB = 'y', k9 = 'z', a = 'w' }), 'x y z w')
end

g.test_a_placeholder_without_a_field_stays_word_for_word = function()
    local fields = { a = 'x', db = { host = 'h' }, s = 'строка' }

    for _, message in ipairs({
        '{b}',
        '{db.port}',
        '{db.host.deeper}',
        '{s.x}',
        '{a..b}',
        '{.a}',
        '{a.}',
        '{}',
        '{ a}',
        '{a b}',
        '{a-b}',
        '{поле}',
        '{"a":1}',
        'function() { return {a}; }',
        '{',
        '}',
        '}{',
    }) do
        t.assert_equals(message_of(message, fields), (message:gsub('{a}', 'x')), message)
    end

    -- Вложенные скобки: подставляется внутренний заполнитель, внешние
    -- скобки остаются.
    t.assert_equals(message_of('{{a}}', fields), '{x}')
    -- Без полей заполнители не применяются вовсе.
    t.assert_equals(message_of('{a}', nil), '{a}')
    t.assert_equals(message_of('{a}', {}), '{a}')
end

g.test_a_filled_value_is_not_filled_again = function()
    t.assert_equals(message_of('{a}', { a = '{b}', b = 'x' }), '{b}')
end

g.test_a_placeholder_takes_the_cleaned_value = function()
    local ring = {}

    ring.self = ring

    local fields = {
        password = 'hunter2',
        endpoint = 'http://root:hunter2@db',
        obj = ring,
        deep = chain(18),
        bad = '\xff',
        big = 9007199254740993LL,
        nan = 0 / 0,
    }

    t.assert_equals(
        message_of('{password} {endpoint} {obj} {bad} {big} {nan}', fields),
        HIDDEN
            .. ' http://root:'
            .. HIDDEN
            .. '@db {"self":"[кольцо]"} [не UTF-8, 1 байт] 9007199254740993 nan'
    )
    t.assert_equals(leaks(last(), 'hunter2'), false)
    t.assert_str_contains(message_of('{deep}', fields), '[глубже]')
end

g.test_a_placeholder_is_filled_after_the_secrets_in_the_text_are_hidden = function()
    -- Тайна в тексте прячется до подстановки, и подставленное значение —
    -- уже очищенное: наружу не уходит ни то, ни другое.
    t.assert_equals(
        message_of('token=hunter2 у {url}', { url = 'postgres://root:hunter2@db' }),
        'token=' .. HIDDEN .. ' у postgres://root:' .. HIDDEN .. '@db'
    )
end

g.test_a_message_grown_by_placeholders_is_cut_at_the_limit = function()
    local fields = { blob = string.rep('x', 4000) }

    t.assert_equals(message_of('{blob}{blob}', fields), string.rep('x', 4096) .. '…')
    t.assert_equals(last().truncated, true)
    t.assert_equals(last().fields, fields)

    -- Ровно потолок после подстановки — без обрезки.
    t.assert_equals(message_of(string.rep('m', 4090) .. '{a}', { a = 'xxxxxx' }), string.rep('m', 4090) .. 'xxxxxx')
    t.assert_equals(last().truncated, nil)
end

g.test_a_message_grown_by_placeholders_is_counted_before_the_record_is_trusted = function()
    -- Поля и сообщение до подстановки укладываются в доверенную оценку
    -- ровно (2493 + 7 = 2500, ×6 = 15000), а подставленное значение
    -- вшестеро длиннее в JSON. Считайся сообщение до подстановки, запись
    -- ушла бы ядру без замера и пробила бы буфер.
    g.log.new('tnt.pool').info('{c}', { c = string.rep('\1', 2480) })

    t.assert_equals(last(), { message = string.rep('?', 1024) .. '…', truncated = true })
end

g.test_a_record_is_measured_only_where_the_estimate_does_not_vouch = function()
    -- Кодировщики заводятся при загрузке и держатся у себя (замер — у журнала,
    -- запись plain — у её модуля), поэтому счётчик ставится в `json.new`
    -- на время загрузки. Запись здесь идёт в JSON, и plain свой кодировщик
    -- не зовёт: счёт — это замеры. Так видна цена: ответ у замера и у
    -- доверенной оценки один, разница — в лишней записи JSON на сообщение.
    local encodes = 0
    local real_new = json.new

    json.new = function()
        local encoder = real_new()
        local encode = encoder.encode

        encoder.encode = function(...)
            encodes = encodes + 1

            return encode(...)
        end

        return encoder
    end

    local loaded, log = pcall(helper.load)

    json.new = real_new

    t.assert(loaded, log)

    log._set_source({
        logger = recorder(g.written),
        settings = function()
            return g.settings
        end,
        instance_name = function()
            return nil
        end,
    })

    local pool = log.new('tnt.pool')

    -- Малая запись: оценка ручается за размер, замера нет.
    pool.info('m', { a = 1 })

    t.assert_equals(encodes, 0)

    -- Оценка ровно на потолке (7 + 2493 = 2500, ×6 = 15000) — ещё доверие.
    local blob = string.rep('x', 2480)

    pool.info('abc', { c = blob })

    t.assert_equals(encodes, 0)
    t.assert_equals(last(), { message = 'abc', fields = { c = blob } })

    -- Байтом больше — уже замер, а запись та же: её JSON в потолок укладывается.
    pool.info('abcd', { c = blob })

    t.assert_equals(encodes, 1)
    t.assert_equals(last(), { message = 'abcd', fields = { c = blob } })
end

g.test_a_table_message_is_not_filled = function()
    g.log.new('tnt.pool').info({ text = '{a}' }, { a = 'x' })

    t.assert_equals(json.decode(last().message), { text = '{a}' })
end

g.test_fields_that_are_not_a_table_fill_the_value_placeholder = function()
    t.assert_equals(message_of('получено {value}', 'строка'), 'получено строка')
end

g.test_placeholders_are_looked_for_only_where_there_is_a_brace = function()
    local pool = g.log.new('tnt.pool')

    --- Сколько раз запись стоила замены в строке. Запись пишется дважды,
    --- считается вторая: первая запоминает имена полей, а без памяти
    --- каждое имя стоило бы замены дефиса на подчёркивание.
    local function cost(message, fields)
        pool.info(message, fields)

        return spied(function()
            pool.info(message, fields)
        end).gsub
    end

    -- Без скобки образец заполнителя не гоняется вовсе; без полей — тоже.
    t.assert_equals(cost('соединение не открылось', { endpoint = 'db', attempt = 3 }), 0)
    t.assert_equals(cost('соединение {endpoint} не открылось', nil), 0)
    t.assert_equals(cost('соединение {endpoint} не открылось', { endpoint = 'db' }), 1)
end

g.test_a_series_is_compared_by_the_filled_message = function()
    local changes = g.log.changes('tnt.failover')

    changes.info('лидер {leader}', { leader = 'a' })
    changes.info('лидер {leader}', { leader = 'a' })
    changes.info('лидер {leader}', { leader = 'b' })

    t.assert_equals(#g.written, 2)
    t.assert_equals(argument_at(1).message, 'лидер a')
    t.assert_equals(argument_at(2), { message = 'лидер b', fields = { leader = 'b' }, suppressed = 1 })
end

-- ── Лишние аргументы ─────────────────────────────────────────────────

g.test_arguments_after_the_fields_go_into_args = function()
    g.log.new('tnt.pool').info('%s %d', 'a', 1)

    -- Не строка в роли полей — `fields.value`, а всё за ней — `args`.
    t.assert_equals(last(), { message = '%s %d', fields = { value = 'a' }, args = { 1 } })
end

g.test_args_keep_their_positions_and_are_cleaned = function()
    local ring = {}

    ring.self = ring

    g.log
        .new('tnt.pool')
        .info('m', { a = 1 }, nil, 'token=hunter2', { password = 'hunter2', list = { 1, 2 } }, ring, nil)

    t.assert_equals(last(), {
        message = 'm',
        fields = { a = 1 },
        args = {
            '[nil]',
            'token=' .. HIDDEN,
            { password = HIDDEN, list = { 1, 2 } },
            { self = '[кольцо]' },
            '[nil]',
        },
    })
    t.assert_equals(leaks(last(), 'hunter2'), false)
end

g.test_args_alone_make_a_record_with_args = function()
    g.log.new('tnt.pool').info('m', nil, 'x')

    t.assert_equals(last(), { message = 'm', args = { 'x' } })
end

g.test_args_are_rendered_in_plain_among_the_pairs_of_the_facade = function()
    g.settings = { level = 'debug', format = 'plain' }

    g.log.new('tnt.pool').info('m', { z = 1, args = 'своё' }, 'x', 2, { k = 'v' })

    t.assert_equals(last(), 'm args=["x",2,{"k":"v"}] args=своё z=1')
    t.assert_equals(
        g.log.render({ message = 'm', args = { 1 }, truncated = true, suppressed = 2 }),
        'm suppressed=2 truncated=true args=[1]'
    )
end

g.test_args_are_counted_and_dropped_by_the_fallback_record = function()
    local pool = g.log.new('tnt.pool')

    -- Четыре аргумента по потолку строки: оценка за пределом, точный замер
    -- показывает 16 КБ, и запись уходит запасной — без полей и аргументов.
    local long = string.rep('x', 4096)

    pool.info('m', { a = 1 }, long, long, long, long)

    t.assert_equals(last(), { message = 'm', truncated = true })

    -- Три таких аргумента укладываются, и `truncated` не ставится.
    pool.info('m', { a = 1 }, long, long, long)

    t.assert_equals(last(), { message = 'm', fields = { a = 1 }, args = { long, long, long } })
end

g.test_args_have_the_same_depth_limit_as_fields = function()
    local pool = g.log.new('tnt.pool')

    pool.info('m', nil, chain(16))
    pool.info('m', nil, chain(17))

    t.assert_equals(argument_at(1).truncated, nil)
    t.assert_equals(argument_at(2).truncated, true)
    t.assert_str_contains(json.encode(argument_at(2).args), '[глубже]')
end

g.test_args_are_cut_like_any_value = function()
    g.log.new('tnt.pool').info('m', nil, string.rep('x', 4097))

    t.assert_equals(last(), { message = 'm', args = { string.rep('x', 4096) .. '…' }, truncated = true })
end

g.test_a_series_is_compared_with_args = function()
    local changes = g.log.changes('tnt.failover')

    changes.info('m', nil, 1)
    changes.info('m', nil, 1)
    changes.info('m', nil, 2)

    t.assert_equals(#g.written, 2)
    t.assert_equals(argument_at(2), { message = 'm', args = { 2 }, suppressed = 1 })
end

-- ── Имя журнала ──────────────────────────────────────────────────────

g.test_a_name_that_is_not_a_short_plain_word_is_a_build_error = function()
    local refused = { '', 42, false, 'tnt pool', 'a"b', 'a\nb', 'пул', '\xff', string.rep('n', 129) }

    for _, make in ipairs({ 'new', 'changes' }) do
        for _, name in ipairs(refused) do
            local ok, err = pcall(function()
                local logger = g.log[make](name)

                return logger
            end)

            t.assert_equals(ok, false, ('%s %q'):format(make, tostring(name)))
            -- Место в отказе — строка, которая завела журнал, а не нутро фасада.
            t.assert_str_contains(tostring(err), 'log_test.lua:')
            t.assert_str_contains(
                tostring(err),
                'имя журнала — до 128 байт из латиницы, цифр, точки,'
            )
        end
    end

    t.assert_error_msg_contains('а не "nil"', g.log.new, nil)
end

g.test_a_name_of_the_longest_allowed_length_and_charset_is_accepted = function()
    -- Длинное имя пробило бы потолок записи: ядро пишет его в заголовок
    -- мимо фасада, и запись длиннее буфера вышла бы с NUL внутри.
    local longest = string.rep('n', 128)

    g.log.new(longest).info('m')
    g.log.changes('stand.panel-v2_x').info('m')

    t.assert_equals(g.written[1].module, longest)
    t.assert_equals(g.written[2].module, 'stand.panel-v2_x')

    -- Правило отдаётся наружу: метку журнала в своей настройке проверяют им.
    t.assert_equals(g.log.is_name(longest), true)
    t.assert_equals(g.log.is_name(longest .. 'n'), false)
    t.assert_equals(
        g.log.NAME_RULE,
        'до 128 байт из латиницы, цифр, точки, подчёркивания и дефиса'
    )
end

g.test_the_name_goes_to_the_core_word_for_word = function()
    g.log.new('stand.failover').info('m')

    t.assert_equals(g.written[1].module, 'stand.failover')
end

-- ── Значения ─────────────────────────────────────────────────────────

g.test_invalid_utf8_is_replaced_by_its_size = function()
    t.assert_equals(shown('\xff\xfe'), '[не UTF-8, 2 байт]')
end

g.test_a_string_of_exactly_the_limit_passes_whole = function()
    local value, record = shown(string.rep('a', 4096))

    t.assert_equals(value, string.rep('a', 4096))
    t.assert_equals(record.truncated, nil)
end

g.test_a_string_over_the_limit_is_cut_and_marked = function()
    local value, record = shown(string.rep('a', 4097))

    t.assert_equals(value, string.rep('a', 4096) .. '…')
    t.assert_equals(record.truncated, true)
end

g.test_a_cut_does_not_tear_a_character_apart = function()
    -- «я» — D1 8F, «р» — D1 80, «п» — D0 BF: границы байтов продолжения.
    for _, char in ipairs({ 'я', 'р', 'п' }) do
        t.assert_equals(shown(string.rep('a', 4095) .. char), string.rep('a', 4095) .. '…', char)
        t.assert_equals(shown(string.rep('a', 4094) .. char .. 'bb'), string.rep('a', 4094) .. char .. '…', char)
    end

    -- Трёх- и четырёхбайтовый знак требуют отступить назад не один раз.
    t.assert_equals(shown(string.rep('a', 4094) .. '€'), string.rep('a', 4094) .. '…')
    t.assert_equals(shown(string.rep('a', 4093) .. '😀'), string.rep('a', 4093) .. '…')
end

g.test_numbers_that_json_cannot_hold_become_strings = function()
    t.assert_equals(shown(1.5), 1.5)
    t.assert_equals(shown(0 / 0), 'nan')
    t.assert_equals(shown(math.huge), 'inf')
    t.assert_equals(shown(-math.huge), '-inf')
end

g.test_booleans_and_null_stay_as_they_are = function()
    t.assert_equals(shown(true), true)
    t.assert_equals(shown(false), false)

    local null = shown(box.NULL)

    t.assert_equals(type(null), 'cdata')
    t.assert_equals(null, box.NULL)
end

g.test_64_bit_integers_become_numbers_only_while_exact = function()
    local exact = shown(9007199254740992LL)

    t.assert_equals(type(exact), 'number')
    t.assert_equals(exact, 2 ^ 53)
    t.assert_equals(shown(-9007199254740992LL), -2 ^ 53)
    t.assert_equals(shown(5ULL), 5)
    -- Беззнаковое у самой границы — числом: сравнение uint64_t с -2^53
    -- на x86 давало ложь для любого ULL, и такое писалось строкой.
    t.assert_equals(shown(9007199254740992ULL), 2 ^ 53)
    t.assert_equals(shown(9007199254740993ULL), '9007199254740993')
    t.assert_equals(shown(9223372036854775807LL), '9223372036854775807')
    t.assert_equals(shown(-9223372036854775807LL - 1), '-9223372036854775808')
    t.assert_equals(shown(9007199254740993LL), '9007199254740993')
    t.assert_equals(shown(-9007199254740993LL), '-9007199254740993')
    t.assert_equals(shown(18446744073709551615ULL), '18446744073709551615')
end

g.test_other_cdata_is_printed = function()
    local id = uuid.new()

    t.assert_equals(shown(id), id:str())
    t.assert_equals(shown(decimal.new('3.14')), '3.14')
    t.assert_equals(shown(Unprintable({ 1 })), '[cdata]')
end

g.test_functions_and_threads_are_named_by_their_kind = function()
    t.assert_equals(shown(print), '[function]')
    t.assert_equals(shown(coroutine.create(print)), '[thread]')
end

g.test_userdata_goes_through_its_serialize = function()
    local proxy = newproxy(true)

    getmetatable(proxy).__serialize = function()
        return { password = 'hunter2', ok = 1 }
    end

    t.assert_equals(shown(proxy), { password = HIDDEN, ok = 1 })
end

g.test_userdata_whose_serialize_throws_is_printed = function()
    local proxy = newproxy(true)

    getmetatable(proxy).__serialize = function()
        error('не сериализуется')
    end
    getmetatable(proxy).__tostring = function()
        return 'объект'
    end

    t.assert_equals(shown(proxy), 'объект')
end

g.test_userdata_that_cannot_be_printed_is_named_by_its_kind = function()
    local proxy = newproxy(true)

    getmetatable(proxy).__serialize = 'map'
    getmetatable(proxy).__tostring = function()
        error('не печатается')
    end

    t.assert_equals(shown(proxy), '[userdata]')
    t.assert_str_matches(shown(newproxy(false)), 'userdata: 0x%x+')
end

g.test_a_table_we_are_inside_is_a_ring_and_a_shared_one_is_not = function()
    local ring = { id = 7 }
    local shared = { host = 'db' }

    ring.self = ring

    t.assert_equals(shown(ring), { id = 7, self = '[кольцо]' })
    t.assert_equals(shown({ left = shared, right = shared }), { left = { host = 'db' }, right = { host = 'db' } })
end

g.test_a_table_goes_through_its_serialize = function()
    local object = setmetatable({ hidden = 1 }, {
        __serialize = function()
            return { password = 'hunter2', ok = 1 }
        end,
    })
    local inside = setmetatable({}, {
        __serialize = function(self)
            return { self }
        end,
    })

    t.assert_equals(shown(object), { password = HIDDEN, ok = 1 })
    t.assert_equals(shown(inside), { '[кольцо]' })
end

g.test_a_serialize_that_throws_is_said_so = function()
    local object = setmetatable({}, {
        __serialize = function()
            error('бросил')
        end,
    })

    t.assert_equals(shown(object), '[__serialize бросил]')
end

g.test_a_serialize_that_is_not_a_function_leaves_an_ordinary_table = function()
    t.assert_equals(shown(setmetatable({ 1, 2 }, { __serialize = 'seq' })), { 1, 2 })
end

g.test_a_table_with_tostring_is_printed = function()
    local printable = setmetatable({ secret_inside = 'hunter2' }, {
        __tostring = function()
            return 'объект token=hunter2'
        end,
    })
    local numeric = setmetatable({}, {
        __tostring = function()
            -- Нарочно не строка: LuaJIT отдаёт из tostring что вернули.
            ---@diagnostic disable-next-line: return-type-mismatch
            return 42
        end,
    })
    local poisoned = setmetatable({}, {
        __tostring = function()
            ---@diagnostic disable-next-line: return-type-mismatch
            return POISON
        end,
    })
    local throwing = setmetatable({}, {
        __tostring = function()
            error('бросил')
        end,
    })

    t.assert_equals(shown(printable), 'объект token=' .. HIDDEN)
    t.assert_equals(shown(numeric), '[__tostring бросил]')
    t.assert_equals(shown(poisoned), '[__tostring бросил]')
    t.assert_equals(shown(throwing), '[__tostring бросил]')
end

g.test_printing_that_gives_no_string_is_named_by_kind = function()
    local proxy = newproxy(true)

    getmetatable(proxy).__tostring = function()
        return POISON
    end

    t.assert_equals(shown(Poisoned({ 1 })), '[cdata]')
    t.assert_equals(shown(proxy), '[userdata]')
end

g.test_sixteen_levels_pass_and_the_seventeenth_does_not = function()
    g.log.new('tnt.pool').info('m', chain(16))

    local at = last().fields

    for _ = 2, 15 do
        at = at.x
    end

    t.assert_equals(at.x, {})
    t.assert_equals(last().truncated, nil)

    g.log.new('tnt.pool').info('m', chain(17))

    at = last().fields

    for _ = 2, 16 do
        at = at.x
    end

    t.assert_equals(at.x, '[глубже]')
    t.assert_equals(last().truncated, true)
end

g.test_a_serialize_counts_as_a_level = function()
    local object = setmetatable({}, {
        __serialize = function()
            return { ok = true }
        end,
    })

    g.log.new('tnt.pool').info('m', placed(15, object))
    t.assert_equals(reached(last().fields, 15), { ok = true })

    g.log.new('tnt.pool').info('m', placed(16, object))
    t.assert_equals(reached(last().fields, 16), '[глубже]')
end

g.test_a_serialize_that_never_ends_stops_at_the_depth_limit = function()
    local endless = {}

    endless.__serialize = function()
        return { next = setmetatable({}, endless) }
    end

    g.log.new('tnt.pool').info('m', { v = setmetatable({}, endless) })

    t.assert_equals(last().truncated, true)
    t.assert_str_contains(json.encode(last().fields), '[глубже]')
end

g.test_a_serialize_that_returns_a_fresh_self_stops_at_the_depth_limit = function()
    local endless = {}

    endless.__serialize = function()
        return setmetatable({}, endless)
    end

    local proxy = newproxy(true)

    getmetatable(proxy).__serialize = function()
        return newproxy(proxy)
    end

    local pool = g.log.new('tnt.pool')

    pool.info('m', { v = setmetatable({}, endless) })
    pool.info('m', { v = proxy })
    pool.info(setmetatable({}, endless))

    t.assert_equals(argument_at(1), { message = 'm', fields = { v = '[глубже]' }, truncated = true })
    t.assert_equals(argument_at(2), { message = 'm', fields = { v = '[глубже]' }, truncated = true })
    t.assert_equals(argument_at(3), { message = '[глубже]', truncated = true })
end

g.test_a_serialize_at_the_last_level_still_speaks = function()
    -- На шестнадцатом уровне `__serialize` ещё зовётся: строка, которую он
    -- отдал, лежит на семнадцатом, а строке глубина не страшна.
    local object = setmetatable({}, {
        __serialize = function()
            return 'ok'
        end,
    })

    g.log.new('tnt.pool').info('m', placed(16, object))

    t.assert_equals(reached(last().fields, 16), 'ok')
    t.assert_equals(last().truncated, nil)

    g.log.new('tnt.pool').info('m', placed(17, object))

    t.assert_equals(reached(last().fields, 17), '[глубже]')
    t.assert_equals(last().truncated, true)
end

g.test_a_message_table_has_the_same_depth_limit = function()
    local pool = g.log.new('tnt.pool')

    pool.info(chain(16))
    pool.info(chain(17))

    t.assert_not_str_contains(argument_at(1).message, '[глубже]')
    t.assert_equals(argument_at(1).truncated, nil)
    t.assert_str_contains(argument_at(2).message, '[глубже]')
    t.assert_equals(argument_at(2).truncated, true)
end

g.test_keys_that_json_cannot_hold_become_strings = function()
    t.assert_equals(
        shown({ [true] = 'b', [1.5] = 'f', [1] = 'i', s = 'x' }),
        { ['true'] = 'b', ['1.5'] = 'f', ['1'] = 'i', s = 'x' }
    )
    t.assert_equals(shown({ [math.huge] = 'x', [-math.huge] = 'y' }), { inf = 'x', ['-inf'] = 'y' })

    t.assert_equals(shown({ [true] = 'b', [1] = 'i' }), { ['true'] = 'b', ['1'] = 'i' })

    -- Целое вне ±2^53 ядро ключом не принимает: оно бросает на нём
    -- «table key must be a number or string».
    t.assert_equals(shown({ [2 ^ 53] = 'a', [-2 ^ 53] = 'b' }), { [2 ^ 53] = 'a', [-2 ^ 53] = 'b' })
    t.assert_equals(shown({ [2 ^ 54] = 'a' }), { ['1.8014398509482e+16'] = 'a' })
    t.assert_equals(shown({ [-2 ^ 54] = 'a' }), { ['-1.8014398509482e+16'] = 'a' })
    t.assert_equals(shown({ [1e300] = 'a' }), { ['1e+300'] = 'a' })

    local merged = shown({ [1] = 'число', ['1'] = 'строка' })

    t.assert_equals(type(next(merged)), 'string')
    t.assert_equals(next(merged, next(merged)), nil)
end

g.test_string_keys_are_checked_scrubbed_and_cut = function()
    local long = string.rep('k', 4097)
    local value = shown({ ['\xff'] = 1, [long] = 2, ['http://root:hunter2@db'] = 3 })

    t.assert_equals(value, {
        ['[не UTF-8, 1 байт]'] = 1,
        [string.rep('k', 4096) .. '…'] = 2,
        ['http://root:' .. HIDDEN .. '@db'] = 3,
    })
    t.assert_equals(last().truncated, true)
end

g.test_a_key_is_printed_safely = function()
    local function keyed(printing)
        return setmetatable({}, { __tostring = printing })
    end

    local throwing = keyed(function()
        error('бросил')
    end)
    local odd = keyed(function()
        return POISON
    end)
    local secret = keyed(function()
        return 'token=hunter2'
    end)
    local broken = keyed(function()
        return '\xff\xfe'
    end)

    t.assert_equals(shown({ [throwing] = 1 }), { ['[table]'] = 1 })
    t.assert_equals(shown({ [odd] = 1 }), { ['[table]'] = 1 })
    -- Напечатанное имя похоже на тайну, и значение под ним спрятано.
    t.assert_equals(shown({ [secret] = 1 }), { ['token=' .. HIDDEN] = HIDDEN })
    t.assert_equals(shown({ [broken] = 1 }), { ['[не UTF-8, 2 байт]'] = 1 })
    t.assert_equals(shown({ [Unprintable({ 1 })] = 1 }), { ['[cdata]'] = 1 })
end

g.test_a_key_is_taken_for_a_secret_by_the_name_it_prints = function()
    local password = setmetatable({}, {
        __tostring = function()
            return 'password'
        end,
    })

    -- В записи ключ выглядит как `password`, и значение под ним — тайна.
    t.assert_equals(shown({ [password] = 'hunter2' }), { password = HIDDEN })

    -- Подсказка в конце ключа длиннее потолка: обрезка её отрезает,
    -- а решение принято по ключу до обрезки.
    local long = string.rep('k', 5000) .. '_token'

    t.assert_equals(shown({ [long] = 'hunter2' }), { [string.rep('k', 4096) .. '…'] = HIDDEN })
end

g.test_a_long_printed_key_is_cut_and_counted = function()
    local long = setmetatable({}, {
        __tostring = function()
            return string.rep('k', 20000)
        end,
    })

    t.assert_equals(shown({ [long] = 1 }), { [string.rep('k', 4096) .. '…'] = 1 })
    t.assert_equals(last().truncated, true)

    -- Ключ из управляющих знаков вшестеро длиннее в JSON: без учёта его
    -- длины оценка поручилась бы за запись, которая не лезет в буфер.
    local escaping = setmetatable({}, {
        __tostring = function()
            return string.rep('\1', 3000)
        end,
    })

    g.log.new('tnt.pool').info('m', { [escaping] = 1 })

    t.assert_equals(last(), { message = 'm', truncated = true })
end

-- ── Размер ───────────────────────────────────────────────────────────

--- Поля из одинаковых по цене пар «ключ = 1».
---
--- Пара стоит в оценке длину ключа плюс восемь: ключ (длина + 4)
--- и число (4). Одинаковые пары нужны потому, что порядок обхода
--- таблицы не задан, а оценка «перед последним ключом» должна выходить
--- одной при любом порядке.
---@param count integer
---@param template string Образец ключа для `format`
---@return table
local function priced(count, template)
    local fields = {}

    for index = 1, count do
        fields[template:format(index)] = 1
    end

    return fields
end

g.test_the_walk_goes_on_while_the_estimate_is_exactly_the_limit = function()
    -- Перед последним ключом оценка ровно 15000: таблица полей (4) и 652
    -- пары по 23 — ключ из пятнадцати знаков. Сообщение обходу полей
    -- не предшествует: оно считается после них, вместе с подставленными
    -- заполнителями.
    g.log.new('tnt.pool').info('abc', priced(653, 'k%014d'))

    t.assert_equals(last().message, 'abc')
    t.assert_equals(last().truncated, nil)
    t.assert_equals(last().fields, priced(653, 'k%014d'))
end

g.test_the_walk_stops_once_the_estimate_is_over_the_limit = function()
    -- Перед последним ключом ровно 15001: таблица полей (4), ключ `i` (5),
    -- вложенная таблица (4) и 1249 пар по 12 — ключ из четырёх цифр.
    -- Плоской таблицей на 15001 не попасть: 14997 на равные пары
    -- не делится. JSON такой записи короче потолка, и поля отбрасывает
    -- именно остановка обхода.
    g.log.new('tnt.pool').info('abc', { i = priced(1250, '%04d') })

    t.assert_equals(last(), { message = 'abc', truncated = true })
end

g.test_a_wide_table_is_not_walked_to_the_end = function()
    local counter = { calls = 0 }
    local wide = {}

    for index = 1, 60000 do
        wide['k' .. index] = counted(counter)
    end

    g.log.new('tnt.pool').warn('широкая', wide)

    t.assert_equals(last(), { message = 'широкая', truncated = true })
    t.assert_lt(counter.calls, 2000)
end

--- Поля из четырёх строк, JSON записи с которыми длиной ровно `size`.
---@param size integer
---@return table
local function sized(size)
    local fields = { b = string.rep('x', 4096), c = string.rep('x', 4096), d = string.rep('x', 4096) }

    -- Пара `"a":"…",` добавляет к JSON семь байт сверх самой строки.
    fields.a = string.rep('x', size - #json.encode({ message = 'm', fields = fields }) - 7)

    t.assert_equals(#json.encode({ message = 'm', fields = fields }), size, 'подготовка записи')

    return fields
end

g.test_a_record_of_exactly_the_limit_keeps_its_fields = function()
    local fields = sized(15000)

    g.log.new('tnt.pool').info('m', fields)

    t.assert_equals(last(), { message = 'm', fields = fields })
end

g.test_a_record_one_byte_over_the_limit_loses_its_fields = function()
    g.log.new('tnt.pool').info('m', sized(15001))

    t.assert_equals(last(), { message = 'm', truncated = true })
end

g.test_escaping_is_counted_before_the_record_is_trusted = function()
    -- Оценка 2618 байт, а JSON вшестеро больше: каждый \1 стал \u0001.
    g.log.new('tnt.pool').info('m', { c = string.rep('\1', 2600) })

    t.assert_equals(last(), { message = 'm', truncated = true })
end

g.test_a_large_estimate_alone_does_not_drop_the_fields = function()
    local fields = { s = string.rep('x', 4000) }

    g.log.new('tnt.pool').info('m', fields)

    t.assert_equals(last(), { message = 'm', fields = fields })
end

g.test_the_fallback_record_keeps_a_short_clean_message = function()
    g.instance = 'router-001-a'

    local pool = g.log.new('tnt.pool')

    pool.info(string.rep('a', 1025), { c = string.rep('\1', 2600) })
    pool.info('раз\1два\nтри', { c = string.rep('\1', 2600) })

    t.assert_equals(
        argument_at(1),
        { message = string.rep('a', 1024) .. '…', instance_name = 'router-001-a', truncated = true }
    )
    t.assert_equals(
        argument_at(2),
        { message = 'раз?два?три', instance_name = 'router-001-a', truncated = true }
    )
end

g.test_a_message_table_cut_short_by_the_walk_is_marked = function()
    local numbers = {}

    for index = 1, 3000 do
        numbers[index] = 1
    end

    g.log.new('tnt.pool').info(numbers)

    -- Обход встал на середине, но JSON вышел короче потолка строки:
    -- отметку даёт остановка, а не обрезка.
    t.assert_lt(#last().message, 4096)
    t.assert_equals(last().truncated, true)
end

-- ── Вид plain ────────────────────────────────────────────────────────

g.test_render_orders_quotes_and_escapes = function()
    local line = g.log.render({
        message = 'строка\nвторая "как есть"',
        fields = {
            b = 'нет связи',
            a = 1,
            c = '',
            d = 'x=y',
            e = 'say "hi"',
            f = 'back\\slash',
            g = 'ctl\1',
            h = { 'p', 'q' },
            i = box.NULL,
            j = true,
            k = 9007199254740992,
            ['key with space'] = 'v',
            plain = 'ok',
        },
        suppressed = 2,
        truncated = true,
        instance_name = 'router-001-a',
    })

    t.assert_equals(
        line,
        'строка\\nвторая "как есть" suppressed=2 truncated=true a=1 b="нет связи" c="" d="x=y"'
            .. ' e="say \\"hi\\"" f="back\\\\slash" g="ctl\\u0001" h=["p","q"] i=null j=true'
            .. ' k=9007199254740992 "key with space"=v plain=ok'
    )
end

g.test_the_pairs_of_the_facade_come_before_the_pairs_of_the_caller = function()
    -- Поле вызывающего по имени `truncated` иначе было бы неотличимо
    -- от отметки фасада: пара фасада стоит сразу за сообщением.
    local line = g.log.render({ message = 'm', fields = { truncated = true, suppressed = 9 }, suppressed = 1 })

    t.assert_equals(line, 'm suppressed=1 suppressed=9 truncated=true')
end

g.test_render_of_a_bare_record_is_its_message = function()
    t.assert_equals(g.log.render({ message = 'пул готов' }), 'пул готов')
end

g.test_plain_never_prints_the_instance_name = function()
    g.settings = { level = 'debug', format = 'plain' }
    g.instance = 'router-001-a'

    g.log.new('tnt.pool').info('m', { a = 1 })

    t.assert_equals(last(), 'm a=1')
end

-- ── Уровень ──────────────────────────────────────────────────────────

g.test_the_level_is_checked_by_the_numbers_of_the_core = function()
    for level, number in pairs(LEVEL_NUMBERS) do
        for _, given in ipairs({ level, number }) do
            for method, severity in pairs(METHOD_NUMBERS) do
                local before = #g.written

                g.settings = { level = given, format = 'json' }
                g.log.new('tnt.pool')[method]('m')

                t.assert_equals(
                    #g.written - before,
                    severity <= number and 1 or 0,
                    ('%s при %s'):format(method, given)
                )
            end
        end
    end
end

g.test_a_module_level_wins_over_the_global_one = function()
    local pool = g.log.new('tnt.pool')
    local http = g.log.new('tnt.http')

    g.settings = { level = 'error', modules = { ['tnt.pool'] = 'debug' } }
    pool.debug('pool debug')
    http.warn('http warn')

    g.settings = { level = 'debug', modules = { ['tnt.pool'] = 4 } }
    pool.info('pool info')
    pool.warn('pool warn')
    http.info('http info')

    local messages = {}

    for _, entry in ipairs(g.written) do
        table.insert(messages, entry.argument.message)
    end

    t.assert_equals(messages, { 'pool debug', 'pool warn', 'http info' })
end

g.test_the_module_map_is_flat = function()
    g.settings = { level = 'info', modules = { tnt = 'debug' } }

    g.log.new('tnt.pool').debug('m')

    t.assert_equals(#g.written, 0)
end

g.test_a_missing_or_odd_module_value_falls_back_to_the_global_level = function()
    local pool = g.log.new('tnt.pool')

    for _, modules in ipairs({ box.NULL, { ['tnt.pool'] = true }, 'tnt.pool=debug' }) do
        g.settings = { level = 'warn', modules = modules }
        pool.info('m')
        pool.warn('m')
    end

    g.settings = { level = 'warn' }
    pool.info('m')
    pool.warn('m')

    t.assert_equals(#g.written, 4)
end

g.test_an_unknown_level_counts_as_info = function()
    local pool = g.log.new('tnt.pool')

    for _, settings in ipairs({
        { level = 'болтливый' },
        { level = true },
        {},
        { level = 'error', modules = { ['tnt.pool'] = 'болтливый' } },
    }) do
        g.settings = settings
        pool.debug('debug')
        pool.info('info')
    end

    t.assert_equals(#g.written, 4)

    for _, entry in ipairs(g.written) do
        t.assert_equals(entry.argument.message, 'info')
    end
end

g.test_a_dropped_record_is_not_even_built = function()
    local counter = { calls = 0 }
    local pool = g.log.new('tnt.pool')

    g.settings = { level = 'info' }
    pool.debug('m', { v = counted(counter) })

    t.assert_equals(counter.calls, 0)
    t.assert_equals(#g.written, 0)

    pool.info('m', { v = counted(counter) })

    t.assert_equals(counter.calls, 1)
end

-- ── Имя инстанса ─────────────────────────────────────────────────────

g.test_the_instance_name_goes_into_the_record = function()
    g.instance = 'router-001-a'

    g.log.new('tnt.pool').info('m')

    t.assert_equals(last(), { message = 'm', instance_name = 'router-001-a' })
end

g.test_the_instance_name_is_read_from_a_configured_box = function()
    g.log._set_source({
        logger = recorder(g.written),
        settings = function()
            return g.settings
        end,
    })

    local pool = g.log.new('tnt.pool')

    with_box_cfg({ instance_name = 'router-001-a' }, function()
        pool.info('названный')
    end)
    with_box_cfg({ instance_name = '' }, function()
        pool.info('пустое имя')
    end)
    with_box_cfg({ instance_name = 42 }, function()
        pool.info('не строка')
    end)
    with_box_cfg(function() end, function()
        pool.info('до настройки')
    end)

    t.assert_equals(argument_at(1), { message = 'названный', instance_name = 'router-001-a' })
    t.assert_equals(argument_at(2), { message = 'пустое имя' })
    t.assert_equals(argument_at(3), { message = 'не строка' })
    t.assert_equals(argument_at(4), { message = 'до настройки' })
end

-- ── Внешние зависимости ──────────────────────────────────────────────

g.test_a_journal_made_before_the_replacement_writes_into_it = function()
    local fresh = helper.load()
    local early = fresh.new('tnt.pool')
    local written = {}

    fresh._set_source({
        logger = recorder(written),
        settings = function()
            return { level = 'debug', format = 'json' }
        end,
    })

    early.info('m')

    t.assert_equals(written, { { module = 'tnt.pool', level = 'info', argument = { message = 'm' } } })
end

g.test_an_unknown_tool_in_the_replacement_is_refused = function()
    t.assert_error_msg_contains(
        'нет такой внешней зависимости: sink',
        g.log._set_source,
        { sink = print }
    )
end

g.test_the_real_settings_and_core_are_used_by_default = function()
    -- Настоящая настройка процесса проверок: ошибка проходит при любом
    -- разумном уровне, а вид берётся у ядра.
    g.log._set_source({ logger = recorder(g.written) })
    g.log.new('tnt.pool').error('настоящая настройка', { a = 1 })

    local expected = { message = 'настоящая настройка', fields = { a = 1 } }

    if require('log').cfg.format == 'plain' then
        expected = g.log.render(expected)
    end

    t.assert_equals(last(), expected)

    -- Настоящий журнал ядра: запись уходит без исключения.
    g.log._set_source(nil)
    g.log.new('tnt.log.test').info('проверка настоящего журнала', { a = 1 })
end

-- ── Подавление повторов ──────────────────────────────────────────────

g.test_a_repeated_record_is_written_once = function()
    local changes = g.log.changes('tnt.failover')

    for _ = 1, 3 do
        changes.warn('назначение не прочитано', { err = 'нет связи' })
    end

    t.assert_equals(#g.written, 1)
    t.assert_equals(g.written[1].module, 'tnt.failover')
end

g.test_the_record_that_breaks_a_series_says_how_many_were_suppressed = function()
    local changes = g.log.changes('tnt.failover')

    for _ = 1, 3 do
        changes.warn('назначение не прочитано', { err = 'нет связи' })
    end

    changes.info('лидером назначен сосед', { leader = 'storage-001-a' })

    t.assert_equals(argument_at(2), {
        message = 'лидером назначен сосед',
        fields = { leader = 'storage-001-a' },
        suppressed = 2,
    })
end

g.test_the_counter_is_rendered_in_plain_too = function()
    g.settings = { level = 'debug', format = 'plain' }

    local changes = g.log.changes('tnt.failover')

    changes.info('назначение прочитано', { leader = 'a' })
    changes.info('назначение прочитано', { leader = 'a' })
    changes.info('назначение сменилось', { leader = 'b' })

    t.assert_equals(g.written[2].argument, 'назначение сменилось suppressed=1 leader=b')
end

g.test_another_reason_or_level_is_not_a_repeat = function()
    local changes = g.log.changes('tnt.failover')

    changes.warn('назначение не прочитано', { err = 'нет связи' })
    changes.warn('назначение не прочитано', { err = 'отказано в доступе' })
    changes.info('назначение не прочитано', { err = 'отказано в доступе' })

    t.assert_equals(#g.written, 3)
    t.assert_equals(argument_at(3).suppressed, nil)
end

g.test_a_record_that_came_back_is_written_again = function()
    local changes = g.log.changes('tnt.failover')

    changes.warn('назначение не прочитано', { err = 'нет связи' })
    changes.info('назначение прочитано')
    changes.warn('назначение не прочитано', { err = 'нет связи' })

    t.assert_equals(#g.written, 3)
end

g.test_equal_tables_are_a_repeat_and_different_ones_are_not = function()
    local changes = g.log.changes('tnt.failover')

    changes.warn('состав', { peers = { 'storage-001-a' } })
    changes.warn('состав', { peers = { 'storage-001-a' } })
    changes.warn('состав', { peers = { 'storage-001-b' } })

    t.assert_equals(#g.written, 2)
    t.assert_equals(argument_at(2).suppressed, 1)
end

g.test_the_series_does_not_touch_the_caller_fields = function()
    local changes = g.log.changes('tnt.failover')
    local fields = { err = 'нет связи' }

    changes.warn('назначение не прочитано', fields)
    changes.warn('назначение не прочитано', fields)
    changes.warn('другое', fields)

    t.assert_equals(fields, { err = 'нет связи' })
    t.assert_equals(argument_at(2).suppressed, 1)
end

g.test_every_journal_counts_on_its_own = function()
    local first = g.log.changes('tnt.failover')
    local second = g.log.changes('tnt.cluster')

    first.warn('одно и то же')
    second.warn('одно и то же')

    t.assert_equals(#g.written, 2)
    t.assert_equals(g.written[2].module, 'tnt.cluster')
end

g.test_a_record_dropped_by_level_neither_breaks_nor_extends_a_series = function()
    local changes = g.log.changes('tnt.failover')

    g.settings = { level = 'info' }
    changes.info('такт')
    changes.debug('отладка между тактами')
    changes.info('такт')
    changes.info('готово')

    t.assert_equals(#g.written, 2)
    t.assert_equals(argument_at(2), { message = 'готово', suppressed = 1 })
end

g.test_a_ring_in_the_fields_does_not_take_the_series_down = function()
    local changes = g.log.changes('tnt.failover')
    local ring = {}

    ring.self = ring

    changes.warn('кольцо', { ring = ring })
    changes.warn('кольцо', { ring = ring })

    t.assert_equals(argument_at(1).fields, { ring = { self = '[кольцо]' } })
    t.assert_equals(#g.written, 1)
end

-- ── Контекст ─────────────────────────────────────────────────────────

--- Подменяет средство контекста двойником: поля берутся из того, что
--- положили, а не из области файбера.
---@return fun(fields: any) Положить поля для следующих записей
local function ambient_double()
    local ambient = nil

    g.log._set_source({
        logger = recorder(g.written),
        settings = function()
            return g.settings
        end,
        context = function()
            return ambient
        end,
    })

    return function(fields)
        ambient = fields
    end
end

--- Ключи трассы и ключ приложения — как их объявят пакет трассы и владелец.
local function declare_context_keys()
    for _, name in ipairs({ 'trace_id', 'span_id', 'trace_flags', 'user', 'zone' }) do
        g.context.declare(name)
    end
end

--- Значения области, в которой пишутся записи о запросе в трассе.
local IN_TRACE = {
    request_id = 'r-7',
    trace_id = string.rep('a', 32),
    span_id = string.rep('b', 16),
    trace_flags = '01',
    user = 'ivan',
    zone = 'eu',
}

g.test_the_context_of_the_fiber_goes_into_the_record_on_top_and_under_context = function()
    declare_context_keys()

    local pool = g.log.new('tnt.pool')

    g.context.run(IN_TRACE, function()
        pool.info('в области', { a = 1, request_id = 'чужой' })
    end)
    pool.info('вне области', { a = 1 })

    t.assert_equals(argument_at(1), {
        message = 'в области',
        fields = { a = 1, request_id = 'чужой' },
        request_id = 'r-7',
        trace_id = string.rep('a', 32),
        span_id = string.rep('b', 16),
        trace_flags = '01',
        context = { user = 'ivan', zone = 'eu' },
    })
    t.assert_equals(argument_at(2), { message = 'вне области', fields = { a = 1 } })
end

g.test_only_the_identifiers_are_on_top_when_there_is_nothing_else = function()
    g.context.run({ request_id = 'r-7' }, function()
        g.log.new('tnt.pool').info('m')
    end)

    t.assert_equals(last(), { message = 'm', request_id = 'r-7' })
end

g.test_context_values_go_through_the_same_secrets_and_limits_as_fields = function()
    ambient_double()({
        request_id = 'r-7 token=hunter2',
        trace_id = string.rep('я', 3000),
        context = {
            token = 'hunter2',
            url = 'postgres://root:hunter2@db',
            ['db-password'] = 'hunter2',
            nan = 0 / 0,
        },
    })

    g.log.new('tnt.pool').info('m')

    local record = last()

    t.assert_equals(record.request_id, 'r-7 token=' .. HIDDEN)
    t.assert_equals(record.trace_id, string.rep('я', 2048) .. '…')
    t.assert_equals(record.truncated, true)
    t.assert_equals(record.context, {
        token = HIDDEN,
        url = 'postgres://root:' .. HIDDEN .. '@db',
        ['db-password'] = HIDDEN,
        nan = 'nan',
    })
    t.assert_equals(leaks(record, 'hunter2'), false)
end

g.test_the_context_has_the_same_depth_limit_as_the_fields = function()
    local put = ambient_double()

    -- Поля контекста — первый уровень, объект `context` — второй, цепочка
    -- из четырнадцати таблиц доходит до шестнадцатого и показывается вся.
    put({ context = { deep = chain(14) } })
    g.log.new('tnt.pool').info('m')

    t.assert_equals(last().context, { deep = chain(14) })
    t.assert_equals(last().truncated, nil)

    put({ context = { deep = chain(15) } })
    g.log.new('tnt.pool').info('m')

    local deep = last().context.deep

    for _ = 2, 14 do
        deep = deep.x
    end

    t.assert_equals(deep, { x = '[глубже]' })
    t.assert_equals(last().truncated, true)
end

g.test_a_context_tool_that_gives_something_else_than_fields_is_ignored = function()
    local put = ambient_double()

    for _, given in ipairs({ 'строка', 42, { context = 'строка' }, { context = 7, request_id = 'r' } }) do
        put(given)
        g.log.new('tnt.pool').info('m')
    end

    t.assert_equals(argument_at(1), { message = 'm' })
    t.assert_equals(argument_at(2), { message = 'm' })
    t.assert_equals(argument_at(3), { message = 'm' })
    t.assert_equals(argument_at(4), { message = 'm', request_id = 'r' })
end

g.test_the_context_counts_towards_the_record_limit = function()
    local pool = g.log.new('tnt.pool')

    -- Ровно потолок вместе с парой `"request_id":"r"` — семнадцать байт.
    g.context.run({ request_id = 'r' }, function()
        pool.info('m', sized(15000 - 17))
    end)

    t.assert_equals(last().truncated, nil)
    t.assert_equals(last().request_id, 'r')
    t.assert_equals(#json.encode(last()), 15000)

    g.context.run({ request_id = 'r' }, function()
        pool.info('m', sized(15000 - 16))
    end)

    t.assert_equals(last(), { message = 'm', request_id = 'r', truncated = true })
end

g.test_the_fallback_record_keeps_the_identifiers_but_not_the_context = function()
    declare_context_keys()

    g.instance = 'router-001-a'

    g.context.run(IN_TRACE, function()
        g.log.new('tnt.pool').info(string.rep('a', 1025), { c = string.rep('\1', 2600) })
    end)

    t.assert_equals(last(), {
        message = string.rep('a', 1024) .. '…',
        instance_name = 'router-001-a',
        request_id = 'r-7',
        trace_id = string.rep('a', 32),
        span_id = string.rep('b', 16),
        trace_flags = '01',
        truncated = true,
    })
end

g.test_the_fallback_record_of_a_wide_table_still_carries_the_identifiers = function()
    local wide = {}

    for index = 1, 60000 do
        wide['k' .. index] = index
    end

    g.context.run({ request_id = 'r-7' }, function()
        g.log.new('tnt.pool').warn('широкая', wide)
    end)

    t.assert_equals(last(), { message = 'широкая', request_id = 'r-7', truncated = true })
end

g.test_a_series_is_not_broken_by_the_context = function()
    declare_context_keys()

    local changes = g.log.changes('tnt.failover')

    g.context.run({ request_id = 'a', user = 'ivan' }, function()
        changes.warn('назначение не прочитано', { err = 'нет связи' })
    end)
    g.context.run({ request_id = 'b', user = 'petr' }, function()
        changes.warn('назначение не прочитано', { err = 'нет связи' })
    end)
    g.context.run({ request_id = 'c' }, function()
        changes.info('назначение прочитано')
    end)

    t.assert_equals(#g.written, 2)
    t.assert_equals(argument_at(1).request_id, 'a')
    t.assert_equals(argument_at(1).context, { user = 'ivan' })
    t.assert_equals(
        argument_at(2),
        { message = 'назначение прочитано', request_id = 'c', suppressed = 1 }
    )
end

g.test_plain_prints_the_identifiers_and_the_context_after_the_pairs_of_the_caller = function()
    declare_context_keys()

    g.settings = { level = 'debug', format = 'plain' }

    g.context.run(IN_TRACE, function()
        g.log.new('tnt.pool').info('m', { b = 2, a = 1 })
    end)

    t.assert_equals(
        last(),
        'm a=1 b=2 request_id=r-7 trace_id='
            .. string.rep('a', 32)
            .. ' span_id='
            .. string.rep('b', 16)
            .. ' context.user=ivan context.zone=eu'
    )
end

g.test_render_prints_the_context_last_and_leaves_out_the_trace_flags = function()
    t.assert_equals(
        g.log.render({
            message = 'm',
            fields = { truncated = 'да' },
            suppressed = 2,
            request_id = 'r 7',
            trace_id = 't',
            span_id = 's',
            trace_flags = '01',
            context = { zone = 'eu', ['user name'] = 'ivan petrov' },
        }),
        'm suppressed=2 truncated=да request_id="r 7" trace_id=t span_id=s '
            .. 'context."user name"="ivan petrov" context.zone=eu'
    )
    t.assert_equals(g.log.render({ message = 'm', span_id = 's' }), 'm span_id=s')
    t.assert_equals(g.log.render({ message = 'm', context = {} }), 'm')
end

-- ── Служебные ключи ──────────────────────────────────────────────────

g.test_caller_fields_named_like_ours_stay_inside_fields = function()
    local allowed = {
        message = true,
        fields = true,
        args = true,
        instance_name = true,
        suppressed = true,
        truncated = true,
    }
    local changes = g.log.changes('tnt.failover')

    g.instance = 'router-001-a'
    changes.warn('наше', helper.SPECIAL)
    changes.warn('наше', helper.SPECIAL)
    changes.warn('снова наше', helper.SPECIAL)

    for index = 1, 2 do
        local record = argument_at(index)

        t.assert_equals(record.fields, helper.SPECIAL)

        for key in pairs(record) do
            t.assert_equals(allowed[key], true, key)
        end
    end

    t.assert_equals(argument_at(1).message, 'наше')
    t.assert_equals(argument_at(2).message, 'снова наше')
    t.assert_equals(argument_at(2).instance_name, 'router-001-a')
    t.assert_equals(argument_at(2).suppressed, 1)
end

-- ── Тайны ────────────────────────────────────────────────────────────

g.test_no_secret_reaches_the_core_in_json = function()
    helper.write_secrets(g.log)

    t.assert_equals(#g.written, 19)
    t.assert_equals(leaks(g.written, 'hunter2'), false)
    t.assert_equals(argument_at(19).suppressed, 1)
    t.assert_equals(argument_at(3).fields, { request = { headers = { ['X-Api-Key'] = HIDDEN } } })
    t.assert_equals(argument_at(6).fields, { ['api-key'] = HIDDEN })
    t.assert_equals(argument_at(17), {
        message = 'вход ivan с паролем ' .. HIDDEN .. ' по postgres://root:' .. HIDDEN .. '@db',
        fields = { user = 'ivan', password = HIDDEN, url = 'postgres://root:' .. HIDDEN .. '@db' },
        args = { 'token=' .. HIDDEN, { password = HIDDEN } },
    })
end

g.test_no_secret_reaches_the_core_in_plain = function()
    g.settings = { level = 'debug', format = 'plain' }

    helper.write_secrets(g.log)

    t.assert_equals(#g.written, 19)
    t.assert_equals(leaks(g.written, 'hunter2'), false)
    t.assert_equals(argument_at(1), 'm password=' .. HIDDEN)
    t.assert_equals(
        argument_at(17),
        'вход ivan с паролем '
            .. HIDDEN
            .. ' по postgres://root:'
            .. HIDDEN
            .. '@db args=["token='
            .. HIDDEN
            .. '",{"password":"'
            .. HIDDEN
            .. '"}] password='
            .. HIDDEN
            .. ' url=postgres://root:'
            .. HIDDEN
            .. '@db user=ivan'
    )
end

g.test_no_disguised_secret_reaches_the_core = function()
    helper.write_disguised(g.log)

    t.assert_equals(#g.written, 44)

    g.settings = { level = 'debug', format = 'plain' }

    helper.write_disguised(g.log)

    t.assert_equals(#g.written, 88)
    t.assert_equals(leaks(g.written, 'hunter2'), false)
end

g.test_a_harmless_pair_does_not_swallow_the_secret_after_it = function()
    local expected = {
        'request failed: https://api.example.com/v1/users?access_token=' .. HIDDEN,
        'GET https://api.example.com/v1/users?access_token=' .. HIDDEN .. ' failed: timeout',
        'url=https://api.example.com/v1?api_key=' .. HIDDEN,
        'redirect_uri=https://app/cb?token=' .. HIDDEN,
        'next=/login?token=' .. HIDDEN,
        'url: https://api/x?api_key=' .. HIDDEN,
        '{"url":"https://h/?token=' .. HIDDEN .. '"}',
        'db:password=' .. HIDDEN,
        'error: password=' .. HIDDEN,
        'error:password=' .. HIDDEN,
        'config: token=' .. HIDDEN,
        'webhook=https://hooks.example.com/services?secret=' .. HIDDEN .. '&x=1',
        'connect to http://storage:' .. HIDDEN .. '@10.0.0.5 failed',
        'status=401 url=/enter?token=' .. HIDDEN,
        'status:401 path:/enter?token=' .. HIDDEN,
        'Location: https://app/cb#access_token=' .. HIDDEN .. '&token_type=' .. HIDDEN,
        'Referer: https://app/page?session_token=' .. HIDDEN,
        'curl error: http://u:' .. HIDDEN .. '@h/?token=' .. HIDDEN,
    }

    t.assert_equals(#helper.SWALLOWED, #expected)

    for index, text in ipairs(helper.SWALLOWED) do
        t.assert_equals(g.log.scrub(text), expected[index], text)
    end
end

g.test_what_the_former_rule_hid_stays_hidden = function()
    local expected = {
        'password=' .. HIDDEN,
        'password=' .. HIDDEN,
        'http://user:' .. HIDDEN .. '@host/p?token=' .. HIDDEN,
        'secret(1)=' .. HIDDEN,
        'token/x=' .. HIDDEN,
        'x:token=' .. HIDDEN,
        'ns:password=' .. HIDDEN,
    }

    t.assert_equals(#helper.FORMERLY_HIDDEN, #expected)

    for index, text in ipairs(helper.FORMERLY_HIDDEN) do
        t.assert_equals(g.log.scrub(text), expected[index], text)
    end
end

g.test_a_quote_that_does_not_close_hides_everything_after_it = function()
    t.assert_equals(g.log.scrub('password="' .. helper.WORDS), 'password="' .. HIDDEN)

    -- Кавычка закрыта за окном: в окне она незакрытая, и прячется всё
    -- до конца окна, а не первое слово.
    local prefix = string.rep('a', 4000) .. ' password="'

    t.assert_equals(shown(prefix .. helper.WORDS .. '"'), prefix .. HIDDEN)
    t.assert_equals(last().truncated, true)

    -- Закрытая в окне кавычка остаётся на месте, как и то, что за ней.
    t.assert_equals(g.log.scrub('password="a b" c'), 'password="' .. HIDDEN .. '" c')
    t.assert_equals(g.log.scrub("password='a'"), "password='" .. HIDDEN .. "'")
    -- Прятать в пустых кавычках нечего.
    t.assert_equals(g.log.scrub('password="" c'), 'password="" c')
end

g.test_a_json_written_as_a_string_inside_json_hides_its_secrets = function()
    -- Экранированную кавычку закрывает экранированная, а не первая попавшаяся.
    t.assert_equals(
        g.log.scrub('{\\"access_token\\":\\"hun"ter2\\",\\"a\\":1}'),
        '{\\"access_token\\":\\"' .. HIDDEN .. '\\",\\"a\\":1}'
    )
    t.assert_equals(
        g.log.scrub('{"body":"{\\"access_token\\":\\"hunter2\\"}"}'),
        '{"body":"{\\"access_token\\":\\"' .. HIDDEN .. '\\"}"}'
    )
    t.assert_equals(g.log.scrub('token=\\"a b\\" c'), 'token=\\"' .. HIDDEN .. '\\" c')
    t.assert_equals(g.log.scrub('token=\\"a b'), 'token=\\"' .. HIDDEN)
end

g.test_a_pair_is_hidden_before_an_address_can_eat_its_name = function()
    local expected = {
        'db:password=' .. HIDDEN,
        'error:password=' .. HIDDEN,
        'config:token=' .. HIDDEN,
        'error: db:password=' .. HIDDEN,
        'x:y:password=' .. HIDDEN,
        'path:x?token=' .. HIDDEN,
        '{db:password=' .. HIDDEN,
        'redis:password=' .. HIDDEN,
    }

    t.assert_equals(#helper.AT_IN_VALUE, #expected)

    for index, text in ipairs(helper.AT_IN_VALUE) do
        t.assert_equals(g.log.scrub(text), expected[index], text)
    end

    -- Адрес внутри безобидной пары прячется так же, как без неё.
    t.assert_equals(g.log.scrub('url=replicator:hunter2@h'), 'url=replicator:' .. HIDDEN .. '@h')
end

g.test_an_authorization_value_is_hidden_to_the_end_of_the_line = function()
    local expected = {
        'Authorization: ' .. HIDDEN,
        'Authorization: ' .. HIDDEN,
        'Authorization: ' .. HIDDEN,
        'Authorization: ' .. HIDDEN,
        'Authorization: ' .. HIDDEN,
        'Authorization: ' .. HIDDEN,
        'Authorization:' .. HIDDEN,
        'Proxy-Authorization: ' .. HIDDEN,
    }

    t.assert_equals(#helper.AUTHORIZATION, #expected)

    for index, text in ipairs(helper.AUTHORIZATION) do
        t.assert_equals(g.log.scrub(text), expected[index], text)
    end

    -- Следующая строка текста остаётся на виду, и перевод строки тоже.
    t.assert_equals(
        g.log.scrub('Authorization: OAuth hunter2\nAccept: */*'),
        'Authorization: ' .. HIDDEN .. '\nAccept: */*'
    )
    t.assert_equals(
        g.log.scrub('Host: h\r\nAuthorization: Bot hunter2\r\nAccept: */*'),
        'Host: h\r\nAuthorization: ' .. HIDDEN .. '\r\nAccept: */*'
    )
    -- Значение в кавычках кончается на кавычке, как у любой пары.
    t.assert_equals(
        g.log.scrub('{"Authorization":"OAuth hunter2","Accept":"*/*"}'),
        '{"Authorization":"' .. HIDDEN .. '","Accept":"*/*"}'
    )
    -- Прятать нечего.
    t.assert_equals(g.log.scrub('Authorization:'), 'Authorization:')
end

g.test_an_escaped_quote_does_not_close_a_quoted_value = function()
    -- Длинные скобки: косые в тексте ровно те, что написаны.
    local hidden = {
        -- Кавычка после одной косой экранирована, после двух — закрывает.
        [ [[{"login":"u","password":"hun\"ter2"}]] ] = '{"login":"u","password":"' .. HIDDEN .. '"}',
        [ [[password="a\\" c]] ] = 'password="' .. HIDDEN .. '" c',
        [ [[password="\\" c]] ] = 'password="' .. HIDDEN .. '" c',
        [ [[password="x\"" c]] ] = 'password="' .. HIDDEN .. '" c',
        [ [[password="\" c]] ] = 'password="' .. HIDDEN,
        -- JSON строкой внутри JSON: три косые — кавычка внутреннего значения,
        -- одна и пять — закрывающая.
        [ [[{\"token\":\"hun\\\"ter2\"}]] ] = [[{\"token\":\"]] .. HIDDEN .. [[\"}]],
        [ [[{\"token\":\"a\\\\\"}]] ] = [[{\"token\":\"]] .. HIDDEN .. [[\"}]],
    }

    for given, expected in pairs(hidden) do
        t.assert_equals(g.log.scrub(given), expected, given)
    end
end

g.test_a_value_that_starts_right_after_a_hidden_one_is_checked_too = function()
    -- Значение `Cookie` кончается перед кавычкой, а с неё начинается
    -- значение `token` в два слова.
    t.assert_equals(g.log.scrub('Cookie: token="x y"'), 'Cookie: ' .. HIDDEN .. '"' .. HIDDEN .. '"')
end

g.test_a_name_added_to_the_list_hides_from_the_next_record = function()
    local pool = g.log.new('tnt.pool')

    pool.info('m', { door = 'hunter2' })
    table.insert(g.log.secret_hints, 'door')
    pool.info('m', { door = 'hunter2' })

    t.assert_equals(argument_at(1).fields, { door = 'hunter2' })
    t.assert_equals(argument_at(2).fields, { door = HIDDEN })
end

g.test_a_replaced_list_is_the_only_list = function()
    local pool = g.log.new('tnt.pool')

    g.log.secret_hints = { 'door' }
    pool.info('m', { door = 'x', password = 'y' })

    t.assert_equals(last().fields, { door = HIDDEN, password = 'y' })
end

g.test_a_name_changed_in_place_is_noticed_at_every_position = function()
    local pool = g.log.new('tnt.pool')
    local hints = g.log.secret_hints

    for position = 1, #hints do
        local original = hints[position]

        pool.info('m', { door = 'hunter2' })
        hints[position] = 'door'
        pool.info('m', { door = 'hunter2' })
        hints[position] = original
        pool.info('m', { door = 'hunter2', [original] = 'hunter2' })

        local from = #g.written - 2

        t.assert_equals(argument_at(from).fields, { door = 'hunter2' }, original)
        t.assert_equals(argument_at(from + 1).fields, { door = HIDDEN }, original)
        t.assert_equals(argument_at(from + 2).fields, { door = 'hunter2', [original] = HIDDEN }, original)
    end
end

g.test_a_checked_name_is_remembered = function()
    g.log.secret('password')

    t.assert_equals(
        lowered(function()
            g.log.secret('password')
        end),
        0
    )
end

g.test_names_in_a_string_without_any_hint_are_not_checked_one_by_one = function()
    -- Подсказки нет во всей строке — нет её и ни в одном имени: строка
    -- проверяется целиком один раз, а не каждое имя в ней.
    t.assert_equals(
        lowered(function()
            g.log.scrub('a=1 b=2')
        end),
        1
    )
end

g.test_patterns_run_only_where_they_can_match = function()
    local function cost(text)
        return spied(function()
            g.log.scrub(text)
        end)
    end

    -- Ни `=`, ни `:` — ни адреса, ни пары: строка не проходит ничем.
    t.assert_equals(cost('storage-001-a'), { lower = 0, gsub = 0, gmatch = 0 })
    -- Двоеточие без `://` и `@`: адресов нет, подсказки нет — пар не ищут.
    t.assert_equals(cost('время 12:30'), { lower = 1, gsub = 1, gmatch = 0 })
    t.assert_equals(cost('a=1 b=2'), { lower = 1, gsub = 1, gmatch = 0 })
    -- `://` без `@` и `@` без `://`: каждый адрес ищется только своим знаком.
    t.assert_equals(cost('http://db:3301/x'), { lower = 1, gsub = 2, gmatch = 0 })
    t.assert_equals(cost('storage:x@h'), { lower = 1, gsub = 2, gmatch = 0 })
    -- Подсказка есть: строка, имя пары дважды (подсказка и `authorization`)
    -- и слово значения — на случай схемы.
    t.assert_equals(cost('token=1'), { lower = 4, gsub = 2, gmatch = 1 })
end

g.test_strings_and_long_names_are_not_remembered = function()
    g.log.secret('password')

    -- Строки проверяются без памяти: иначе тысяча строк вытеснила бы
    -- из неё настоящие имена и держала бы в памяти сами строки.
    for index = 1, 1100 do
        g.log.scrub(('k%d=1 token=%d'):format(index, index))
        shown(('ключ %d: token=1'):format(index))
    end

    t.assert_equals(
        lowered(function()
            g.log.secret('password')
        end),
        0,
        'имя не вытеснено строками'
    )

    local longest = string.rep('k', 128)
    local longer = longest .. 'k'

    g.log.secret(longest)
    g.log.secret(longer)

    t.assert_equals(
        lowered(function()
            g.log.secret(longest)
            g.log.secret(longer)
        end),
        1,
        'помнится имя в 128 байт, а в 129 — нет'
    )
end

g.test_names_that_are_not_strings_are_not_remembered = function()
    t.assert_equals(
        lowered(function()
            g.log.secret(7)
            g.log.secret(7)
        end),
        2
    )
end

g.test_the_memory_of_names_is_cleared_when_full = function()
    for index = 1, 1024 do
        g.log.secret('name' .. index)
    end

    t.assert_equals(
        lowered(function()
            g.log.secret('name1')
        end),
        0,
        'полная память ещё помнит первое имя'
    )

    g.log.secret('name1025')

    t.assert_equals(
        lowered(function()
            g.log.secret('name1')
        end),
        1,
        'переполненная память забыла всё'
    )
end

g.test_public_secret_follows_the_list = function()
    t.assert_equals(g.log.secret('db_password'), true)
    t.assert_equals(g.log.secret('X-Api-Key'), true)
    t.assert_equals(g.log.secret('host'), false)
    t.assert_equals(g.log.secret(nil), false)

    g.log.secret_hints = { 'api.key' }

    t.assert_equals(g.log.secret('api.key'), true)
    t.assert_equals(g.log.secret('apiXkey'), false)
    t.assert_equals(g.log.secret('password'), false)
end

g.test_public_scrub_follows_the_list = function()
    t.assert_equals(
        g.log.scrub('postgres://root:hunter2@db:5432/main'),
        'postgres://root:' .. HIDDEN .. '@db:5432/main'
    )
    t.assert_equals(
        g.log.scrub('/enter?login=ivan&token=abc&page=2'),
        '/enter?login=ivan&token=' .. HIDDEN .. '&page=2'
    )
    t.assert_equals(g.log.scrub('http://tarantool:3301/logs@main'), 'http://tarantool:3301/logs@main')
    t.assert_equals(g.log.scrub('http://db/users:7@list'), 'http://db/users:7@list')
    t.assert_equals(g.log.scrub('http://:hunter2@db'), 'http://:' .. HIDDEN .. '@db')
    t.assert_equals(g.log.scrub('http://root:@db'), 'http://root:@db')
    t.assert_equals(g.log.scrub('/enter?token=&page=2'), '/enter?token=&page=2')
    t.assert_equals(g.log.scrub('/enter?api-key=abc'), '/enter?api-key=' .. HIDDEN)
    t.assert_equals(g.log.scrub(7), 7)
    t.assert_equals(g.log.scrub(nil), nil)

    g.log.secret_hints = { 'door' }

    t.assert_equals(g.log.scrub('/x?door=1&token=2'), '/x?door=' .. HIDDEN .. '&token=2')
end

g.test_a_one_letter_hint_hides_a_one_letter_name = function()
    -- Подсказку задаёт приложение, и она бывает из одной буквы: имя пары
    -- из одного знака образец обязан видеть так же, как длинное.
    g.log.secret_hints = { 'k' }

    t.assert_equals(g.log.scrub('k=1 x'), 'k=' .. HIDDEN .. ' x')
    t.assert_equals(g.log.scrub('a k: 2'), 'a k: ' .. HIDDEN)
end

g.test_an_address_without_a_scheme_hides_its_password = function()
    -- Так адрес пишут репликация и advertise, и так он попадает в отказ.
    local hidden = {
        ['replicator:hunter2@127.0.0.1:3301'] = 'replicator:' .. HIDDEN .. '@127.0.0.1:3301',
        ['connect to storage:hunter2@10.0.0.5:3301 failed'] = 'connect to storage:'
            .. HIDDEN
            .. '@10.0.0.5:3301 failed',
        ['uri="replicator:hunter2@h"'] = 'uri="replicator:' .. HIDDEN .. '@h"',
        ['(storage:pa:ss@h)'] = '(storage:' .. HIDDEN .. '@h)',
        ['{"uri":"storage:hunter2=@h"}'] = '{"uri":"storage:' .. HIDDEN .. '@h"}',
        ['a,b-c.d_e:hunter2@h'] = 'a,b-c.d_e:' .. HIDDEN .. '@h',
    }

    for given, expected in pairs(hidden) do
        t.assert_equals(g.log.scrub(given), expected, given)
    end
end

g.test_ordinary_journal_text_is_not_taken_for_an_address = function()
    for _, text in ipairs({
        'в 12:30:00 пишет ivan@example.org',
        'узел [fe80::1]:3301 и user@host',
        '/var/lib/tarantool/a:b@c',
        'http://db/users:7@list',
        'http://tarantool:3301/logs@main',
        'ERROR: нет связи с storage@h',
        'git@github.com:org/repo.git',
        'ключ: значение',
        'время=12:30',
        'порт :3301@узел',
        'root:@db',
        'путь db/users:7@list',
    }) do
        t.assert_equals(g.log.scrub(text), text, text)
    end
end

g.test_pairs_with_quotes_spaces_and_colons_are_hidden = function()
    local hidden = {
        ['password="hunter 2" user=ivan'] = 'password="' .. HIDDEN .. '" user=ivan',
        ["password='hunter 2'"] = "password='" .. HIDDEN .. "'",
        ['password = hunter2'] = 'password = ' .. HIDDEN,
        ['password: hunter2'] = 'password: ' .. HIDDEN,
        ['password="hunter2'] = 'password="' .. HIDDEN,
        ['X-Api-Key: abc123'] = 'X-Api-Key: ' .. HIDDEN,
        ['Authorization: Bearer hunter2 next'] = 'Authorization: ' .. HIDDEN,
        ['authorization:Basic dXNlcjpwYXNz=='] = 'authorization:' .. HIDDEN,
        ['{"password":"hunter2","user":"ivan"}'] = '{"password":"' .. HIDDEN .. '","user":"ivan"}',
        -- Значение без кавычек идёт через запятую и скобку: пароль
        -- `hun,ter2` целиком — пароль.
        ['{"token": 12345}'] = '{"token": ' .. HIDDEN,
        ['token=hun,ter2 user=ivan'] = 'token=' .. HIDDEN .. ' user=ivan',
        ['user[password]=x&a=b'] = 'user[password]=' .. HIDDEN .. '&a=b',
        ['password: 12 34'] = 'password: ' .. HIDDEN .. ' 34',
        ['token: ab@cd'] = 'token: ' .. HIDDEN,
        ['token=a;b'] = 'token=' .. HIDDEN .. ';b',
        ["token=a'b"] = 'token=' .. HIDDEN .. "'b",
        ['Authorization: Bearer hun-ter.2_~+/=='] = 'Authorization: ' .. HIDDEN,
        ['Authorization: Bearer @x'] = 'Authorization: ' .. HIDDEN,
        ['Authorization=Bearer hunter2'] = 'Authorization=' .. HIDDEN,
        -- Под другим именем-тайной за словом схемы прячется только токен.
        ['X-Token: bearer hunter2 next'] = 'X-Token: ' .. HIDDEN .. ' next',
        ['X-Token: bearer'] = 'X-Token: ' .. HIDDEN,
        ['X-Token: Basic x&y'] = 'X-Token: ' .. HIDDEN .. '&y',
        -- За словом схемы одни пробелы: токена нет, и пробелы остаются.
        ['X-Token: Basic  &y'] = 'X-Token: ' .. HIDDEN .. '  &y',
        ['X-Token: Token x;y'] = 'X-Token: ' .. HIDDEN .. ';y',
        ['X-Token: Negotiate x y'] = 'X-Token: ' .. HIDDEN .. ' y',
        ['X-Token: NTLM x"y'] = 'X-Token: ' .. HIDDEN .. '"y',
        ['X-Token: Digest x'] = 'X-Token: ' .. HIDDEN,
        ['X-Token: Custom x'] = 'X-Token: ' .. HIDDEN .. ' x',
        ['token=a'] = 'token=' .. HIDDEN,
        ['password="a"'] = 'password="' .. HIDDEN .. '"',
    }

    for given, expected in pairs(hidden) do
        t.assert_equals(g.log.scrub(given), expected, given)
    end

    for _, text in ipairs({ 'user = ivan', 'время: 12:30', 'Authorization failed: expired', '{"user":"ivan"}' }) do
        t.assert_equals(g.log.scrub(text), text, text)
    end
end

g.test_a_hidden_string_stays_hidden_when_hidden_again = function()
    for _, text in ipairs({
        'postgres://root:hunter2@db',
        'replicator:hunter2@h',
        'password="hunter 2"',
        'password=hunter2',
        'Authorization: Bearer hunter2',
    }) do
        local once = g.log.scrub(text)

        t.assert_equals(g.log.scrub(once), once, text)
    end
end

g.test_a_string_is_scrubbed_within_a_window = function()
    -- Образцы гоняются по первым 8192 байтам: за окном в запись всё равно
    -- ничего не попадёт.
    local exact = 'password=' .. string.rep('x', 8183)
    local over = exact .. 'x'

    t.assert_equals(shown(exact), 'password=' .. HIDDEN)
    t.assert_equals(last().truncated, nil)
    t.assert_equals(shown(over), 'password=' .. HIDDEN)
    t.assert_equals(last().truncated, true)
end

g.test_public_scrub_cuts_a_string_at_the_window = function()
    t.assert_equals(g.log.scrub(string.rep('x', 8192)), string.rep('x', 8192))
    t.assert_equals(g.log.scrub(string.rep('x', 8193)), string.rep('x', 8192) .. '…')
    -- Строку, которую никто не сверял с UTF-8, срез ищет назад не дальше
    -- трёх байт: дальше знак UTF-8 начинаться не может.
    t.assert_equals(g.log.scrub(string.rep('\x80', 9000)), string.rep('\x80', 8189) .. '…')
end

--- Окно, в котором образцы проходят строку: длиннее окна строка режется
--- до разбора, и квадратичный образец страшен только на всём окне.
local WINDOW = 8192

--- Во сколько раз короткая строка меньше окна.
---
--- Короткие строки меряются пачкой длиной в окно — стороны сравнения
--- равной длины, и у линейного прохода отношение около единицы, а у
--- квадратичного — шестнадцать. Одна короткая строка в восьмую часть
--- окна против окна мигала под нагрузкой: у линейного прохода отношение
--- там восемь, и пауза машины сдвигала его за любую разумную планку.
local SHORT_SHARE = 16

--- Во сколько раз окно может быть дороже пачки коротких строк.
---
--- Линейный проход отличается от квадратичного не абсолютным временем:
--- хук покрытия удорожает проход раз в тридцать, и планка в миллисекундах
--- падала под `--coverage`. Отношение от хука не зависит: он дорожает
--- одинаково с обеих сторон. У линейного прохода оно около единицы,
--- у образцов, сломанных под перебор, — от шестнадцати до сотни с лишним;
--- вчетверо — запас на паузы машины.
local GROWTH = 4

--- Кругов замера: берётся лучший, и пауза машины посреди круга
--- сравнения не портит.
local ROUNDS = 7

--- Строка из повторов куска длиной ровно `size` байт.
---@param unit string
---@param size integer
---@return string
local function filled(unit, size)
    return string.rep(unit, math.ceil(size / #unit)):sub(1, size)
end

--- Строки, на которых образец, написанный небрежно, идёт квадратично.
---
--- Каждая — ровно `size` байт; порядок строк не зависит от длины,
--- и строки одного места в двух списках — один образец разной длины.
---@param size integer
---@return string[]
local function hostile(size)
    local texts = {
        -- Слово без `%f` у имени пары перебиралось бы с каждой позиции.
        'token= ' .. string.rep('a', size - 7),
        -- Пароль адреса с `=` среди разделителей перебирался бы с каждого `=`.
        '@' .. filled('a:=', size - 1),
        '@ ' .. filled('a:a=', size - 2),
        '@=' .. filled('a:=', size - 2),
        'token @' .. filled('=a:', size - 7),
        '@' .. filled('=:', size - 1),
        filled('a:', size - 1) .. '@',
        'token=' .. string.rep('a', size - 6),
        'password="' .. string.rep('a', size - 10),
        'Authorization: ' .. string.rep('a', size - 15),
        'Authorization:' .. string.rep(' ', size - 15) .. '!',
        'password' .. string.rep(' ', size - 8),
        -- Косые перед кавычками считаются назад: каждая — один раз.
        'password="' .. filled('\\"', size - 10),
        'password="' .. string.rep('\\', size - 11) .. '"',
    }

    for _, unit in ipairs({
        'a',
        '=',
        ':',
        '@',
        '/',
        ' ',
        'я',
        'password=',
        'password',
        '"a":"',
        'password: ',
        '://a:',
        'token="',
        'a="token=',
        'token=\'"',
    }) do
        table.insert(texts, filled(unit, size))
    end

    for _, unit in ipairs({ 'a=', 'a ', 'a :', "a':", 'a" =  ', 'a="', 'a="b=\'' }) do
        table.insert(texts, 'token ' .. filled(unit, size - 6))
    end

    table.insert(texts, '://' .. filled(':', size - 3))

    return texts
end

--- Лучшее время двух дел за `ROUNDS` кругов, в секундах.
---
--- Дела меряются по очереди внутри круга, а не каждое своей серией: поток
--- переезжает между быстрыми и медленными ядрами, и серия, целиком
--- попавшая на медленное ядро, сравнивалась бы с серией на быстром.
---@param first fun()
---@param second fun()
---@return number first_best
---@return number second_best
local function best_pair(first, second)
    local clock = require('clock')
    local first_best, second_best = math.huge, math.huge

    --- Секунды одного дела.
    ---@param work fun()
    ---@return number
    local function timed(work)
        local started = clock.monotonic()

        work()

        return clock.monotonic() - started
    end

    for _ = 1, ROUNDS do
        first_best = math.min(first_best, timed(first))
        second_best = math.min(second_best, timed(second))
    end

    return first_best, second_best
end

--- Текст отказа с замерами в миллисекундах: без чисел плавающий отказ
--- не отличить от настоящего.
---@param what string Что мерили
---@param base number Секунды мерила: пачки коротких строк либо окна
---@param grown number Секунды того, что сверяется с мерилом
---@return string
local function growth_shown(what, base, grown)
    return ('%s: мерило %.3f мс, сверяемое %.3f мс, рост в %.1f раза при планке %d'):format(
        what,
        base * 1000,
        grown * 1000,
        grown / base,
        GROWTH
    )
end

--- Дело, которое проходит каждую строку списка одним действием.
---@param act fun(text: string)
---@param texts string[]
---@return fun()
local function over(act, texts)
    return function()
        for _, text in ipairs(texts) do
            act(text)
        end
    end
end

g.test_hostile_strings_are_scrubbed_in_linear_time = function()
    local short = hostile(WINDOW / SHORT_SHARE)
    local long = hostile(WINDOW)
    local scrub = function(text)
        g.log.scrub(text)
    end

    for index, text in ipairs(long) do
        local batch = {}

        for _ = 1, SHORT_SHARE do
            table.insert(batch, short[index])
        end

        local what = text:sub(1, 24)
        local by_scrub, by_scrub_long = best_pair(over(scrub, batch), over(scrub, { text }))

        t.assert_lt(by_scrub_long, GROWTH * by_scrub, growth_shown('scrub ' .. what, by_scrub, by_scrub_long))

        local by_field, by_field_long = best_pair(over(shown, batch), over(shown, { text }))

        t.assert_lt(by_field_long, GROWTH * by_field, growth_shown('поле ' .. what, by_field, by_field_long))
    end

    -- Строка длиннее окна проходит образцами только в окне: мегабайт
    -- стоит столько же, сколько окно.
    local window = '@' .. filled('a:=', WINDOW)
    local megabyte = '@' .. filled('a:=', 1024 * 1024)
    local both = function(text)
        g.log.scrub(text)
        shown(text)
    end
    local by_window, by_megabyte = best_pair(over(both, { window }), over(both, { megabyte }))

    t.assert_lt(
        by_megabyte,
        GROWTH * by_window,
        growth_shown('мегабайт против окна', by_window, by_megabyte)
    )
end

g.test_markers_are_exported = function()
    t.assert_equals(g.log.HIDDEN, '[скрыто]')
    t.assert_equals(g.log.CYCLE, '[кольцо]')
end
