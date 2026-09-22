--- Общие средства проверок журнала: исходники, оснастка и записи, на которых
--- он проверяется, — тайны на своих местах, служебные имена полей и значения,
--- на которых ломается встроенный журнал.
---
--- Записи общие для проверки в процессе и для дочернего процесса
--- с настоящим журналом ядра: ребёнок берёт этот файл по абсолютному пути
--- (`PATH`). Переписанный в две копии набор однажды разошёлся бы, и одна
--- из проверок молча перестала бы проверять новое место тайны. Поэтому
--- оснастку файл берёт лениво, при первом обращении: ребёнку она не нужна,
--- и подставить её там некому.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.context` и `tnt.external` — берутся из `.rocks` обычным
--- `require`: проверяется этот пакет, а не они. Оснастка в `test/testing/`
--- грузится так же и один раз на процесс: второй экземпляр загрузчика
--- не знал бы, что вытеснил первый, и не вернул бы вытесненное на место.

local fio = require('fio')

local Module = {}

--- Этот файл абсолютным путём: ребёнок-процесс берёт записи по нему.
Module.PATH = fio.abspath(
    assert(debug.getinfo(1, 'S'), 'нет отладочной информации о файле').source:sub(2)
)

--- Модули пакета в порядке зависимостей.
Module.MODULES = {
    { name = 'tnt.log.plain', path = 'tnt/log/plain.lua' },
    { name = 'tnt.log', path = 'tnt/log.lua' },
}

--- Модули оснастки в порядке зависимостей.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.files', path = 'test/testing/files.lua' },
    { name = 'tnt.testing.child', path = 'test/testing/child.lua' },
}

--- Оснастка проверок, взятая при первом обращении.
---@type table|nil
local tooling = nil

--- Оснастка проверок под теми именами, что зовёт помощник: загрузчик
--- исходников, ребёнок-процесс и файлы.
---@return table
local function testing()
    if tooling == nil then
        for _, module in ipairs(TESTING) do
            if package.loaded[module.name] == nil then
                local chunk, failure = loadfile(fio.abspath(module.path))

                if chunk == nil then
                    error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
                end

                package.loaded[module.name] = chunk()
            end
        end

        tooling = {
            load_sources = package.loaded['tnt.testing.sources'].load,
            unload_sources = package.loaded['tnt.testing.sources'].unload,
            module = package.loaded['tnt.testing.sources'].module,
            run_script = package.loaded['tnt.testing.child'].run,
            read_file = package.loaded['tnt.testing.files'].read,
        }
    end

    return tooling
end

--- Фасад журнала из исходников.
---
--- Заново на каждую проверку: подменённые средства и память проверенных
--- имён живут в модуле, и не загруженный заново модуль принёс бы их
--- в следующую проверку.
---@return table
function Module.load()
    return testing().load_sources(Module.MODULES, 'tnt.log')
end

--- Убирает загруженное и возвращает то, что оно вытеснило: соседи, взятые
--- раньше, держат прежний журнал.
function Module.unload()
    testing().unload_sources(Module.MODULES)
end

--- Контекст файбера — установленная копия, которую берёт и фасад.
---
--- Тот же экземпляр, что берёт фасад: область, открытая в проверке, иначе
--- не дошла бы до записи.
---@return table
function Module.context()
    return testing().module('tnt.context')
end

--- Выполняет сценарий отдельным процессом Tarantool с исходниками фасада
--- и отдаёт его каталог; каталог сценария — переменная `DIR`.
---@param body string
---@return string dir
function Module.run_script(body)
    return testing().run_script(Module.MODULES, body)
end

--- Содержимое файла целиком.
---@param path string
---@return string
function Module.read_file(path)
    return testing().read_file(path)
end

--- Поля, названные так же, как поля ядра, фасада и прежнего журнала.
Module.SPECIAL = {
    time = 'вчера',
    level = 'ERROR',
    message = 'подменённое',
    msg = 'старое',
    pid = 1,
    cord_name = 'чужой',
    fiber_id = 2,
    fiber_name = 'чужой',
    file = 'чужой.lua',
    line = 3,
    module = 'чужой',
    error_msg = 'чужое',
    ts = 'вчера',
    tag = 'чужой',
    instance = 'чужой',
    instance_name = 'чужой',
    fields = 'вложенное',
    args = 'чужое',
    suppressed = 9,
    truncated = 'да',
}

--- Пишет тайну во всех местах, где она встречается в жизни.
---
--- Записей выходит девятнадцать: последняя серия из трёх — повтор
--- подавлен, и третья запись несёт `suppressed = 1`.
---@param log table Фасад журнала
function Module.write_secrets(log)
    local pool = log.new('tnt.pool')
    ---@type table<string, any>
    local wide = { url = 'postgres://root:hunter2@db' }

    for index = 1, 60000 do
        wide['k' .. index] = index
    end

    pool.warn('m', { password = 'hunter2' })
    pool.warn('m', { db = { password = 'hunter2' } })
    pool.warn('m', { request = { headers = { ['X-Api-Key'] = 'hunter2' } } })
    pool.warn('m', { Authorization = 'Bearer hunter2' })
    pool.warn('m', { PASSWORD = 'hunter2' })
    pool.warn('m', { ['api-key'] = 'hunter2' })
    pool.warn('postgres://root:hunter2@db', { url = 'postgres://root:hunter2@db' })
    pool.warn('m', { path = '/enter?token=hunter2&x=1' })
    pool.warn({ password = 'hunter2' })
    pool.warn('m', {
        object = setmetatable({}, {
            __serialize = function()
                return { password = 'hunter2' }
            end,
        }),
    })
    pool.warn('m', { peers = { 'postgres://root:hunter2@db' } })
    pool.warn('connect to storage:hunter2@10.0.0.5:3301 failed', { uri = 'replicator:hunter2@127.0.0.1:3301' })
    pool.warn('m', {
        body = '{"password":"hunter2"}',
        header = 'Authorization: Bearer hunter2',
        env = 'password = hunter2',
        quoted = 'password="hunter2 и ещё"',
    })
    pool.warn('m', { ['postgres://root:hunter2@db'] = 'down' })
    pool.warn('m', {
        [setmetatable({}, {
            __tostring = function()
                return 'token=hunter2'
            end,
        })] = 1,
    })
    pool.warn('postgres://root:hunter2@db', wide)
    pool.warn(
        'вход {user} с паролем {password} по {url}',
        { user = 'ivan', password = 'hunter2', url = 'postgres://root:hunter2@db' },
        'token=hunter2',
        { password = 'hunter2' }
    )

    local changes = log.changes('tnt.failover')

    changes.warn('token=hunter2', { url = 'postgres://root:hunter2@db' })
    changes.warn('token=hunter2', { url = 'postgres://root:hunter2@db' })
    changes.warn('снова postgres://root:hunter2@db', { token = 'hunter2' })
end

--- Тайны за парой с безобидным именем.
---
--- Значение безобидной пары обязано не поглощать то, что за ним: адрес
--- в `url=…` или текст за `error:` сами несут пару-тайну.
Module.SWALLOWED = {
    'request failed: https://api.example.com/v1/users?access_token=hunter2',
    'GET https://api.example.com/v1/users?access_token=hunter2 failed: timeout',
    'url=https://api.example.com/v1?api_key=hunter2',
    'redirect_uri=https://app/cb?token=hunter2',
    'next=/login?token=hunter2',
    'url: https://api/x?api_key=hunter2',
    '{"url":"https://h/?token=hunter2"}',
    'db:password=hunter2',
    'error: password=hunter2',
    'error:password=hunter2',
    'config: token=hunter2',
    'webhook=https://hooks.example.com/services?secret=hunter2&x=1',
    'connect to http://storage:hunter2@10.0.0.5 failed',
    'status=401 url=/enter?token=hunter2',
    'status:401 path:/enter?token=hunter2',
    'Location: https://app/cb#access_token=hunter2&token_type=bearer',
    'Referer: https://app/page?session_token=hunter2',
    'curl error: http://u:p@h/?token=hunter2',
}

--- Тайны, которые прятало прежнее правило пакета отказов: значение идёт
--- через запятую и скобку, а в имени бывают скобки, косая черта
--- и двоеточие.
Module.FORMERLY_HIDDEN = {
    'password=hun,hunter2',
    'password=hun}hunter2',
    'http://user:pw@host/p?token=hunter2',
    'secret(1)=hunter2',
    'token/x=hunter2',
    'x:token=hunter2',
    'ns:password=hunter2',
}

--- Пароль с `@` в паре за двоеточием: образец адреса без схемы видит в нём
--- логин и пароль и, спрятав их раньше пары, съел бы её имя.
Module.AT_IN_VALUE = {
    'db:password=p@hunter2',
    'error:password=p@hunter2',
    'config:token=ab@hunter2',
    'error: db:password=p@hunter2',
    'x:y:password=p@hunter2',
    'path:x?token=ab@hunter2',
    '{db:password=p@hunter2}',
    'redis:password=P@ss:hunter2',
}

--- Заголовок авторизации со схемами, которых нет в списке схем, и без схемы.
Module.AUTHORIZATION = {
    'Authorization: OAuth hunter2',
    'Authorization: ApiKey hunter2',
    'Authorization: Bot hunter2',
    'Authorization: Bearer hunter2',
    'Authorization: Basic hunter2',
    'Authorization: hunter2',
    'Authorization:Bot hunter2',
    'Proxy-Authorization: SSWS hunter2',
}

--- Пароль из многих слов: утечка любого слова видна по `hunter2`.
Module.WORDS = 'hunter2' .. string.rep(' hunter2', 1499)

--- Пишет тайны, которые прячутся не по одному образцу: за безобидной
--- парой, в незакрытой кавычке и в кавычке, закрытой за окном вырезания.
---
--- Записей выходит сорок четыре, все от журнала `tnt.pool`: каждая
--- строка из списков идёт и сообщением, и полем.
---@param log table Фасад журнала
function Module.write_disguised(log)
    local pool = log.new('tnt.pool')

    for _, list in ipairs({ Module.SWALLOWED, Module.FORMERLY_HIDDEN, Module.AT_IN_VALUE, Module.AUTHORIZATION }) do
        for _, text in ipairs(list) do
            pool.warn(text, { reason = text })
        end
    end

    pool.warn('незакрытая', { quoted = 'password="' .. Module.WORDS })
    pool.warn(
        'закрытая за окном',
        { quoted = string.rep('a', 4000) .. ' password="' .. Module.WORDS .. '"' }
    )
    pool.warn('ключ за окном', { body = '{"private_key":"' .. Module.WORDS .. '"}' })
end

--- Пишет значения, на которых встроенный журнал без фасада ломается или
--- портит запись, и одну обычную запись после них.
---
--- Записей выходит десять, все от журнала `tnt.pool`.
---@param log table Фасад журнала
function Module.write_worst(log)
    local pool = log.new('tnt.pool')
    local ring = {}
    local deep = {}
    local wide = {}
    local at = deep

    ring.self = ring

    for _ = 1, 200 do
        at.x = {}
        at = at.x
    end

    for index = 1, 60000 do
        wide['k' .. index] = index
    end

    pool.warn('кольцо', { ring = ring })
    pool.warn('глубина', deep)
    pool.warn('строка 1 МБ', { blob = string.rep('я', 512 * 1024) })
    pool.warn(string.rep('я', 600000))
    pool.warn('широкая', wide)
    pool.warn(string.rep('\1', 5000), { x = string.rep('\1', 5000) })
    pool.warn('числа', { nan = 0 / 0, inf = math.huge, ninf = -math.huge })
    pool.warn('байты', { bad = '\xff' })
    pool.warn('большое целое', { big = 18446744073709551615ULL })
    pool.warn('после больших')
end

return Module
