# Workshop text for AD_FIX

Paste these into the Publish dialog. The Title must not start with "test" and the
Summary must not be empty, or the Workshop backend rejects the item.

## Title

AD_FIX - Arma Reforger 1.9 Crash Fix

## Summary (one line)

Repairs Creature Melee AI's StopLoitering override for Arma Reforger 1.9, which otherwise stops the Game module compiling and crashes the Arma Dudes 1 preset.

## Description

Arma Reforger 1.9 added a parameter to StopLoitering:

    void StopLoitering(bool terminateFast, SCR_LoiterCustomAnimData customAnimData = null)

Creature Melee AI still overrides the old single-parameter version, so the whole Game script module fails to compile with:

    CMAI_PersonThrow.c(107): Overloaded function 'StopLoitering' not compatible
    CMAI_CarryPresentation.c(145): Overloaded function 'StopLoitering' not compatible

AD_FIX ships the mod's script set with both overrides updated and forwards the new argument. Creature Melee AI keeps providing all content and assets.

Requirements:
- Creature Melee AI (4FD4A1BD550793F4), enabled.
- Load AD_FIX after Creature Melee AI.
