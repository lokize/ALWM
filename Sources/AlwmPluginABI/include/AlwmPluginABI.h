#ifndef ALWM_PLUGIN_ABI_H
#define ALWM_PLUGIN_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AlwmHostContextVTable {
    void *userData;
    double (*barScale)(void *userData);
    const char *(*localeUTF8)(void *userData);
    void (*requestBarRefresh)(void *userData);
} AlwmHostContextVTable;

typedef struct AlwmPluginVTable {
    void *userData;
    int32_t apiVersion;
    const char *pluginID;
    void (*load)(void *userData, const AlwmHostContextVTable *host);
    void (*unload)(void *userData);
    /* Returns +1 retained NSView*, or NULL. */
    void *(*barItem)(void *userData, int32_t placement);
    const char *(*barSignature)(void *userData);
    void (*destroy)(void *userData);
} AlwmPluginVTable;

typedef AlwmPluginVTable *(*alwm_plugin_create_fn)(void);

#ifdef __cplusplus
}
#endif

#endif /* ALWM_PLUGIN_ABI_H */
