// panel_test.mm  (macOS only)
// Loads the built CLAP, opens its panel through the CLAP GUI extension in an
// offscreen window, renders screenshots, drives the controls with synthetic
// mouse events, checks that edits reach the host as gesture / value events,
// tests the presets and naming, and closes it again. The checks are the
// 10.8.5 build's editor test, through a small shim that looks like its host.
//
//   panel_test <path to the .clap binary> <output dir for PNGs>

#import <Cocoa/Cocoa.h>

#include <clap/clap.h>

#include "Params.h"
#include "Editor.h"

#include <dlfcn.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <algorithm>
#include <vector>

static int failures = 0;
static void check (bool ok, const char* what)
{
    std::printf ("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (! ok) ++failures;
}

static void hpRescan (const clap_host_t*, clap_param_rescan_flags) {}
static void hpClear (const clap_host_t*, clap_id, clap_param_clear_flags) {}
static void hpRequestFlush (const clap_host_t*) {}
static const clap_host_params_t hostParams = { hpRescan, hpClear, hpRequestFlush };
static const void* hGetExt (const clap_host_t*, const char* id) { return ! std::strcmp (id, CLAP_EXT_PARAMS) ? &hostParams : nullptr; }
static void hNoop (const clap_host_t*) {}
static const clap_host_t host = { CLAP_VERSION_INIT, nullptr, "panel_test", "TB", "", "1.0", hGetExt, hNoop, hNoop, hNoop };

// What the plugin reports to the host, counted like the VST host callback did
static int automateCalls = 0, beginCalls = 0, endCalls = 0;
static bool sPush (const clap_output_events_t*, const clap_event_header_t* h)
{
    if (h->type == CLAP_EVENT_PARAM_VALUE) ++automateCalls;
    if (h->type == CLAP_EVENT_PARAM_GESTURE_BEGIN) ++beginCalls;
    if (h->type == CLAP_EVENT_PARAM_GESTURE_END) ++endCalls;
    return true;
}
static const clap_output_events_t outEvents = { nullptr, sPush };
static uint32_t noEvents (const clap_input_events_t*) { return 0; }
static const clap_event_header_t* noGet (const clap_input_events_t*, uint32_t) { return nullptr; }
static const clap_input_events_t emptyIn = { nullptr, noEvents, noGet };

// The shim: e->getParameter / e->setParameter (the host's values are the panel's 0..1)
struct Fx
{
    const clap_plugin_t* p;
    const clap_plugin_params_t* pp;
    float (*getParameter) (Fx*, int);
    void (*setParameter) (Fx*, int, float);
};
static void drain (Fx* e) { e->pp->flush (e->p, &emptyIn, &outEvents); }
static float fxGet (Fx* e, int i)
{
    drain (e);
    double v = 0; e->pp->get_value (e->p, (clap_id) i, &v);
    return (float) v;
}
static void fxSet (Fx* e, int i, float value)
{
    clap_event_param_value_t ev; std::memset (&ev, 0, sizeof (ev));
    ev.header.size = sizeof (ev); ev.header.space_id = CLAP_CORE_EVENT_SPACE_ID; ev.header.type = CLAP_EVENT_PARAM_VALUE;
    ev.param_id = (clap_id) i; ev.value = value; ev.note_id = -1; ev.port_index = -1; ev.channel = -1; ev.key = -1;
    struct L { static uint32_t size (const clap_input_events_t*) { return 1; }
               static const clap_event_header_t* get (const clap_input_events_t* l, uint32_t) { return (const clap_event_header_t*) l->ctx; } };
    clap_input_events_t in = { &ev, L::size, L::get };
    e->pp->flush (e->p, &in, &outEvents);
}
static Fx* gFx = nullptr;

static NSData* renderPNG (NSView* v, const std::string& path)
{
    const NSRect b = [v bounds];
    NSBitmapImageRep* rep = [v bitmapImageRepForCachingDisplayInRect: b];
    [v cacheDisplayInRect: b toBitmapImageRep: rep];
    NSData* png = [rep representationUsingType: NSBitmapImageFileTypePNG properties: [NSDictionary dictionary]];
    [png writeToFile: [NSString stringWithUTF8String: path.c_str()] atomically: YES];
    std::printf ("  wrote %s (%lu bytes)\n", path.c_str(), (unsigned long) [png length]);
    return png;
}

// A mouse event at a point in the panel's (flipped) coordinates; then whatever
// the panel queued goes to the "host", as a real host's flush would
static void mouse (NSWindow* w, NSView* v, NSEventType type, NSPoint panelPt, int clicks = 1)
{
    const NSPoint wp = [v convertPoint: panelPt toView: nil];
    NSEvent* e = [NSEvent mouseEventWithType: type location: wp modifierFlags: 0 timestamp: 0
                                windowNumber: [w windowNumber] context: nil eventNumber: 0
                                  clickCount: clicks pressure: 1.0f];
    if (type == NSEventTypeLeftMouseDown) [v mouseDown: e];
    else if (type == NSEventTypeLeftMouseDragged) [v mouseDragged: e];
    else [v mouseUp: e];
    if (gFx) drain (gFx);
}

static void pump (double secs)
{
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: secs]];
}

// Does the preset file hold this name line?
static bool fileHasLine (const std::string& path, const char* needle)
{
    bool found = false;
    FILE* nf = std::fopen (path.c_str(), "r");
    if (nf)
    {
        char ln[256];
        while (std::fgets (ln, sizeof (ln), nf)) if (std::strstr (ln, needle)) found = true;
        std::fclose (nf);
    }
    return found;
}

int main (int argc, char** argv)
{
    if (argc < 3) { std::printf ("usage: %s <plugin binary> <png dir>\n", argv[0]); return 2; }
    setvbuf (stdout, 0, _IONBF, 0);   // unbuffered, so a crash still shows how far it got
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    const std::string dir = argv[2];

    // Keep the test's presets away from any real ones
    const std::string presetFile = dir + "/test_presets/Presets.txt";
    setenv ("TBCS_PRESET_FILE", presetFile.c_str(), 1);
    std::remove (presetFile.c_str());

    void* lib = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
    if (! lib) { std::printf ("dlopen failed: %s\n", dlerror()); return 1; }
    const clap_plugin_entry_t* entry = (const clap_plugin_entry_t*) dlsym (lib, "clap_entry");
    if (! entry || ! entry->init (argv[1])) { std::printf ("no entry point\n"); return 1; }
    const clap_plugin_factory_t* f = (const clap_plugin_factory_t*) entry->get_factory (CLAP_PLUGIN_FACTORY_ID);
    const clap_plugin_t* plug = f->create_plugin (f, &host, f->get_plugin_descriptor (f, 0)->id);
    if (! plug || ! plug->init (plug)) { std::printf ("create failed\n"); return 1; }
    plug->activate (plug, 44100.0, 1, 4096);
    Fx fx = { plug, (const clap_plugin_params_t*) plug->get_extension (plug, CLAP_EXT_PARAMS), &fxGet, &fxSet };
    Fx* e = &fx;
    gFx = e;

    using namespace tbcs;
    std::printf ("Editor\n");
    const clap_plugin_gui_t* gui = (const clap_plugin_gui_t*) plug->get_extension (plug, CLAP_EXT_GUI);
    check (gui && gui->is_api_supported (plug, CLAP_WINDOW_API_COCOA, false), "plugin has a Cocoa panel");
    uint32_t gw = 0, gh = 0;
    check (gui->create (plug, CLAP_WINDOW_API_COCOA, false) && gui->get_size (plug, &gw, &gh)
           && gw == (uint32_t) kEditorWidth && gh == (uint32_t) kEditorHeight, "editor size as declared");
    NSWindow* win = [[NSWindow alloc] initWithContentRect: NSMakeRect (0, 0, kEditorWidth, kEditorHeight)
                                                styleMask: NSWindowStyleMaskBorderless
                                                  backing: NSBackingStoreBuffered defer: NO];
    NSView* parent = [win contentView];
    clap_window_t cw; cw.api = CLAP_WINDOW_API_COCOA; cw.cocoa = parent;
    check (gui->set_parent (plug, &cw) && gui->show (plug), "set_parent opens the panel");
    check ([[parent subviews] count] == 1, "panel view added to the host's view");
    NSView* panel = [[parent subviews] count] ? [[parent subviews] objectAtIndex: 0] : nil;
    if (! panel) return 1;
    check (NSEqualSizes ([panel frame].size, NSMakeSize (kEditorWidth, kEditorHeight)), "panel has the declared size");

    NSData* pngDefault = renderPNG (panel, dir + "/panel_default.png");
    check ([pngDefault length] > 10000, "panel renders");

    std::printf ("\nControls\n");
    // Drag the Ch 1 VOLUME knob down 50 px: -0.25
    e->setParameter (e, kCh1Volume, 0.5f);
    const float g0 = e->getParameter (e, kCh1Volume);
    automateCalls = beginCalls = endCalls = 0;
    mouse (win, panel, NSEventTypeLeftMouseDown,    NSMakePoint (92, 72));
    mouse (win, panel, NSEventTypeLeftMouseDragged, NSMakePoint (92, 97));
    mouse (win, panel, NSEventTypeLeftMouseDragged, NSMakePoint (92, 122));
    mouse (win, panel, NSEventTypeLeftMouseUp,      NSMakePoint (92, 122));
    const float g1 = e->getParameter (e, kCh1Volume);
    std::printf ("  Ch 1 Volume %.2f -> %.2f\n", g0, g1);
    check (std::fabs (g1 - (g0 - 0.25f)) < 0.02f, "dragging a knob down turns it down");
    check (automateCalls > 0 && beginCalls == 1 && endCalls == 1, "host gets begin / automate / end");

    mouse (win, panel, NSEventTypeLeftMouseDown, NSMakePoint (92, 72), 2);
    mouse (win, panel, NSEventTypeLeftMouseUp,   NSMakePoint (92, 72), 2);
    check (std::fabs (e->getParameter (e, kCh1Volume) - kDefaults[kCh1Volume]) < 1e-6f, "double-click resets a knob");

    // Each knob answers where it is drawn (dragged up from mid-travel)
    {
        const int knobs[13] = { kCh1Volume, kPresence, kCh1Treble, kMiddle, kCh1Bass, kSuzzGain, kSuzzSustain,
                                kCh2Volume, kCh2Treble, kCh2Bass, kMaster, kInput, kOutput };
        const CGFloat kx[13] = { 92, 180, 268, 356, 444, 540, 628, 752, 840, 928, 1100, 170, 250 };
        const CGFloat ky[13] = { 72, 72, 72, 72, 72, 72, 72, 72, 72, 72, 72, 276, 276 };
        bool all = true;
        for (int k = 0; k < 13; ++k)
        {
            e->setParameter (e, knobs[k], 0.5f);
            mouse (win, panel, NSEventTypeLeftMouseDown,    NSMakePoint (kx[k], ky[k]));
            mouse (win, panel, NSEventTypeLeftMouseDragged, NSMakePoint (kx[k], ky[k] - 20));
            mouse (win, panel, NSEventTypeLeftMouseUp,      NSMakePoint (kx[k], ky[k] - 20));
            if (! (e->getParameter (e, knobs[k]) > 0.55f)) { all = false; std::printf ("  knob %d did not turn\n", knobs[k]); }
            e->setParameter (e, knobs[k], kDefaults[knobs[k]]);
        }
        check (all, "all thirteen knobs turn");
    }

    // Rockers: press the top half for on, the bottom half for off
    {
        const int rockers[5] = { kCh1Bright, kCh1On, kCh2Bright, kCh2On, kSpeaker };
        const CGFloat rx[5] = { 230, 340, 770, 880, 60 };
        const CGFloat ry[5] = { 196, 196, 196, 196, 278 };
        bool all = true;
        for (int k = 0; k < 5; ++k)
        {
            mouse (win, panel, NSEventTypeLeftMouseDown, NSMakePoint (rx[k], ry[k] + 8));
            mouse (win, panel, NSEventTypeLeftMouseUp,   NSMakePoint (rx[k], ry[k] + 8));
            const bool off = e->getParameter (e, rockers[k]) < 0.5f;
            mouse (win, panel, NSEventTypeLeftMouseDown, NSMakePoint (rx[k], ry[k] - 8));
            mouse (win, panel, NSEventTypeLeftMouseUp,   NSMakePoint (rx[k], ry[k] - 8));
            const bool on = e->getParameter (e, rockers[k]) >= 0.5f;
            if (! (off && on)) { all = false; std::printf ("  rocker %d did not switch\n", rockers[k]); }
        }
        check (all, "all five rockers switch off (bottom) and on (top)");
        // Showcase settings: Ch 1 bright, both channels on
        e->setParameter (e, kCh1Bright, 1.0f);
        e->setParameter (e, kCh2Bright, 0.0f);
        e->setParameter (e, kCh2On, 1.0f);
    }

    // The Suzz footswitch: each click toggles it
    {
        e->setParameter (e, kSuzzOn, 0.0f);
        mouse (win, panel, NSEventTypeLeftMouseDown, NSMakePoint (584, 192));
        mouse (win, panel, NSEventTypeLeftMouseUp,   NSMakePoint (584, 192));
        const bool on = e->getParameter (e, kSuzzOn) >= 0.5f;
        pump (0.1);
        renderPNG (panel, dir + "/panel_suzz_on.png");
        mouse (win, panel, NSEventTypeLeftMouseDown, NSMakePoint (584, 192));
        mouse (win, panel, NSEventTypeLeftMouseUp,   NSMakePoint (584, 192));
        const bool off = e->getParameter (e, kSuzzOn) < 0.5f;
        check (on && off, "the Suzz footswitch toggles on and off");
    }

    // A knob turned shows in the readout
    mouse (win, panel, NSEventTypeLeftMouseDown,    NSMakePoint (180, 72));
    mouse (win, panel, NSEventTypeLeftMouseDragged, NSMakePoint (180, 52));
    mouse (win, panel, NSEventTypeLeftMouseUp,      NSMakePoint (180, 52));
    renderPNG (panel, dir + "/panel_readout.png");
    e->setParameter (e, kPresence, kDefaults[kPresence]);

    std::printf ("\nPresets\n");
    #define SLOT(k) NSMakePoint (372.0 + (k) * 31.0 + 13.5, 277.0)
    e->setParameter (e, kCh1Bass, 0.3f);
    e->setParameter (e, kSuzzOn, 1.0f);
    pump (0.1);
    mouse (win, panel, NSEventTypeLeftMouseDown, NSMakePoint (337, 277));    // SAVE
    mouse (win, panel, NSEventTypeLeftMouseUp,   NSMakePoint (337, 277));
    mouse (win, panel, NSEventTypeLeftMouseDown, SLOT (2));                   // slot 3
    mouse (win, panel, NSEventTypeLeftMouseUp,   SLOT (2));
    FILE* pf = std::fopen (presetFile.c_str(), "r");
    check (pf != 0, "SAVE then a slot writes the preset file");
    if (pf) std::fclose (pf);

    // Saving opens a name box over the readout
    NSTextField* field = nil;
    for (NSView* sv in [panel subviews]) if ([sv isKindOfClass: [NSTextField class]]) field = (NSTextField*) sv;
    check (field != nil, "saving opens a box to name the preset");
    renderPNG (panel, dir + "/panel_naming.png");
    if (field)
    {
        [field setStringValue: @"A forty character preset name for tests"];   // 40 characters
        [(id) panel controlTextDidChange: nil];
        renderPNG (panel, dir + "/panel_naming_long.png");
        [field setStringValue: @"Gang of Four"];
        [field sendAction: [field action] to: [field target]];       // Return
        pump (0.2);
    }
    check (fileHasLine (presetFile, "name 3: Gang of Four"), "Return saves the name with the preset");
    bool gone = true;
    for (NSView* sv in [panel subviews]) if ([sv isKindOfClass: [NSTextField class]]) gone = false;
    check (gone, "and the name box goes away");
    renderPNG (panel, dir + "/panel_preset_saved.png");

    e->setParameter (e, kCh1Bass, 0.9f);
    e->setParameter (e, kSuzzOn, 0.0f);
    pump (0.1);
    automateCalls = 0;
    mouse (win, panel, NSEventTypeLeftMouseDown, SLOT (2));
    mouse (win, panel, NSEventTypeLeftMouseUp,   SLOT (2));
    check (std::fabs (e->getParameter (e, kCh1Bass) - 0.3f) < 1e-5f
           && e->getParameter (e, kSuzzOn) >= 0.5f, "clicking the slot recalls the saved settings");
    check (automateCalls >= kNumParams, "recall tells the host about every parameter");
    renderPNG (panel, dir + "/panel_preset_loaded.png");

    // Clicking the readout while the preset is in use renames it; Esc keeps the old name
    mouse (win, panel, NSEventTypeLeftMouseDown, NSMakePoint (915, 277));
    mouse (win, panel, NSEventTypeLeftMouseUp,   NSMakePoint (915, 277));
    field = nil;
    for (NSView* sv in [panel subviews]) if ([sv isKindOfClass: [NSTextField class]]) field = (NSTextField*) sv;
    check (field != nil && [[field stringValue] isEqualToString: @"Gang of Four"], "clicking the readout opens the name to edit");
    if (field)
    {
        [field setStringValue: @"Something else"];
        [(id) panel control: field textView: nil doCommandBySelector: @selector (cancelOperation:)];   // Esc
        pump (0.2);
    }
    check (fileHasLine (presetFile, "name 3: Gang of Four"), "Esc keeps the old name");

    const float before = e->getParameter (e, kCh1Bass);
    mouse (win, panel, NSEventTypeLeftMouseDown, SLOT (5));                   // empty slot 6
    mouse (win, panel, NSEventTypeLeftMouseUp,   SLOT (5));
    check (e->getParameter (e, kCh1Bass) == before, "an empty slot changes nothing");

    std::printf ("\nHost automation shows on the panel\n");
    NSData* pngBefore = renderPNG (panel, dir + "/panel_before_host.png");
    e->setParameter (e, kCh2Volume, 0.9f);
    e->setParameter (e, kCh2Bright, 1.0f);
    pump (0.3);
    NSData* pngAfter = renderPNG (panel, dir + "/panel_changed.png");
    check (! [pngAfter isEqualToData: pngBefore], "panel redraws after host changes");

    // Showcase: a typical setting with the Suzz on, Ch 1 Volume shown in the readout
    {
        e->setParameter (e, kSuzzOn, 1.0f);
        e->setParameter (e, kCh1Bass, 0.6f);
        e->setParameter (e, kMiddle, 0.4f);
        e->setParameter (e, kMaster, 0.6f);
        e->setParameter (e, kCh1Treble, 0.55f);
        e->setParameter (e, kPresence, 0.45f);
        e->setParameter (e, kCh2Volume, 0.4f);
        e->setParameter (e, kCh2Bright, 0.0f);
        e->setParameter (e, kCh1Bright, 1.0f);
        mouse (win, panel, NSEventTypeLeftMouseDown,    NSMakePoint (92, 72));
        mouse (win, panel, NSEventTypeLeftMouseDragged, NSMakePoint (92, 52));
        mouse (win, panel, NSEventTypeLeftMouseUp,      NSMakePoint (92, 52));
        pump (0.2);
        renderPNG (panel, dir + "/panel_showcase.png");
    }
    std::printf ("\nClose\n");
    gui->destroy (plug);
    check ([[parent subviews] count] == 0, "destroying the GUI removes the panel");
    check (gui->create (plug, CLAP_WINDOW_API_COCOA, false) && gui->set_parent (plug, &cw) && [[parent subviews] count] == 1, "reopens");
    gui->destroy (plug);
    gFx = nullptr;
    plug->deactivate (plug);
    plug->destroy (plug);
    entry->deinit();
    [win release];
    [pool release];      // drain before unloading the plugin's code
    dlclose (lib);

    std::printf ("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL PANEL CHECKS PASSED", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
