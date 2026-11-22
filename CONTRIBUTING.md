# Contributing to Mugen OBS Titlebars

Thanks for helping improve this small OBS Studio Lua script!

[Русский](#по-русски) · [English](#english)

## English

Please search existing issues before opening a new report. For a bug, include:

- OBS Studio version and whether it is installed or portable; Windows version.
- Mugen OBS Titlebars version and the selected color mode.
- The active OBS theme/style (for example, Yami Light).
- Reproduction steps, what happened and what you expected.
- Relevant **OBS log** or the output of **Show advanced settings → Write diagnostics to script log**.

**Privacy:** OBS logs may contain usernames, machine paths, streaming service details or other sensitive values. Review and redact them before posting. Never share streaming keys, passwords or access tokens.

A screenshot can help, but please crop out chat messages, stream keys, viewers' names and other personal details.

For code changes, keep the standalone Lua distribution (no external DLLs or services), respect bilingual RU/EN settings, avoid synchronous Qt/OBS frontend calls from the script timer and test in OBS before claiming a GUI fix. Do not remove the MIT copyright/license notice.

## По-русски

Прежде чем создавать новый Issue, проверьте, не обсуждается ли проблема уже где-нибудь. Для ошибки укажите:

- Версию OBS Studio и тип установки (обычная/портативная), версию Windows.
- Версию Mugen OBS Titlebars и выбранный режим цвета.
- Тему и стиль OBS (например, Yami Light).
- Шаги воспроизведения, фактическое и ожидаемое поведение.
- Журнал OBS или вывод **«Показать дополнительные настройки → Записать диагностику в журнал»**.

**Конфиденциальность:** в журналах OBS могут встречаться имена пользователей, локальные пути и сведения о трансляциях. Перед публикацией проверьте и при необходимости скройте их. Никогда не выкладывайте ключ трансляции, пароли и токены.

Скриншоты полезны, но лучше обрезать чат, имена зрителей и личные данные.

При доработке кода сохраняйте самостоятельный Lua-скрипт без дополнительных DLL/сервисов, русский и английский интерфейс и безопасную работу таймера без синхронных вызовов GUI/OBS frontend. Не удаляйте авторские уведомления MIT.

## License

Contributions are intended to be distributed under the existing [MIT License](LICENSE).
