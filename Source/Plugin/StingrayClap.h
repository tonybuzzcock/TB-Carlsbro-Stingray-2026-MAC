// StingrayClap.h
// The three entry functions clap-wrapper links into every format.

#pragma once

bool tbcs_entry_init (const char* pluginPath);
void tbcs_entry_deinit();
const void* tbcs_entry_get_factory (const char* factoryId);
