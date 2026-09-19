#include <stdbool.h>
#include <libultraship/bridge/consolevariablebridge.h>
#include "bootcommands.h"
#include "soh/cvar_prefixes.h"

#ifdef __IOS__
#include "ios/HarkinianPadTouchControls.h"
#endif

void BootCommands_Init() {
    // Clears vars to prevent randomizer menu from being disabled
    CVarClear(CVAR_GENERAL("RandoGenerating")); // Clear when a crash happened during rando seed generation
    CVarClear(CVAR_GENERAL("NewSeedGenerated"));
    CVarClear(CVAR_GENERAL("OnFileSelectNameEntry")); // Clear when soh is killed on the file name entry page
    CVarClear(CVAR_GENERAL("BetterDebugWarpScreenMQMode"));
    CVarClear(CVAR_GENERAL("BetterDebugWarpScreenMQModeScene"));
#if defined(__SWITCH__) || defined(__WIIU__)
    CVarRegisterInteger(CVAR_IMGUI_CONTROLLER_NAV, 1); // always enable controller nav on switch/wii u
#elif defined(__IOS__)
    CVarSetInteger(CVAR_IMGUI_CONTROLLER_NAV, 1); // controller-first menus on iOS
    CVarRegisterInteger(CVAR_SETTING("HarkinianPad.TouchControls"), 1);
    HarkinianPad_SetTouchControlsEnabled(
        CVarGetInteger(CVAR_SETTING("HarkinianPad.TouchControls"), 1));
    CVarRegisterInteger(CVAR_SETTING("HarkinianPad.TouchControlTransparency"), 0);
    CVarRegisterFloat(CVAR_SETTING("HarkinianPad.TouchControlOpacity"), 0.5f);
    HarkinianPad_SetTouchControlsOpacity(
        CVarGetInteger(CVAR_SETTING("HarkinianPad.TouchControlTransparency"), 0)
            ? CVarGetFloat(CVAR_SETTING("HarkinianPad.TouchControlOpacity"), 0.5f)
            : 1.0f);
    CVarRegisterInteger(CVAR_SETTING("HarkinianPad.LegacyFixedTouchControls"), 0);
    const int modernTouchControls =
        !CVarGetInteger(CVAR_SETTING("HarkinianPad.LegacyFixedTouchControls"), 0);
    CVarSetInteger(CVAR_SETTING("HarkinianPad.CustomizableTouchControls"), modernTouchControls);
    CVarSetInteger(CVAR_SETTING("HarkinianPad.NativeHudTouch"), modernTouchControls);
    HarkinianPad_SetCustomizableTouchControlsEnabled(modernTouchControls);
    HarkinianPad_SetNativeHudTouchEnabled(modernTouchControls);
#endif
}
