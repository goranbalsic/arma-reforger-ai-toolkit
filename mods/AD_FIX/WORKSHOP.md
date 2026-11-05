# Workshop text for AD_FIX

The item was first created with placeholder metadata ("AD_FIX - test" /
"testing" / "test"). The CLI copies that forward, so correct it once in the
Publish dialog; later headless updates keep the corrected fields.

## Title

AD_FIX - Arma Reforger 1.9 Crash Fix

## Summary (one line)

Repairs RHS - Status Quo's SetAuthor and wheel-slot overrides for Arma Reforger 1.9, which otherwise stop the Game module compiling and crash the Arma Dudes 1 preset.

## Description

Arma Reforger 1.9 changed two APIs that RHS - Status Quo 0.16.5237 still uses the old way:

- SCR_EditableEntityComponent.SetAuthor(int) became SetAuthor(int, bool isGM).
- SCR_WheelSlotInfo.m_iWheelIndex was replaced by GetWheelIndex().

Both stop the Game script module compiling. AD_FIX ships patched copies of the two affected RHS files. RHS stays enabled and provides all other content.

Requirements: RHS - Status Quo (595F2BF2F44836FB). Load AD_FIX after it.
