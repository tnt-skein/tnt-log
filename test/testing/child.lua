--- Ребёнок-процесс: сценарий отдельным Tarantool ради настоящего журнала
--- и настоящего конца процесса.
---
--- Настоящий журнал ядра в процессе проверок не прочитать: его уже настроил
--- luatest, а `log.cfg{log=...}` на ходу ядро запрещает. Поэтому то, что
--- пишет само ядро, проверяется в дочернем процессе: сценарий настраивает
--- журнал в файл своего каталога, пишет и выходит, а проверка читает файл.
--- Так же проверяется сам конец процесса — код выхода, сигнал: аварийный
--- сторож роняет процесс, и показать это можно только со стороны.
---
--- Исходники подставляются в `package.loaded` первыми строками сценария
--- и абсолютными путями: иначе загрузчик `.rocks` подсунул бы установленную
--- копию, и проверка шла бы против вчерашнего кода.

local fio = require('fio')
local popen = require('popen')
local t = require('luatest')

local files = require('tnt.testing.files')

local Module = {}

--- Сколько ждать очередной порции потока ошибок, в секундах.
---
--- Ребёнок, замолчавший на минуту, — зависший ребёнок; ждать его дольше
--- значит ждать до конца гейта.
Module.READ_TIMEOUT = 60

---@class TntTestingOutcome
---@field dir string Каталог сценария; удаляет его проверка
---@field status table Ответ `popen:wait()`: `state` и `exit_code`
---@field said string Поток ошибок целиком

--- Выполняет сценарий отдельным процессом Tarantool и отдаёт исход:
--- каталог сценария, как процесс кончился и что сказал в поток ошибок.
---
--- Сценарий, который обязан кончиться хорошо, гоняет `run`.
---@param preload TntTestingSource[] Исходники в порядке зависимостей
---@param body string Текст сценария; его каталог — переменная `DIR`
---@return TntTestingOutcome
function Module.spawn(preload, body)
    local dir = fio.tempdir()
    local lines = { ('local DIR = %q'):format(dir) }

    for _, module in ipairs(preload) do
        table.insert(lines, ('package.loaded[%q] = dofile(%q)'):format(module.name, fio.abspath(module.path)))
    end

    table.insert(lines, body)
    table.insert(lines, 'os.exit(0)')

    local script = fio.pathjoin(dir, 'scenario.lua')

    files.write(script, table.concat(lines, '\n'))

    local child = popen.new({ arg[-1], script }, { stdout = popen.opts.DEVNULL, stderr = popen.opts.PIPE })
    local said = {}

    -- Поток ошибок читается до конца прежде ожидания: заполненная труба
    -- остановила бы ребёнка, и ожидание не кончилось бы никогда.
    repeat
        local chunk = child:read({ stderr = true, timeout = Module.READ_TIMEOUT })

        table.insert(said, chunk or '')
    until chunk == nil or chunk == ''

    local status = child:wait()

    child:close()

    return { dir = dir, status = status, said = table.concat(said) }
end

--- Выполняет сценарий, который обязан кончиться хорошо, и отдаёт его каталог.
---
--- Ненулевой код выхода — отказ проверки, и в нём — всё, что ребёнок сказал
--- в поток ошибок: иначе падение сценария пришлось бы искать по каталогу.
---@param preload TntTestingSource[] Исходники в порядке зависимостей
---@param body string Текст сценария; его каталог — переменная `DIR`
---@return string dir Каталог сценария; удаляет его проверка
function Module.run(preload, body)
    local outcome = Module.spawn(preload, body)

    t.assert_equals(outcome.status.exit_code, 0, outcome.said)

    return outcome.dir
end

return Module
