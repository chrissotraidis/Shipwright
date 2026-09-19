#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int HarkinianPad_TouchControlsAvailable(void);
void HarkinianPad_SetTouchControlsEnabled(int enabled);
void HarkinianPad_SetCustomizableTouchControlsEnabled(int enabled);
void HarkinianPad_SetTouchControlsOpacity(float opacity);
void HarkinianPad_BeginTouchLayoutEditing(void);
void HarkinianPad_SetTouchControlsMenuVisible(int visible);

enum {
    HARKINIANPAD_HUD_BUTTON_A = 0,
    HARKINIANPAD_HUD_BUTTON_B,
    HARKINIANPAD_HUD_BUTTON_C_UP,
    HARKINIANPAD_HUD_BUTTON_C_DOWN,
    HARKINIANPAD_HUD_BUTTON_C_LEFT,
    HARKINIANPAD_HUD_BUTTON_C_RIGHT,
    HARKINIANPAD_HUD_BUTTON_COUNT,
};

void HarkinianPad_SetNativeHudTouchEnabled(int enabled);
void HarkinianPad_SetNativeHudTouchGameplayActive(int active);
int HarkinianPad_GetNativeHudButtonCenter(int button, float aspectRatio, float* x, float* y);
float HarkinianPad_GetNativeHudButtonScale(int button, float aspectRatio);
int HarkinianPad_GetNativeHudTouchAlpha(int alpha);

#ifdef __cplusplus
}
#endif
