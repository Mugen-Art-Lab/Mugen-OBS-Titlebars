# Changelog

Notable changes to **Mugen OBS Titlebars**. The versions below are development candidates; **no public GitHub release has been published yet**.

## [1.8.3 BETA] — 2026-11-22

- Adopted the **MIT License**, consistent with other Mugen Art Lab projects; added a copyright/SPDX notice to the Lua source.
- Updated the OBS Scripts description with the clickable **Made by Mugen Art Lab** credit.
- Included `LICENSE` in the distributable ZIP.
- Preserved the existing title-bar engine, automatic matching, live preview and manual color selection.
- Changed the current build label from **TEST** to **BETA** for private pre-release validation.

## [1.8.2 TEST] — 2026-11-22

- Detects the active OBS installation and its own `user.ini`, including standard and portable installations, without fixed machine-specific paths.
- Manual config override remains available.
- Diagnostics can identify whether configuration comes from a portable installation, the standard installation or an override.
- Updated the platform description to **For OBS Studio 32–33 | Windows 11** after initial manual testing on OBS 32.2.2 Portable and 33.0.2.

## [1.8.1 TEST] — 2026-11-22

- Added a clickable Mugen Art Lab website credit to the OBS Scripts description. OBS asks for confirmation before opening the site.

## [1.8 TEST] — 2026-11-22

- Default **Automatic** mode now uses visible OBS palette matching *after* Settings closes to correct cases where `user.ini` still contains an older theme ID.
- Keeps unsaved appearance changes from affecting the native title bar in Automatic mode.
- Retains opt-in Live Preview and manually specified colors.

## Earlier development milestones (1.1–1.7.4)

- Initial Yami caption/text coloring on Windows 11.
- Added safer theme-file parsing, automatic palette discovery and opt-in visible-menu preview.
- Added occlusion-safe retention of the last recognized color.
- Added bilingual Russian/English settings with automatic language selection and contextual advanced settings.
- Corrected several preview and UI-update edge cases during private testing.

**Compatibility notes:** Windows 11 and specific OBS 32/33 builds were manually tested. Custom themes, unusual display/DPI configurations and long sessions require further validation. See [README.md](README.md) or [README_RU.md](README_RU.md) for current requirements and troubleshooting.
