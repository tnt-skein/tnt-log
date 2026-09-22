rockspec_format = '3.0'

package = 'tnt-log'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-log.git',
    branch = 'main',
}

description = {
    summary = 'Фасад над встроенным log Tarantool: тайны, обезвреживание, потолок записи',
    detailed = [[
        Записи пишет встроенный журнал ядра: log.new(имя модуля), вид json
        или plain, уровни по модулям. Уровень, вид и назначение принадлежат
        ядру и разделу log конфигурации кластера — у пакета настроек нет.

        Фасад отвечает за то, чего ядро не делает: вырезает тайны по имени
        поля и по образцам в строках до передачи в ядро, обезвреживает
        значения (nan, int64, невалидный UTF-8, кольца, глубина, нестроковые
        ключи), держит потолок записи ниже буфера ядра, печатает plain одной
        строкой, подставляет поля в сообщение по имени и подавляет подряд
        идущие повторы. Метод журнала никогда не бросает: запись о беде
        не должна становиться второй бедой.

        В каждую запись кладёт поля контекста файбера из tnt-context:
        опознаватели запроса и трассы верхними полями, прочие ключи объектом
        context. Правило тайн (secret, scrub) отдаётся наружу, чтобы тот,
        кто показывает причину отказа человеку, прятал их тем же правилом.

        Зависит от tnt-context (поля контекста файбера) и tnt-external
        (подмена журнала ядра в проверках). Покрытие строк и убитых
        мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-log',
    issues_url = 'https://github.com/tnt-skein/tnt-log/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'log', 'logging', 'json', 'secrets', 'context' },
}

dependencies = {
    'lua >= 5.1',
    'tnt-context',
    'tnt-external',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.log'] = 'tnt/log.lua',
        ['tnt.log.plain'] = 'tnt/log/plain.lua',
    },
}
