#ifndef ZIG_BROWSER_SDL2_H
#define ZIG_BROWSER_SDL2_H

#if defined(ZB_ENABLE_SDL) && ZB_ENABLE_SDL
#include <SDL2/SDL.h>
#define ZB_HAS_SDL2 1
#else
#define ZB_HAS_SDL2 0
#endif

#if !ZB_HAS_SDL2
#include <stdint.h>

typedef uint32_t Uint32;
typedef int32_t Sint32;
typedef uint8_t Uint8;

typedef struct SDL_Window SDL_Window;
typedef struct SDL_Renderer SDL_Renderer;
typedef struct SDL_Texture SDL_Texture;

typedef struct SDL_MouseWheelEvent {
    Uint32 type;
    Sint32 x;
    Sint32 y;
    Uint32 direction;
} SDL_MouseWheelEvent;

typedef struct SDL_MouseButtonEvent {
    Uint32 type;
    Uint8 button;
    Uint8 state;
    Uint8 clicks;
    Uint8 padding1;
    Sint32 x;
    Sint32 y;
} SDL_MouseButtonEvent;

typedef struct SDL_WindowEvent {
    Uint32 type;
    Uint8 event;
    Uint8 padding1;
    Uint8 padding2;
    Uint8 padding3;
    Sint32 data1;
    Sint32 data2;
} SDL_WindowEvent;

typedef union SDL_Event {
    Uint32 type;
    SDL_MouseWheelEvent wheel;
    SDL_MouseButtonEvent button;
    SDL_WindowEvent window;
} SDL_Event;

enum {
    SDL_INIT_VIDEO = 0x00000020u,
    SDL_WINDOW_RESIZABLE = 0x00000020u,
    SDL_WINDOWPOS_CENTERED = 0,
    SDL_PIXELFORMAT_ARGB8888 = 372645892u,
    SDL_TEXTUREACCESS_STREAMING = 1,
    SDL_MOUSEWHEEL = 0x403u,
    SDL_MOUSEBUTTONDOWN = 0x401u,
    SDL_WINDOWEVENT = 0x200u,
    SDL_WINDOWEVENT_RESIZED = 0x05u,
    SDL_QUIT = 0x100u,
};

static inline int SDL_Init(Uint32 flags) {
    (void)flags;
    return -1;
}

static inline void SDL_Quit(void) {}

static inline SDL_Window *SDL_CreateWindow(
    const char *title,
    int x,
    int y,
    int w,
    int h,
    Uint32 flags
) {
    (void)title;
    (void)x;
    (void)y;
    (void)w;
    (void)h;
    (void)flags;
    return (SDL_Window *)0;
}

static inline void SDL_DestroyWindow(SDL_Window *window) { (void)window; }

static inline SDL_Renderer *SDL_CreateRenderer(SDL_Window *window, int index, Uint32 flags) {
    (void)window;
    (void)index;
    (void)flags;
    return (SDL_Renderer *)0;
}

static inline void SDL_DestroyRenderer(SDL_Renderer *renderer) { (void)renderer; }

static inline SDL_Texture *SDL_CreateTexture(
    SDL_Renderer *renderer,
    Uint32 format,
    int access,
    int w,
    int h
) {
    (void)renderer;
    (void)format;
    (void)access;
    (void)w;
    (void)h;
    return (SDL_Texture *)0;
}

static inline void SDL_DestroyTexture(SDL_Texture *texture) { (void)texture; }

static inline int SDL_UpdateTexture(
    SDL_Texture *texture,
    const void *rect,
    const void *pixels,
    int pitch
) {
    (void)texture;
    (void)rect;
    (void)pixels;
    (void)pitch;
    return -1;
}

static inline int SDL_RenderClear(SDL_Renderer *renderer) {
    (void)renderer;
    return -1;
}

static inline int SDL_RenderCopy(
    SDL_Renderer *renderer,
    SDL_Texture *texture,
    const void *srcrect,
    const void *dstrect
) {
    (void)renderer;
    (void)texture;
    (void)srcrect;
    (void)dstrect;
    return -1;
}

static inline void SDL_RenderPresent(SDL_Renderer *renderer) { (void)renderer; }

static inline int SDL_PollEvent(SDL_Event *event) {
    (void)event;
    return 0;
}

static inline const char *SDL_GetError(void) {
    return "SDL2 headers unavailable";
}
#endif

#endif
