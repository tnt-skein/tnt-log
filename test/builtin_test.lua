--- Тесты фасада против настоящего встроенного журнала ядра.
---
--- В процессе проверок журнал ядра уже настроил luatest, и настоящую запись
--- там не прочитать. Здесь каждый сценарий — отдельный процесс Tarantool:
--- он настраивает журнал в файл, пишет через фасад и выходит, а проверки
--- читают файл — сырыми байтами, строками и разобранным JSON. Так видно то,
--- чего двойник не покажет: что ядро дописывает к записи, где режет буфер
--- и откуда берёт место вызова.

local t = require('luatest')
local fio = require('fio')
local json = require('json')
local utf8 = require('utf8')

local helper = dofile('test/helper.lua')

--- Поля, которые пишет ядро. Список закрытый нарочно: новое поле ядра
--- в следующей версии Tarantool обязано ронять проверку, а не проходить
--- мимо неё.
local CORE_FIELDS = { 'time', 'level', 'pid', 'cord_name', 'fiber_id', 'fiber_name', 'file', 'line', 'module' }

--- Сколько байт в строке журнала ядро держит до перевода строки.
local LINE_LIMIT = 16383

--- Строка, которой начинается каждый сценарий: путь к общим записям.
local PREAMBLE = ('local helper = dofile(%q)\n'):format(helper.PATH)

--- Сценарий json: box.cfg с именем инстанса, общие записи, служебные имена,
--- записи в области контекста, место вызова в горячем цикле при выключенном
--- и включённом JIT.
local JSON_SCENARIO = PREAMBLE
    .. [=[
local fio = require('fio')
local json = require('json')

box.cfg({
    work_dir = DIR,
    instance_name = 'router-001-a',
    log = DIR .. '/journal.log',
    log_format = 'json',
    log_level = 'info',
    memtx_memory = 32 * 1024 * 1024,
})

local log = require('tnt.log')
local pool = log.new('tnt.pool')
local agent = log.changes('tnt.failover')
local marks = { src = debug.getinfo(1, 'S').short_src }

helper.write_worst(log)
helper.write_secrets(log)
helper.write_disguised(log)
require('log').new('tnt.control').info({ password = 'hunter2' })

marks.special = debug.getinfo(1, 'l').currentline + 1
pool.warn('служебные', helper.SPECIAL)
pool.warn('чистая', { a = 1 })
require('log').new('tnt.control').warn({ message = 'подделка', time = 'fake', module = 'spoof' })

local context = require('tnt.context')

for _, name in ipairs({ 'trace_id', 'span_id', 'trace_flags', 'user' }) do
    context.declare(name)
end

context.run({
    request_id = 'r-1',
    trace_id = ('a'):rep(32),
    span_id = ('b'):rep(16),
    trace_flags = '01',
    user = 'ivan',
}, function()
    pool.warn('в области', { a = 1 })
    agent.warn('в серии')
end)
context.run({ request_id = 'r-2' }, function()
    agent.warn('в серии')
    agent.warn('после серии')
end)

marks.hot = debug.getinfo(1, 'l').currentline + 4
for _, mode in ipairs({ 'off', 'on' }) do
    jit[mode]()
    for index = 1, 2000 do
        pool.info('горячий', { index = index, mode = mode })
        agent.info('серия', { index = index, mode = mode })
    end
end

local file = fio.open(DIR .. '/marks.json', { 'O_WRONLY', 'O_CREAT' }, tonumber('644', 8))
file:write(json.encode(marks))
file:close()
]=]

--- Сценарий plain: те же записи без box.cfg и одна запись в области контекста.
local PLAIN_SCENARIO = PREAMBLE
    .. [=[
require('log').cfg({ log = DIR .. '/journal.log', format = 'plain', level = 'info' })

local log = require('tnt.log')
local context = require('tnt.context')

helper.write_worst(log)
helper.write_secrets(log)
helper.write_disguised(log)
require('log').new('tnt.control').info({ password = 'hunter2' })

context.declare('user')
context.run({ request_id = 'r-1', user = 'ivan' }, function()
    log.new('tnt.pool').warn('в области', { a = 1 })
end)
]=]

--- Сценарий уровней: решение фасада сверяется с уровнем модуля у ядра после
--- каждого способа его поменять. Функция ядра зовётся через ffi только здесь:
--- так ловится расхождение, если следующая версия Tarantool поменяет правило.
local LEVELS_SCENARIO = [=[
local ffi = require('ffi')
local fio = require('fio')
local json = require('json')
local log = require('log')
local facade = require('tnt.log')

local SEVERITY = { debug = 7, info = 5, warn = 4, error = 2 }
local calls = 0
local counted = setmetatable({}, {
    __serialize = function()
        calls = calls + 1
        return 1
    end,
})
local results = {}

local function compare(step)
    for _, name in ipairs({ 'tnt.pool', 'tnt.http', 'tnt' }) do
        local logger = facade.new(name)

        for method, severity in pairs(SEVERITY) do
            calls = 0
            logger[method]('проба', { v = counted })
            table.insert(results, {
                step = step,
                name = name,
                method = method,
                facade = calls > 0,
                core = severity <= ffi.C.say_get_module_log_level(name),
            })
        end
    end
end

log.cfg({ log = DIR .. '/journal.log', level = 'info' })
compare('log.cfg')
log.cfg({ modules = { ['tnt.pool'] = 'debug', ['tnt.http'] = 'error' } })
compare('log.cfg modules')
log.level('warn')
compare('log.level')
log.cfg({ modules = box.NULL })
compare('modules = null')
box.cfg({ work_dir = DIR, log_level = 'verbose', log_modules = { ['tnt.http'] = 7, tnt = 'error' } })
compare('box.cfg')

local file = fio.open(DIR .. '/levels.json', { 'O_WRONLY', 'O_CREAT' }, tonumber('644', 8))
file:write(json.encode(results))
file:close()
]=]

local g = t.group('tnt.log.builtin')

--- Каталоги сценариев: json, plain и уровни.
---@type table<string, string>
local dirs = {}

g.before_all(function()
    dirs.json = helper.run_script(JSON_SCENARIO)
    dirs.plain = helper.run_script(PLAIN_SCENARIO)
    dirs.levels = helper.run_script(LEVELS_SCENARIO)
end)

g.after_all(function()
    for _, dir in pairs(dirs) do
        fio.rmtree(dir)
    end
end)

--- Строки файла журнала сценария.
---@param dir string
---@return string[]
local function lines_of(dir)
    local lines = {}

    for line in helper.read_file(fio.pathjoin(dir, 'journal.log')):gmatch('([^\n]*)\n') do
        table.insert(lines, line)
    end

    return lines
end

--- Разобранные записи json с данным сообщением.
---@param message string
---@return table[] records
---@return string[] raw
local function records_with(message)
    local records = {}
    local raw = {}

    for _, line in ipairs(lines_of(dirs.json)) do
        local ok, record = pcall(json.decode, line)

        if ok and record.message == message then
            table.insert(records, record)
            table.insert(raw, line)
        end
    end

    return records, raw
end

--- Единственная запись json с данным сообщением.
---@param message string
---@return table record
---@return string raw
local function only(message)
    local records, raw = records_with(message)

    t.assert_equals(#records, 1, message)

    local record = assert(records[1], message)
    local line = assert(raw[1], message)

    return record, line
end

--- Сколько раз ключ верхнего уровня встречается в сырой строке.
---@param line string
---@param key string
---@return integer
local function occurrences(line, key)
    local _, count = line:gsub('"' .. key .. '":', '')

    return count
end

--- Ключи записи по порядку имён.
---@param record table
---@return string[]
local function keys_of(record)
    local keys = {}

    for key in pairs(record) do
        table.insert(keys, key)
    end

    table.sort(keys)

    return keys
end

--- Поля ядра и названные поля фасада по порядку имён.
---@param ... string
---@return string[]
local function expected_keys(...)
    local keys = { 'message', ... }

    for _, key in ipairs(CORE_FIELDS) do
        table.insert(keys, key)
    end

    table.sort(keys)

    return keys
end

g.test_every_line_is_strict_json_that_fits_the_buffer = function()
    local lines = lines_of(dirs.json)

    t.assert_gt(#lines, 30)

    for index, line in ipairs(lines) do
        local where = ('строка %d: %s'):format(index, line:sub(1, 200))

        t.assert_not_equals(utf8.len(line), nil, where)
        t.assert_equals(line:find('\0', 1, true), nil, where)
        t.assert_le(#line, LINE_LIMIT, where)
        t.assert_equals(line:find(':%s*%-?nan[,}]'), nil, where)
        t.assert_equals(line:find(':%s*%-?inf[,}]'), nil, where)
        t.assert_equals((pcall(json.decode, line)), true, where)
    end
end

g.test_a_record_after_the_big_ones_is_whole = function()
    local record = only('после больших')

    t.assert_equals(record.module, 'tnt.pool')
    t.assert_equals(record.level, 'WARN')
end

g.test_a_record_carries_exactly_the_expected_keys = function()
    local clean = only('чистая')
    local fallback = only('широкая')
    local series = only('снова postgres://root:[скрыто]@db')

    t.assert_equals(keys_of(clean), expected_keys('fields', 'instance_name'))
    t.assert_equals(keys_of(fallback), expected_keys('instance_name', 'truncated'))
    t.assert_equals(keys_of(series), expected_keys('fields', 'instance_name', 'suppressed'))
    t.assert_equals(clean.instance_name, 'router-001-a')
    t.assert_equals(clean.module, 'tnt.pool')
    t.assert_equals(clean.level, 'WARN')
    t.assert_equals(clean.fields, { a = 1 })
    t.assert_equals(series.suppressed, 1)
    t.assert_equals(series.module, 'tnt.failover')
end

g.test_a_filled_message_with_args_reaches_the_file_without_the_secret = function()
    local message = 'вход ivan с паролем [скрыто] по postgres://root:[скрыто]@db'
    local record, line = only(message)

    t.assert_equals(keys_of(record), expected_keys('fields', 'args', 'instance_name'))
    t.assert_equals(
        record.fields,
        { user = 'ivan', password = '[скрыто]', url = 'postgres://root:[скрыто]@db' }
    )
    t.assert_equals(record.args, { 'token=[скрыто]', { password = '[скрыто]' } })
    t.assert_equals(line:find('hunter2', 1, true), nil)

    -- В plain аргументы стоят среди пар фасада, до пар вызывающего.
    local plain = nil

    for _, text in ipairs(lines_of(dirs.plain)) do
        if text:find(message, 1, true) ~= nil then
            plain = text
        end
    end

    t.assert_str_contains(
        plain,
        message .. ' args=["token=[скрыто]",{"password":"[скрыто]"}] password=[скрыто] url='
    )
end

g.test_caller_fields_named_like_the_core_ones_leave_the_core_fields_alone = function()
    local marks = json.decode(helper.read_file(fio.pathjoin(dirs.json, 'marks.json')))
    local special = only('служебные')

    t.assert_str_matches(special.time, '%d%d%d%d%-%d%d%-%d%dT.*')
    t.assert_equals(special.level, 'WARN')
    t.assert_equals(special.module, 'tnt.pool')
    t.assert_equals(special.file, marks.src)
    t.assert_equals(special.line, marks.special)
    t.assert_equals(special.instance_name, 'router-001-a')
    t.assert_equals(special.fields, helper.SPECIAL)
end

g.test_every_top_level_key_is_written_once = function()
    local _, clean = only('чистая')

    for _, key in ipairs({ 'time', 'level', 'message', 'module', 'file', 'line', 'pid', 'instance_name', 'fields' }) do
        t.assert_equals(occurrences(clean, key), 1, key)
    end

    -- Поля контекста ядро тоже пропускает ровно по разу: в его списке
    -- служебных имён их нет.
    local _, traced = only('в области')

    for _, key in ipairs({ 'request_id', 'trace_id', 'span_id', 'trace_flags', 'context' }) do
        t.assert_equals(occurrences(traced, key), 1, key)
    end

    -- Отрицательный контроль: мимо фасада ядро дублирует время и модуль,
    -- и счёт это видит.
    local _, forged = only('подделка')

    t.assert_equals(occurrences(forged, 'time'), 2)
    t.assert_equals(occurrences(forged, 'module'), 2)
end

g.test_a_record_in_an_area_carries_the_context_and_a_record_outside_does_not = function()
    local traced = only('в области')

    t.assert_equals(
        keys_of(traced),
        expected_keys('fields', 'instance_name', 'request_id', 'trace_id', 'span_id', 'trace_flags', 'context')
    )
    t.assert_equals(traced.fields, { a = 1 })
    t.assert_equals(traced.request_id, 'r-1')
    t.assert_equals(traced.trace_id, ('a'):rep(32))
    t.assert_equals(traced.span_id, ('b'):rep(16))
    t.assert_equals(traced.trace_flags, '01')
    t.assert_equals(traced.context, { user = 'ivan' })

    -- Отрицательный контроль: запись вне области — без пяти полей.
    t.assert_equals(keys_of(only('чистая')), expected_keys('fields', 'instance_name'))
end

g.test_a_series_goes_on_across_areas_and_the_record_that_breaks_it_carries_its_own_context = function()
    local repeated = records_with('в серии')

    t.assert_equals(#repeated, 1)
    t.assert_equals(assert(repeated[1]).request_id, 'r-1')

    local broke = only('после серии')

    t.assert_equals(broke.suppressed, 1)
    t.assert_equals(broke.request_id, 'r-2')
    t.assert_equals(broke.context, nil)
end

g.test_plain_prints_the_context_after_the_pairs_of_the_caller = function()
    local found = nil

    for _, line in ipairs(lines_of(dirs.plain)) do
        if line:find('в области', 1, true) ~= nil then
            found = line
        end
    end

    t.assert_str_matches(found, '.* W> в области a=1 request_id=r%-1 context%.user=ivan$')
end

--- Строки, в которых нашлась тайна, — только строки контрольной записи.
---@param lines string[]
---@param control string Как в строке назван журнал контрольной записи
local function assert_only_the_control_leaks(lines, control)
    local leaked = 0

    for _, line in ipairs(lines) do
        if line:find('hunter2', 1, true) ~= nil then
            leaked = leaked + 1

            t.assert_str_contains(line, control)
        end
    end

    -- Контроль: мимо фасада пароль в файл попадает, значит проверка
    -- утечку увидела бы.
    t.assert_equals(leaked, 1)
end

g.test_no_secret_reaches_the_json_file = function()
    assert_only_the_control_leaks(lines_of(dirs.json), '"module": "tnt.control"')
end

g.test_no_secret_reaches_the_plain_file = function()
    assert_only_the_control_leaks(lines_of(dirs.plain), '/tnt.control ')
end

g.test_plain_records_never_glue_together = function()
    local ours = 0

    for index, line in ipairs(lines_of(dirs.plain)) do
        local where = ('строка %d: %s'):format(index, line:sub(1, 200))
        local _, headers = line:gsub('%] main/', '')

        t.assert_not_equals(utf8.len(line), nil, where)
        t.assert_le(#line, LINE_LIMIT, where)
        t.assert_le(headers, 1, where)

        if line:find('/tnt.pool ', 1, true) ~= nil then
            ours = ours + 1
        end
    end

    -- Десять записей худших значений, семнадцать записей тайн, сорок
    -- четыре записи переодетых тайн и одна запись в области от tnt.pool.
    t.assert_equals(ours, 72)
end

g.test_the_call_site_survives_the_hot_loop_with_and_without_jit = function()
    local marks = json.decode(helper.read_file(fio.pathjoin(dirs.json, 'marks.json')))

    for offset, message in ipairs({ 'горячий', 'серия' }) do
        local records = records_with(message)

        t.assert_equals(#records, 4000, message)

        for _, record in ipairs(records) do
            t.assert_equals({ record.file, record.line }, { marks.src, marks.hot + offset - 1 }, message)
        end
    end
end

g.test_the_early_level_check_agrees_with_the_core = function()
    local results = json.decode(helper.read_file(fio.pathjoin(dirs.levels, 'levels.json')))

    t.assert_equals(#results, 60)

    for _, result in ipairs(results) do
        t.assert_equals(result.facade, result.core, ('%s: %s.%s'):format(result.step, result.name, result.method))
    end
end
