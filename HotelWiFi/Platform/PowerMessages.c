#include "PowerMessages.h"
#include <IOKit/IOMessage.h>
/* Public SDK macros are bridged by C because Swift cannot import their macro expansion. */
uint32_t HWSystemWillSleep(void) { return kIOMessageSystemWillSleep; }
uint32_t HWCanSystemSleep(void) { return kIOMessageCanSystemSleep; }
uint32_t HWSystemHasPoweredOn(void) { return kIOMessageSystemHasPoweredOn; }
