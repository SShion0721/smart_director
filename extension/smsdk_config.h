#pragma once

#define SMEXT_CONF_NAME        "Smart Director NNUE"
#define SMEXT_CONF_DESCRIPTION "Native CPU NNUE batch evaluator for Smart Director"
#define SMEXT_CONF_VERSION     "0.2.0"
#define SMEXT_CONF_AUTHOR      "Sion Gemini"
#define SMEXT_CONF_URL         ""
#define SMEXT_CONF_LOGTAG      "SDNNUE"
#define SMEXT_CONF_LICENSE     "GPL"
#define SMEXT_CONF_DATESTRING  __DATE__

#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

// Pure SourceMod extension: no Metamod or HL2SDK hooks are required.
