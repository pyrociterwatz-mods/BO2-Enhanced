/* Shared miniaudio configuration: every unit that includes miniaudio.h must see the same set of backends,
   because ma_device's layout depends on it. */
#pragma once
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_ENGINE
#define MA_NO_NODE_GRAPH
#define MA_NO_RESOURCE_MANAGER
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#define MA_ENABLE_WASAPI
#define MA_ENABLE_DSOUND
#define MA_ENABLE_WINMM
#include "third_party/miniaudio-0.11.26/miniaudio.h"
